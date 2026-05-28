// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IPositionManagerLP} from "../../interfaces/manager/base/IPositionManagerLP.sol";
import {ITransferGuard} from "../../interfaces/guard/ITransferGuard.sol";
import {WithdrawalStrategy} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {PositionManagerBase} from "./PositionManagerBase.sol";
import {PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibOperations} from "../../libs/manager/LibOperations.sol";
import {LibView} from "../../libs/manager/LibView.sol";
import {LibExecutor} from "../../libs/manager/LibExecutor.sol";
import {LibManagerErrors} from "../../libs/manager/LibManagerErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../libs/common/LibCommonErrors.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

/// @title PositionManagerLP
/// @author 3F Protocol
/// @notice Abstract contract handling LP operations (deposit, withdraw, burn) for PositionManager.
/// @dev Inherits PositionManagerBase for roles, fee accrual, and reentrancy protection.
abstract contract PositionManagerLP is IPositionManagerLP, PositionManagerBase {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using LibExecutor for address;
  using LibStorage for PositionManagerStorageData;
  using LibOperations for PositionManagerStorageData;
  using LibView for PositionManagerStorageData;
  using LibView for uint256;
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManagerLP
  /// @dev Reverts with {LibCommonErrors.AmountZero} if both collateral and debt are zero.
  ///      Reverts with {LibManagerErrors.EmptySupplyQueue} if debt is zero but collateral > 0 and supply queue is empty.
  function deposit(uint256 collateral, uint256 debt)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (int256 shares)
  {
    if (collateral == 0 && debt == 0) revert CommonErrors.AmountZero();

    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Accrue fees and get current total assets.
    // Use ERC20.totalSupply() to bypass the nonReadReentrant override on the public totalSupply().
    uint256 totalAssetsBefore = _accrueFees();
    uint256 _totalSupply = ERC20.totalSupply();

    // Pull collateral from caller
    if (collateral > 0) {
      _storage.metadata.collateralAsset.safeTransferFrom(msg.sender, address(this), collateral);
    }

    // Process deposits through supply queue
    if (debt == 0) {
      // No debt: deposit all collateral to first position
      if (collateral > 0) {
        if (_storage.supplyQueue.length == 0) revert LibManagerErrors.EmptySupplyQueue();
        _storage.supplyQueue[0].position.supply(_storage.metadata.collateralAsset, collateral);
      }
    } else {
      // With debt: iterate through queue
      _storage.processDeposit(collateral, debt);
    }

    // Settle shares based on assets delta before any external transfer to keep
    // totalAssets() and totalSupply() consistent during outbound calls.
    shares = _settleShares(totalAssetsBefore, _totalSupply);

    // Send borrowed debt to caller
    if (debt > 0) {
      _storage.metadata.debtAsset.safeTransfer(msg.sender, debt);
    }

    emit Deposit(msg.sender, collateral, debt, shares);
  }

  /// @inheritdoc IPositionManagerLP
  /// @dev Reverts with {LibCommonErrors.AmountZero} if both collateral and debt are zero.
  function withdraw(uint256 collateral, uint256 debt, WithdrawalStrategy strategy)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (int256 shares)
  {
    if (collateral == 0 && debt == 0) revert CommonErrors.AmountZero();

    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Accrue fees and get current total assets.
    // Use ERC20.totalSupply() to bypass the nonReadReentrant override on the public totalSupply().
    uint256 totalAssetsBefore = _accrueFees();
    uint256 _totalSupply = ERC20.totalSupply();

    // Pull debt from caller for repayment
    if (debt > 0) {
      _storage.metadata.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    }

    // Process withdrawals through withdrawal queue using the specified strategy
    // checkLtv=true: proportional withdrawals must respect per-position LTV bounds
    _storage.processWithdrawal(collateral, debt, strategy, true);

    // Settle shares based on assets delta before any external transfer to keep
    // totalAssets() and totalSupply() consistent during outbound calls.
    shares = _settleShares(totalAssetsBefore, _totalSupply);

    // Send collateral to caller
    if (collateral > 0) {
      _storage.metadata.collateralAsset.safeTransfer(msg.sender, collateral);
    }

    emit Withdraw(msg.sender, collateral, debt, shares);
  }

  /// @inheritdoc IPositionManagerLP
  /// @dev Reverts with {LibCommonErrors.AmountZero} if shares is zero.
  function burn(uint256 shares, WithdrawalStrategy strategy)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (uint256 collateral, uint256 debt)
  {
    if (shares == 0) revert CommonErrors.AmountZero();

    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Accrue fees first
    _accrueFees();

    // Use ERC20.totalSupply() to bypass the nonReadReentrant override on the public totalSupply().
    uint256 _totalSupply = ERC20.totalSupply();
    uint256 _totalCollateral = _storage.collateralAmount();
    uint256 _totalDebt = _storage.debtAmount();
    uint256 virtualShareOffset_ = _storage.virtualShareOffset;

    // Calculate proportional amounts to maintain average LTV.
    // Include virtualShareOffset in the denominator so that virtual shares absorb their
    // proportional fraction of collateral/debt, preventing extraction of donated assets
    // that inflate totalAssets without minting shares.
    // Round down collateral (user gets less), round up debt (user repays more)
    collateral = _totalCollateral.mulDiv(shares, _totalSupply + virtualShareOffset_);
    debt = _totalDebt.mulDivUp(shares, _totalSupply + virtualShareOffset_);

    // Burn shares first
    _burn(msg.sender, shares);

    // Pull debt from caller for repayment
    if (debt > 0) {
      _storage.metadata.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    }

    // Process through withdrawal queue using the specified strategy.
    // When the withdrawal queue covers all whitelisted positions, burn amounts are proportional
    // to total debt/collateral so per-position LTV is maintained by construction — skip the check.
    // When the queue is a strict subset, some positions are excluded from the proportional
    // distribution, so queue positions may bear a disproportionate share of the withdrawal
    // and per-position LTV checks are required.
    bool skipLtvCheck = _storage.withdrawalQueue.length == _storage.borrowModules.length();
    _storage.processWithdrawal(collateral, debt, strategy, !skipLtvCheck);

    // Send collateral to caller
    if (collateral > 0) {
      _storage.metadata.collateralAsset.safeTransfer(msg.sender, collateral);
    }

    // Update snapshot for performance fees
    _storage.updateSnapshot();

    emit Burn(msg.sender, shares, collateral, debt);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    SHARE CALCULATIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Settles share changes based on total assets delta.
  ///      Mints shares if assets increased, burns shares if assets decreased.
  /// @param totalAssetsBefore The total assets before the operation
  /// @param _totalSupply The total supply before the operation
  /// @return sharesDelta Positive if shares minted, negative if shares burned
  function _settleShares(uint256 totalAssetsBefore, uint256 _totalSupply) internal returns (int256 sharesDelta) {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    (uint256 totalAssetsAfter,,) = _storage.totalAssets();
    uint256 virtualShareOffset_ = _storage.virtualShareOffset;

    if (totalAssetsAfter > totalAssetsBefore) {
      // Assets increased: mint shares to caller
      uint256 assetsAdded = totalAssetsAfter - totalAssetsBefore;
      uint256 sharesToMint = assetsAdded.convertToShares(_totalSupply, totalAssetsBefore, virtualShareOffset_, false);
      if (sharesToMint > 0) {
        _mint(msg.sender, sharesToMint);
        // Safe: sharesToMint is capped by total supply which fits in uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        sharesDelta = int256(sharesToMint);
      } else {
        // Shares rounded to zero: run the transfer guard since _beforeTokenTransfer won't.
        address guard = _storage.transferGuard;
        if (guard != address(0) && !ITransferGuard(guard).canTransfer(address(this), msg.sender, msg.sender, 0)) {
          revert LibManagerErrors.TransferBlocked();
        }
      }
    } else if (totalAssetsAfter < totalAssetsBefore) {
      // Assets decreased: burn shares from caller
      uint256 assetsRemoved = totalAssetsBefore - totalAssetsAfter;
      uint256 sharesToBurn = assetsRemoved.convertToShares(_totalSupply, totalAssetsBefore, virtualShareOffset_, true);
      _burn(msg.sender, sharesToBurn);
      // Safe: sharesToBurn is capped by total supply which fits in uint128
      // forge-lint: disable-next-line(unsafe-typecast)
      sharesDelta = -int256(sharesToBurn);
    } else {
      // Assets unchanged: no mint/burn, but run the transfer guard since _beforeTokenTransfer won't.
      address guard = _storage.transferGuard;
      if (guard != address(0) && !ITransferGuard(guard).canTransfer(address(this), msg.sender, msg.sender, 0)) {
        revert LibManagerErrors.TransferBlocked();
      }
    }
    // If sharesToMint rounds to 0 or assets are equal, sharesDelta remains 0

    // Update snapshot for performance fees
    _storage.updateSnapshot();
  }
}
