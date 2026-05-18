// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IPositionManager, SupplyQueueEntry} from "../interfaces/manager/IPositionManager.sol";
import {IPositionManagerAdmin} from "../interfaces/manager/base/IPositionManagerAdmin.sol";
import {ITransferGuard} from "../interfaces/guard/ITransferGuard.sol";
import {PositionManagerLP} from "./base/PositionManagerLP.sol";
import {PositionManagerAdmin} from "./base/PositionManagerAdmin.sol";
import {PositionManagerRebalancing} from "./base/PositionManagerRebalancing.sol";
import {
  FeeData,
  PositionManagerMetadata,
  PositionManagerStorageData,
  RebalanceConfig
} from "../libs/manager/LibStorage.sol";
import {LibStorage} from "../libs/manager/LibStorage.sol";
import {LibView} from "../libs/manager/LibView.sol";
import {LibManagerErrors} from "../libs/manager/LibManagerErrors.sol";
import {LibChecks} from "../libs/common/LibChecks.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PositionManager
/// @author 3F Protocol
/// @notice Aggregates multiple borrow positions into a single vault with share-based accounting.
/// @dev Uses supply/withdrawal queues for deposit/withdraw operations, implements fee accrual,
///      and uses virtual share offset for inflation attack protection.
contract PositionManager is
  IPositionManager,
  PositionManagerLP,
  PositionManagerAdmin,
  PositionManagerRebalancing,
  Initializable
{
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using LibStorage for PositionManagerStorageData;
  using LibView for PositionManagerStorageData;
  using LibChecks for address;

  constructor() {
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the PositionManager.
  /// @param owner_ The owner of the contract
  /// @param metadata_ The metadata containing name, symbol, collateral and debt assets
  /// @param ltv_ The LTV for available collateral calculation (WAD precision)
  /// @param transferGuard_ The initial transfer guard address (address(0) to disable)
  /// @param maxRebalanceLoss_ The max rebalance loss in basis points (e.g., 100 = 1%)
  /// @param rebalanceCooldown_ The cooldown period in seconds between rebalance calls (0 = disabled)
  function initialize(
    address owner_,
    PositionManagerMetadata memory metadata_,
    uint256 ltv_,
    address transferGuard_,
    uint16 maxRebalanceLoss_,
    uint40 rebalanceCooldown_
  ) external initializer {
    owner_.checkNotZero();
    _initializeOwner(owner_);
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    _storage.metadata = metadata_;
    _storage.setLtv(ltv_);
    // Compute virtual share offset from debt asset decimals for inflation attack protection.
    // Uses zeroFloorSub to safely handle tokens with >18 decimals (offset becomes 10^0 = 1).
    // Safe: max exponent is 18, so 10^18 = 1e18 fits in uint64 (max ~1.8e19)
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.virtualShareOffset =
      uint64(10 ** FixedPointMathLib.zeroFloorSub(18, ERC20(metadata_.debtAsset).decimals()));
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.lastFeeAccrualTimestamp = uint40(block.timestamp);
    if (transferGuard_ != address(0)) {
      _storage.transferGuard = transferGuard_;
      emit IPositionManagerAdmin.TransferGuardSet(transferGuard_);
    }
    if (maxRebalanceLoss_ > 0 || rebalanceCooldown_ > 0) {
      _storage.setRebalanceConfig(maxRebalanceLoss_, rebalanceCooldown_);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEW                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ERC20
  function name() public view override returns (string memory) {
    return LibStorage.positionManagerStorage().metadata.name;
  }

  /// @inheritdoc ERC20
  function symbol() public view override returns (string memory) {
    return LibStorage.positionManagerStorage().metadata.symbol;
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
    collateralAsset = _storage.metadata.collateralAsset;
    debtAsset = _storage.metadata.debtAsset;
  }

  /// @inheritdoc IPositionManager
  function collateralAmount() public view nonReadReentrant returns (uint256) {
    return LibStorage.positionManagerStorage().collateralAmount();
  }

  /// @inheritdoc IPositionManager
  function collateralAmountQuoted() public view nonReadReentrant returns (uint256) {
    return LibStorage.positionManagerStorage().collateralAmountQuoted();
  }

  /// @inheritdoc IPositionManager
  function debtAmount() public view nonReadReentrant returns (uint256) {
    return LibStorage.positionManagerStorage().debtAmount();
  }

  /// @inheritdoc IPositionManager
  function totalAssets() public view nonReadReentrant returns (uint256 amount) {
    (amount,,) = LibStorage.positionManagerStorage().totalAssets();
  }

  /// @inheritdoc ERC20
  /// @dev Reverts via {nonReadReentrant} when read during a deposit/withdraw/burn so external
  ///      integrators cannot observe a stale supply against a freshly-mutated NAV.
  function totalSupply() public view override nonReadReentrant returns (uint256) {
    return ERC20.totalSupply();
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
  function lastDebt() public view returns (uint256) {
    return LibStorage.positionManagerStorage().lastDebt;
  }

  /// @inheritdoc IPositionManager
  function pendingFees()
    public
    view
    nonReadReentrant
    returns (uint256 totalAssets_, uint256 totalSupply_, uint256 managementFeeShares, uint256 performanceFeeShares)
  {
    (totalAssets_, totalSupply_,, managementFeeShares, performanceFeeShares) = _pendingFees();
  }

  /// @inheritdoc IPositionManager
  function virtualShareOffset() public view returns (uint256) {
    return LibStorage.positionManagerStorage().virtualShareOffset;
  }

  /// @inheritdoc IPositionManager
  function config() public view returns (uint256 ltv, address transferGuard) {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    ltv = _storage.ltv;
    transferGuard = _storage.transferGuard;
  }

  /// @inheritdoc IPositionManager
  function rebalanceConfig()
    public
    view
    returns (uint16 maxRebalanceLoss, uint40 rebalanceCooldown, uint40 lastRebalanceTimestamp)
  {
    RebalanceConfig storage rc = LibStorage.positionManagerStorage().rebalanceConfig;
    maxRebalanceLoss = rc.maxRebalanceLoss;
    rebalanceCooldown = rc.rebalanceCooldown;
    lastRebalanceTimestamp = rc.lastRebalanceTimestamp;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL OVERRIDES                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ERC20
  /// @dev Validates transfers through the transfer guard if one is set.
  ///      Reverts with {LibManagerErrors.TransferBlocked} if the transfer is blocked by the guard.
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
    address guard = LibStorage.positionManagerStorage().transferGuard;
    if (guard != address(0)) {
      if (!ITransferGuard(guard).canTransfer(address(this), from, to, amount)) {
        revert LibManagerErrors.TransferBlocked();
      }
    }
  }
}
