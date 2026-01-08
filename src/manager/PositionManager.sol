// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManager, SupplyQueueEntry} from "../interfaces/manager/IPositionManager.sol";
import {ITransferGuard} from "../interfaces/guard/ITransferGuard.sol";
import {PositionManagerShares} from "./base/PositionManagerShares.sol";
import {PositionManagerAdmin} from "./base/PositionManagerAdmin.sol";
import {PositionManagerRebalancing} from "./base/PositionManagerRebalancing.sol";
import {FeeData, PositionManagerStorageData} from "../libs/manager/LibStorage.sol";
import {LibStorage} from "../libs/manager/LibStorage.sol";
import {LibOperations} from "../libs/manager/LibOperations.sol";
import {LibView} from "../libs/manager/LibView.sol";
import {LibExecutor} from "../libs/manager/LibExecutor.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

/// @title PositionManager
/// @notice Aggregates multiple borrow positions into a single vault with share-based accounting.
/// @dev Uses supply/withdrawal queues for deposit/withdraw operations, implements fee accrual,
///      and uses virtual share offset for inflation attack protection.
contract PositionManager is
  IPositionManager,
  PositionManagerShares,
  PositionManagerAdmin,
  PositionManagerRebalancing,
  Initializable,
  ReentrancyGuardTransient
{
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using LibExecutor for address;
  using LibOperations for PositionManagerStorageData;
  using LibView for PositionManagerStorageData;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Role for minting/burning shares via deposit/withdraw/burn.
  uint256 internal constant MINTER_ROLE = _ROLE_0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the PositionManager.
  /// @param owner_ The owner of the contract
  /// @param name_ The name of the share token
  /// @param symbol_ The symbol of the share token
  /// @param decimals_ The decimals of the share token
  /// @param collateralAsset_ The collateral asset address
  /// @param debtAsset_ The debt asset address
  /// @param lltv_ The LLTV for available collateral calculation (WAD precision)
  function initialize(
    address owner_,
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    address collateralAsset_,
    address debtAsset_,
    uint256 lltv_
  ) external initializer {
    _initializeOwner(owner_);
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();
    ps.name = name_;
    ps.symbol = symbol_;
    ps.decimals = decimals_;
    ps.collateralAsset = collateralAsset_;
    ps.debtAsset = debtAsset_;
    // Safe: lltv_ is WAD precision (1e18 max), which fits in uint64 (max ~1.8e19)
    // forge-lint: disable-next-line(unsafe-typecast)
    ps.lltv = uint64(lltv_);
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    ps.lastFeeAccrualTimestamp = uint40(block.timestamp);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEW                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ERC20
  function name() public view override returns (string memory) {
    return LibStorage.positionManagerStorage().name;
  }

  /// @inheritdoc ERC20
  function symbol() public view override returns (string memory) {
    return LibStorage.positionManagerStorage().symbol;
  }

  /// @inheritdoc ERC20
  function decimals() public view override returns (uint8) {
    return LibStorage.positionManagerStorage().decimals;
  }

  /// @inheritdoc IPositionManager
  function supplyQueue() public view returns (SupplyQueueEntry[] memory) {
    return LibStorage.positionManagerStorage().supplyQueue;
  }

  /// @inheritdoc IPositionManager
  function withdrawalQueue() public view returns (address[] memory) {
    return LibStorage.positionManagerStorage().withdrawalQueue;
  }

  /// @inheritdoc IPositionManager
  function borrowModules() public view returns (address[] memory) {
    return LibStorage.positionManagerStorage().borrowModules.values();
  }

  /// @inheritdoc IPositionManager
  function isBorrowModule(address module) public view returns (bool) {
    return LibStorage.positionManagerStorage().borrowModules.contains(module);
  }

  /// @inheritdoc IPositionManager
  function assets() public view returns (address collateralAsset, address debtAsset) {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();
    collateralAsset = ps.collateralAsset;
    debtAsset = ps.debtAsset;
  }

  /// @inheritdoc IPositionManager
  function collateralAmount() public view returns (uint256) {
    return LibStorage.positionManagerStorage().collateralAmount();
  }

  /// @inheritdoc IPositionManager
  function collateralAmountQuoted() public view returns (uint256) {
    return LibStorage.positionManagerStorage().collateralAmountQuoted();
  }

  /// @inheritdoc IPositionManager
  function debtAmount() public view returns (uint256) {
    return LibStorage.positionManagerStorage().debtAmount();
  }

  /// @inheritdoc IPositionManager
  function totalAssets() public view returns (uint256) {
    return LibStorage.positionManagerStorage().totalAssets();
  }

  /// @inheritdoc IPositionManager
  function feeData()
    public
    view
    returns (
      address feeRecipient,
      uint24 managementFee,
      uint24 performanceFee,
      uint256 lastTotalAssets,
      uint256 lastFeeAccrualTimestamp
    )
  {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();
    FeeData memory fd = ps.feeData;
    feeRecipient = fd.feeRecipient;
    managementFee = fd.managementFee;
    performanceFee = fd.performanceFee;
    lastTotalAssets = ps.lastTotalAssets;
    lastFeeAccrualTimestamp = ps.lastFeeAccrualTimestamp;
  }

  /// @inheritdoc IPositionManager
  function config() public view returns (uint256 lltv, uint16 maxRebalanceLoss, address transferGuard) {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();
    lltv = ps.lltv;
    maxRebalanceLoss = ps.maxRebalanceLoss;
    transferGuard = ps.transferGuard;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManager
  function deposit(uint256 collateral, uint256 debt)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (int256 shares)
  {
    if (collateral == 0 && debt == 0) revert ZeroAmount();

    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();

    // Accrue fees and get current total assets
    uint256 totalAssetsBefore = _accrueFees();
    uint256 _totalSupply = totalSupply();

    // Pull collateral from caller
    if (collateral > 0) {
      ps.collateralAsset.safeTransferFrom(msg.sender, address(this), collateral);
    }

    // Process deposits through supply queue
    if (debt == 0) {
      // No debt: deposit all collateral to first position
      if (collateral > 0) {
        if (ps.supplyQueue.length == 0) revert EmptySupplyQueue();
        ps.supplyQueue[0].position.supply(ps.collateralAsset, collateral);
      }
    } else {
      // With debt: iterate through queue
      ps.processDeposit(collateral, debt);
    }

    // Send borrowed debt to caller
    if (debt > 0) {
      ps.debtAsset.safeTransfer(msg.sender, debt);
    }

    // Settle shares based on assets delta
    shares = _settleShares(totalAssetsBefore, _totalSupply);

    emit Deposit(msg.sender, collateral, debt, shares);
  }

  /// @inheritdoc IPositionManager
  function withdraw(uint256 collateral, uint256 debt)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (int256 shares)
  {
    if (collateral == 0 && debt == 0) revert ZeroAmount();

    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();

    // Accrue fees and get current total assets
    uint256 totalAssetsBefore = _accrueFees();
    uint256 _totalSupply = totalSupply();

    // Pull debt from caller for repayment
    if (debt > 0) {
      ps.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    }

    // Process withdrawals through withdrawal queue
    ps.processWithdrawal(collateral, debt);

    // Send collateral to caller
    if (collateral > 0) {
      ps.collateralAsset.safeTransfer(msg.sender, collateral);
    }

    // Settle shares based on assets delta
    shares = _settleShares(totalAssetsBefore, _totalSupply);

    emit Withdraw(msg.sender, collateral, debt, shares);
  }

  /// @inheritdoc IPositionManager
  function burn(uint256 shares)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (uint256 collateral, uint256 debt)
  {
    if (shares == 0) revert ZeroAmount();

    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();

    // Accrue fees first
    _accrueFees();

    uint256 _totalSupply = totalSupply();
    uint256 _totalCollateral = collateralAmount();
    uint256 _totalDebt = debtAmount();

    // Calculate proportional amounts to maintain average LTV
    // Round down collateral (user gets less), round up debt (user repays more)
    collateral = _totalCollateral.mulDiv(shares, _totalSupply);
    debt = _totalDebt.mulDivUp(shares, _totalSupply);

    // Burn shares first
    _burn(msg.sender, shares);

    // Pull debt from caller for repayment
    if (debt > 0) {
      ps.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    }

    // Process burn through withdrawal queue - withdraws/repays proportionally on each position
    ps.processBurn(collateral, debt, _totalCollateral, _totalDebt);

    // Send collateral to caller
    if (collateral > 0) {
      ps.collateralAsset.safeTransfer(msg.sender, collateral);
    }

    // Update snapshot for performance fees
    _updateSnapshot();

    emit Burn(msg.sender, shares, collateral, debt);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL OVERRIDES                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc PositionManagerAdmin
  function _accrueFeesBeforeFeeDataChange() internal override {
    _accrueFees();
  }

  /// @inheritdoc PositionManagerRebalancing
  function _accrueFeesForRebalance() internal override returns (uint256 totalAssetsBefore) {
    return _accrueFees();
  }

  /// @inheritdoc ERC20
  /// @dev Validates transfers through the transfer guard if one is set.
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
    address guard = LibStorage.positionManagerStorage().transferGuard;
    if (guard != address(0)) {
      if (!ITransferGuard(guard).canTransfer(address(this), from, to, amount)) {
        revert IPositionManager.TransferBlocked();
      }
    }
  }
}
