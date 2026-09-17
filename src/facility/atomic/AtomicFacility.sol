// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {IAtomicFacility, EntryOffer, ExitOffer, Auth} from "../../interfaces/facility/IAtomicFacility.sol";
import {IAtomicExitCallback} from "../../interfaces/facility/IAtomicExitCallback.sol";
import {IFacilityCapsWhitelist} from "../../interfaces/facility/IFacilityCapsWhitelist.sol";
import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {WithdrawalStrategy} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {LibCaps, CapType} from "../../libs/facility/LibCaps.sol";
import {LibPause} from "../../libs/common/LibPause.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {LibCommonErrors} from "../../libs/common/LibCommonErrors.sol";
import {LibView} from "../../libs/manager/LibView.sol";
import {BPS} from "../../libs/Constants.sol";

/// @title AtomicFacility
/// @author 3F Protocol
/// @notice Permissionless atomic entry and exit over PositionManager (PM) vaults. An entry wraps
///         the PM collateral's underlying 1:1 and enters at the pool's live debt-per-collateral
///         ratio; an exit unwinds proportionally against the same ratio. Fees are skimmed in PM
///         shares on both sides, the debt leg is exact.
/// @dev Ratio-matched flows never cross a price. With `C` collateral units, `D` debt and quote
///      `p`, an entrant bringing `c` units borrows `d = c * D / C`; the shares `PM.deposit` mints
///      are proportional to the quoted equity added, `p * c - d = (c / C)(pC - D)`, so the entrant
///      gets the fraction `c / (C + c)` of the pool whatever `p` is. At the next quote `p'` their
///      equity is exactly `p' * c - d` and holders' equity per share is unchanged. Exits mirror
///      `PM.burn`'s native-unit proportional math. Round trips are strictly lossy (rounding plus
///      the two share fees).
///
///      Since a ratio-matched entrant can only ever receive shares, every mint is checked
///      against the fraction `S_adj * c / C` and any excess reverts (`NonNeutralMint`). This
///      bounds the over-mint of a multi-module PM whose receiving module quotes above the pool
///      average, a bad-debt filtering slip, and unknown PM bugs alike.
///
///      Caps, all in debt units, are consumed before any token moves: the PM's capacity cap, then
///      the caller's auth on the underlying asset and, for the remainder, the asset's security
///      cap (shared by every PM wrapping that asset, against unbacked issuer mints). Exits consume
///      the PM's exit cap; pointing it at the shared absolute pool with a negative multiplier
///      gives entry capacity back.
///
///      Trust surface: the facility holds MINTER_ROLE on each PM it serves and is itself
///      permissionless, so PM flows are publicly reachable through this code. Disabling an offer
///      does not revoke that role. The facility must hold SENDER_ROLE on the wrapper, pass the
///      PM's TransferGuard and the underlying's transfer restrictions; so must receivers and the
///      fee recipient (it holds PM shares).
///
///      Known limitations:
///      - Multi-module PMs with divergent per-module quotes: the receiving module prices the
///        deposit while the debt leg is aggregate. Serve PMs whose modules share one price feed.
///      - A module above its liquidation LTV but below 100% is not bad debt. An exit while the
///        PM's withdrawal queue excludes that module leaves the penalty on stayers. Serve PMs
///        whose withdrawal queue covers every module.
///      - A dynamic security cap is throughput only: exits do not refund it, so a looper drains
///        it at the cost of two share fees plus rounding per loop. Size the fees accordingly.
///      - An exit word on a shared absolute pool with a negative multiplier reverts
///        `HardCapExceeded` while the pool sits at its hard cap: exits block until entries
///        consume headroom or the facilitator re-arms the word.
///      - An ABSOLUTE exit word is drainable by enter/exit loops at fee cost, blocking exits for
///        everyone until re-armed. Prefer the shared-pool netting (entry +1x, exit -1x).
///      - Any revert inside the PM's fee accrual (a de-allowlisted PM fee recipient) reverts
///        every flow.
///      - The underlying and the debt asset must be exact-transfer tokens (no fee on transfer,
///        no rebasing, no transfer hooks), as required by every fund adapter.
///      - Gains between NAV prints travel with the collateral, so an exit before a print and a
///        re-entry after it skip the PM performance fee on that gain (a loss to the PM fee
///        recipient, not to holders). The share fees are the deterrent.
contract AtomicFacility is IAtomicFacility, OwnableRoles, ReentrancyGuardTransient, Initializable {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using LibCaps for uint256;
  using LibPause for uint40;
  using LibChecks for address;
  using LibChecks for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to set offers and security caps.
  uint256 internal constant FACILITATOR_ROLE = _ROLE_0;
  /// @notice Role for addresses authorized to pause the facility.
  /// @dev `_ROLE_1` is left free so the bits line up with the Facility family.
  uint256 internal constant COMPLIANCE_ROLE = _ROLE_2;
  /// @notice Role for addresses authorized to set user auths.
  uint256 internal constant OPERATOR_ROLE = _ROLE_3;

  /// @notice Maximum fee on either side: 10% of the shares.
  uint256 internal constant MAX_FEE = 1_000;

  /// @notice Storage slot of the facility state.
  /// @dev Computed as: keccak256("facility.atomic.storage")
  /// @custom:value 0x761cd1f441e845cdb6e880759e936b3b8a1b245f78953b3ff645e92c3d5c48fd
  bytes32 internal constant ATOMIC_STORAGE_SLOT = 0x761cd1f441e845cdb6e880759e936b3b8a1b245f78953b3ff645e92c3d5c48fd;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The registry of caps contracts an EXTERNAL cap word may reference.
  IFacilityCapsWhitelist public immutable CAPS_WHITELIST;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  struct Storage {
    /// @notice Entry offer per position manager.
    mapping(address positionManager => EntryOffer) entries;
    /// @notice Exit offer per position manager.
    mapping(address positionManager => ExitOffer) exits;
    /// @notice Security cap word per underlying asset.
    mapping(address asset => uint256) securityCaps;
    /// @notice User auths per underlying asset.
    mapping(address asset => mapping(address user => Auth)) auths;
    /// @notice Recipient of the share fees of both sides.
    address feeRecipient;
    /// @notice Pause-until timestamp (see LibPause).
    uint40 pausedUntil;
  }

  function _storage() internal pure returns (Storage storage s) {
    bytes32 slot = ATOMIC_STORAGE_SLOT;
    assembly ("memory-safe") {
      s.slot := slot
    }
  }

  /// @dev Parameters of an entry, bundled to keep the stack flat.
  struct Entry {
    address positionManager;
    address collateralAsset;
    address debtAsset;
    address underlying;
    address receiver;
    uint256 amount;
    uint256 debt;
    uint256 totalCollateral;
    uint256 minSharesOut;
    uint24 feeBps;
  }

  /// @dev Parameters of an exit, bundled to keep the stack flat.
  struct Exit {
    address positionManager;
    address collateralAsset;
    address debtAsset;
    address receiver;
    uint256 shares;
    uint256 burnShares;
    uint256 feeShares;
    uint256 debt;
    uint256 minUnderlyingOut;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @param capsWhitelist The caps whitelist shared by every facility built from this implementation.
  constructor(address capsWhitelist) {
    capsWhitelist.checkContract();
    CAPS_WHITELIST = IFacilityCapsWhitelist(capsWhitelist);
    _disableInitializers();
  }

  /// @notice Initializes the facility.
  /// @param owner_ The owner of the contract.
  /// @param facilitator_ The initial FACILITATOR_ROLE holder (address(0) to skip).
  /// @param feeRecipient_ The recipient of the share fees.
  function initialize(address owner_, address facilitator_, address feeRecipient_) external initializer {
    owner_.checkNotZero();
    feeRecipient_.checkNotZero();
    _initializeOwner(owner_);
    if (facilitator_ != address(0)) _grantRoles(facilitator_, FACILITATOR_ROLE);
    _storage().feeRecipient = feeRecipient_;
    emit FeeRecipientSet(feeRecipient_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IAtomicFacility
  function setEntry(address positionManager, uint256 capacityCap, uint40 expiry, uint24 feeBps)
    external
    onlyOwnerOrRoles(FACILITATOR_ROLE)
  {
    if (feeBps > MAX_FEE) revert FeeExceedsMax();
    _validatePositionManager(positionManager);
    _validateConsumingWord(capacityCap);
    _storage().entries[positionManager] = EntryOffer({capacityCap: capacityCap, expiry: expiry, feeBps: feeBps});
    emit EntrySet(positionManager, capacityCap, expiry, feeBps);
  }

  /// @inheritdoc IAtomicFacility
  function setExit(address positionManager, uint256 cap, uint40 expiry, uint24 feeBps)
    external
    onlyOwnerOrRoles(FACILITATOR_ROLE)
  {
    if (feeBps > MAX_FEE) revert FeeExceedsMax();
    _validatePositionManager(positionManager);
    cap.validate(CAPS_WHITELIST);
    _storage().exits[positionManager] = ExitOffer({cap: cap, expiry: expiry, feeBps: feeBps});
    emit ExitSet(positionManager, cap, expiry, feeBps);
  }

  /// @inheritdoc IAtomicFacility
  function setSecurityCap(address asset, uint256 cap) external onlyOwnerOrRoles(FACILITATOR_ROLE) {
    asset.checkNotZero();
    _validateConsumingWord(cap);
    _storage().securityCaps[asset] = cap;
    emit SecurityCapSet(asset, cap);
  }

  /// @inheritdoc IAtomicFacility
  function setAuth(address asset, address user, uint128 amount, uint40 expiry)
    external
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    asset.checkNotZero();
    user.checkNotZero();
    _storage().auths[asset][user] = Auth({amount: amount, expiry: expiry});
    emit AuthSet(asset, user, amount, expiry);
  }

  /// @inheritdoc IAtomicFacility
  function setFeeRecipient(address feeRecipient) external onlyOwner {
    feeRecipient.checkNotZero();
    _storage().feeRecipient = feeRecipient;
    emit FeeRecipientSet(feeRecipient);
  }

  /// @inheritdoc IAtomicFacility
  function pauseFor(uint256 duration) external onlyOwnerOrRoles(COMPLIANCE_ROLE) {
    uint40 pauseUntil = LibPause.pauseFor(duration);
    _storage().pausedUntil = pauseUntil;
    emit AtomicFacilityPausedSet(pauseUntil);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          VIEWS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IAtomicFacility
  function getEntry(address positionManager) external view returns (EntryOffer memory offer) {
    return _storage().entries[positionManager];
  }

  /// @inheritdoc IAtomicFacility
  function getExit(address positionManager) external view returns (ExitOffer memory offer) {
    return _storage().exits[positionManager];
  }

  /// @inheritdoc IAtomicFacility
  function getSecurityCap(address asset) external view returns (uint256 cap) {
    return _storage().securityCaps[asset];
  }

  /// @inheritdoc IAtomicFacility
  function getAuth(address asset, address user) external view returns (Auth memory auth) {
    return _storage().auths[asset][user];
  }

  /// @inheritdoc IAtomicFacility
  function config() external view returns (address feeRecipient, bool isPaused, uint40 pausedUntil) {
    Storage storage s = _storage();
    feeRecipient = s.feeRecipient;
    pausedUntil = s.pausedUntil;
    isPaused = pausedUntil.paused();
  }

  /// @inheritdoc IAtomicFacility
  function previewEnter(address positionManager, uint256 amount)
    external
    view
    returns (uint256 debt, uint256 shares, uint256 feeShares)
  {
    amount.checkNotZero();
    EntryOffer storage offer = _enabledEntry(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    (uint256 totalCollateral, uint256 totalDebt) = _leveredPoolState(pm);
    debt = amount.mulDiv(totalDebt, totalCollateral);
    if (debt == 0) revert UnleveredPool(positionManager);
    uint256 minted = _estimateShares(pm, amount, totalCollateral, debt);
    feeShares = minted.mulDivUp(offer.feeBps, BPS);
    shares = minted - feeShares;
  }

  /// @inheritdoc IAtomicFacility
  function previewExit(address positionManager, uint256 shares)
    external
    view
    returns (uint256 debtIn, uint256 underlyingOut, uint256 feeShares)
  {
    shares.checkNotZero();
    ExitOffer storage offer = _enabledExit(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    if (pm.hasBadDebt()) revert BadDebtState(positionManager);
    uint256 burnShares;
    (burnShares, feeShares) = _splitExitFee(shares, offer.feeBps);
    uint256 supplyAdj = _adjustedSupply(pm);
    debtIn = pm.debtAmount().mulDivUp(burnShares, supplyAdj);
    underlyingOut = pm.collateralAmount().mulDiv(burnShares, supplyAdj);
  }

  /// @inheritdoc IAtomicFacility
  function maxEnter(address positionManager, address user) external view returns (uint256 amount) {
    EntryOffer storage offer = _enabledEntry(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    (uint256 totalCollateral, uint256 totalDebt) = _leveredPoolState(pm);
    (address collateralAsset,) = pm.assets();
    address asset = IWrappedAsset(collateralAsset).underlying();

    Storage storage s = _storage();
    uint256 debtMax = offer.capacityCap.available();
    uint256 security = s.securityCaps[asset].available();
    Auth storage auth = s.auths[asset][user];
    uint256 authed = block.timestamp < auth.expiry ? auth.amount : 0;
    // the security leg is the auth plus the security cap (saturating)
    uint256 securityLeg = security > type(uint256).max - authed ? type(uint256).max : security + authed;
    debtMax = debtMax.min(securityLeg);
    if (debtMax == type(uint256).max) return type(uint256).max;
    return _saturatingMulDiv(debtMax, totalCollateral, totalDebt);
  }

  /// @inheritdoc IAtomicFacility
  function maxExit(address positionManager) external view returns (uint256 shares) {
    ExitOffer storage offer = _enabledExit(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    if (pm.hasBadDebt()) revert BadDebtState(positionManager);
    uint256 debtMax = offer.cap.available();
    uint256 totalDebt = pm.debtAmount();
    if (debtMax == type(uint256).max || totalDebt == 0) return type(uint256).max;
    // largest burnable amount whose rounded-up debt slice fits the cap
    uint256 burnShares = _saturatingMulDiv(debtMax, _adjustedSupply(pm), totalDebt);
    // gross it up by the fee: net(gross) <= burnShares holds since the fee rounds up
    return _saturatingMulDiv(burnShares, BPS, BPS - offer.feeBps);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IAtomicFacility
  function enter(
    address positionManager,
    uint256 amount,
    uint256 minDebt,
    uint256 maxDebt,
    uint256 minSharesOut,
    address receiver
  ) external nonReentrant returns (uint256 shares, uint256 debt) {
    receiver.checkNotZero();
    amount.checkNotZero();
    EntryOffer storage offer = _enabledEntry(positionManager);

    Entry memory entry;
    entry.positionManager = positionManager;
    entry.receiver = receiver;
    entry.amount = amount;
    entry.minSharesOut = minSharesOut;
    entry.feeBps = offer.feeBps;
    (entry.collateralAsset, entry.debtAsset) = IPositionManager(positionManager).assets();
    entry.underlying = IWrappedAsset(entry.collateralAsset).underlying();
    {
      uint256 totalDebt;
      (entry.totalCollateral, totalDebt) = _leveredPoolState(IPositionManager(positionManager));
      debt = amount.mulDiv(totalDebt, entry.totalCollateral);
    }
    // a zero ratio-derived debt would slip past the debt-denominated caps for free
    if (debt == 0) revert UnleveredPool(positionManager);
    if (debt < minDebt || debt > maxDebt) revert DebtOutOfBounds(debt, minDebt, maxDebt);
    entry.debt = debt;

    // caps absorb the gross debt before any token interaction (CEI)
    offer.capacityCap = offer.capacityCap.consume(uint256(uint160(positionManager)), debt);
    _consumeSecurity(entry.underlying, debt);

    entry.underlying.safeTransferFrom(msg.sender, address(this), amount);
    uint256 feeShares;
    (shares, feeShares) = _enterAndForward(entry);
    emit Entered(positionManager, msg.sender, receiver, amount, debt, shares, feeShares);
  }

  /// @inheritdoc IAtomicFacility
  function exit(
    address positionManager,
    uint256 shares,
    uint256 maxDebtIn,
    uint256 minUnderlyingOut,
    address receiver,
    bytes calldata data
  ) external nonReentrant returns (uint256 underlyingOut, uint256 debtIn) {
    receiver.checkNotZero();
    shares.checkNotZero();
    ExitOffer storage offer = _enabledExit(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    if (pm.hasBadDebt()) revert BadDebtState(positionManager);

    Exit memory exit_;
    exit_.positionManager = positionManager;
    exit_.receiver = receiver;
    exit_.shares = shares;
    exit_.minUnderlyingOut = minUnderlyingOut;
    (exit_.collateralAsset, exit_.debtAsset) = pm.assets();
    (exit_.burnShares, exit_.feeShares) = _splitExitFee(shares, offer.feeBps);

    // Mirror of burn's debt math: post-accrual supply + virtual offset, rounded up. Final
    // before the callback: nothing outside this transaction can interleave, and any module
    // state change the callback makes is caught by the mirror check after burn.
    debtIn = pm.debtAmount().mulDivUp(exit_.burnShares, _adjustedSupply(pm));
    if (debtIn > maxDebtIn) revert ExcessiveDebtIn(debtIn, maxDebtIn);
    exit_.debt = debtIn;

    // the cap absorbs the gross debt before any token interaction (CEI); a pool that became
    // unlevered stays exitable
    if (debtIn > 0) offer.cap = offer.cap.consume(uint256(uint160(positionManager)), debtIn);

    underlyingOut = _burnAndUnwrap(exit_, data);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Consumes `debt` from the caller's auth on `asset` first, then the remainder from the
  ///      asset's security cap.
  function _consumeSecurity(address asset, uint256 debt) internal {
    Storage storage s = _storage();
    uint256 fromAuth;
    Auth storage auth = s.auths[asset][msg.sender];
    if (block.timestamp < auth.expiry) {
      uint256 authed = auth.amount;
      fromAuth = authed.min(debt);
      if (fromAuth > 0) {
        // casting to 'uint128' is safe because authed - fromAuth <= authed, which is a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 remaining = uint128(authed - fromAuth);
        auth.amount = remaining;
        emit AuthConsumed(asset, msg.sender, fromAuth, remaining);
      }
    }
    uint256 fromSecurity = debt - fromAuth;
    if (fromSecurity > 0) {
      s.securityCaps[asset] = s.securityCaps[asset].consume(uint256(uint160(asset)), fromSecurity);
    }
  }

  /// @dev Wraps `amount` underlying already held by the facility 1:1 into the PM's collateral,
  ///      enters the PM at the live ratio, checks the mint against the ratio-matched fraction,
  ///      then forwards the debt and the shares net of fee to `receiver` and the fee shares to
  ///      the recipient. Approvals are exact and reset after use.
  function _enterAndForward(Entry memory entry) internal returns (uint256 shares, uint256 feeShares) {
    IPositionManager pm = IPositionManager(entry.positionManager);

    // Fair mint for a ratio-matched entrant is the fraction `amount / C` of the post-accrual
    // supply (virtual offset included, as burn's denominator). Under one quote the actual mint
    // is that times `TA / (TA + 1)` plus rounding: one debt-wei from rounding the debt down and
    // one per module the deposit touches (each floors its quoted collateral on both sides of
    // the flow). The tolerance is that many debt-wei worth of shares plus one share; anything
    // above is a transfer from holders and is refused.
    uint256 expected;
    uint256 tolerance;
    {
      uint256 supplyAdj = _adjustedSupply(pm);
      expected = supplyAdj.mulDiv(entry.amount, entry.totalCollateral);
      tolerance = supplyAdj.mulDivUp(2 + pm.supplyQueue().length, pm.totalAssets() + 1) + 1;
    }

    entry.underlying.safeApproveWithRetry(entry.collateralAsset, entry.amount);
    IWrappedAsset(entry.collateralAsset).mint(address(this), entry.amount);
    entry.underlying.safeApproveWithRetry(entry.collateralAsset, 0);
    entry.collateralAsset.safeApproveWithRetry(entry.positionManager, entry.amount);
    int256 sharesDelta = pm.deposit(entry.amount, entry.debt);
    entry.collateralAsset.safeApproveWithRetry(entry.positionManager, 0);

    if (sharesDelta <= 0) revert InsufficientSharesOut(0, entry.minSharesOut);
    // casting to 'uint256' is safe because sharesDelta is positive past the check above
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 minted = uint256(sharesDelta);
    if (minted > expected + tolerance) revert NonNeutralMint(minted, expected);

    feeShares = minted.mulDivUp(entry.feeBps, BPS);
    shares = minted - feeShares;
    if (shares < entry.minSharesOut) revert InsufficientSharesOut(shares, entry.minSharesOut);

    entry.debtAsset.safeTransfer(entry.receiver, entry.debt);
    if (feeShares > 0) entry.positionManager.safeTransfer(_storage().feeRecipient, feeShares);
    if (shares > 0) entry.positionManager.safeTransfer(entry.receiver, shares);
  }

  /// @dev Pulls `shares` PM shares, runs the exit callback when `data` is non-empty, pulls
  ///      exactly `debt` debt asset from the caller, repays and burns the shares net of fee,
  ///      forwards the fee shares to the recipient, then unwraps the collateral straight to
  ///      `receiver` and emits the exit event. Approvals are exact and reset.
  function _burnAndUnwrap(Exit memory exit_, bytes calldata data) internal returns (uint256 collateralOut) {
    exit_.positionManager.safeTransferFrom(msg.sender, address(this), exit_.shares);
    // The facility holds the shares and the PM is in no guarded frame: every PM view the
    // callback reads returns exactly the inputs the mirror math used. Settlement is pull-only.
    if (data.length > 0) {
      IAtomicExitCallback(msg.sender).onAtomicExit(exit_.positionManager, exit_.shares, exit_.debt, data);
    }
    if (exit_.debt > 0) {
      exit_.debtAsset.safeTransferFrom(msg.sender, address(this), exit_.debt);
      exit_.debtAsset.safeApproveWithRetry(exit_.positionManager, exit_.debt);
    }
    uint256 debtPulled;
    (collateralOut, debtPulled) =
      IPositionManager(exit_.positionManager).burn(exit_.burnShares, WithdrawalStrategy.PROPORTIONAL);
    // Divergence below burn's figure already fails on burn's allowance pull; divergence above
    // would silently strand the difference here. Fail loudly instead (mirror symmetry).
    if (debtPulled != exit_.debt) revert DebtMirrorMismatch(exit_.debt, debtPulled);
    if (exit_.debt > 0) exit_.debtAsset.safeApproveWithRetry(exit_.positionManager, 0);
    if (collateralOut < exit_.minUnderlyingOut) {
      revert InsufficientUnderlyingOut(collateralOut, exit_.minUnderlyingOut);
    }
    if (exit_.feeShares > 0) exit_.positionManager.safeTransfer(_storage().feeRecipient, exit_.feeShares);
    if (collateralOut > 0) IWrappedAsset(exit_.collateralAsset).burn(address(this), exit_.receiver, collateralOut);
    emit Exited(
      exit_.positionManager, msg.sender, exit_.receiver, collateralOut, exit_.debt, exit_.burnShares, exit_.feeShares
    );
  }

  /// @dev Splits the shares of an exit into the burned part and the fee part (rounded up for
  ///      the recipient). Reverts with NothingToBurn when the fee takes everything.
  function _splitExitFee(uint256 shares, uint24 feeBps) internal pure returns (uint256 burnShares, uint256 feeShares) {
    feeShares = shares.mulDivUp(feeBps, BPS);
    burnShares = shares - feeShares;
    if (burnShares == 0) revert NothingToBurn();
  }

  /// @dev Returns the entry offer of `positionManager`, reverting with UnknownEntry when it is
  ///      disabled or expired, and with Paused while the facility-wide pause is active.
  function _enabledEntry(address positionManager) internal view returns (EntryOffer storage offer) {
    if (_storage().pausedUntil.paused()) revert LibCommonErrors.Paused();
    offer = _storage().entries[positionManager];
    if (block.timestamp >= offer.expiry) revert UnknownEntry(positionManager);
  }

  /// @dev Returns the exit offer of `positionManager`, reverting with UnknownExit when it is
  ///      disabled or expired, and with Paused while the facility-wide pause is active.
  function _enabledExit(address positionManager) internal view returns (ExitOffer storage offer) {
    if (_storage().pausedUntil.paused()) revert LibCommonErrors.Paused();
    offer = _storage().exits[positionManager];
    if (block.timestamp >= offer.expiry) revert UnknownExit(positionManager);
  }

  /// @dev Returns the pool aggregates for an entry, enforcing the bad-debt and unlevered gates:
  ///      pricing against a bad-debt universe is undefined, and with no rate field there is no
  ///      bootstrap ratio for an empty or unlevered pool.
  function _leveredPoolState(IPositionManager pm) internal view returns (uint256 totalCollateral, uint256 totalDebt) {
    if (pm.hasBadDebt()) revert BadDebtState(address(pm));
    totalCollateral = pm.collateralAmount();
    totalDebt = pm.debtAmount();
    if (totalCollateral == 0 || totalDebt == 0) revert UnleveredPool(address(pm));
  }

  /// @dev Returns burn's exact share denominator: the post-fee-accrual total supply (pending
  ///      management and performance fee shares included) plus the virtual share offset.
  function _adjustedSupply(IPositionManager pm) internal view returns (uint256 supplyAdj) {
    (, uint256 totalSupply_, uint256 mgmtFeeShares, uint256 perfFeeShares) = pm.pendingFees();
    return totalSupply_ + mgmtFeeShares + perfFeeShares + pm.virtualShareOffset();
  }

  /// @dev Best-effort share estimate for previews: quoted equity added, converted at the
  ///      pre-flow share price (post-fee-accrual supply, as PM.deposit accrues fees first).
  function _estimateShares(IPositionManager pm, uint256 amount, uint256 totalCollateral, uint256 debt)
    internal
    view
    returns (uint256 shares)
  {
    uint256 quoted = pm.collateralAmountQuoted().mulDiv(amount, totalCollateral);
    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtFeeShares, uint256 perfFeeShares) = pm.pendingFees();
    shares = LibView.convertToShares(
      quoted.zeroFloorSub(debt),
      totalSupply_ + mgmtFeeShares + perfFeeShares,
      totalAssets_,
      pm.virtualShareOffset(),
      false
    );
  }

  /// @dev `x * y / d` rounded down, saturating at type(uint256).max instead of reverting
  ///      (an ABSOLUTE word near MAX_ABSOLUTE scaled by a decimals gap overflows). `d` nonzero.
  function _saturatingMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
    uint256 q = x / d;
    uint256 r = x - q * d;
    if (q != 0 && q > type(uint256).max / y) return type(uint256).max;
    uint256 base = q * y;
    // r < d, so r * y / d < y fits and mulDiv's 512-bit intermediate cannot overflow the result
    uint256 rest = r.mulDiv(y, d);
    unchecked {
      result = base + rest;
    }
    if (result < base) return type(uint256).max;
  }

  /// @dev Validates a word that must bound entries: LibCaps.validate, plus an EXTERNAL word must
  ///      carry a positive multiplier (zero or negative would consume nothing, i.e. no cap).
  function _validateConsumingWord(uint256 word) internal view {
    word.validate(CAPS_WHITELIST);
    if (word.capType() == CapType.EXTERNAL) {
      (,, int24 multiplier) = word.decodeExternal();
      if (multiplier <= 0) revert NonConsumingCap(word);
    }
  }

  /// @dev Validates that `positionManager` exposes the PM surface this facility needs: assets()
  ///      must resolve to a wrapped collateral with a nonzero underlying.
  function _validatePositionManager(address positionManager) internal view {
    if (positionManager.code.length == 0) revert InvalidPositionManager(positionManager);
    try IPositionManager(positionManager).assets() returns (address collateralAsset, address) {
      if (collateralAsset.code.length == 0) revert InvalidPositionManager(positionManager);
      try IWrappedAsset(collateralAsset).underlying() returns (address underlying) {
        if (underlying == address(0)) revert InvalidPositionManager(positionManager);
      } catch {
        revert InvalidPositionManager(positionManager);
      }
    } catch {
      revert InvalidPositionManager(positionManager);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   REENTRANCY GUARD TRANSIENT               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Use the transient reentrancy guard on all chains.
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
