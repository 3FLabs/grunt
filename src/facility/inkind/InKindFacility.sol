// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {IInKindFacility, EntryOffer, ExitOffer, Auth} from "../../interfaces/facility/IInKindFacility.sol";
import {IInKindExitCallback} from "../../interfaces/facility/IInKindExitCallback.sol";
import {IFacilityCapsWhitelist} from "../../interfaces/facility/IFacilityCapsWhitelist.sol";
import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {WithdrawalStrategy} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {LibCaps, CapType} from "../../libs/facility/LibCaps.sol";
import {LibInKindStorage, InKindStorageData} from "../../libs/facility/inkind/LibInKindStorage.sol";
import {LibInKindView} from "../../libs/facility/inkind/LibInKindView.sol";
import {LibSaturatingMath} from "../../libs/common/LibSaturatingMath.sol";
import {LibPause} from "../../libs/common/LibPause.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {BPS} from "../../libs/Constants.sol";

/// @title InKindFacility
/// @author 3F Protocol
/// @notice Permissionless in-kind entry and exit over PositionManager (PM) vaults. An entry wraps
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
///      - The ratio is read from the PM's views. The Morpho borrow position quotes accrued debt
///        (expected market balances); a module whose `totalBorrowed` lags the market would let
///        flows use a stale ratio. Only serve PMs whose modules quote accrued debt.
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
contract InKindFacility is IInKindFacility, OwnableRoles, ReentrancyGuardTransient, Initializable {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using LibCaps for uint256;
  using LibInKindStorage for InKindStorageData;
  using LibInKindView for IPositionManager;
  using LibChecks for address;
  using LibChecks for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to set entry and exit offers.
  uint256 internal constant FACILITATOR_ROLE = _ROLE_0;
  /// @notice Role for addresses authorized to pause the facility.
  /// @dev `_ROLE_1` is left free so the bits line up with the Facility family.
  uint256 internal constant COMPLIANCE_ROLE = _ROLE_2;
  /// @notice Role for addresses authorized to set security caps and user auths.
  uint256 internal constant OPERATOR_ROLE = _ROLE_3;

  /// @notice Maximum fee on either side: 10% of the shares.
  uint256 internal constant MAX_FEE = 1_000;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The registry of caps contracts an EXTERNAL cap word may reference.
  IFacilityCapsWhitelist public immutable CAPS_WHITELIST;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TYPES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
    LibInKindStorage.inKindStorage().feeRecipient = feeRecipient_;
    emit FeeRecipientSet(feeRecipient_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IInKindFacility
  function setEntry(address positionManager, uint256 capacityCap, uint40 expiry, uint24 feeBps)
    external
    onlyOwnerOrRoles(FACILITATOR_ROLE)
  {
    if (feeBps > MAX_FEE) revert FeeExceedsMax();
    LibInKindView.validatePositionManager(positionManager);
    _validateConsumingWord(capacityCap);
    LibInKindStorage.inKindStorage().entries[positionManager] =
      EntryOffer({capacityCap: capacityCap, expiry: expiry, feeBps: feeBps});
    emit EntrySet(positionManager, capacityCap, expiry, feeBps);
  }

  /// @inheritdoc IInKindFacility
  function setExit(address positionManager, uint256 cap, uint40 expiry, uint24 feeBps)
    external
    onlyOwnerOrRoles(FACILITATOR_ROLE)
  {
    if (feeBps > MAX_FEE) revert FeeExceedsMax();
    LibInKindView.validatePositionManager(positionManager);
    cap.validate(CAPS_WHITELIST);
    LibInKindStorage.inKindStorage().exits[positionManager] = ExitOffer({cap: cap, expiry: expiry, feeBps: feeBps});
    emit ExitSet(positionManager, cap, expiry, feeBps);
  }

  /// @inheritdoc IInKindFacility
  function setSecurityCap(address asset, uint256 cap) external onlyOwnerOrRoles(OPERATOR_ROLE) {
    asset.checkNotZero();
    _validateConsumingWord(cap);
    LibInKindStorage.inKindStorage().securityCaps[asset] = cap;
    emit SecurityCapSet(asset, cap);
  }

  /// @inheritdoc IInKindFacility
  function setAuth(address asset, address user, uint128 amount, uint40 expiry)
    external
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    asset.checkNotZero();
    user.checkNotZero();
    LibInKindStorage.inKindStorage().auths[asset][user] = Auth({amount: amount, expiry: expiry});
    emit AuthSet(asset, user, amount, expiry);
  }

  /// @inheritdoc IInKindFacility
  function setFeeRecipient(address feeRecipient) external onlyOwner {
    feeRecipient.checkNotZero();
    LibInKindStorage.inKindStorage().feeRecipient = feeRecipient;
    emit FeeRecipientSet(feeRecipient);
  }

  /// @inheritdoc IInKindFacility
  function pauseFor(uint256 duration) external onlyOwnerOrRoles(COMPLIANCE_ROLE) {
    uint40 pauseUntil = LibPause.pauseFor(duration);
    LibInKindStorage.inKindStorage().pausedUntil = pauseUntil;
    emit InKindFacilityPausedSet(pauseUntil);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          VIEWS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IInKindFacility
  function getEntry(address positionManager) external view returns (EntryOffer memory offer) {
    return LibInKindStorage.inKindStorage().entries[positionManager];
  }

  /// @inheritdoc IInKindFacility
  function getExit(address positionManager) external view returns (ExitOffer memory offer) {
    return LibInKindStorage.inKindStorage().exits[positionManager];
  }

  /// @inheritdoc IInKindFacility
  function getSecurityCap(address asset) external view returns (uint256 cap) {
    return LibInKindStorage.inKindStorage().securityCaps[asset];
  }

  /// @inheritdoc IInKindFacility
  function getAuth(address asset, address user) external view returns (Auth memory auth) {
    return LibInKindStorage.inKindStorage().auths[asset][user];
  }

  /// @inheritdoc IInKindFacility
  function config() external view returns (address feeRecipient, bool isPaused, uint40 pausedUntil) {
    InKindStorageData storage s = LibInKindStorage.inKindStorage();
    feeRecipient = s.feeRecipient;
    pausedUntil = s.pausedUntil;
    isPaused = LibPause.paused(pausedUntil);
  }

  /// @inheritdoc IInKindFacility
  function previewEnter(address positionManager, uint256 amount)
    external
    view
    returns (uint256 debt, uint256 shares, uint256 feeShares)
  {
    amount.checkNotZero();
    EntryOffer storage offer = LibInKindStorage.inKindStorage().getEnabledEntry(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    (uint256 totalCollateral, uint256 totalDebt) = pm.leveredPoolState();
    debt = amount.mulDiv(totalDebt, totalCollateral);
    if (debt == 0) revert UnleveredPool(positionManager);
    (shares, feeShares) = LibInKindView.splitFee(pm.estimateShares(amount, totalCollateral, debt), offer.feeBps);
  }

  /// @inheritdoc IInKindFacility
  function previewExit(address positionManager, uint256 shares)
    external
    view
    returns (uint256 debtIn, uint256 underlyingOut, uint256 feeShares)
  {
    shares.checkNotZero();
    ExitOffer storage offer = LibInKindStorage.inKindStorage().getEnabledExit(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    (uint256 burnShares, uint256 fee) = _splitExitShares(shares, offer.feeBps);
    return (pm.exitDebt(burnShares), pm.exitCollateral(burnShares), fee);
  }

  /// @inheritdoc IInKindFacility
  function maxEnter(address positionManager, address user) external view returns (uint256 amount) {
    InKindStorageData storage s = LibInKindStorage.inKindStorage();
    EntryOffer storage offer = s.getEnabledEntry(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    (uint256 totalCollateral, uint256 totalDebt) = pm.leveredPoolState();
    uint256 debtMax = s.securityLimit(pm.underlying(), user).min(offer.capacityCap.available());
    return LibSaturatingMath.mulDiv(debtMax, totalCollateral, totalDebt);
  }

  /// @inheritdoc IInKindFacility
  function maxExit(address positionManager) external view returns (uint256 shares) {
    ExitOffer storage offer = LibInKindStorage.inKindStorage().getEnabledExit(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    pm.checkNoBadDebt();
    uint256 totalDebt = pm.debtAmount();
    if (totalDebt == 0) return type(uint256).max;
    // largest burnable amount whose rounded-up debt slice fits the cap, grossed up by the fee
    // (net(gross) <= burnShares holds since the fee rounds up)
    uint256 burnShares = LibSaturatingMath.mulDiv(offer.cap.available(), pm.adjustedSupply(), totalDebt);
    return LibSaturatingMath.mulDiv(burnShares, BPS, BPS - offer.feeBps);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IInKindFacility
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
    InKindStorageData storage s = LibInKindStorage.inKindStorage();
    EntryOffer storage offer = s.getEnabledEntry(positionManager);
    IPositionManager pm = IPositionManager(positionManager);

    Entry memory entry;
    entry.positionManager = positionManager;
    entry.receiver = receiver;
    entry.amount = amount;
    entry.minSharesOut = minSharesOut;
    entry.feeBps = offer.feeBps;
    (entry.collateralAsset, entry.debtAsset) = pm.assets();
    entry.underlying = IWrappedAsset(entry.collateralAsset).underlying();
    {
      uint256 totalDebt;
      (entry.totalCollateral, totalDebt) = pm.leveredPoolState();
      debt = amount.mulDiv(totalDebt, entry.totalCollateral);
    }
    // a zero ratio-derived debt would slip past the debt-denominated caps for free
    if (debt == 0) revert UnleveredPool(positionManager);
    if (debt < minDebt || debt > maxDebt) revert DebtOutOfBounds(debt, minDebt, maxDebt);
    entry.debt = debt;

    // caps absorb the gross debt before any token interaction (CEI)
    offer.capacityCap = offer.capacityCap.consume(LibInKindStorage.capId(positionManager), debt);
    s.consumeSecurity(entry.underlying, msg.sender, debt);

    entry.underlying.safeTransferFrom(msg.sender, address(this), amount);
    uint256 feeShares;
    (shares, feeShares) = _enterAndForward(entry);
    emit Entered(positionManager, msg.sender, receiver, amount, debt, shares, feeShares);
  }

  /// @inheritdoc IInKindFacility
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
    ExitOffer storage offer = LibInKindStorage.inKindStorage().getEnabledExit(positionManager);
    IPositionManager pm = IPositionManager(positionManager);

    Exit memory exit_;
    exit_.positionManager = positionManager;
    exit_.receiver = receiver;
    exit_.shares = shares;
    exit_.minUnderlyingOut = minUnderlyingOut;
    (exit_.collateralAsset, exit_.debtAsset) = pm.assets();
    (exit_.burnShares, exit_.feeShares) = _splitExitShares(shares, offer.feeBps);

    // Mirror of burn's debt math, final before the callback: nothing outside this transaction
    // can interleave, and any module state change the callback makes is caught by the mirror
    // check after burn.
    debtIn = pm.exitDebt(exit_.burnShares);
    if (debtIn > maxDebtIn) revert ExcessiveDebtIn(debtIn, maxDebtIn);
    exit_.debt = debtIn;

    // the cap absorbs the gross debt before any token interaction (CEI); a pool that became
    // unlevered stays exitable
    if (debtIn > 0) offer.cap = offer.cap.consume(LibInKindStorage.capId(positionManager), debtIn);

    underlyingOut = _burnAndUnwrap(exit_, data);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Wraps `amount` underlying already held by the facility 1:1 into the PM's collateral,
  ///      enters the PM at the live ratio, checks the mint against the ratio-matched fraction,
  ///      then forwards the debt and the shares net of fee to `receiver` and the fee shares to
  ///      the recipient. Approvals are exact and reset after use.
  function _enterAndForward(Entry memory entry) internal returns (uint256 shares, uint256 feeShares) {
    IPositionManager pm = IPositionManager(entry.positionManager);
    (uint256 expected, uint256 tolerance) = pm.fairMint(entry.amount, entry.totalCollateral);

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
    // anything above the fair fraction plus rounding is a transfer from holders
    if (minted > expected + tolerance) revert NonNeutralMint(minted, expected);

    (shares, feeShares) = LibInKindView.splitFee(minted, entry.feeBps);
    if (shares < entry.minSharesOut) revert InsufficientSharesOut(shares, entry.minSharesOut);

    entry.debtAsset.safeTransfer(entry.receiver, entry.debt);
    if (feeShares > 0) entry.positionManager.safeTransfer(LibInKindStorage.inKindStorage().feeRecipient, feeShares);
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
      IInKindExitCallback(msg.sender).onInKindExit(exit_.positionManager, exit_.shares, exit_.debt, data);
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
    if (exit_.feeShares > 0) {
      exit_.positionManager.safeTransfer(LibInKindStorage.inKindStorage().feeRecipient, exit_.feeShares);
    }
    if (collateralOut > 0) IWrappedAsset(exit_.collateralAsset).burn(address(this), exit_.receiver, collateralOut);
    emit Exited(
      exit_.positionManager, msg.sender, exit_.receiver, collateralOut, exit_.debt, exit_.burnShares, exit_.feeShares
    );
  }

  /// @dev Splits the shares of an exit into the burned part and the fee part, reverting with
  ///      NothingToBurn when the fee takes everything.
  function _splitExitShares(uint256 shares, uint24 feeBps)
    internal
    pure
    returns (uint256 burnShares, uint256 feeShares)
  {
    (burnShares, feeShares) = LibInKindView.splitFee(shares, feeBps);
    if (burnShares == 0) revert NothingToBurn();
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   REENTRANCY GUARD TRANSIENT               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Use the transient reentrancy guard on all chains.
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
