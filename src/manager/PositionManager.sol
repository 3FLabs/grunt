// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManager, SupplyQueueEntry, RebalancingData} from "../interfaces/manager/IPositionManager.sol";
import {ITransferGuard} from "../interfaces/guard/ITransferGuard.sol";
import {PositionManagerShares} from "./base/PositionManagerShares.sol";
import {PositionManagerAdmin} from "./base/PositionManagerAdmin.sol";
import {PositionManagerRebalancing} from "./base/PositionManagerRebalancing.sol";
import {FeeData, PositionManagerStorageData} from "../libs/manager/LibStorage.sol";
import {LibStorage} from "../libs/manager/LibStorage.sol";
import {LibOperations} from "../libs/manager/LibOperations.sol";
import {LibView} from "../libs/manager/LibView.sol";
import {LibExecutor} from "../libs/manager/LibExecutor.sol";
import {LibErrors} from "../libs/manager/LibErrors.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

/// @title PositionManager
/// @author 3F Protocol
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
  /// @param transferGuard_ The initial transfer guard address (address(0) to disable)
  function initialize(
    address owner_,
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    address collateralAsset_,
    address debtAsset_,
    uint256 lltv_,
    address transferGuard_
  ) external initializer {
    _initializeOwner(owner_);
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    _storage.name = name_;
    _storage.symbol = symbol_;
    _storage.decimals = decimals_;
    _storage.collateralAsset = collateralAsset_;
    _storage.debtAsset = debtAsset_;
    // Safe: lltv_ is WAD precision (1e18 max), which fits in uint64 (max ~1.8e19)
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.lltv = uint64(lltv_);
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.lastFeeAccrualTimestamp = uint40(block.timestamp);
    emit IPositionManager.LLTVSet(lltv_);
    if (transferGuard_ != address(0)) {
      _storage.transferGuard = transferGuard_;
      emit IPositionManager.TransferGuardSet(transferGuard_);
    }
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
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    collateralAsset = _storage.collateralAsset;
    debtAsset = _storage.debtAsset;
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
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    FeeData memory fd = _storage.feeData;
    feeRecipient = fd.feeRecipient;
    managementFee = fd.managementFee;
    performanceFee = fd.performanceFee;
    lastTotalAssets = _storage.lastTotalAssets;
    lastFeeAccrualTimestamp = _storage.lastFeeAccrualTimestamp;
  }

  /// @inheritdoc IPositionManager
  function config() public view returns (uint256 lltv, uint16 maxRebalanceLoss, address transferGuard) {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    lltv = _storage.lltv;
    maxRebalanceLoss = _storage.maxRebalanceLoss;
    transferGuard = _storage.transferGuard;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManager
  /// @dev Reverts with {LibErrors.ZeroAmount} if both collateral and debt are zero.
  ///      Reverts with {LibErrors.EmptySupplyQueue} if debt is zero but collateral > 0 and supply queue is empty.
  function deposit(uint256 collateral, uint256 debt)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (int256 shares)
  {
    if (collateral == 0 && debt == 0) revert LibErrors.ZeroAmount();

    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Accrue fees and get current total assets
    uint256 totalAssetsBefore = _accrueFees();
    uint256 _totalSupply = totalSupply();

    // Pull collateral from caller
    if (collateral > 0) {
      _storage.collateralAsset.safeTransferFrom(msg.sender, address(this), collateral);
    }

    // Process deposits through supply queue
    if (debt == 0) {
      // No debt: deposit all collateral to first position
      if (collateral > 0) {
        if (_storage.supplyQueue.length == 0) revert LibErrors.EmptySupplyQueue();
        _storage.supplyQueue[0].position.supply(_storage.collateralAsset, collateral);
      }
    } else {
      // With debt: iterate through queue
      _storage.processDeposit(collateral, debt);
    }

    // Send borrowed debt to caller
    if (debt > 0) {
      _storage.debtAsset.safeTransfer(msg.sender, debt);
    }

    // Settle shares based on assets delta
    shares = _settleShares(totalAssetsBefore, _totalSupply);

    emit Deposit(msg.sender, collateral, debt, shares);
  }

  /// @inheritdoc IPositionManager
  /// @dev Reverts with {LibErrors.ZeroAmount} if both collateral and debt are zero.
  function withdraw(uint256 collateral, uint256 debt)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (int256 shares)
  {
    if (collateral == 0 && debt == 0) revert LibErrors.ZeroAmount();

    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Accrue fees and get current total assets
    uint256 totalAssetsBefore = _accrueFees();
    uint256 _totalSupply = totalSupply();

    // Pull debt from caller for repayment
    if (debt > 0) {
      _storage.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    }

    // Process withdrawals through withdrawal queue
    _storage.processWithdrawal(collateral, debt);

    // Send collateral to caller
    if (collateral > 0) {
      _storage.collateralAsset.safeTransfer(msg.sender, collateral);
    }

    // Settle shares based on assets delta
    shares = _settleShares(totalAssetsBefore, _totalSupply);

    emit Withdraw(msg.sender, collateral, debt, shares);
  }

  /// @inheritdoc IPositionManager
  /// @dev Reverts with {LibErrors.ZeroAmount} if shares is zero.
  function burn(uint256 shares)
    external
    onlyRoles(MINTER_ROLE)
    nonReentrant
    returns (uint256 collateral, uint256 debt)
  {
    if (shares == 0) revert LibErrors.ZeroAmount();

    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

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
      _storage.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    }

    // Process burn through withdrawal queue - withdraws/repays proportionally on each position
    _storage.processBurn(collateral, debt, _totalCollateral, _totalDebt);

    // Send collateral to caller
    if (collateral > 0) {
      _storage.collateralAsset.safeTransfer(msg.sender, collateral);
    }

    // Update snapshot for performance fees
    _updateSnapshot();

    emit Burn(msg.sender, shares, collateral, debt);
  }

  /// @inheritdoc IPositionManager
  /// @dev Protected by nonReentrant to prevent malicious modules from manipulating
  ///      guard state (pause/unpause) mid-transaction via callbacks.
  function rebalance(RebalancingData calldata data, address receiver)
    public
    override(IPositionManager, PositionManagerRebalancing)
    onlyRoles(REBALANCER_ROLE)
    nonReentrant
    returns (uint256 collateralExcess, uint256 debtExcess)
  {
    return super.rebalance(data, receiver);
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
  ///      Reverts with {LibErrors.TransferBlocked} if the transfer is blocked by the guard.
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
    address guard = LibStorage.positionManagerStorage().transferGuard;
    if (guard != address(0)) {
      if (!ITransferGuard(guard).canTransfer(address(this), from, to, amount)) {
        revert LibErrors.TransferBlocked();
      }
    }
  }
}
