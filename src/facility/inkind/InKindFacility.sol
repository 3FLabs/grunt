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
import {LibManagerErrors} from "../../libs/manager/LibManagerErrors.sol";
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
///      gives entry capacity back. A pool with no debt moves none, so every cap reads as zero on
///      it: those flows are gated by the offers alone (see the known limitations).
///
///      Trust surface: the facility holds MINTER_ROLE on each PM it serves and is itself
///      permissionless, so anyone can reach PM.deposit and PM.burn through it, including from
///      Morpho or Request callbacks. Disabling an offer does not revoke that role. The facility
///      needs SENDER_ROLE on the wrapper and the consumer role on every caps contract its words
///      use, and must pass the PM's TransferGuard and the underlying's transfer restrictions; so
///      must share receivers and the fee recipient (it holds PM shares). Entry payers are not
///      guard-checked.
///
///      Security caps and auths bound in-kind borrowing against unbacked issuer mints. Whoever
///      controls them must be a trusted multisig: the owner and OPERATOR here and, for an
///      EXTERNAL security word, the caps contract's owner and managers, the whitelist owner and
///      the FACILITATOR of any consumer able to credit its pools with a negative word. Prefer a
///      dynamic security word.
///
///      Known limitations:
///      - Entries need the pool's LTV at or below the PM's target `ltv`, as PM.deposit sizes
///        every borrow at it: above it they revert and {maxEnter} returns zero. The views read
///        the quoted LTV, so within a few debt units of the target they can disagree with
///        PM.deposit. Exits revert while a withdrawal-queue module is above its safeLtv.
///      - Multi-module PMs with divergent per-module quotes: the receiving module prices the
///        deposit while the debt leg is aggregate. Serve PMs whose modules share one price feed.
///        Round trips also shift positions toward the supply-queue head; prefer single-module PMs.
///      - The ratio is read from the PM's views. The Morpho borrow position quotes accrued debt
///        (expected market balances); a module whose `totalBorrowed` lags the market would let
///        flows use a stale ratio. Only serve PMs whose modules quote accrued debt.
///      - A module above its liquidation LTV but below 100% is not bad debt. An exit while the
///        PM's withdrawal queue excludes that module leaves the penalty on stayers. Serve PMs
///        whose withdrawal queue covers every module.
///      - Exits burn PROPORTIONAL, touching every withdrawal-queue module, so each must repay and
///        withdraw atomically. A module that cannot has to leave the withdrawal queue, at the
///        cost above, and exits then need each remaining module at or below the target LTV.
///      - Exits do not refund the security cap: a dynamic one is throughput only and an ABSOLUTE
///        one a lifetime budget, so a looper drains it at the cost of two share fees plus
///        rounding per loop. Size the fees accordingly.
///      - An exit word on a shared absolute pool with a negative multiplier credits the debt each
///        exit repays, not what entries consumed: interest, shares that never entered and any
///        change in debt per share outside in-kind flows (REBALANCER or Retargetter lever-ups
///        and delevers, liquidations, third-party repays) move the pool. Lever-ups over-credit
///        it, so it drifts to its hard cap and exits above the headroom revert `HardCapExceeded`
///        until entries consume headroom, the facilitator re-arms the word or setCap raises the
///        hard cap. Delevers under-credit it, stranding capacity after the last in-kind holder
///        leaves until the caps manager reconciles the pool. Leave hard-cap slack and reconcile
///        the pool after large rebalances.
///      - An ABSOLUTE exit word is drainable by enter/exit loops at fee cost, blocking exits for
///        everyone until re-armed. Prefer the shared-pool netting (entry +1x, exit -1x).
///      - Any revert inside the PM's fee accrual (a de-allowlisted PM fee recipient) reverts every
///        flow. A fee recipient here failing the PM's guard reverts every flow with a nonzero fee.
///      - The underlying and the debt asset must be exact-transfer tokens (no fee on transfer,
///        no rebasing, no transfer hooks), as required by every fund adapter.
///      - An unlevered pool (`D == 0`) is served on the entry side only under the offer's
///        `allowUnlevered` flag, and on the exit side always (a pool that repays to zero must
///        stay exitable). Both borrow and repay nothing, so no cap, auth or per-user gate binds
///        them: the flag and the offer expiry are the only levers, and size is unbounded. Set
///        the flag only on PMs whose in-kind size is acceptable unbounded.
///      - Gains between NAV prints travel with the collateral, so an exit before a print and a
///        re-entry after it skip the PM performance fee on that gain (a loss to the PM fee
///        recipient, not to holders). The share fees are the deterrent.
///      - Anyone can checkpoint the PM's fees with a dust flow: at a quote trough it lowers the
///        performance reference, at a peak it crystallizes a gain a reversal never refunds.
///        Serve PMs whose quote does not fall, or with no performance fee.
///      - On a Retargetter-bound PM, flows move an open operation's principal cap and
///        settlement bound. Close the offers during ASYNC operations.
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
  /// @dev Only grant it to a trusted multisig (see the security caps note above).
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
    uint256 debtRequired;
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
  function setEntry(address positionManager, uint256 capacityCap, uint40 expiry, uint24 feeBps, bool allowUnlevered)
    external
    onlyOwnerOrRoles(FACILITATOR_ROLE)
  {
    if (feeBps > MAX_FEE) revert FeeExceedsMax();
    LibInKindView.validatePositionManager(positionManager);
    _validateConsumingWord(capacityCap);
    LibInKindStorage.inKindStorage().entries[positionManager] =
      EntryOffer({capacityCap: capacityCap, expiry: expiry, feeBps: feeBps, allowUnlevered: allowUnlevered});
    emit EntrySet(positionManager, capacityCap, expiry, feeBps, allowUnlevered);
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
    (uint256 totalCollateral, uint256 totalDebt) = pm.entryPoolState(offer.allowUnlevered);
    debt = amount.mulDiv(totalDebt, totalCollateral);
    if (totalDebt > 0 && debt == 0) revert DustEntry(amount);
    // PM.deposit reverts the same way: it sizes every borrow at the target LTV
    if (pm.aboveTargetLtv(totalDebt)) revert LibManagerErrors.InsufficientBorrowCapacity();
    (shares, feeShares) = LibInKindView.splitFee(pm.estimateShares(amount, totalCollateral, debt), offer.feeBps);
  }

  /// @inheritdoc IInKindFacility
  function previewExit(address positionManager, uint256 shares)
    external
    view
    returns (uint256 debtIn, uint256 underlyingOut, uint256 feeShares, uint256 debtRequired)
  {
    shares.checkNotZero();
    ExitOffer storage offer = LibInKindStorage.inKindStorage().getEnabledExit(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    uint256 burnShares;
    (burnShares, feeShares) = _splitExitShares(shares, offer.feeBps);
    debtIn = pm.exitDebt(burnShares);
    underlyingOut = pm.exitCollateral(burnShares);
    debtRequired = LibInKindView.exitDebtRequired(debtIn);
  }

  /// @inheritdoc IInKindFacility
  function maxEnter(address positionManager, address user) external view returns (uint256 amount) {
    InKindStorageData storage s = LibInKindStorage.inKindStorage();
    EntryOffer storage offer = s.getEnabledEntry(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    (uint256 totalCollateral, uint256 totalDebt) = pm.entryPoolState(offer.allowUnlevered);
    // an unlevered entry borrows nothing, so no debt-denominated cap bounds it
    if (totalDebt == 0) return type(uint256).max;
    if (pm.aboveTargetLtv(totalDebt)) return 0;
    (, address debtAsset) = pm.assets();
    uint256 debtMax = s.securityLimit(pm.underlying(), user, debtAsset).min(offer.capacityCap.available(debtAsset));
    return LibSaturatingMath.mulDiv(debtMax, totalCollateral, totalDebt);
  }

  /// @inheritdoc IInKindFacility
  function maxExit(address positionManager) external view returns (uint256 shares) {
    ExitOffer storage offer = LibInKindStorage.inKindStorage().getEnabledExit(positionManager);
    IPositionManager pm = IPositionManager(positionManager);
    pm.checkNoBadDebt();
    uint256 totalDebt = pm.debtAmount();
    if (totalDebt == 0) return type(uint256).max;
    // largest burnable amount whose rounded-up debt slice fits the cap, then the largest gross
    // amount burning at most that after the rounded-up fee
    (, address debtAsset) = pm.assets();
    uint256 burnShares = LibSaturatingMath.mulDiv(offer.cap.available(debtAsset), pm.adjustedSupply(), totalDebt);
    return LibInKindView.grossForNet(burnShares, offer.feeBps);
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
    _checkReceiver(receiver);
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
      (entry.totalCollateral, totalDebt) = pm.entryPoolState(offer.allowUnlevered);
      debt = amount.mulDiv(totalDebt, entry.totalCollateral);
      // in a levered pool a zero ratio-derived debt would slip past the debt-denominated caps
      // for free; in an unlevered one there is no debt to bound
      if (totalDebt > 0 && debt == 0) revert DustEntry(amount);
    }
    if (debt < minDebt || debt > maxDebt) revert DebtOutOfBounds(debt, minDebt, maxDebt);
    entry.debt = debt;

    // caps absorb the gross debt before any token interaction (CEI)
    if (debt > 0) {
      offer.capacityCap = offer.capacityCap.consume(LibInKindStorage.capId(positionManager), debt, entry.debtAsset);
      s.consumeSecurity(entry.underlying, msg.sender, debt, entry.debtAsset);
    }

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
    _checkReceiver(receiver);
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

    // Mirror of burn's debt math. The callback can move it (a repay on behalf of a module grows
    // burn's fee accrual), so the pull carries a headroom and the unused part is refunded.
    exit_.debtRequired = LibInKindView.exitDebtRequired(pm.exitDebt(exit_.burnShares));
    if (exit_.debtRequired > maxDebtIn) revert ExcessiveDebtIn(exit_.debtRequired, maxDebtIn);

    (underlyingOut, debtIn) = _burnAndUnwrap(exit_, data);

    // the cap absorbs the debt burn repaid, not the mirror: a credit word must not credit debt
    // the callback kept burn from repaying. Runs after the token moves, under nonReentrant and
    // against a whitelisted caps contract; a pool that became unlevered stays exitable.
    if (debtIn > 0) offer.cap = offer.cap.consume(LibInKindStorage.capId(positionManager), debtIn, exit_.debtAsset);
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

    if (entry.debt > 0) entry.debtAsset.safeTransfer(entry.receiver, entry.debt);
    if (feeShares > 0) entry.positionManager.safeTransfer(LibInKindStorage.inKindStorage().feeRecipient, feeShares);
    if (shares > 0) entry.positionManager.safeTransfer(entry.receiver, shares);
  }

  /// @dev Pulls `shares` PM shares, runs the exit callback when `data` is non-empty and checks
  ///      bad debt again after it, pulls `debtRequired` debt asset from the caller, repays and
  ///      burns the shares net of fee, refunds the debt burn left unused, forwards the fee shares
  ///      to the recipient, then unwraps the collateral straight to `receiver` and emits the exit
  ///      event. Approvals are exact and reset.
  function _burnAndUnwrap(Exit memory exit_, bytes calldata data)
    internal
    returns (uint256 collateralOut, uint256 debtPulled)
  {
    exit_.positionManager.safeTransferFrom(msg.sender, address(this), exit_.shares);
    // The facility holds the shares and the PM is in no guarded frame: every PM view the
    // callback reads returns exactly the inputs the mirror math used. Settlement is pull-only.
    if (data.length > 0) {
      IInKindExitCallback(msg.sender).onInKindExit(exit_.positionManager, exit_.shares, exit_.debtRequired, data);
      // the callback can push a module into bad debt (a Morpho liquidation)
      IPositionManager(exit_.positionManager).checkNoBadDebt();
    }
    if (exit_.debtRequired > 0) {
      exit_.debtAsset.safeTransferFrom(msg.sender, address(this), exit_.debtRequired);
      exit_.debtAsset.safeApproveWithRetry(exit_.positionManager, exit_.debtRequired);
    }
    // burn pulls at most the approved headroom, or reverts on the allowance
    (collateralOut, debtPulled) =
      IPositionManager(exit_.positionManager).burn(exit_.burnShares, WithdrawalStrategy.PROPORTIONAL);
    if (exit_.debtRequired > 0) {
      exit_.debtAsset.safeApproveWithRetry(exit_.positionManager, 0);
      uint256 refund = exit_.debtRequired - debtPulled;
      if (refund > 0) exit_.debtAsset.safeTransfer(msg.sender, refund);
    }
    if (collateralOut < exit_.minUnderlyingOut) {
      revert InsufficientUnderlyingOut(collateralOut, exit_.minUnderlyingOut);
    }
    if (exit_.feeShares > 0) {
      exit_.positionManager.safeTransfer(LibInKindStorage.inKindStorage().feeRecipient, exit_.feeShares);
    }
    if (collateralOut > 0) IWrappedAsset(exit_.collateralAsset).burn(address(this), exit_.receiver, collateralOut);
    emit Exited(
      exit_.positionManager, msg.sender, exit_.receiver, collateralOut, debtPulled, exit_.burnShares, exit_.feeShares
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

  /// @dev Rejects zero and the facility itself, where tokens would be stuck.
  function _checkReceiver(address receiver) internal view {
    receiver.checkNotZero();
    if (receiver == address(this)) revert InvalidReceiver(receiver);
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
