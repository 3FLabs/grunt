// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {InKindFacility} from "src/facility/inkind/InKindFacility.sol";
import {IInKindFacility, Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IMorpho, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";

/// @title InKindFacilityHandler
/// @notice Handler contract for InKindFacility invariant tests.
/// @dev Provides fuzzed action functions that exercise the in-kind lifecycle: entries and exits
///      by a fixed set of users, direct PM seeding by the ops seeder, time warps, oracle moves,
///      interest accrual, offer / security cap / auth re-arms with ABSOLUTE words and compliance
///      pauses. Every action ends with a ghost snapshot (`_afterOp`) so the invariant contract
///      can assert:
///      - INK-1: the facility is a pure pass-through: it holds no underlying, wrapper, debt
///        asset or PM shares after an action.
///      - INK-2: the facility never keeps allowances it granted.
///      - INK-3: the ABSOLUTE capacity, security and exit words and every user auth match an
///        exact ghost mirror of every consume the contract performs.
///      - INK-4: the ABSOLUTE words and the auth amounts only decrease between re-arms.
///      - INK-5: `previewEnter` / `previewExit` agree with what the flows do (debt exact on
///        entry, debtIn / underlyingOut / feeShares exact on exit) and revert on the same gates.
///      - INK-6: `maxEnter` / `maxExit` never quote an amount the caps then refuse.
///      - INK-7: the share fee is exactly `ceil(minted * fee / BPS)` on entry and
///        `ceil(shares * fee / BPS)` on exit, paid to the fee recipient.
///      - INK-8: the token legs are exact: the receiver's debt delta is the returned debt on
///        entry, the caller's debt delta is minus `debtIn` on exit, and the underlying legs
///        match `amount` / `underlyingOut`.
///      No handler action ever reverts: every facility call whose revert is legitimate is
///      wrapped in try/catch and its outcome counted.
contract InKindFacilityHandler is Test {
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TYPES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Snapshot of an entry attempt, bundled to keep the stack flat.
  struct EnterCtx {
    address who;
    address receiver;
    uint256 amount;
    bool usesMax;
    bool previewOk;
    uint256 previewDebt;
    uint24 feeBps;
    uint256 receiverSharesBefore;
    uint256 feeSharesBefore;
    uint256 receiverDebtBefore;
    uint256 callerUnderlyingBefore;
  }

  /// @dev Snapshot of an exit attempt, bundled to keep the stack flat.
  struct ExitCtx {
    address who;
    address receiver;
    uint256 balance;
    uint256 shares;
    bool usesMax;
    bool previewOk;
    uint256 previewDebtIn;
    uint256 previewOut;
    uint256 previewFee;
    uint24 feeBps;
    uint256 callerDebtBefore;
    uint256 feeSharesBefore;
    uint256 receiverUnderlyingBefore;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONTRACTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  InKindFacility public facility;
  PositionManager public positionManager;
  WrappedAsset public collateralToken;
  MockERC20 public underlyingToken;
  MockERC20 public debtToken;

  // Dependency-graph refs (set via initializeDependencies)
  OracleMock public oracle;
  IMorpho public morpho;
  MarketParams public marketParams;
  bool public dependenciesInitialized;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ADDRESSES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public facilitator;
  address public operator;
  address public compliance;
  address public seeder;
  /// @notice The facility's share fee recipient (read from `config()` at initialization).
  address public feeRecipient;

  /// @notice Fixed users array used by the fuzzer (callers and receivers).
  address[] public users;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CAP GHOSTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice INK-3: exact mirror of the entry offer's ABSOLUTE `capacityCap` word.
  uint256 public ghostCapacity;

  /// @notice INK-3: exact mirror of the underlying's ABSOLUTE security cap word.
  uint256 public ghostSecurity;

  /// @notice INK-3: exact mirror of the exit offer's ABSOLUTE `cap` word.
  uint256 public ghostExit;

  /// @notice INK-3: exact mirror of each user's auth on the underlying.
  mapping(address => Auth) internal ghostAuths;

  /// @notice INK-4: last observed ABSOLUTE words (reset by re-arms).
  uint256 public trackedCapacity;
  uint256 public trackedSecurity;
  uint256 public trackedExit;
  mapping(address => uint128) public trackedAuth;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  PER-ACTION INVARIANT FLAGS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice INK-1: the facility held underlying / wrapper / debt asset / PM shares after an action.
  bool public facilityHeldTokens;

  /// @notice INK-2: the facility left a granted allowance after an action.
  bool public facilityHeldAllowance;

  /// @notice INK-3: a cap word or an auth diverged from its exact ghost mirror, or a word was
  ///         not ABSOLUTE.
  bool public capMirrorBroken;

  /// @notice INK-4: an ABSOLUTE word or an auth amount increased without a re-arm.
  bool public absoluteCapIncreased;

  /// @notice INK-5: a preview reverted or disagreed while the flow went through, or passed
  ///         while the flow hit a gate the preview claims to cover.
  bool public previewDesync;

  /// @notice INK-6: `maxEnter` quoted an amount whose entry reverted on a cap.
  bool public maxEnterLied;

  /// @notice INK-6: `maxExit` quoted an amount whose exit reverted on the cap.
  bool public maxExitLied;

  /// @notice INK-7: the fee recipient's PM share delta was not the rounded-up fee.
  bool public feeMirrorBroken;

  /// @notice INK-8: a debt leg (receiver on entry, caller on exit) was not exact.
  bool public debtLegBroken;

  /// @notice INK-8: an underlying leg (caller on entry, receiver on exit) was not exact.
  bool public underlyingLegBroken;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     COVERAGE COUNTERS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 public enterSuccesses;
  uint256 public enterCapFailures;
  uint256 public enterGateFailures;
  uint256 public enterOtherFailures;
  uint256 public exitSuccesses;
  uint256 public exitCapFailures;
  uint256 public exitGateFailures;
  uint256 public exitOtherFailures;
  uint256 public exitNoops;
  uint256 public maxEnterProbes;
  uint256 public maxExitProbes;
  uint256 public seedSuccesses;
  uint256 public seedFailures;
  uint256 public entryRearms;
  uint256 public exitRearms;
  uint256 public securityRearms;
  uint256 public authRearms;
  uint256 public pauses;
  uint256 public badDebtObserved;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 internal constant BPS = 10_000;
  uint256 internal constant MAX_FEE = 1_000;
  uint256 internal constant MIN_ENTER = 1e13;
  uint256 internal constant MAX_ENTER = 5_000e18;
  /// @dev Sanity bound on a `maxEnter` quote the handler is willing to enter in full.
  uint256 internal constant MAX_PROBED_ENTER = 2_000_000e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INIT FLAG                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  bool public initialized;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  constructor() {
    // Create 3 fixed users for the fuzzer to pick from.
    users.push(makeAddr("inv_user0"));
    users.push(makeAddr("inv_user1"));
    users.push(makeAddr("inv_user2"));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INITIALIZE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the handler with all required contract references.
  /// @dev Must be called exactly once after deployment.
  function initialize(
    InKindFacility facility_,
    PositionManager positionManager_,
    WrappedAsset collateralToken_,
    MockERC20 underlyingToken_,
    MockERC20 debtToken_,
    address facilitator_,
    address operator_,
    address compliance_,
    address seeder_
  ) external {
    require(!initialized, "InKindFacilityHandler: already initialized");
    initialized = true;

    facility = facility_;
    positionManager = positionManager_;
    collateralToken = collateralToken_;
    underlyingToken = underlyingToken_;
    debtToken = debtToken_;
    facilitator = facilitator_;
    operator = operator_;
    compliance = compliance_;
    seeder = seeder_;
    (feeRecipient,,) = facility_.config();
  }

  /// @notice Initializes dependency-graph references (oracle, morpho, marketParams) and primes
  ///         the cap and auth ghosts with the words currently stored on the facility.
  /// @dev Must be called after initialize() and after the setUp opened the offers.
  function initializeDependencies(OracleMock oracle_, IMorpho morpho_, MarketParams memory marketParams_) external {
    require(initialized, "InKindFacilityHandler: not initialized");
    require(!dependenciesInitialized, "InKindFacilityHandler: dependencies already initialized");
    dependenciesInitialized = true;

    oracle = oracle_;
    morpho = morpho_;
    marketParams = marketParams_;

    ghostCapacity = facility.getEntry(address(positionManager)).capacityCap;
    ghostExit = facility.getExit(address(positionManager)).cap;
    ghostSecurity = facility.getSecurityCap(address(underlyingToken));
    trackedCapacity = ghostCapacity;
    trackedExit = ghostExit;
    trackedSecurity = ghostSecurity;
    for (uint256 u = 0; u < users.length; u++) {
      Auth memory auth = facility.getAuth(address(underlyingToken), users[u]);
      ghostAuths[users[u]] = auth;
      trackedAuth[users[u]] = auth.amount;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        VIEW HELPERS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns all tracked users.
  function getUsers() external view returns (address[] memory) {
    return users;
  }

  /// @notice Returns the ghost auth of `user` on the underlying.
  function ghostAuth(address user) external view returns (Auth memory) {
    return ghostAuths[user];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      HANDLER ACTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Enters the PM through the facility as a fuzzed user, forwarding to a fuzzed
  ///         receiver from the users array.
  /// @dev Funds and approves exactly `amount`; unconstrained bounds so every gate (unknown
  ///      offer, pause, bad debt, unlevered pool, caps, PM LTV) is reachable and caught. One
  ///      time in four the amount is `maxEnter`'s quote, which must then not fail on a cap
  ///      (INK-6). Mirrors the consumed debt on the capacity, auth and security ghosts (INK-3)
  ///      and cross-checks the preview (INK-5), the fee (INK-7) and the legs (INK-8).
  /// @param userSeed Seed for selecting the caller.
  /// @param amountSeed Seed for fuzzing the amount.
  /// @param receiverSeed Seed for selecting the receiver.
  /// @param modeSeed Seed for choosing the `maxEnter` probe.
  function act_enter(uint256 userSeed, uint256 amountSeed, uint256 receiverSeed, uint256 modeSeed) external {
    EnterCtx memory ctx;
    ctx.who = users[userSeed % users.length];
    ctx.receiver = users[receiverSeed % users.length];

    ctx.amount = _bound(amountSeed, MIN_ENTER, MAX_ENTER);
    if (modeSeed % 4 == 0) {
      try facility.maxEnter(address(positionManager), ctx.who) returns (uint256 quote) {
        if (quote > 0 && quote <= MAX_PROBED_ENTER) {
          ctx.amount = quote;
          ctx.usesMax = true;
          maxEnterProbes++;
        }
      } catch {}
    }

    try facility.previewEnter(address(positionManager), ctx.amount) returns (uint256 d, uint256, uint256) {
      ctx.previewOk = true;
      ctx.previewDebt = d;
    } catch {}

    ctx.feeBps = facility.getEntry(address(positionManager)).feeBps;
    ctx.receiverSharesBefore = positionManager.balanceOf(ctx.receiver);
    ctx.feeSharesBefore = positionManager.balanceOf(feeRecipient);
    ctx.receiverDebtBefore = debtToken.balanceOf(ctx.receiver);
    ctx.callerUnderlyingBefore = underlyingToken.balanceOf(ctx.who) + ctx.amount;

    underlyingToken.setBalance(ctx.who, ctx.callerUnderlyingBefore);
    vm.startPrank(ctx.who);
    underlyingToken.approve(address(facility), ctx.amount);
    try facility.enter(address(positionManager), ctx.amount, 0, type(uint256).max, 0, ctx.receiver) returns (
      uint256 shares, uint256 debt
    ) {
      vm.stopPrank();
      _onEntered(ctx, shares, debt);
    } catch (bytes memory reason) {
      vm.stopPrank();
      _onEnterFailed(ctx, _selectorOf(reason));
    }

    _afterOp();
  }

  /// @dev Post-processing of a successful entry: preview agreement (INK-5), cap and auth
  ///      mirrors (INK-3), fee split (INK-7) and token legs (INK-8).
  function _onEntered(EnterCtx memory ctx, uint256 shares, uint256 debt) internal {
    enterSuccesses++;

    // INK-5: the preview must have passed and quoted the exact debt.
    if (!ctx.previewOk || ctx.previewDebt != debt) previewDesync = true;

    // INK-3: capacity, then the caller's auth (when valid), then the security cap.
    if (debt > ghostCapacity) capMirrorBroken = true;
    else ghostCapacity -= debt;
    uint256 fromAuth;
    Auth memory auth = ghostAuths[ctx.who];
    if (block.timestamp < auth.expiry) {
      fromAuth = debt.min(auth.amount);
      // casting is safe: fromAuth <= auth.amount, a uint128
      // forge-lint: disable-next-line(unsafe-typecast)
      ghostAuths[ctx.who].amount = uint128(auth.amount - fromAuth);
    }
    uint256 fromSecurity = debt - fromAuth;
    if (fromSecurity > ghostSecurity) capMirrorBroken = true;
    else ghostSecurity -= fromSecurity;

    // INK-7: fee shares are the rounded-up fee on the gross mint, net shares go to the receiver.
    uint256 feeDelta = positionManager.balanceOf(feeRecipient) - ctx.feeSharesBefore;
    uint256 receiverDelta = positionManager.balanceOf(ctx.receiver) - ctx.receiverSharesBefore;
    uint256 minted = receiverDelta + feeDelta;
    if (receiverDelta != shares || feeDelta != minted.mulDivUp(ctx.feeBps, BPS)) feeMirrorBroken = true;

    // INK-8: the receiver got exactly `debt`, the caller paid exactly `amount`.
    if (debtToken.balanceOf(ctx.receiver) - ctx.receiverDebtBefore != debt) debtLegBroken = true;
    if (ctx.callerUnderlyingBefore - underlyingToken.balanceOf(ctx.who) != ctx.amount) underlyingLegBroken = true;
  }

  /// @dev Classification of a failed entry: cap shortfalls must not follow a `maxEnter` quote
  ///      (INK-6), gates must not follow a passing preview (INK-5).
  function _onEnterFailed(EnterCtx memory ctx, bytes4 selector) internal {
    if (selector == LibFacilityErrors.DepositCapExceeded.selector) {
      enterCapFailures++;
      // INK-6: the quote was computed against the same caps this call consumed.
      if (ctx.usesMax) maxEnterLied = true;
    } else if (_isEnterGate(selector)) {
      enterGateFailures++;
      // INK-5: the preview claims to revert on these gates too.
      if (ctx.previewOk) previewDesync = true;
    } else {
      enterOtherFailures++;
    }
  }

  /// @notice Exits a fuzzed slice of a user's PM shares through the facility to a fuzzed
  ///         receiver, with empty callback data.
  /// @dev Approves exactly the share amount and exactly the previewed `debtIn` (the mirror is
  ///      claimed exact within one transaction, so a bigger pull is a preview lie). One time
  ///      in four the amount is `maxExit`'s quote when it fits the balance (INK-6). Mirrors the
  ///      consumed debt on the exit ghost (INK-3) and cross-checks the preview (INK-5), the fee
  ///      (INK-7) and the legs (INK-8). Falls back to the next tracked holder when the picked
  ///      user holds no shares; early-returns when nobody does.
  /// @param userSeed Seed for selecting the caller.
  /// @param sharesSeed Seed for fuzzing the share amount.
  /// @param receiverSeed Seed for selecting the receiver.
  /// @param modeSeed Seed for choosing the `maxExit` probe.
  function act_exit(uint256 userSeed, uint256 sharesSeed, uint256 receiverSeed, uint256 modeSeed) external {
    ExitCtx memory ctx;
    ctx.who = _holderFrom(userSeed);
    ctx.receiver = users[receiverSeed % users.length];
    if (ctx.who == address(0)) {
      exitNoops++;
      _afterOp();
      return;
    }
    ctx.balance = positionManager.balanceOf(ctx.who);

    ctx.shares = _bound(sharesSeed, 1, ctx.balance);
    if (modeSeed % 4 == 0) {
      try facility.maxExit(address(positionManager)) returns (uint256 quote) {
        if (quote > 0 && quote <= ctx.balance) {
          ctx.shares = quote;
          ctx.usesMax = true;
          maxExitProbes++;
        }
      } catch {}
    }

    try facility.previewExit(address(positionManager), ctx.shares) returns (uint256 d, uint256 o, uint256 f) {
      ctx.previewOk = true;
      ctx.previewDebtIn = d;
      ctx.previewOut = o;
      ctx.previewFee = f;
    } catch {}
    // Without a preview (gated), any pull is a lie: fund the theoretical maximum so the gate,
    // not the allowance, is what reverts.
    uint256 allowance = ctx.previewOk ? ctx.previewDebtIn : positionManager.debtAmount() + 1;

    ctx.feeBps = facility.getExit(address(positionManager)).feeBps;
    ctx.callerDebtBefore = debtToken.balanceOf(ctx.who) + allowance;
    ctx.feeSharesBefore = positionManager.balanceOf(feeRecipient);
    ctx.receiverUnderlyingBefore = underlyingToken.balanceOf(ctx.receiver);

    debtToken.setBalance(ctx.who, ctx.callerDebtBefore);
    vm.startPrank(ctx.who);
    debtToken.approve(address(facility), allowance);
    positionManager.approve(address(facility), ctx.shares);
    try facility.exit(address(positionManager), ctx.shares, type(uint256).max, 0, ctx.receiver, "") returns (
      uint256 out, uint256 debtIn
    ) {
      vm.stopPrank();
      _onExited(ctx, out, debtIn);
    } catch (bytes memory reason) {
      vm.stopPrank();
      _onExitFailed(ctx, _selectorOf(reason));
    }

    _afterOp();
  }

  /// @dev The first tracked user holding PM shares, scanning from the seeded index, or zero.
  function _holderFrom(uint256 seed) internal view returns (address) {
    uint256 n = users.length;
    uint256 start = seed % n;
    for (uint256 i = 0; i < n; i++) {
      address candidate = users[(start + i) % n];
      if (positionManager.balanceOf(candidate) > 0) return candidate;
    }
    return address(0);
  }

  /// @dev Post-processing of a successful exit: preview agreement (INK-5), exit cap mirror
  ///      (INK-3), fee split (INK-7) and token legs (INK-8).
  function _onExited(ExitCtx memory ctx, uint256 out, uint256 debtIn) internal {
    exitSuccesses++;

    uint256 feeDelta = positionManager.balanceOf(feeRecipient) - ctx.feeSharesBefore;

    // INK-5: the preview must have passed and quoted the exact figures.
    if (!ctx.previewOk || ctx.previewDebtIn != debtIn || ctx.previewOut != out || ctx.previewFee != feeDelta) {
      previewDesync = true;
    }

    // INK-3: the exit cap absorbs the gross debt, skipped when zero.
    if (debtIn > ghostExit) capMirrorBroken = true;
    else ghostExit -= debtIn;

    // INK-7: fee shares are the rounded-up fee on the pulled shares, the caller lost them all.
    if (feeDelta != ctx.shares.mulDivUp(ctx.feeBps, BPS)) feeMirrorBroken = true;
    if (ctx.balance - positionManager.balanceOf(ctx.who) != ctx.shares) feeMirrorBroken = true;

    // INK-8: the caller paid exactly `debtIn`, the receiver got exactly `out`.
    if (ctx.callerDebtBefore - debtToken.balanceOf(ctx.who) != debtIn) debtLegBroken = true;
    if (underlyingToken.balanceOf(ctx.receiver) - ctx.receiverUnderlyingBefore != out) underlyingLegBroken = true;
  }

  /// @dev Classification of a failed exit: cap shortfalls must not follow a `maxExit` quote
  ///      (INK-6), gates and over-pulls must not follow a passing preview (INK-5).
  function _onExitFailed(ExitCtx memory ctx, bytes4 selector) internal {
    if (selector == LibFacilityErrors.DepositCapExceeded.selector) {
      exitCapFailures++;
      if (ctx.usesMax) maxExitLied = true;
    } else if (_isExitGate(selector)) {
      exitGateFailures++;
      if (ctx.previewOk) previewDesync = true;
    } else {
      exitOtherFailures++;
      // The debt allowance was exactly the preview: a failed pull means the flow wanted more.
      if (ctx.previewOk && selector == SafeTransferLib.TransferFromFailed.selector) previewDesync = true;
    }
  }

  /// @notice Seeds/levers the pool through the ops path: the seeder wraps underlying and
  ///         deposits (collateral, debt) into the PM directly, moving the pool ratio.
  /// @dev Debt is bounded to roughly half the collateral value at the 1:1 price so the PM's
  ///      target-LTV check usually passes; failures (drifted ratio, bad debt) are caught.
  /// @param collateralSeed Seed for fuzzing the collateral amount.
  /// @param debtSeed Seed for fuzzing the debt amount.
  function act_seed(uint256 collateralSeed, uint256 debtSeed) external {
    uint256 collateral = _bound(collateralSeed, 1e18, 10_000e18);
    // Collateral is 18 dec, debt 6 dec: value at the 1:1 price is collateral / 1e12.
    uint256 debt = _bound(debtSeed, 0, collateral / 1e12 / 2);

    underlyingToken.setBalance(seeder, underlyingToken.balanceOf(seeder) + collateral);
    vm.startPrank(seeder);
    underlyingToken.approve(address(collateralToken), collateral);
    collateralToken.mint(seeder, collateral);
    collateralToken.approve(address(positionManager), collateral);
    try positionManager.deposit(collateral, debt) {
      seedSuccesses++;
    } catch {
      seedFailures++;
    }
    vm.stopPrank();

    _afterOp();
  }

  /// @notice Warps time forward, accruing interest and expiring short-lived offers, auths and
  ///         pauses.
  /// @dev Half of the warps are short (1 second to 6 hours, crossing pauses and near auth
  ///      expiries), the rest 1 hour to 30 days.
  /// @param deltaSeed Seed for fuzzing the warp duration.
  function act_warp(uint256 deltaSeed) external {
    uint256 delta = deltaSeed % 2 == 0 ? _bound(deltaSeed, 1, 6 hours) : _bound(deltaSeed, 1 hours, 30 days);
    vm.warp(block.timestamp + delta);
    _afterOp();
  }

  /// @notice Changes the oracle price, moving quoted equity and the PM LTV. One time in sixteen
  ///         the price lands in a drawdown band (0.45x to 0.7x the 1:1 value price) where the
  ///         PM's target LTV refuses entries, Morpho's health check refuses exits and, below
  ///         the pool ratio, the pool is in bad debt (counted, every flow then reverts until
  ///         the price recovers); otherwise 0.7x to 2x.
  /// @param priceSeed Seed for fuzzing the new price.
  function act_moveOracle(uint256 priceSeed) external {
    if (!dependenciesInitialized) return;
    uint256 price = priceSeed % 16 == 0 ? _bound(priceSeed, 0.45e24, 0.7e24) : _bound(priceSeed, 0.7e24, 2e24);
    oracle.setPrice(price);
    _afterOp();
  }

  /// @notice Accrues interest on the underlying Morpho market, drifting the pool ratio up.
  function act_accrueInterest() external {
    if (!dependenciesInitialized) return;
    MarketParams memory params = marketParams;
    morpho.accrueInterest(params);
    _afterOp();
  }

  /// @notice Re-arms the entry offer as the facilitator with an ABSOLUTE capacity word: either
  ///         effectively unlimited or tight (so cap shortfalls are reachable).
  /// @dev Keeps the offer mostly enabled with a long expiry; occasionally sets a short expiry
  ///      so warps exercise the expired-offer path. Re-arms reset the ghost mirrors (INK-3, INK-4).
  /// @param capSeed Seed for fuzzing the ABSOLUTE cap.
  /// @param expirySeed Seed for choosing the expiry.
  /// @param feeSeed Seed for fuzzing the fee.
  function act_setEntry(uint256 capSeed, uint256 expirySeed, uint256 feeSeed) external {
    uint256 cap = capSeed % 3 == 0 ? LibCaps.MAX_ABSOLUTE : _bound(capSeed, 1_000e6, 50_000e6);
    uint24 feeBps = uint24(_bound(feeSeed, 0, MAX_FEE));
    uint40 expiry = expirySeed % 16 == 0 ? uint40(block.timestamp + 1) : uint40(block.timestamp + 365 days);

    vm.prank(facilitator);
    facility.setEntry(address(positionManager), cap, expiry, feeBps);
    entryRearms++;

    ghostCapacity = cap;
    trackedCapacity = cap;

    _afterOp();
  }

  /// @notice Re-arms the exit offer as the facilitator with an ABSOLUTE cap word (see act_setEntry).
  /// @param capSeed Seed for fuzzing the ABSOLUTE cap.
  /// @param expirySeed Seed for choosing the expiry.
  /// @param feeSeed Seed for fuzzing the fee.
  function act_setExit(uint256 capSeed, uint256 expirySeed, uint256 feeSeed) external {
    uint256 cap = capSeed % 3 == 0 ? LibCaps.MAX_ABSOLUTE : _bound(capSeed, 1_000e6, 50_000e6);
    uint24 feeBps = uint24(_bound(feeSeed, 0, MAX_FEE));
    uint40 expiry = expirySeed % 16 == 0 ? uint40(block.timestamp + 1) : uint40(block.timestamp + 365 days);

    vm.prank(facilitator);
    facility.setExit(address(positionManager), cap, expiry, feeBps);
    exitRearms++;

    ghostExit = cap;
    trackedExit = cap;

    _afterOp();
  }

  /// @notice Re-arms the underlying's security cap as the operator with an ABSOLUTE word:
  ///         unlimited (one time in eight), zero (one time in eight, closed to unauthed users so
  ///         auths are the only way in), otherwise tight.
  /// @param capSeed Seed for fuzzing the ABSOLUTE cap.
  function act_setSecurityCap(uint256 capSeed) external {
    uint256 mode = capSeed % 8;
    uint256 cap = mode == 0 ? LibCaps.MAX_ABSOLUTE : mode == 1 ? 0 : _bound(capSeed, 1_000e6, 50_000e6);

    vm.prank(operator);
    facility.setSecurityCap(address(underlyingToken), cap);
    securityRearms++;

    ghostSecurity = cap;
    trackedSecurity = cap;

    _afterOp();
  }

  /// @notice Sets a fuzzed user's auth on the underlying as the operator: a random amount with
  ///         an expiry near now (already expired one time in four, otherwise 1 hour to 3 days).
  /// @dev Overwrites the remaining amount, as the contract does; resets the ghosts (INK-3, INK-4).
  /// @param userSeed Seed for selecting the user.
  /// @param amountSeed Seed for fuzzing the auth amount.
  /// @param expirySeed Seed for choosing the expiry.
  function act_setAuth(uint256 userSeed, uint256 amountSeed, uint256 expirySeed) external {
    address who = users[userSeed % users.length];
    uint128 amount = uint128(_bound(amountSeed, 0, 20_000e6));
    uint40 expiry = expirySeed % 4 == 0
      ? uint40(block.timestamp - _bound(expirySeed, 0, 1 days))
      : uint40(block.timestamp + _bound(expirySeed, 1 hours, 3 days));

    vm.prank(operator);
    facility.setAuth(address(underlyingToken), who, amount, expiry);
    authRearms++;

    ghostAuths[who] = Auth({amount: amount, expiry: expiry});
    trackedAuth[who] = amount;

    _afterOp();
  }

  /// @notice Pauses the facility for a bounded short duration, or unpauses it, as compliance.
  /// @dev Short enough that later warps unpause, and explicit unpauses half of the time, so the
  ///      paused gate is exercised without starving the flows.
  /// @param durationSeed Seed for fuzzing the pause duration (even seeds unpause).
  function act_pause(uint256 durationSeed) external {
    uint256 duration = durationSeed % 2 == 0 ? 0 : _bound(durationSeed, 1, 6 hours);
    vm.prank(compliance);
    facility.pauseFor(duration);
    if (duration > 0) pauses++;
    _afterOp();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTERNAL HELPERS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Whether a revert is one of the entry gates `previewEnter` claims to share.
  function _isEnterGate(bytes4 selector) internal pure returns (bool) {
    return selector == IInKindFacility.UnknownEntry.selector || selector == LibCommonErrors.Paused.selector
      || selector == IInKindFacility.BadDebtState.selector || selector == IInKindFacility.UnleveredPool.selector;
  }

  /// @dev Whether a revert is one of the exit gates `previewExit` claims to share, or the
  ///      mirror check that a passing preview rules out.
  function _isExitGate(bytes4 selector) internal pure returns (bool) {
    return selector == IInKindFacility.UnknownExit.selector || selector == LibCommonErrors.Paused.selector
      || selector == IInKindFacility.BadDebtState.selector || selector == IInKindFacility.NothingToBurn.selector
      || selector == IInKindFacility.DebtMirrorMismatch.selector;
  }

  function _selectorOf(bytes memory reason) internal pure returns (bytes4 selector) {
    if (reason.length < 4) return bytes4(0);
    assembly ("memory-safe") {
      selector := mload(add(reason, 32))
    }
  }

  /// @dev Ghost snapshot taken after every action: clean balances, no granted allowances,
  ///      exact cap and auth mirrors, monotone words and auths, bad-debt coverage.
  function _afterOp() internal {
    // INK-1: the facility is a pure pass-through.
    if (
      underlyingToken.balanceOf(address(facility)) != 0 || collateralToken.balanceOf(address(facility)) != 0
        || debtToken.balanceOf(address(facility)) != 0 || positionManager.balanceOf(address(facility)) != 0
    ) {
      facilityHeldTokens = true;
    }

    // INK-2: the facility never keeps allowances it granted.
    if (
      underlyingToken.allowance(address(facility), address(collateralToken)) != 0
        || collateralToken.allowance(address(facility), address(positionManager)) != 0
        || debtToken.allowance(address(facility), address(positionManager)) != 0
    ) {
      facilityHeldAllowance = true;
    }

    uint256 capacity = facility.getEntry(address(positionManager)).capacityCap;
    uint256 exitCap = facility.getExit(address(positionManager)).cap;
    uint256 security = facility.getSecurityCap(address(underlyingToken));

    // INK-3: every word is ABSOLUTE here and matches its exact ghost mirror.
    if (
      capacity >> LibCaps.TYPE_OFFSET != 0 || exitCap >> LibCaps.TYPE_OFFSET != 0
        || security >> LibCaps.TYPE_OFFSET != 0
    ) capMirrorBroken = true;
    if (capacity != ghostCapacity || exitCap != ghostExit || security != ghostSecurity) capMirrorBroken = true;

    // INK-4: the words only decrease between re-arms.
    if (capacity > trackedCapacity || exitCap > trackedExit || security > trackedSecurity) absoluteCapIncreased = true;
    trackedCapacity = capacity;
    trackedExit = exitCap;
    trackedSecurity = security;

    for (uint256 u = 0; u < users.length; u++) {
      address who = users[u];
      Auth memory auth = facility.getAuth(address(underlyingToken), who);
      Auth memory ghost = ghostAuths[who];
      if (auth.amount != ghost.amount || auth.expiry != ghost.expiry) capMirrorBroken = true;
      if (auth.amount > trackedAuth[who]) absoluteCapIncreased = true;
      trackedAuth[who] = auth.amount;
    }

    if (positionManager.hasBadDebt()) badDebtObserved++;
  }
}
