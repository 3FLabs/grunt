// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "lib/morpho-blue/src/interfaces/IOracle.sol";
import {SharesMathLib} from "../libs/borrow/SharesMathLib.sol";
import {MorphoBalancesLib} from "../libs/borrow/MorphoBalancesLib.sol";
import {LibBorrowErrors} from "../libs/borrow/LibBorrowErrors.sol";
import {LibBorrowOffers} from "../libs/borrow/LibBorrowOffers.sol";
import {
  ROLE_ADMIN,
  PROPOSER_ROLE,
  GUARDIAN_ROLE,
  MAX_OFFERS,
  DEFAULT_OFFER_TIMELOCK,
  MIN_OFFER_TIMELOCK,
  MAX_OFFER_TIMELOCK,
  MAX_OFFER_LIFESPAN,
  DEFAULT_MIN_OFFER_BONUS_BPS,
  MAX_MIN_OFFER_BONUS_BPS
} from "../libs/borrow/LibBorrowOffersConstants.sol";
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
/// @dev This contract manages a single collateralized borrow position on Morpho Blue.
///      It acts as the position holder and delegates control to an owner (typically a Position Manager).
///      The contract uses ERC-7201 namespaced storage for proxy compatibility and follows
///      the Checks-Effects-Interactions pattern for security.
///
///      **Offer-based pre-liquidation.** The contract also opens an earlier, privileged, timelocked
///      liquidation band beneath the existing `liquidationLtv`. Trusted proposers post standing
///      {Offer}s (a quantity of collateral for a quantity of debt-share repayment); liquidators
///      consume them through the *same* `preLiquidate` entrypoint when the LTV is in
///      `(safeLtv, liquidationLtv]`. The `LTV > liquidationLtv` proportional path is unchanged. All
///      offer storage, the slab/bitmap bookkeeping, the timelock and the fill/consume math live in
///      {LibBorrowOffers}; the base auth mixin is Solady `OwnableRoles` (storage-safe over a plain
///      `Ownable`: `OwnableRoles is Ownable`, same `_OWNER_SLOT`, roles live in keccak-derived slots
///      that cannot collide with the owner slot, the `Initializable` slot, the existing
///      `"morpho.borrow.position"` namespace, or the new `"borrow.offers.main"` namespace).
///
///      The {MorphoBorrowPositionFactory} is unchanged: `initialize` keeps its exact signature and
///      now also runs the offer setup, landing fresh proxies at version 2 in one call. Existing
///      version-1 proxies are migrated by a permissionless {initializeV2} sweep after the beacon
///      upgrade.
/// @author 3F Protocol
contract MorphoBorrowPosition is IBorrowPosition, IBorrowOffers, Initializable, OwnableRoles, IMorphoRepayCallback {
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
  ///      Saves a warm SLOAD (2100 gas) on every external call compared to storage.
  IMorpho public immutable MORPHO;

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

  /// @param morpho_ The Morpho Blue protocol contract address.
  constructor(IMorpho morpho_) {
    address(morpho_).checkContract();
    MORPHO = morpho_;
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the MorphoBorrowPosition contract with all required parameters.
  /// @dev Same signature as before (so the factory is unchanged), but now also runs the offer setup
  ///      and lands the proxy at version 2 in one call. The `onlyUninitialized` modifier is ordered
  ///      *before* `reinitializer(2)`: modifiers apply outside-in, so its `_getInitializedVersion()`
  ///      check still reads the pre-bump value (0 on a fresh proxy). An already-initialized proxy
  ///      (e.g. an existing version-1 proxy after the beacon upgrade) reverts with `AlreadyInitialized`
  ///      and must use {initializeV2} instead.
  ///      Validates all inputs and fetches market parameters from Morpho.
  ///      The position manager becomes the owner and has exclusive control over the position.
  /// @param marketId_ The Morpho market ID for this borrow position. Must correspond to an existing market.
  /// @param positionManager_ The address of the position manager (owner) that will control this position.
  /// @param safeLtv_ The safe LTV threshold that must not be reached upon position mutations. Must be > 0, < liquidationLtv_.
  /// @param liquidationLtv_ The liquidation LTV at which the position can be liquidated. Must be > safeLtv_, <= WAD, and <= market LLTV.
  /// @dev Reverts with {LibBorrowErrors.InvalidMarketId} if marketId_ is zero.
  ///      Reverts with {LibBorrowErrors.MarketNotCreated} if the market doesn't exist in Morpho.
  ///      Reverts with {LibCommonErrors.InvalidLtv} if liquidationLtv_ is zero or greater than WAD.
  ///      Reverts with {LibBorrowErrors.SafeLtvNotLessThanLiquidationLtv} if safeLtv_ >= liquidationLtv_.
  ///      Reverts with {LibBorrowErrors.AssetMismatch} if the market's collateral token doesn't match the PositionManager's collateral asset.
  ///      Reverts with {LibBorrowErrors.AssetMismatch} if the market's loan token doesn't match the PositionManager's debt asset.
  ///      Reverts with {LibBorrowErrors.LiquidationLtvExceedsMarketLltv} if liquidationLtv_ exceeds the Morpho market LLTV.
  function initialize(Id marketId_, address positionManager_, uint128 safeLtv_, uint128 liquidationLtv_)
    public
    onlyUninitialized
    reinitializer(2)
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

    // Owner must be set before _initializeV2(), which derives the admin from the owner chain.
    _initializeOwner(positionManager_);
    _initializeV2();
  }

  /// @inheritdoc IBorrowOffers
  /// @dev Migration-only entrypoint for an existing version-1 proxy (after the beacon upgrade).
  ///      `onlyVersion1` (ordered before `reinitializer(2)`) reads the pre-bump version: it reverts
  ///      `NotInitialized` on a fresh (version-0) or already-migrated (version-2) proxy, so it can
  ///      neither skip v1 setup on a fresh/self-deployed proxy nor double-run. Permissionless is
  ///      safe: it ignores `msg.sender` and derives the admin from the on-chain owner chain, so a
  ///      front-run only completes the protocol's own correct setup.
  function initializeV2() public onlyVersion1 reinitializer(2) {
    _initializeV2();
  }

  /// @dev Shared setup run by both {initialize} and {initializeV2}: seed the default offer timelock
  ///      and minimum offer bonus, initialize the offer-book bookkeeping, and grant `ROLE_ADMIN` to
  ///      the governance owner.
  function _initializeV2() internal {
    LibBorrowOffers.BorrowOffersStorage storage o = LibBorrowOffers.borrowOffersStorage();
    o.offerTimelock = DEFAULT_OFFER_TIMELOCK;
    o.minOfferBonusBps = DEFAULT_MIN_OFFER_BONUS_BPS;
    LibBorrowOffers.initOfferBook(o);

    // ROLE_ADMIN -> the PositionManager's governance owner(), falling back to the position owner
    // (the PositionManager) if that lookup fails.
    address admin = _governanceOwner();
    _grantRoles(admin, ROLE_ADMIN);
    emit RoleAdminInitialized(admin);
  }

  /// @dev Resolves the governance admin as `owner()`-of-`owner()`. `owner()` here is the
  ///      PositionManager (Solady `OwnableRoles`), which always exposes `owner()`. The lookup is
  ///      total: any anomaly (the position owner is not a contract, its `owner()` reverts, or it
  ///      returns anything other than a single non-zero address word) falls back to the position
  ///      owner rather than reverting and bricking initialization.
  ///
  ///      A low-level `staticcall` is used deliberately, not a typed call / `try-catch`: the latter
  ///      cannot be made total here. A call to a codeless address fails the compiler's extcodesize
  ///      check, and a successful-but-malformed return fails ABI return-decoding; neither is trapped
  ///      by `catch`, so both bubble up and revert. The low-level call instead reports a codeless
  ///      target or a revert as `ok == false`, and an unexpected return as a length mismatch. The
  ///      word is decoded as `uint256` and masked to `uint160` (rather than `abi.decode(ret,
  ///      (address))`, which itself reverts on dirty high bits) so even a malformed word falls back.
  function _governanceOwner() internal view returns (address) {
    address positionOwner = owner();
    (bool ok, bytes memory ret) = positionOwner.staticcall(abi.encodeWithSignature("owner()"));
    if (ok && ret.length == 32) {
      address gov = address(uint160(abi.decode(ret, (uint256))));
      if (gov != address(0)) return gov;
    }
    return positionOwner;
  }

  /// @dev Reverts unless the proxy is uninitialized (version 0). Ordered before `reinitializer(2)`
  ///      so it observes the pre-bump version.
  modifier onlyUninitialized() {
    if (_getInitializedVersion() != 0) revert LibBorrowErrors.AlreadyInitialized();
    _;
  }

  /// @dev Reverts unless the proxy is exactly at version 1. Ordered before `reinitializer(2)` so it
  ///      observes the pre-bump version.
  modifier onlyVersion1() {
    if (_getInitializedVersion() != 1) revert LibBorrowErrors.NotInitialized();
    _;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OPERATIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers collateral from the caller to this contract, approves Morpho, and supplies it.
  ///      Uses SafeTransferLib for secure token transfers.
  ///      Increases the position's collateral, which increases borrowing capacity.
  ///      Reverts with {CommonErrors.AmountZero} if amount is 0.
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
  ///      If there is an active borrow, the remaining collateral must maintain adequate collateralization.
  ///      Reverts with {CommonErrors.AmountZero} if amount is 0.
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
  ///      Requires sufficient collateral to maintain a healthy position based on the safe LTV.
  ///      Morpho enforces health checks and liquidity constraints.
  ///      Reverts with {CommonErrors.AmountZero} if amount is 0.
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
  /// @dev Transfers loan tokens from the caller, approves Morpho, and repays the debt.
  ///      Reduces the borrowed amount, improving the position's health factor.
  ///      Can repay partial or full debt. Uses SafeTransferLib for secure token transfers.
  ///      Reverts with {CommonErrors.AmountZero} if amount is 0.
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
  /// @dev This function allows anyone to liquidate an unhealthy position. Unlike Morpho's native liquidation,
  ///      this mechanism gives **proportional collateral** to the liquidator without applying a liquidation
  ///      incentive factor (LIF). This means:
  ///
  ///      **Liquidation Bonus = 1 - LTV (at time of liquidation)**
  ///
  ///      For example, if a position has:
  ///      - 100 collateral tokens (worth $100)
  ///      - 80 debt tokens (worth $80)
  ///      - LTV = 80%
  ///
  ///      A liquidator repaying 50% of the debt ($40) will seize 50% of the collateral (50 tokens worth $50).
  ///      The liquidator's profit is $50 - $40 = $10, which equals (1 - 0.80) × $50 = 20% × $50.
  ///
  ///      This ensures liquidators can always seize their proportional share of collateral, and the liquidation
  ///      bonus scales with how underwater the position is. At the liquidation LTV threshold, the bonus approaches 1 - liquidation LTV.
  ///
  ///      **Morpho Health Check Adjustment:**
  ///      When the position's LTV exceeds the Morpho market LLTV, purely proportional liquidation would fail
  ///      Morpho's internal health check (since removing the same fraction of debt and collateral preserves
  ///      the LTV). To handle this:
  ///      - **seizedAssets mode:** The liquidator specifies the collateral to seize. The function computes the
  ///        minimum debt repayment required to bring the position back to a healthy state on the underlying
  ///        Morpho market after collateral withdrawal (at least proportional, but potentially more).
  ///      - **repaidShares mode:** The liquidator specifies the debt to repay. The function computes the
  ///        maximum collateral that can be seized while keeping the position healthy on Morpho after
  ///        the withdrawal (at most proportional, but potentially less).
  ///
  ///      This means that for small partial liquidations of deeply unhealthy positions, more debt may be
  ///      repaid than the proportional collateral seized, since the primary goal is to restore the position's
  ///      health on the underlying Morpho market.
  ///
  ///      The liquidation uses a callback pattern: Morpho calls `onMorphoRepay` which withdraws collateral
  ///      to the liquidator, optionally calls the liquidator's callback, then pulls loan tokens from the liquidator.
  ///
  ///      **Callback Interface:**
  ///      This function conforms to the same signature and callback interface as Morpho's PreLiquidation contract.
  ///      Liquidators implementing `IPreLiquidationCallback.onPreLiquidate(uint256 repaidAssets, bytes calldata data)`
  ///      will receive the callback if `data` is non-empty.
  ///
  ///      **Reentrancy:**
  ///      `preLiquidate()` is intentionally not marked `nonReentrant`. A liquidator's `onPreLiquidate`
  ///      callback may re-enter `preLiquidate()` on this or another `MorphoBorrowPosition`. This is safe
  ///      because:
  ///      - Morpho settles the position and market state for the in-flight `repay` before invoking
  ///        `onMorphoRepay`, so a nested `preLiquidate` reads fresh state and computes its own
  ///        `seizedAssets` / `repaidShares` against it; economically identical to two sequential,
  ///        independent liquidation transactions.
  ///      - The window in `onMorphoRepay` where the liquidator holds seized collateral but has not yet
  ///        returned loan tokens cannot corrupt `PositionManager` or `Facility` state: the
  ///        state-changing entry points there (`deposit`, `withdraw`, `burn`, `cancel`, `commit`,
  ///        `unlock`, `recover`, `pull`, `repay`) are gated by `MINTER_ROLE` / `FACILITATOR_ROLE` plus
  ///        `nonReentrant`.
  ///
  ///      This relies on the assumption that liquidators are external actors and are never granted
  ///      `MINTER_ROLE` or `FACILITATOR_ROLE`. Any future integration that grants a callback-capable
  ///      address either of those roles invalidates this analysis and must add a guard here.
  ///
  ///      **Dispatch (after accruing interest, by current LTV):**
  ///      - `LTV > liquidationLtv`: the EXISTING proportional path ({_proportionalPreLiquidate}),
  ///        behaviorally unchanged.
  ///      - `safeLtv < LTV <= liquidationLtv`: the offer/band path ({_offerPreLiquidate}), which
  ///        consumes standing offers (each chunk profitable and strictly LTV-decreasing) and settles
  ///        with one shares-mode Morpho repay through the same `onMorphoRepay` callback.
  ///      - `LTV <= safeLtv`: healthy, revert `PositionHealthy()`.
  ///      The offer branch reads offer storage lazily (only when taken), so the proportional path
  ///      never touches offer-initialized state and keeps working in the post-upgrade /
  ///      pre-`initializeV2` window.
  ///
  ///      The reentrancy analysis above also covers the new offer roles: a reentrant `proposeOffer`
  ///      creates a timelocked (not same-block consumable) offer; a reentrant `revokeOffers` only
  ///      removes offers while the in-flight consume has already committed its fills as effects; the
  ///      admin setters have no fund impact. Holding offer roles is therefore not exploitable in the
  ///      callback (the `MINTER`/`FACILITATOR` rule is the only liquidator role restriction).
  /// @param borrower The address of the position owner (typically this contract's address).
  /// @param seizedAssets The amount of collateral to seize. Pass 0 to calculate based on repaidShares.
  /// @param repaidShares The amount of borrow shares to repay. Pass 0 to calculate based on seizedAssets.
  /// @param data Arbitrary data to pass to the `onPreLiquidate` callback. Pass empty data if not needed.
  /// @return The amount of collateral seized.
  /// @return The amount of debt assets repaid.
  /// @dev Reverts with {LibBorrowErrors.InvalidBorrower} if borrower is not address(this).
  ///      Reverts with {LibBorrowErrors.InconsistentInput} if both seizedAssets and repaidShares are non-zero or both are zero.
  ///      Reverts with {LibBorrowErrors.PositionHealthy} if the position is healthy based on the custom liquidation LTV.
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
      // LTV > liquidationLtv: EXISTING proportional path (behaviorally unchanged).
      return _proportionalPreLiquidate(borrower, seizedAssets, repaidShares, data);
    } else if (!_isHealthy(_storage.safeLtv, oracle)) {
      // safeLtv < LTV <= liquidationLtv: NEW offer/band path.
      return _offerPreLiquidate(borrower, seizedAssets, repaidShares, data);
    } else {
      // LTV <= safeLtv: nothing to do, whatever the contract's offer/role state.
      revert LibBorrowErrors.PositionHealthy();
    }
  }

  /// @dev The proportional pre-liquidation path (pre-existing behavior), extracted unchanged.
  ///      Reached only when `LTV > liquidationLtv`. Interest has already been accrued and the health
  ///      check performed by {preLiquidate}. Settlement is purely proportional (with a Morpho-health
  ///      adjustment for deeply-underwater positions); see the {preLiquidate} NatSpec for the
  ///      economics.
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
  ///      Walks the consumable offers sorted by effective price (most owner-favorable first),
  ///      consuming chunks that are each profitable and strictly LTV-decreasing, then settles once
  ///      with a shares-mode Morpho repay reusing the same `onMorphoRepay` callback as the
  ///      proportional path.
  ///
  ///      Market/position state is read once at entry (post-accrual, so exact: it matches Morpho's
  ///      internal totals) and passed to {LibBorrowOffers.consume}, which applies all offer
  ///      mutations as effects BEFORE this function performs the single repay (CEI; see the consume
  ///      reentrancy note). Repaying in shares is the natural fit (offers are share-denominated) and
  ///      sidesteps the assets-mode `borrowShares` underflow: `totalDebtShares <= position.borrowShares`
  ///      by construction, so Morpho's `borrowShares -= totalDebtShares` cannot underflow.
  ///
  ///      Morpho health: the branch is entered with `LTV <= liquidationLtv <= market LLTV`, so
  ///      `_isHealthy(LLTV)` holds; every fill strictly lowers LTV, so the post-withdraw state that
  ///      Morpho re-checks inside `withdrawCollateral` retains margin. The conservative rounding in
  ///      the fill math is load-bearing at the knife edge.
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
      minOfferBonusBps: o.minOfferBonusBps
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
  /// @dev This callback is called by Morpho during the pre-liquidation flow:
  ///      1. preLiquidate() calls MORPHO.repay() with callback data
  ///      2. Morpho repays the debt and calls this callback
  ///      3. This callback withdraws collateral to the liquidator
  ///      4. Optionally calls the liquidator's onPreLiquidate callback
  ///      5. Pulls loan tokens from the liquidator to complete the repayment
  ///      Reverts with {LibBorrowErrors.NotMorpho} if called by any address other than the Morpho contract.
  ///      `seizedAssets` is decoded directly from `callbackData` (passed by `preLiquidate`); we do
  ///      not infer it from balance differences in this contract.
  ///
  ///      **Reentrancy:** This callback is intentionally not marked `nonReentrant`. Its only access
  ///      control is the `msg.sender == address(MORPHO)` check in the function body. See the
  ///      `preLiquidate` Reentrancy note for the full rationale.
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
  /// @dev Converts borrow shares to asset amount using SharesMathLib with expected (interest-accrued)
  ///      market totals from MorphoBalancesLib.
  ///      Uses `toAssetsDown` to round down, ensuring repay(totalBorrowed()) never reverts.
  ///      Morpho's repay() converts assets back to shares via toSharesDown; the round-trip
  ///      toSharesDown(toAssetsDown(bs)) is guaranteed <= bs, avoiding underflow.
  ///      Accounts for accrued interest since the borrow shares represent a proportion
  ///      of the total market debt that grows over time.
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
  /// @dev Computes the additional collateral needed so that supplying it and then borrowing `borrowAmount`
  ///      would keep the position at or below the given `ltv`.
  ///      Steps:
  ///        1. Fetch interest-accrued market balances to get accurate current debt.
  ///        2. Revert if `borrowAmount` exceeds available market liquidity.
  ///        3. Compute the total required collateral for (currentDebt + borrowAmount) at `ltv`.
  ///        4. Subtract the position's existing collateral (floored at 0).
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
  /// @dev Computes the additional borrow capacity if `collateralAmount` were supplied, at the given `ltv`.
  ///      Steps:
  ///        1. Fetch interest-accrued market balances to get accurate current debt and liquidity.
  ///        2. Compute max borrow for (currentCollateral + collateralAmount) at `ltv`.
  ///        3. Subtract current debt (floored at 0) to get additional capacity.
  ///        4. Cap at available market liquidity.
  ///      The result accounts for any existing excess collateral: if the position is already
  ///      under-leveraged, passing collateralAmount=0 returns the existing spare capacity.
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

  /// @dev Computes the additional collateral needed to back `borrowed` at the given `ltv`.
  ///      Formula: additionalCollateral = ceil(borrowed * ORACLE_PRICE_SCALE / (ltv * price)) - collateral
  ///      The division rounds up so the collateral requirement is conservative (never underestimates).
  ///      Returns 0 (via zeroFloorSub) if the existing `collateral` already covers the requirement.
  /// @param collateral The position's current collateral (in collateral asset units).
  /// @param borrowed The total debt to collateralize (in borrow asset units).
  /// @param price The oracle price of collateral denominated in borrow asset (ORACLE_PRICE_SCALE-scaled).
  /// @param ltv The loan-to-value ratio (WAD-scaled, 1e18 = 100%).
  /// @return The additional collateral required (in collateral asset units). 0 if already sufficient.
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

  /// @dev Computes the remaining borrow capacity in share space to match Morpho's rounding.
  ///      Morpho's borrow() converts assets → shares via toSharesUp, then _isHealthy converts
  ///      total shares → assets via toAssetsUp. Computing in share space avoids the round-trip
  ///      inflation that can make the returned amount unborrowable.
  ///      Steps:
  ///        1. Compute max allowable debt matching _isHealthy's two sequential floors.
  ///        2. Find max total borrow shares whose toAssetsUp <= max allowable debt.
  ///        3. Subtract existing borrow shares to get max additional shares.
  ///        4. Convert additional shares to assets (rounding down so toSharesUp stays within budget).
  ///        5. Cap at available market liquidity.
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

  /// @dev Internal helper to determine if the position is healthy based on provided ltv and oracle.
  ///      Health calculation:
  ///      1. If no borrow exists (borrowShares == 0), position is always healthy.
  ///      2. Otherwise, calculates: maxBorrow = (collateral * oraclePrice / ORACLE_PRICE_SCALE) * ltv
  ///      3. Position is healthy if maxBorrow >= borrowed amount (with interest).
  ///      Uses conservative rounding: borrowed amount rounds up, max borrow rounds down.
  ///      Uses expected (interest-accrued) market totals from MorphoBalancesLib.
  /// @param _ltv The LTV to use for the health calculation.
  /// @param oracle The oracle address to fetch the collateral price.
  /// @return True if the position is healthy, false otherwise.
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
  /// @dev Gated to `PROPOSER_ROLE | ROLE_ADMIN | owner`. `activeAt` is fixed here with the timelock
  ///      effective NOW (after promoting any due pending change), so a later {setOfferTimelock}
  ///      cannot retroactively shorten this offer's veto window. The creation-time profitability
  ///      and minimum-bonus checks ({_checkOfferProfitable}) are admission filters at the current
  ///      market state; the binding checks run per fill at consume time (price and accrued interest
  ///      drift afterwards). Offer amounts are `uint128` (matching Morpho's `uint128` collateral
  ///      and borrow totals), so the upper bound is enforced by the parameter type and only the
  ///      `> 0` lower bound needs an explicit check.
  function proposeOffer(uint128 collateral, uint128 debtShares, uint40 expiresAt)
    external
    override
    onlyOwnerOrRoles(PROPOSER_ROLE | ROLE_ADMIN)
    returns (uint8 id)
  {
    if (collateral == 0 || debtShares == 0) revert LibBorrowErrors.OfferAmountZero();

    LibBorrowOffers.BorrowOffersStorage storage o = LibBorrowOffers.borrowOffersStorage();

    // Promote a due pending timelock, then fix activeAt with the timelock effective NOW.
    uint40 timelock = o.promoteTimelock();
    if (timelock == 0) revert LibBorrowErrors.OfferTimelockUnset();
    // block.timestamp + timelock fits uint40 for ~34000 years; the cast cannot truncate in practice.
    uint40 activeAt = uint40(block.timestamp + timelock);
    if (expiresAt <= activeAt) revert LibBorrowErrors.OfferExpiryTooShort();
    // Lifespan is measured from when the offer becomes consumable (`activeAt`), not from now: the
    // timelock (veto) window is not part of the offer's live span, so a longer timelock should not
    // eat into how long the offer can actually be used. `expiresAt > activeAt` was just checked, so
    // the subtraction cannot underflow.
    if (uint256(expiresAt) - activeAt > MAX_OFFER_LIFESPAN) revert LibBorrowErrors.OfferExpiryTooLong();

    _checkOfferProfitable(collateral, debtShares, o.minOfferBonusBps);

    id = o.insert(msg.sender, activeAt, expiresAt, collateral, debtShares);
  }

  /// @dev Creation-time profitability filter at the current (interest-accrued) market state.
  ///      Factored out of {proposeOffer} to keep its stack shallow. Two checks:
  ///      - Strict profitability: reverts {LibBorrowErrors.OfferNotProfitable} unless
  ///        `collateral value > debt value`.
  ///      - Minimum bonus: reverts {LibBorrowErrors.OfferBonusTooLow} unless the excess
  ///        `offerValue - offerDebt` is at least `minBonusBps` basis points of the debt value.
  ///        Anti-griefing admission filter: a barely-profitable offer would be consumed first
  ///        (lowest price first) and drag the profitability of every band liquidation down to near
  ///        zero. With `minBonusBps == 0` the floor is disabled and only the strict check applies.
  ///      Both gates evaluate {LibBorrowOffers.isProfitableAboveBonusFloor} (the single
  ///      implementation of the floor's inequality and rounding); the strict profitability
  ///      comparison is split out first only to pick the right error. They are proposal-time
  ///      filters against the state now; the same
  ///      checks are re-evaluated per fill at consume time (see {LibBorrowOffers._priceAction}), so
  ///      a live offer whose bonus later drifts below the floor via price or accrued-interest
  ///      movement is skipped by the consume walk rather than dragging the band's profitability
  ///      down (a guardian can also revoke it).
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
  /// @dev Gated to `GUARDIAN_ROLE | ROLE_ADMIN | owner`. Removes each id from the offer book
  ///      (the guardian veto inside the timelock window, and the kill switch for a bad standing
  ///      offer at any later stage). Self-revoke by a plain proposer is deliberately not offered:
  ///      the role table keeps revoke to guardian/admin/owner, who can already remove any offer.
  function revokeOffers(uint8[] calldata ids) external override onlyOwnerOrRoles(GUARDIAN_ROLE | ROLE_ADMIN) {
    LibBorrowOffers.BorrowOffersStorage storage o = LibBorrowOffers.borrowOffersStorage();
    // Cache the calldata length once, and each id into a stack variable, so the loop performs a
    // single CALLDATALOAD per iteration instead of re-reading `ids.length` and `ids[i]` twice each.
    uint256 length = ids.length;
    for (uint256 i; i < length; ++i) {
      uint8 id = ids[i];
      o.removeOffer(id);
      emit OfferRevoked(id, msg.sender);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       OFFERS (ADMIN)                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowOffers
  /// @dev Gated to `ROLE_ADMIN | owner`. Toggles the proposer bit via Solady `_updateRoles` (which
  ///      `_grantRoles`/`_removeRoles` themselves wrap with a boolean); the owner (PositionManager)
  ///      also retains native `grantRoles`/`revokeRoles`.
  function setProposer(address account, bool enabled) external override onlyOwnerOrRoles(ROLE_ADMIN) {
    account.checkNotZero();
    _updateRoles(account, PROPOSER_ROLE, enabled);
  }

  /// @inheritdoc IBorrowOffers
  /// @dev Gated to `ROLE_ADMIN | owner`. Toggles the guardian bit via Solady `_updateRoles`.
  function setGuardian(address account, bool enabled) external override onlyOwnerOrRoles(ROLE_ADMIN) {
    account.checkNotZero();
    _updateRoles(account, GUARDIAN_ROLE, enabled);
  }

  /// @inheritdoc IBorrowOffers
  /// @dev Gated to `ROLE_ADMIN | owner`. The change is itself timelocked: it lands only after the
  ///      *current* effective timelock elapses (re-based on each call, so a reduction can never be
  ///      accelerated). Bounded to `[MIN_OFFER_TIMELOCK, MAX_OFFER_TIMELOCK]`: the floor guarantees
  ///      a non-zero veto window; the ceiling stops an admin from freezing the band (and, because a
  ///      change is delayed by the current timelock, from self-locking the correction). Over many
  ///      sequential steps an admin can still ratchet the timelock down, but each step costs at
  ///      least the current timelock and is monitorable; that is the intended trade-off.
  function setOfferTimelock(uint40 timelock) external override onlyOwnerOrRoles(ROLE_ADMIN) {
    if (timelock < MIN_OFFER_TIMELOCK || timelock > MAX_OFFER_TIMELOCK) {
      revert LibBorrowErrors.OfferTimelockOutOfRange();
    }
    LibBorrowOffers.BorrowOffersStorage storage o = LibBorrowOffers.borrowOffersStorage();
    uint40 currentTimelock = o.promoteTimelock();
    uint40 effectiveAt = uint40(block.timestamp + currentTimelock);
    o.pendingTimelock = timelock;
    o.pendingTimelockAt = effectiveAt;
    emit OfferTimelockScheduled(timelock, effectiveAt);
  }

  /// @inheritdoc IBorrowOffers
  /// @dev Gated to `ROLE_ADMIN | owner`. Effective immediately (no timelock; see the interface
  ///      NatSpec for the rationale) and bounded to `[0, MAX_MIN_OFFER_BONUS_BPS]`, so a fallible
  ///      admin cannot demand a bonus floor no realistic offer could clear. Enforced at both
  ///      proposal and consume time; live offers keep standing but a raised floor gates their
  ///      consumption too (guardians revoke any that should not stand).
  function setMinOfferBonus(uint16 minOfferBonusBps_) external override onlyOwnerOrRoles(ROLE_ADMIN) {
    if (minOfferBonusBps_ > MAX_MIN_OFFER_BONUS_BPS) revert LibBorrowErrors.MinOfferBonusOutOfRange();
    LibBorrowOffers.borrowOffersStorage().minOfferBonusBps = minOfferBonusBps_;
    emit MinOfferBonusSet(minOfferBonusBps_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       OFFERS (VIEWS)                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowOffers
  function offerTimelock() external view override returns (uint40) {
    return LibBorrowOffers.borrowOffersStorage().effectiveTimelock();
  }

  /// @inheritdoc IBorrowOffers
  function pendingOfferTimelock() external view override returns (uint40 value, uint40 effectiveAt) {
    LibBorrowOffers.BorrowOffersStorage storage o = LibBorrowOffers.borrowOffersStorage();
    if (o.pendingTimelockAt == 0) return (0, 0);
    return (o.pendingTimelock, o.pendingTimelockAt);
  }

  /// @inheritdoc IBorrowOffers
  function minOfferBonus() external view override returns (uint16) {
    return LibBorrowOffers.borrowOffersStorage().minOfferBonusBps;
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
      LibBorrowOffers.borrowOffersStorage().minOfferBonusBps
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
      minOfferBonusBps: o.minOfferBonusBps
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
