// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "lib/morpho-blue/src/interfaces/IOracle.sol";
import {SharesMathLib} from "../libs/borrow/SharesMathLib.sol";
import {MorphoBalancesLib} from "../libs/borrow/MorphoBalancesLib.sol";
import {LibBorrowErrors} from "../libs/borrow/LibBorrowErrors.sol";
import {LibBorrowOffers} from "../libs/borrow/LibBorrowOffers.sol";
import {MAX_OFFERS, MAX_OFFER_LIFESPAN} from "../libs/borrow/LibBorrowOffersConstants.sol";
import {IBorrowOffersRegistry} from "../interfaces/borrow/IBorrowOffersRegistry.sol";
import {LibChecks} from "../libs/common/LibChecks.sol";
import {LibCommonErrors} from "../libs/common/LibCommonErrors.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {IBorrowPosition} from "../interfaces/borrow/IBorrowPosition.sol";
import {IBorrowOffers, Offer} from "../interfaces/borrow/IBorrowOffers.sol";
import {UtilsLib} from "lib/morpho-blue/src/libraries/UtilsLib.sol";
import {IMorphoRepayCallback} from "lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IPreLiquidationCallback} from "../interfaces/borrow/IPreliquidationCallback.sol";
import {IPositionManager} from "../interfaces/manager/IPositionManager.sol";

/// @title MorphoBorrowPosition
/// @notice Implementation of a borrow position with the Morpho Blue protocol.
/// @dev Manages a single collateralized borrow position on Morpho Blue, owned by a position
///      manager. Two liquidation paths share the `preLiquidate` entrypoint: the proportional path
///      (LTV above `liquidationLtv`) and the offer band (LTV in `(safeLtv, liquidationLtv]`).
///      Offer storage and fill math live in {LibBorrowOffers}, in its own ERC-7201 namespace;
///      the offer roles and per-collateral configuration live on the shared
///      {BorrowOffersRegistry} immutable. See docs/borrow.md#liquidation-offers.
/// @author 3F Protocol
contract MorphoBorrowPosition is IBorrowPosition, IBorrowOffers, Initializable, Ownable, IMorphoRepayCallback {
  using SharesMathLib for uint256;
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;
  using LibChecks for address;
  using LibChecks for uint256;
  using MorphoBalancesLib for IMorpho;
  using LibBorrowOffers for LibBorrowOffers.BorrowOffersStorage;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Morpho protocol contract address, stored as an immutable in bytecode.
  /// @dev Set once in the constructor and shared across all beacon proxies.
  IMorpho public immutable MORPHO;

  /// @notice The shared {BorrowOffersRegistry}: the source of truth for the offer roles and the
  ///         per-collateral offer configuration (timelock, minimum bonus).
  /// @dev Roles and configuration are derived from the registry rather than stored per proxy, so
  ///      no offer-specific initializer or migration exists.
  IBorrowOffersRegistry public immutable OFFERS_REGISTRY;

  /// @notice Storage struct containing all persistent state for the BorrowPosition contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param marketId The Morpho market ID for this borrow position
  /// @param marketParams The Morpho market parameters for this borrow position
  /// @param safeLtv The safe LTV threshold that must not be reached upon position mutations (immutable after initialization)
  /// @param liquidationLtv The liquidation LTV at which the position can be liquidated (immutable after initialization)
  struct BorrowPositionStorage {
    Id marketId;
    MarketParams marketParams;
    uint128 safeLtv;
    uint128 liquidationLtv;
  }

  /// @dev Storage slot for the MorphoBorrowPosition contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("morpho.borrow.position")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0xe3d52ac7b6434dd627426ef8fa2ba1a2f9cb96afe079ac59af28727292403c00;

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return borrowPositionStorage A storage pointer to the BorrowPositionStorage struct
  function _borrowPositionStorage() internal pure returns (BorrowPositionStorage storage borrowPositionStorage) {
    assembly ("memory-safe") {
      borrowPositionStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  /// @dev Every future beacon upgrade must pass the SAME registry address, otherwise offer
  ///      authority silently moves to a different role book.
  ///      See docs/deployment.md#post-deployment-wiring.
  /// @param morpho_ The Morpho Blue protocol contract address.
  /// @param offersRegistry_ The shared {BorrowOffersRegistry} proxy address.
  constructor(IMorpho morpho_, IBorrowOffersRegistry offersRegistry_) {
    address(morpho_).checkContract();
    address(offersRegistry_).checkContract();
    MORPHO = morpho_;
    OFFERS_REGISTRY = offersRegistry_;
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the MorphoBorrowPosition contract with all required parameters.
  /// @dev Validates all inputs and fetches market parameters from Morpho.
  ///      The position manager becomes the owner and has exclusive control over the position.
  ///      The offer feature needs no per-proxy setup: roles and configuration live on the shared
  ///      {BorrowOffersRegistry}, and an all-zero offer namespace reads as an empty book.
  /// @param marketId_ The Morpho market ID for this borrow position. Must correspond to an existing market.
  /// @param positionManager_ The address of the position manager (owner) that will control this position.
  /// @param safeLtv_ The safe LTV threshold that must not be reached upon position mutations. Must be > 0, < liquidationLtv_.
  /// @param liquidationLtv_ The liquidation LTV at which the position can be liquidated. Must be > safeLtv_, <= WAD, and <= market LLTV.
  function initialize(Id marketId_, address positionManager_, uint128 safeLtv_, uint128 liquidationLtv_)
    public
    initializer
  {
    if (Id.unwrap(marketId_) == bytes32(0)) revert LibBorrowErrors.InvalidMarketId(marketId_);
    if (MORPHO.market(marketId_).lastUpdate == 0) revert LibBorrowErrors.MarketNotCreated();
    LibChecks.checkValidLtv(liquidationLtv_);
    if (safeLtv_ == 0) revert LibCommonErrors.InvalidLtv();

    // Validate safeLtv < liquidationLtv
    if (safeLtv_ >= liquidationLtv_) {
      revert LibBorrowErrors.SafeLtvNotLessThanLiquidationLtv(safeLtv_, liquidationLtv_);
    }

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    _storage.marketId = marketId_;
    _storage.marketParams = MORPHO.idToMarketParams(marketId_);

    // Validate market assets match PositionManager's expected assets
    (address expectedCollateral, address expectedDebt) = IPositionManager(positionManager_).assets();
    if (_storage.marketParams.collateralToken != expectedCollateral) {
      revert LibBorrowErrors.AssetMismatch(expectedCollateral, _storage.marketParams.collateralToken);
    }
    if (_storage.marketParams.loanToken != expectedDebt) {
      revert LibBorrowErrors.AssetMismatch(expectedDebt, _storage.marketParams.loanToken);
    }

    // Validate liquidationLtv does not exceed market LLTV
    // This ensures pre-liquidation triggers before Morpho's native liquidation
    if (liquidationLtv_ > _storage.marketParams.lltv) {
      revert LibBorrowErrors.LiquidationLtvExceedsMarketLltv(liquidationLtv_, _storage.marketParams.lltv);
    }

    _storage.safeLtv = safeLtv_;
    _storage.liquidationLtv = liquidationLtv_;

    _initializeOwner(positionManager_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OPERATIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers collateral from the caller to this contract, approves Morpho, and supplies it.
  function supplyCollateral(uint256 amount) external override onlyOwner {
    amount.checkNotZero();

    MarketParams memory _marketParams = _borrowPositionStorage().marketParams;

    // Transfer collateral from caller to this contract
    _marketParams.collateralToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend collateral
    _marketParams.collateralToken.safeApproveWithRetry(address(MORPHO), amount);

    // Supply collateral to Morpho on behalf of this contract
    MORPHO.supplyCollateral(_marketParams, amount, address(this), "");
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Withdraws collateral directly from Morpho to the owner (msg.sender).
  ///      Reverts with {LibBorrowErrors.InsufficientCollateral} if withdrawal would exceed safe LTV.
  function withdrawCollateral(uint256 amount) external override onlyOwner {
    amount.checkNotZero();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    MarketParams memory _marketParams = _storage.marketParams;

    // Withdraw collateral from Morpho to the owner (Position Manager)
    // This will revert if the position would become unhealthy
    MORPHO.withdrawCollateral(_marketParams, amount, address(this), msg.sender);

    if (!_isHealthy(_storage.safeLtv, _marketParams.oracle)) {
      revert LibBorrowErrors.InsufficientCollateral();
    }
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Borrows assets from Morpho and sends them directly to the owner (msg.sender).
  ///      Reverts with {LibBorrowErrors.InsufficientCollateral} if borrowing would exceed safe LTV.
  function borrow(uint256 amount) external override onlyOwner {
    amount.checkNotZero();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    MarketParams memory _marketParams = _storage.marketParams;

    // Borrow from Morpho, sending borrowed assets to the owner (Position Manager)
    // This will revert if the position would become unhealthy or insufficient liquidity
    MORPHO.borrow(_marketParams, amount, 0, address(this), msg.sender);

    if (!_isHealthy(_storage.safeLtv, _marketParams.oracle)) {
      revert LibBorrowErrors.InsufficientCollateral();
    }
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers loan tokens from the caller, approves Morpho, and repays the debt (partial or
  ///      full).
  function repay(uint256 amount) external override onlyOwner {
    amount.checkNotZero();

    MarketParams memory _marketParams = _borrowPositionStorage().marketParams;

    // Transfer loan tokens from caller to this contract
    _marketParams.loanToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend loan tokens
    _marketParams.loanToken.safeApproveWithRetry(address(MORPHO), amount);

    // Repay debt to Morpho
    MORPHO.repay(_marketParams, amount, 0, address(this), "");
  }

  /// @notice Pre-liquidates the position when it becomes unhealthy based on the custom liquidation LTV.
  /// @dev Callable by anyone. Above `liquidationLtv`, settlement is proportional: debt repaid and
  ///      collateral seized in the same fraction, with no liquidation incentive factor, so the
  ///      liquidator bonus is `1 - LTV` at liquidation time. Above the market LLTV the amounts
  ///      are adjusted (repaid debt raised, or seized collateral reduced) so the position passes
  ///      Morpho's own health check after the withdrawal; small partial liquidations may then
  ///      repay more than the proportional amount. In `(safeLtv, liquidationLtv]` standing offers
  ///      are consumed instead. See docs/borrow.md#pre-liquidation for the economics.
  ///
  ///      Matches the signature and callback interface of Morpho's PreLiquidation contract:
  ///      liquidators implementing {IPreLiquidationCallback.onPreLiquidate} receive the callback
  ///      when `data` is non-empty, after the collateral transfer and before the debt is pulled.
  ///
  ///      Intentionally not `nonReentrant`: Morpho settles the position and market state for the
  ///      in-flight repay before invoking `onMorphoRepay`, so a nested `preLiquidate` reads fresh
  ///      state, and the state-changing entry points on `PositionManager` and `Facility`
  ///      reachable during the callback are gated by `MINTER_ROLE` / `FACILITATOR_ROLE` plus
  ///      `nonReentrant`. INVARIANT: liquidators must never be granted `MINTER_ROLE` or
  ///      `FACILITATOR_ROLE`; any integration that grants either to a callback-capable address
  ///      must add a guard here. Offer roles are safe to hold (offers are never same-block
  ///      consumable, and offer mutations are committed before the repay).
  ///      See docs/borrow.md#pre-liquidation for the full argument.
  /// @param borrower The address of the position owner (typically this contract's address).
  /// @param seizedAssets The amount of collateral to seize. Pass 0 to calculate based on repaidShares.
  /// @param repaidShares The amount of borrow shares to repay. Pass 0 to calculate based on seizedAssets.
  /// @param data Arbitrary data to pass to the `onPreLiquidate` callback. Pass empty data if not needed.
  /// @return The amount of collateral seized.
  /// @return The amount of debt assets repaid.
  function preLiquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data)
    external
    returns (uint256, uint256)
  {
    if (borrower != address(this)) revert LibBorrowErrors.InvalidBorrower();
    if (!UtilsLib.exactlyOneZero(seizedAssets, repaidShares)) revert LibBorrowErrors.InconsistentInput();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Accrue interest BEFORE the health check so the debt calculation is up-to-date.
    // Without this, the _isHealthy check uses stale totalBorrowAssets, which could
    // understate debt and incorrectly report a healthy position.
    MORPHO.accrueInterest(_storage.marketParams);

    address oracle = _storage.marketParams.oracle;
    // _isHealthy(ltv) is true iff LTV <= ltv. Dispatch by band:
    if (!_isHealthy(_storage.liquidationLtv, oracle)) {
      // LTV > liquidationLtv: proportional path.
      return _proportionalPreLiquidate(borrower, seizedAssets, repaidShares, data);
    } else if (!_isHealthy(_storage.safeLtv, oracle)) {
      // safeLtv < LTV <= liquidationLtv: offer/band path.
      return _offerPreLiquidate(borrower, seizedAssets, repaidShares, data);
    } else {
      // LTV <= safeLtv: healthy, nothing to do.
      revert LibBorrowErrors.PositionHealthy();
    }
  }

  /// @dev The proportional pre-liquidation path. Reached only when `LTV > liquidationLtv`;
  ///      interest has already been accrued by {preLiquidate}. See the {preLiquidate} NatSpec for
  ///      the economics.
  function _proportionalPreLiquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data)
    internal
    returns (uint256, uint256)
  {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    {
      Position memory position = MORPHO.position(_storage.marketId, borrower);
      Market memory market = MORPHO.market(_storage.marketId);
      if (seizedAssets > 0) {
        repaidShares = _computeRepaidShares(position, market, _storage.marketParams, seizedAssets);
      } else {
        seizedAssets = _computeSeizedAssets(position, market, _storage.marketParams, repaidShares);
      }
    }

    uint256 repaidAssets;
    {
      bytes memory callbackData = abi.encode(seizedAssets, borrower, msg.sender, data);
      (repaidAssets,) = MORPHO.repay(_storage.marketParams, 0, repaidShares, borrower, callbackData);
    }

    return (seizedAssets, repaidAssets);
  }

  /// @dev The offer/band pre-liquidation path. Reached only when `safeLtv < LTV <= liquidationLtv`.
  ///      Walks the consumable offers cheapest-first, then settles once with a shares-mode Morpho
  ///      repay through the same `onMorphoRepay` callback as the proportional path. All offer
  ///      mutations are persisted by {LibBorrowOffers.consume} before the repay (CEI). Shares-mode
  ///      repay cannot underflow: `totalDebtShares <= position.borrowShares` by construction.
  ///      Morpho's own health check stays satisfied: the branch is entered at `LTV <= market LLTV`
  ///      and every fill strictly lowers the LTV; the conservative fill rounding is load-bearing
  ///      at the knife edge.
  function _offerPreLiquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data)
    internal
    returns (uint256, uint256)
  {
    // The walk reads market/position once (post-accrual, so exact) and applies all offer mutations
    // as effects before the repay below. Scoped in a helper to keep this function's stack shallow.
    (uint256 totalSeized, uint256 totalDebtShares) = _consumeOffers(borrower, seizedAssets, repaidShares);

    // Mandatory: a zero-amount repay would hit Morpho's exactlyOneZero (INCONSISTENT_INPUT); this
    // gives liquidators a clear signal when the band is entered but nothing is fillable.
    if (totalSeized == 0 || totalDebtShares == 0) revert LibBorrowErrors.NoConsumableOffer();

    bytes memory callbackData = abi.encode(totalSeized, borrower, msg.sender, data);
    (uint256 repaidAssets,) =
      MORPHO.repay(_borrowPositionStorage().marketParams, 0, totalDebtShares, borrower, callbackData);

    return (totalSeized, repaidAssets);
  }

  /// @dev Reads the post-accrual market/position snapshot and runs the offer consume walk. Returns
  ///      the aggregate `(totalSeized, totalDebtShares)`. Split out of {_offerPreLiquidate} so the
  ///      large `Market`/`Position` memory structs do not coexist on the stack with the repay.
  function _consumeOffers(address borrower, uint256 seizedAssets, uint256 repaidShares)
    internal
    returns (uint256 totalSeized, uint256 totalDebtShares)
  {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    Position memory position = MORPHO.position(_storage.marketId, borrower);
    Market memory market = MORPHO.market(_storage.marketId);

    LibBorrowOffers.BorrowOffersStorage storage o = LibBorrowOffers.borrowOffersStorage();
    LibBorrowOffers.ConsumeInput memory input = LibBorrowOffers.ConsumeInput({
      seizedTarget: seizedAssets,
      repaidSharesTarget: repaidShares,
      price: IOracle(_storage.marketParams.oracle).price(),
      totalBorrowAssets: uint256(market.totalBorrowAssets),
      totalBorrowShares: uint256(market.totalBorrowShares),
      positionCollateral: uint256(position.collateral),
      positionBorrowShares: uint256(position.borrowShares),
      minOfferBonusBps: _minOfferBonusBps()
    });
    return o.consume(input);
  }

  /// @dev Computes the repaid shares when the liquidator specifies the collateral to seize.
  ///      Returns the greater of the proportional amount and the minimum amount required
  ///      for the position to pass Morpho's health check after collateral withdrawal.
  ///      The result is capped at the position's total borrow shares.
  function _computeRepaidShares(
    Position memory position,
    Market memory market,
    MarketParams memory marketParams,
    uint256 seizedAssets
  ) internal view returns (uint256 repaidShares) {
    uint256 borrowShares = uint256(position.borrowShares);
    uint256 collateral = uint256(position.collateral);

    // Proportional repaidShares (rounds up, conservative for liquidator)
    uint256 proportional = seizedAssets.mulDivUp(borrowShares, collateral);

    // Minimum repaidShares for Morpho's health check after collateral withdrawal
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 maxRemainingDebt =
      (collateral - seizedAssets).mulDiv(collateralPrice, ORACLE_PRICE_SCALE).mulWad(marketParams.lltv);
    uint256 currentDebt = borrowShares.toAssetsUp(uint256(market.totalBorrowAssets), uint256(market.totalBorrowShares));

    uint256 minShares;
    if (currentDebt > maxRemainingDebt) {
      uint256 minRepaidAssets = currentDebt - maxRemainingDebt;
      minShares = minRepaidAssets.toSharesUp(uint256(market.totalBorrowAssets), uint256(market.totalBorrowShares));
    }

    // Use the greater of proportional and minimum required, capped at total borrow shares
    repaidShares = proportional.max(minShares).min(borrowShares);
  }

  /// @dev Computes the seized assets when the liquidator specifies the debt to repay.
  ///      Returns the lesser of the proportional amount and the maximum amount allowed
  ///      by Morpho's health check after collateral withdrawal.
  function _computeSeizedAssets(
    Position memory position,
    Market memory market,
    MarketParams memory marketParams,
    uint256 repaidShares
  ) internal view returns (uint256 seizedAssets) {
    uint256 borrowShares = uint256(position.borrowShares);
    uint256 collateral = uint256(position.collateral);
    uint256 totalBorrowAssets = uint256(market.totalBorrowAssets);
    uint256 totalBorrowShares = uint256(market.totalBorrowShares);

    // Proportional seizedAssets (rounds down, conservative for liquidator)
    uint256 proportional = repaidShares.mulDiv(collateral, borrowShares);

    // Maximum seizedAssets for Morpho's health check after collateral withdrawal
    uint256 remainingBorrowShares = borrowShares - repaidShares;

    uint256 maxSeized;
    if (remainingBorrowShares == 0) {
      maxSeized = collateral;
    } else {
      uint256 remainingDebt = remainingBorrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
      uint256 collateralPrice = IOracle(marketParams.oracle).price();
      uint256 minCollateralValue = remainingDebt.mulDivUp(1e18, marketParams.lltv);
      uint256 requiredCollateral = minCollateralValue.mulDivUp(ORACLE_PRICE_SCALE, collateralPrice);
      maxSeized = collateral.zeroFloorSub(requiredCollateral);
    }

    // Use the lesser of proportional and maximum allowed
    seizedAssets = proportional.min(maxSeized);
  }

  /// @notice Morpho callback invoked after a repay operation.
  /// @dev Callable only by Morpho; intentionally not `nonReentrant` (see the {preLiquidate}
  ///      reentrancy note). Withdraws the seized collateral to the liquidator, optionally invokes
  ///      the liquidator's callback, then pulls the loan tokens. `seizedAssets` is decoded
  ///      directly from `callbackData` (passed by `preLiquidate`), never inferred from balance
  ///      differences.
  /// @param repaidAssets The amount of loan tokens that were repaid.
  /// @param callbackData Encoded data containing (seizedAssets, borrower, liquidator, data).
  function onMorphoRepay(uint256 repaidAssets, bytes calldata callbackData) external {
    if (msg.sender != address(MORPHO)) revert LibBorrowErrors.NotMorpho();

    (uint256 seizedAssets, address borrower, address liquidator, bytes memory data) =
      abi.decode(callbackData, (uint256, address, address, bytes));

    MarketParams memory marketParams = _borrowPositionStorage().marketParams;

    if (seizedAssets > 0) {
      MORPHO.withdrawCollateral(marketParams, seizedAssets, borrower, liquidator);
    }

    if (data.length > 0) {
      IPreLiquidationCallback(liquidator).onPreLiquidate(repaidAssets, data);
    }

    marketParams.loanToken.safeTransferFrom(liquidator, address(this), repaidAssets);
    marketParams.loanToken.safeApproveWithRetry(address(MORPHO), repaidAssets);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ASSETS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the loan token address from the cached market parameters.
  function borrowAsset() external view override returns (address) {
    return _borrowPositionStorage().marketParams.loanToken;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the collateral token address from the cached market parameters.
  function collateralAsset() external view override returns (address) {
    return _borrowPositionStorage().marketParams.collateralToken;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          POSITION                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Converts borrow shares to assets using expected (interest-accrued) market totals.
  ///      Rounds down (`toAssetsDown`) so `repay(totalBorrowed())` never reverts: Morpho's repay
  ///      converts back via `toSharesDown`, and toSharesDown(toAssetsDown(bs)) <= bs.
  function totalBorrowed() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    Id _marketId = _storage.marketId;

    Position memory _pos = MORPHO.position(_marketId, address(this));

    // Use expected (interest-accrued) market totals to avoid understating debt
    (,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _marketId);

    // Convert borrow shares to assets using expected market totals
    return uint256(_pos.borrowShares).toAssetsDown(_totalBorrowAssets, _totalBorrowShares);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the raw collateral amount stored in the Morpho position.
  function totalCollateral() external view override returns (uint256) {
    return uint256(MORPHO.position(_borrowPositionStorage().marketId, address(this)).collateral);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Takes the raw collateral amount stored in the Morpho position and quotes it
  ///      in borrowed asset units.
  function totalCollateralQuoted() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    return uint256(MORPHO.position(_storage.marketId, address(this)).collateral)
      .mulDiv(IOracle(_storage.marketParams.oracle).price(), ORACLE_PRICE_SCALE);
  }

  /// @inheritdoc IBorrowPosition
  function isHealthy(uint256 _ltv) external view override returns (bool) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    return _isHealthy(_ltv, _storage.marketParams.oracle);
  }

  /// @inheritdoc IBorrowPosition
  function maxBorrow(uint256 _ltv) external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Use expected (interest-accrued) market balances to avoid understating debt
    (uint256 _totalSupplyAssets,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);

    Position memory _pos = MORPHO.position(_storage.marketId, address(this));

    return _maxBorrow(
      uint256(_pos.collateral),
      uint256(_pos.borrowShares),
      _totalBorrowAssets,
      _totalBorrowShares,
      _totalSupplyAssets - _totalBorrowAssets,
      IOracle(_storage.marketParams.oracle).price(),
      _ltv
    );
  }

  /// @inheritdoc IBorrowPosition
  function availableLiquidity() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Use expected (interest-accrued) market balances so that accrued
    // interest is reflected in both totalSupplyAssets and totalBorrowAssets.
    (uint256 _totalSupplyAssets,, uint256 _totalBorrowAssets,) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);
    return _totalSupplyAssets - _totalBorrowAssets;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Calculates available collateral as: totalCollateral - (debt * ORACLE_PRICE_SCALE) / (ltv * price)
  ///      If no debt, returns all collateral. Returns 0 if position would be unhealthy.
  function availableCollateral(uint256 _ltv) external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    Id _marketId = _storage.marketId;

    Position memory _pos = MORPHO.position(_marketId, address(this));

    // If no debt, all collateral is available
    if (_pos.borrowShares == 0) return uint256(_pos.collateral);

    // Use expected (interest-accrued) market totals to avoid understating debt
    (,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _marketId);

    return uint256(_pos.collateral)
      .zeroFloorSub(
        _requiredCollateral(
          // set the collateral to 0 to compute the total required collateral
          0,
          // compute the borrowed amount
          uint256(_pos.borrowShares).toAssetsUp(_totalBorrowAssets, _totalBorrowShares),
          IOracle(_storage.marketParams.oracle).price(),
          _ltv
        )
      );
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Computes the additional collateral needed so that supplying it and then borrowing
  ///      `borrowAmount` would keep the position at or below the given `ltv`.
  ///      Reverts with {LibBorrowErrors.InsufficientLiquidity} if `borrowAmount` exceeds market liquidity.
  function collateralForBorrow(uint256 borrowAmount, uint256 ltv) external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Fetch interest-accrued market totals for accurate debt conversion
    (uint256 _totalSupplyAssets,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);

    // Ensure the market has enough liquidity to fulfill the requested borrow
    if (borrowAmount > _totalSupplyAssets - _totalBorrowAssets) revert LibBorrowErrors.InsufficientLiquidity();

    Position memory _pos = MORPHO.position(_storage.marketId, address(this));

    // Simulate Morpho's share round-trip to predict the exact post-borrow debt that
    // _isHealthy will see: borrow() converts assets → shares via toSharesUp, then
    // _isHealthy converts total shares → assets via toAssetsUp. The double rounding
    // can inflate actual debt beyond (currentDebt + borrowAmount).
    uint256 newShares = borrowAmount.toSharesUp(_totalBorrowAssets, _totalBorrowShares);
    uint256 postBorrowDebt = (uint256(_pos.borrowShares) + newShares)
    .toAssetsUp(_totalBorrowAssets + borrowAmount, _totalBorrowShares + newShares);

    return
      _requiredCollateral(uint256(_pos.collateral), postBorrowDebt, IOracle(_storage.marketParams.oracle).price(), ltv);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Computes the additional borrow capacity if `collateralAmount` were supplied, at the
  ///      given `ltv`, capped at available market liquidity. Accounts for any existing excess
  ///      collateral: passing collateralAmount=0 returns the existing spare capacity.
  function borrowForCollateral(uint256 collateralAmount, uint256 ltv) external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Fetch interest-accrued market totals for accurate debt conversion and liquidity
    (uint256 _totalSupplyAssets,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);

    Position memory _pos = MORPHO.position(_storage.marketId, address(this));

    // Compute remaining borrow capacity with hypothetical additional collateral,
    // accounting for existing debt and capped at available market liquidity
    return _maxBorrow(
      uint256(_pos.collateral) + collateralAmount,
      uint256(_pos.borrowShares),
      _totalBorrowAssets,
      _totalBorrowShares,
      _totalSupplyAssets - _totalBorrowAssets,
      IOracle(_storage.marketParams.oracle).price(),
      ltv
    );
  }

  /// @dev Computes the additional collateral (in collateral asset units) needed to back
  ///      `borrowed` at the given `ltv`; rounds up so the requirement is never underestimated,
  ///      and returns 0 if the existing `collateral` already covers it.
  /// @param collateral The position's current collateral (in collateral asset units).
  /// @param borrowed The total debt to collateralize (in borrow asset units).
  /// @param price The oracle price of collateral denominated in borrow asset (ORACLE_PRICE_SCALE-scaled).
  /// @param ltv The loan-to-value ratio (WAD-scaled, 1e18 = 100%).
  function _requiredCollateral(uint256 collateral, uint256 borrowed, uint256 price, uint256 ltv)
    internal
    pure
    returns (uint256)
  {
    // Invert _isHealthy's two sequential floors with two sequential ceilings:
    //   _isHealthy: floor(floor(c * price / SCALE) * ltv / WAD) >= borrowed
    //   Step 1: ceil(borrowed * WAD / ltv)         (minimum collateral value)
    //   Step 2: ceil(minValue * SCALE / price)     (minimum collateral units)
    // Subtract existing collateral; floor at 0 if position is already sufficiently collateralized
    uint256 minCollateralValue = borrowed.mulDivUp(1e18, ltv);
    return minCollateralValue.mulDivUp(ORACLE_PRICE_SCALE, price).zeroFloorSub(collateral);
  }

  /// @dev Computes the remaining borrow capacity in share space to match Morpho's rounding:
  ///      Morpho's borrow() converts assets to shares via toSharesUp, then _isHealthy converts
  ///      total shares back to assets via toAssetsUp, so computing in share space avoids the
  ///      round-trip inflation that could make the returned amount unborrowable.
  /// @param collateral The position's collateral (in collateral asset units).
  /// @param borrowShares The position's current borrow shares.
  /// @param totalBorrowAssets The market's total borrow assets.
  /// @param totalBorrowShares The market's total borrow shares.
  /// @param liquidity The available market liquidity (in borrow asset units).
  /// @param price The oracle price of collateral denominated in borrow asset (ORACLE_PRICE_SCALE-scaled).
  /// @param ltv The loan-to-value ratio (WAD-scaled, 1e18 = 100%).
  /// @return The additional amount that can be borrowed (in borrow asset units).
  function _maxBorrow(
    uint256 collateral,
    uint256 borrowShares,
    uint256 totalBorrowAssets,
    uint256 totalBorrowShares,
    uint256 liquidity,
    uint256 price,
    uint256 ltv
  ) internal pure returns (uint256) {
    // Max allowable debt matching _isHealthy's two sequential floors
    uint256 maxAllowableDebt = collateral.mulDiv(price, ORACLE_PRICE_SCALE).mulWad(ltv);
    // Max total borrow shares whose toAssetsUp <= maxAllowableDebt
    uint256 maxBorrowShares = maxAllowableDebt.toSharesDown(totalBorrowAssets, totalBorrowShares);
    // Max additional shares this position can take on
    uint256 additionalShares = maxBorrowShares.zeroFloorSub(borrowShares);
    // Convert to max borrowable assets (toSharesUp on result <= additionalShares)
    return additionalShares.toAssetsDown(totalBorrowAssets, totalBorrowShares).min(liquidity);
  }

  /// @dev Returns whether the position is healthy at `_ltv`: healthy iff
  ///      `collateralValue * ltv >= borrowed`, with expected (interest-accrued) market totals.
  ///      Conservative rounding: the borrowed amount rounds up, the borrow capacity rounds down.
  /// @param _ltv The LTV to use for the health calculation.
  /// @param oracle The oracle address to fetch the collateral price.
  function _isHealthy(uint256 _ltv, address oracle) internal view returns (bool) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    Id _marketId = _storage.marketId;
    Position memory _pos = MORPHO.position(_marketId, address(this));

    // If no borrow, position is always healthy
    if (_pos.borrowShares == 0) return true;

    // Use expected (interest-accrued) market totals to avoid understating debt
    (,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _marketId);

    // Get collateral price from oracle
    uint256 _collateralPrice = IOracle(oracle).price();

    // Calculate borrowed amount (rounds up to be conservative)
    uint256 _borrowed = uint256(_pos.borrowShares).toAssetsUp(_totalBorrowAssets, _totalBorrowShares);

    // Calculate max borrow based on collateral value and provided LTV
    return uint256(_pos.collateral).mulDiv(_collateralPrice, ORACLE_PRICE_SCALE).mulWad(_ltv) >= _borrowed;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       OFFERS (WRITE)                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowOffers
  /// @dev Gated by {IBorrowOffersRegistry.checkCanCreateOffer} (a proposer, or the registry
  ///      owner); the position owner has no bypass. `activeAt` is fixed here from the
  ///      collateral's currently-effective registry timelock (see {Offer.activeAt}: a later
  ///      timelock change is never retroactive). The creation-time profitability and
  ///      minimum-bonus checks ({_checkOfferProfitable}) are admission filters at the current
  ///      market state; the binding checks run per fill at consume time.
  function proposeOffer(uint128 collateral, uint128 debtShares, uint40 expiresAt) external override returns (uint8 id) {
    OFFERS_REGISTRY.checkCanCreateOffer(msg.sender);
    if (collateral == 0 || debtShares == 0) revert LibBorrowErrors.OfferAmountZero();

    (uint40 timelock, uint16 minOfferBonusBps) = _offerConfig();
    // block.timestamp + timelock fits uint40 for ~34000 years; the cast cannot truncate in practice.
    uint40 activeAt = uint40(block.timestamp + timelock);
    if (expiresAt <= activeAt) revert LibBorrowErrors.OfferExpiryTooShort();
    // Lifespan is measured from when the offer becomes consumable (`activeAt`), so the veto
    // window does not eat into the live span. `expiresAt > activeAt` was just checked, so the
    // subtraction cannot underflow.
    if (uint256(expiresAt) - activeAt > MAX_OFFER_LIFESPAN) revert LibBorrowErrors.OfferExpiryTooLong();

    _checkOfferProfitable(collateral, debtShares, minOfferBonusBps);

    id = LibBorrowOffers.borrowOffersStorage().insert(msg.sender, activeAt, expiresAt, collateral, debtShares);
  }

  /// @dev Proposal-time admission filter at the current (interest-accrued) market state, factored
  ///      out of {proposeOffer} to keep its stack shallow. Two gates, both evaluated through
  ///      {LibBorrowOffers.isProfitableAboveBonusFloor}: strict profitability
  ///      ({LibBorrowErrors.OfferNotProfitable}) and the minimum bonus floor
  ///      ({LibBorrowErrors.OfferBonusTooLow}); the strict comparison is split out first only to
  ///      pick the right error. The same checks re-run per fill at consume time
  ///      ({LibBorrowOffers._priceAction}), where a below-floor offer is skipped, not reverted.
  function _checkOfferProfitable(uint128 collateral, uint128 debtShares, uint16 minBonusBps) internal view {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);
    uint256 offerValue = uint256(collateral).mulDiv(IOracle(_storage.marketParams.oracle).price(), ORACLE_PRICE_SCALE);
    uint256 offerDebt = uint256(debtShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    if (offerValue <= offerDebt) revert LibBorrowErrors.OfferNotProfitable();
    if (!LibBorrowOffers.isProfitableAboveBonusFloor(offerValue, offerDebt, minBonusBps)) {
      revert LibBorrowErrors.OfferBonusTooLow();
    }
  }

  /// @inheritdoc IBorrowOffers
  /// @dev Gated by {IBorrowOffersRegistry.checkCanRevokeOffer} (a guardian, or the registry
  ///      owner). Self-revoke by a plain proposer is deliberately not offered: revoke stays with
  ///      the guardians and the registry owner.
  function revokeOffers(uint8[] calldata ids) external override {
    OFFERS_REGISTRY.checkCanRevokeOffer(msg.sender);
    LibBorrowOffers.BorrowOffersStorage storage o = LibBorrowOffers.borrowOffersStorage();
    uint256 length = ids.length;
    for (uint256 i; i < length; ++i) {
      uint8 id = ids[i];
      o.removeOffer(id);
      emit OfferRevoked(id, msg.sender);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       OFFERS (VIEWS)                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reads this market's offer configuration from the shared registry, keyed by the market's
  ///      collateral token; the returned timelock is never zero (registry-floored).
  function _offerConfig() internal view returns (uint40 offerTimelock, uint16 minOfferBonusBps) {
    return OFFERS_REGISTRY.offerConfig(_borrowPositionStorage().marketParams.collateralToken);
  }

  /// @dev Convenience wrapper over {_offerConfig} returning only the bonus floor (used where the
  ///      timelock is irrelevant: the consume walk and the offer views).
  function _minOfferBonusBps() internal view returns (uint16 minOfferBonusBps) {
    (, minOfferBonusBps) = _offerConfig();
  }

  /// @inheritdoc IBorrowOffers
  function offerCount() external view override returns (uint256) {
    return LibBorrowOffers.borrowOffersStorage().liveCount();
  }

  /// @inheritdoc IBorrowOffers
  function offer(uint8 id) external view override returns (Offer memory) {
    if (id >= MAX_OFFERS) {
      Offer memory empty;
      return empty;
    }
    return LibBorrowOffers.borrowOffersStorage().slab[id];
  }

  /// @inheritdoc IBorrowOffers
  function offers() external view override returns (Offer[] memory) {
    return LibBorrowOffers.borrowOffersStorage().listOffers();
  }

  /// @inheritdoc IBorrowOffers
  function isConsumable(uint8 id) external view override returns (bool) {
    if (!LibBorrowOffers.borrowOffersStorage().isLive(id)) return false;
    Offer memory offerData = LibBorrowOffers.borrowOffersStorage().slab[id];
    if (block.timestamp < offerData.activeAt || block.timestamp >= offerData.expiresAt) return false;

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);
    Position memory position = MORPHO.position(_storage.marketId, address(this));
    return LibBorrowOffers.consumableAtPrice(
      offerData.remainingCollateral,
      offerData.remainingDebtShares,
      uint256(position.collateral),
      uint256(position.borrowShares),
      IOracle(_storage.marketParams.oracle).price(),
      totalBorrowAssets,
      totalBorrowShares,
      _minOfferBonusBps()
    );
  }

  /// @inheritdoc IBorrowOffers
  function previewConsume(uint256 seizedAssets, uint256 repaidShares)
    external
    view
    override
    returns (uint256 seized, uint256 debtShares)
  {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);
    Position memory position = MORPHO.position(_storage.marketId, address(this));
    LibBorrowOffers.BorrowOffersStorage storage o = LibBorrowOffers.borrowOffersStorage();
    LibBorrowOffers.ConsumeInput memory input = LibBorrowOffers.ConsumeInput({
      seizedTarget: seizedAssets,
      repaidSharesTarget: repaidShares,
      price: IOracle(_storage.marketParams.oracle).price(),
      totalBorrowAssets: totalBorrowAssets,
      totalBorrowShares: totalBorrowShares,
      positionCollateral: uint256(position.collateral),
      positionBorrowShares: uint256(position.borrowShares),
      minOfferBonusBps: _minOfferBonusBps()
    });
    return o.previewConsume(input);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           GETTERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the Morpho market ID associated with this borrow position.
  /// @dev The market ID is set during initialization and uniquely identifies the Morpho market
  ///      (loan token, collateral token, oracle, LLTV, and IRM combination).
  /// @return The Morpho market ID (bytes32 encoded).
  function marketId() external view returns (Id) {
    return _borrowPositionStorage().marketId;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev The safe LTV is immutable after initialization and determines the threshold
  ///      that must not be reached upon position mutations (borrow, withdrawCollateral).
  function safeLtv() external view override returns (uint128) {
    return _borrowPositionStorage().safeLtv;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Immutable after initialization. Determines when the position enters the proportional
  ///      pre-liquidation path (above it) versus the offer band (at or below it, down to `safeLtv`).
  function liquidationLtv() external view override returns (uint128) {
    return _borrowPositionStorage().liquidationLtv;
  }
}
