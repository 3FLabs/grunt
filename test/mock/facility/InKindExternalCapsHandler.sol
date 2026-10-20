// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {InKindFacility} from "src/facility/inkind/InKindFacility.sol";
import {IInKindFacility, Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {BaseExiter, ApproveExactExiter, RepayOnBehalfExiter} from "test/mock/facility/InKindExiters.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {IMorpho, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";

/// @title InKindExternalCapsHandler
/// @notice Handler for the in-kind invariant campaign on EXTERNAL cap words: two PMs over one
///         underlying, entry words on FacilityAbsoluteCaps pools, a FacilityDynamicCaps security
///         word shared by both PMs with auth spill-over, signed exit words (ABSOLUTE, absolute
///         pools or dynamic caps; a negative one credits its pools up to their hard caps and
///         reverts HardCapExceeded beyond), exits with and without a callback, slippage bounds
///         drawn from the previews and a dry run, warps with interest, oracle moves (one lane
///         above the PM target LTV), pool top-ups, hard-cap raises and PM fee accrual.
/// @dev No action reverts. Every flow's outcome is predicted from the previews and an
///      independent model of the caps and the target LTV, and checked to the revert data, except
///      two documented cases: a dust entry the PM mints nothing for is accepted on its revert, and
///      entries within NEAR_TARGET_UNITS of the target LTV are skipped. Flags are sticky.
contract InKindExternalCapsHandler is Test {
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TYPES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev A cap word as armed. `caps == address(0)` is an ABSOLUTE word.
  struct Word {
    address caps;
    uint64 id;
    int24 multiplier;
  }

  struct Config {
    InKindFacility facility;
    PositionManager pm1;
    PositionManager pm2;
    FacilityAbsoluteCaps absoluteCaps;
    FacilityDynamicCaps dynamicCaps;
    MockERC20 underlyingToken;
    MockERC20 debtToken;
    OracleMock oracle;
    IMorpho morpho;
    MarketParams marketParams;
    address facilitator;
    address operator;
    address capsManager;
    ApproveExactExiter[2] exactExiters;
    RepayOnBehalfExiter[2] repayExiters;
    Word[2] entryWords;
    Word[2] exitWords;
    Word securityWord;
  }

  /// @dev Holder value of a PM: equity and burn's share denominator.
  struct Value {
    uint256 assets;
    uint256 supply;
  }

  /// @dev What a flow must do: succeed, or revert like its preview (GATE), on a caller bound
  ///      (BOUND) or on a cap the model cannot fit (CAP).
  enum Expect {
    SUCCESS,
    GATE,
    BOUND,
    CAP
  }

  struct EnterCtx {
    uint256 idx;
    PositionManager pm;
    address who;
    address receiver;
    uint256 amount;
    uint256 minDebt;
    uint256 maxDebt;
    uint256 minShares;
    bool usesMax;
    bool previewOk;
    uint256 previewDebt;
    bytes previewReason;
    bool exactBound;
    bool dryOk;
    uint256 dryShares;
    uint256 dryDebt;
    Expect expect;
    bytes expected;
    Value[2] values;
  }

  struct ExitCtx {
    uint256 idx;
    PositionManager pm;
    uint256 kind;
    address who;
    address receiver;
    uint256 shares;
    bool callback;
    uint256 repay;
    uint256 maxDebtIn;
    uint256 minOut;
    bool usesMax;
    bool previewOk;
    uint256 previewDebtIn;
    uint256 previewOut;
    uint256 required;
    bytes previewReason;
    bool exactBound;
    Expect expect;
    bytes expected;
    uint256 callsBefore;
    uint256 callerDebtBefore;
    uint256 receiverUnderlyingBefore;
    Value[2] values;
  }

  error DryRun(uint256 shares, uint256 debt);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint16 public constant POOL_1 = 1;
  uint16 public constant POOL_2 = 2;
  uint16 public constant SHARED_POOL = 3;
  uint16 public constant EXIT_POOL = 4;
  uint64 public constant SECURITY_DYN = 1;
  uint64 public constant EXIT_DYN = 2;

  uint256 internal constant KIND_USER = 0;
  uint256 internal constant KIND_EXACT = 1;
  uint256 internal constant KIND_REPAY = 2;

  /// @dev Exit word kinds, indexing exitSuccessesByWord.
  uint256 internal constant WORD_ABSOLUTE = 0;
  uint256 internal constant WORD_POOL_DEBIT = 1;
  uint256 internal constant WORD_DYNAMIC_DEBIT = 2;
  uint256 internal constant WORD_POOL_CREDIT = 3;
  uint256 internal constant WORD_DYNAMIC_CREDIT = 4;

  uint256 internal constant MAX_FEE = 1_000;
  /// @dev Caps contracts count in 18 decimals (LibCaps scales EXTERNAL amounts), the debt has 6.
  uint256 internal constant CAPS_SCALE = 1e12;
  uint256 internal constant BPS = 10_000;
  /// @dev The above-target oracle lane lands 30 to 120 bps above the PM target LTV.
  uint256 internal constant ABOVE_TARGET_MIN_BPS = 30;
  uint256 internal constant ABOVE_TARGET_MAX_BPS = 120;
  /// @dev A warp that brings a pool to this LTV resets the oracle: exits need every module
  ///      below its safeLtv (0.72 in the fixture).
  uint256 internal constant LTV_CEILING = 0.71e18;
  /// @dev Within this many debt units of the target LTV the views and PM.deposit can disagree.
  uint256 internal constant NEAR_TARGET_UNITS = 4;
  uint256 internal constant DEFAULT_PRICE = 1e24;
  uint40 internal constant FAR_EXPIRY = type(uint40).max;
  uint256 internal constant MIN_ENTER = 1e13;
  uint256 internal constant MAX_ENTER = 5_000e18;
  uint256 internal constant MAX_PROBED_ENTER = 2_000_000e18;
  uint256 internal constant DUST_SHARES = 1e13;

  /// @dev Stayer value a flow may shave off, in debt units: one for the collateral quote floor, one
  ///      for Morpho's share rounding.
  uint256 public constant STAYER_DUST = 2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  InKindFacility public facility;
  PositionManager[2] public pms;
  FacilityAbsoluteCaps public absoluteCaps;
  FacilityDynamicCaps public dynamicCaps;
  MockERC20 public underlyingToken;
  MockERC20 public debtToken;
  OracleMock public oracle;
  IMorpho public morpho;
  MarketParams public marketParams;
  address public facilitator;
  address public operator;
  address public capsManager;
  ApproveExactExiter[2] public exactExiters;
  RepayOnBehalfExiter[2] public repayExiters;
  address[] public users;
  bool public initialized;
  /// @dev Set while the oracle sits on the above-target lane, the only one reaching the target.
  bool public oracleNearTarget;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           GHOSTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256[2] public ghostEntryWord;
  uint256[2] public ghostExitWord;
  uint256 public ghostSecurityWord;
  Word[2] internal entryModel;
  Word[2] internal exitModel;
  Word internal securityModel;
  mapping(uint16 => uint256) public ghostPoolCap;
  mapping(uint16 => uint256) public ghostPoolHardCap;
  mapping(uint64 => uint256) public ghostOrigin;
  mapping(uint64 => uint256) internal dynRecovery;
  mapping(uint64 => uint256) internal dynRecoveryTime;
  mapping(address => Auth) internal ghostAuths;
  uint256[2] public maxStayerDrop;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           FLAGS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  bool public unexpectedRevert;
  bool public gateParityBroken;
  bool public slippageBroken;
  bool public capOutcomeBroken;
  bool public capMirrorBroken;
  bool[2] public stayerValueDropped;
  bool public maxEnterLied;
  bool public maxExitLied;
  bool public previewDesync;
  bool public legBroken;
  bool public targetGateBroken;
  /// @notice Revert data of the first flow whose outcome differed from its prediction.
  bytes public firstMismatch;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         COUNTERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 public enterSuccesses;
  uint256 public enterBoundedSuccesses;
  uint256 public enterSlippageReverts;
  uint256 public enterCapFailures;
  uint256 public enterGateFailures;
  uint256 public enterDustFailures;
  uint256 public enterZeroMintFailures;
  uint256 public enterAboveTargetFailures;
  uint256 public enterNearTargetSkips;
  uint256 public spillOvers;
  uint256 public maxEnterProbes;
  uint256 public maxEnterProbeSuccesses;
  uint256 public maxEnterProbeDust;
  uint256 public exitSuccesses;
  uint256 public exitCallbackSuccesses;
  uint256 public exitRepaySuccesses;
  uint256 public exitBoundedSuccesses;
  uint256 public exitSlippageReverts;
  uint256 public exitCapFailures;
  uint256 public exitHardCapFailures;
  uint256 public exitGateFailures;
  uint256 public exitNoops;
  uint256 public maxExitProbes;
  uint256 public maxExitProbeSuccesses;
  uint256[5] public exitSuccessesByWord;
  uint256 public entryRearms;
  uint256 public exitRearms;
  uint256 public securityRearms;
  uint256 public authRearms;
  uint256 public refills;
  uint256 public hardCapRaises;
  uint256 public priceMoves;
  uint256 public aboveTargetMoves;
  uint256 public priceResets;
  uint256 public warps;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           SETUP                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  constructor() {
    users.push(makeAddr("ext_user0"));
    users.push(makeAddr("ext_user1"));
    users.push(makeAddr("ext_user2"));
  }

  /// @notice Wires the contracts, takes the armed words as the model and primes every ghost from
  ///         the live state.
  function initialize(Config memory config) external {
    require(!initialized, "already initialized");
    initialized = true;
    facility = config.facility;
    pms[0] = config.pm1;
    pms[1] = config.pm2;
    absoluteCaps = config.absoluteCaps;
    dynamicCaps = config.dynamicCaps;
    underlyingToken = config.underlyingToken;
    debtToken = config.debtToken;
    oracle = config.oracle;
    morpho = config.morpho;
    marketParams = config.marketParams;
    facilitator = config.facilitator;
    operator = config.operator;
    capsManager = config.capsManager;
    exactExiters = config.exactExiters;
    repayExiters = config.repayExiters;

    for (uint256 i = 0; i < 2; i++) {
      entryModel[i] = config.entryWords[i];
      exitModel[i] = config.exitWords[i];
      ghostEntryWord[i] = facility.getEntry(address(pms[i])).capacityCap;
      ghostExitWord[i] = facility.getExit(address(pms[i])).cap;
    }
    securityModel = config.securityWord;
    ghostSecurityWord = facility.getSecurityCap(address(underlyingToken));
    for (uint16 p = POOL_1; p <= EXIT_POOL; p++) {
      (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(p);
      ghostPoolCap[p] = cap;
      ghostPoolHardCap[p] = hardCap;
    }
    for (uint64 id = SECURITY_DYN; id <= EXIT_DYN; id++) {
      (uint128 recovery, uint64 recoveryTime, uint64 origin) = dynamicCaps.getCap(id);
      dynRecovery[id] = recovery;
      dynRecoveryTime[id] = recoveryTime;
      ghostOrigin[id] = origin;
    }
    for (uint256 u = 0; u < users.length; u++) {
      ghostAuths[users[u]] = facility.getAuth(address(underlyingToken), users[u]);
    }
  }

  function getUsers() external view returns (address[] memory) {
    return users;
  }

  function ghostAuth(address user) external view returns (Auth memory) {
    return ghostAuths[user];
  }

  /// @notice Capacity of a dynamic cap per the model, at the current timestamp.
  function ghostRemaining(uint64 id) public view returns (uint256) {
    uint256 origin = ghostOrigin[id];
    if (block.timestamp <= origin) return 0;
    uint256 elapsed = block.timestamp - origin;
    if (elapsed >= dynRecoveryTime[id]) return dynRecovery[id];
    return dynRecovery[id] * elapsed / dynRecoveryTime[id];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ENTER                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Enters a PM as a user. `modeSeed % 16`: 6-7 maxEnter quote, 8-9 exact debt bounds,
  ///         10 minDebt one above, 11 maxDebt one below, 12 both off, 13-14 minSharesOut from a
  ///         dry run, 15 that minSharesOut plus one, otherwise unbounded. `(modeSeed >> 4) % 4 == 3`
  ///         draws a dust amount. Above the target LTV the entry runs unbounded; within
  ///         NEAR_TARGET_UNITS of it the entry is skipped.
  function act_enter(uint256 pmSeed, uint256 userSeed, uint256 amountSeed, uint256 receiverSeed, uint256 modeSeed)
    external
  {
    EnterCtx memory ctx;
    ctx.idx = pmSeed % 2;
    ctx.pm = pms[ctx.idx];
    ctx.who = users[userSeed % users.length];
    (ctx.receiver,) = _actor(ctx.idx, receiverSeed % 5);
    ctx.amount = (modeSeed >> 4) % 4 == 3 ? _bound(amountSeed, 1, MIN_ENTER) : _bound(amountSeed, MIN_ENTER, MAX_ENTER);
    ctx.maxDebt = type(uint256).max;
    uint256 lane = modeSeed % 16;
    if (oracleNearTarget) {
      (bool above, bool near) = _targetSide(ctx.pm);
      if (near) {
        enterNearTargetSkips++;
        return;
      }
      if (above) {
        _enterAboveTarget(ctx);
        return;
      }
    }

    if (lane == 6 || lane == 7) {
      try facility.maxEnter(address(ctx.pm), ctx.who) returns (uint256 quote) {
        if (quote > 0 && quote <= MAX_PROBED_ENTER) {
          ctx.amount = quote;
          ctx.usesMax = true;
          maxEnterProbes++;
        }
      } catch {}
    }
    try facility.previewEnter(address(ctx.pm), ctx.amount) returns (uint256 d, uint256, uint256) {
      ctx.previewOk = true;
      ctx.previewDebt = d;
    } catch (bytes memory reason) {
      ctx.previewReason = reason;
      // below the target LTV the PM can place a ratio-matched borrow
      if (keccak256(reason) == keccak256(_borrowCapacityError())) targetGateBroken = true;
    }

    _fundEntry(ctx);
    _expectEnter(ctx, lane);
    _snapshotValues(ctx.expect, ctx.values);

    vm.prank(ctx.who);
    try facility.enter(address(ctx.pm), ctx.amount, ctx.minDebt, ctx.maxDebt, ctx.minShares, ctx.receiver) returns (
      uint256 shares, uint256 debt
    ) {
      _onEntered(ctx, shares, debt);
    } catch (bytes memory reason) {
      _onEnterFailed(ctx, reason);
    }
  }

  /// @notice Runs an unbounded entry and reverts with its result. Only callable by the handler.
  function dryEnter(address pm, address who, uint256 amount, address receiver) external {
    require(msg.sender == address(this), "self only");
    vm.prank(who);
    (uint256 shares, uint256 debt) = facility.enter(pm, amount, 0, type(uint256).max, 0, receiver);
    revert DryRun(shares, debt);
  }

  /// @dev Sets the caller's bounds for `lane` and predicts the outcome: the preview's revert, then
  ///      the debt bounds (checked before the caps), then the caps, then the share bound.
  function _expectEnter(EnterCtx memory ctx, uint256 lane) internal {
    if (!ctx.previewOk) {
      _setExpected(ctx, Expect.GATE, ctx.previewReason);
      return;
    }
    uint256 d = ctx.previewDebt;
    if (lane >= 10 && lane <= 12 && d > 0) {
      if (lane != 11) ctx.minDebt = d + 1;
      if (lane != 10) ctx.maxDebt = d - 1;
      _setExpected(
        ctx, Expect.BOUND, abi.encodeWithSelector(IInKindFacility.DebtOutOfBounds.selector, d, ctx.minDebt, ctx.maxDebt)
      );
      return;
    }
    if (lane == 8 || lane == 9) {
      ctx.minDebt = d;
      ctx.maxDebt = d;
      ctx.exactBound = true;
    }
    bytes memory capError = _enterCapError(ctx.idx, ctx.who, d);
    if (capError.length > 0) {
      if (ctx.usesMax) maxEnterLied = true;
      _setExpected(ctx, Expect.CAP, capError);
      return;
    }
    if (lane < 13) return;
    try this.dryEnter(address(ctx.pm), ctx.who, ctx.amount, ctx.receiver) {}
    catch (bytes memory reason) {
      if (_selectorOf(reason) != DryRun.selector) return;
      (ctx.dryShares, ctx.dryDebt) = _decodeTwo(reason);
      ctx.dryOk = true;
      if (lane < 15) {
        ctx.minShares = ctx.dryShares;
        ctx.exactBound = true;
      } else {
        ctx.minShares = ctx.dryShares + 1;
        bytes memory bound =
          abi.encodeWithSelector(IInKindFacility.InsufficientSharesOut.selector, ctx.dryShares, ctx.dryShares + 1);
        _setExpected(ctx, Expect.BOUND, bound);
      }
    }
  }

  /// @dev The capacity word first, then the auth and the shared security cap.
  function _enterCapError(uint256 idx, address who, uint256 debt) internal view returns (bytes memory) {
    if (debt == 0) return "";
    Word memory word = entryModel[idx];
    if (_consumption(debt, word.multiplier) > _ghostRoom(word.id)) {
      return abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, word.id);
    }
    uint256 fromSecurity = debt - _ghostAuthAvailable(who).min(debt);
    if (fromSecurity > 0 && _consumption(fromSecurity, securityModel.multiplier) > ghostRemaining(SECURITY_DYN)) {
      return abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, securityModel.id);
    }
    return "";
  }

  function _onEntered(EnterCtx memory ctx, uint256 shares, uint256 debt) internal {
    enterSuccesses++;
    if (ctx.expect != Expect.SUCCESS) _mismatch(ctx.expect, "");
    if (ctx.dryOk && (shares != ctx.dryShares || debt != ctx.dryDebt)) slippageBroken = true;
    if (ctx.exactBound) enterBoundedSuccesses++;
    if (debt != ctx.previewDebt) previewDesync = true;
    if (ctx.usesMax) maxEnterProbeSuccesses++;

    Word memory word = entryModel[ctx.idx];
    _ghostWalk(word.id, _consumption(debt, word.multiplier));

    Auth memory auth = ghostAuths[ctx.who];
    uint256 fromAuth = _ghostAuthAvailable(ctx.who).min(debt);
    // forge-lint: disable-next-line(unsafe-typecast)
    ghostAuths[ctx.who].amount = uint128(auth.amount - fromAuth);
    uint256 fromSecurity = debt - fromAuth;
    if (fromAuth > 0 && fromSecurity > 0) spillOvers++;
    if (fromSecurity > 0) _ghostDynamic(securityModel.id, _consumption(fromSecurity, securityModel.multiplier));

    if (ctx.expect == Expect.SUCCESS) _checkStayers(ctx.values);
  }

  function _onEnterFailed(EnterCtx memory ctx, bytes memory reason) internal {
    if (_zeroMint(ctx, reason)) {
      enterZeroMintFailures++;
      return;
    }
    if (keccak256(reason) != keccak256(ctx.expected)) _mismatch(ctx.expect, reason);
    if (ctx.expect == Expect.BOUND) {
      enterSlippageReverts++;
    } else if (ctx.expect == Expect.CAP) {
      enterCapFailures++;
    } else if (_selectorOf(reason) == IInKindFacility.DustEntry.selector) {
      enterDustFailures++;
      if (ctx.usesMax) maxEnterProbeDust++;
    } else {
      enterGateFailures++;
    }
  }

  /// @dev A dust entry adding no quoted equity makes the PM mint nothing, which the preview does
  ///      not foresee: it reverts InsufficientSharesOut(0, minSharesOut).
  function _zeroMint(EnterCtx memory ctx, bytes memory reason) internal pure returns (bool) {
    if (ctx.expect != Expect.SUCCESS || ctx.amount >= MIN_ENTER) return false;
    return keccak256(reason)
      == keccak256(abi.encodeWithSelector(IInKindFacility.InsufficientSharesOut.selector, 0, ctx.minShares));
  }

  /// @dev Above the PM target LTV maxEnter quotes zero and the preview refuses like the entry:
  ///      DustEntry first, then InsufficientBorrowCapacity. The entry checks its caps between
  ///      the two, PM.deposit raising the latter.
  function _enterAboveTarget(EnterCtx memory ctx) internal {
    uint256 debt = ctx.amount.mulDiv(ctx.pm.debtAmount(), ctx.pm.collateralAmount());
    bytes memory refusal =
      debt == 0 ? abi.encodeWithSelector(IInKindFacility.DustEntry.selector, ctx.amount) : _borrowCapacityError();
    try facility.maxEnter(address(ctx.pm), ctx.who) returns (uint256 quote) {
      if (quote != 0) maxEnterLied = true;
    } catch {
      maxEnterLied = true;
    }
    try facility.previewEnter(address(ctx.pm), ctx.amount) returns (uint256, uint256, uint256) {
      targetGateBroken = true;
    } catch (bytes memory reason) {
      if (keccak256(reason) != keccak256(refusal)) _mismatch(Expect.GATE, reason);
    }
    bytes memory capError = _enterCapError(ctx.idx, ctx.who, debt);
    if (capError.length > 0) _setExpected(ctx, Expect.CAP, capError);
    else _setExpected(ctx, Expect.GATE, refusal);

    _fundEntry(ctx);
    vm.prank(ctx.who);
    try facility.enter(address(ctx.pm), ctx.amount, 0, type(uint256).max, 0, ctx.receiver) returns (uint256, uint256) {
      targetGateBroken = true;
      _mismatch(ctx.expect, "");
    } catch (bytes memory reason) {
      if (keccak256(reason) != keccak256(ctx.expected)) _mismatch(ctx.expect, reason);
      if (ctx.expect == Expect.CAP) enterCapFailures++;
      else if (debt == 0) enterDustFailures++;
      else enterAboveTargetFailures++;
    }
  }

  function _fundEntry(EnterCtx memory ctx) internal {
    underlyingToken.setBalance(ctx.who, underlyingToken.balanceOf(ctx.who) + ctx.amount);
    vm.prank(ctx.who);
    underlyingToken.approve(address(facility), ctx.amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            EXIT                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Exits a PM. `actorSeed % 5`: 0-2 users (no callback), 3 ApproveExactExiter (callback
  ///         when bit 4 of `modeSeed` is set), 4 RepayOnBehalfExiter (repays `modeSeed >> 5`,
  ///         bounded, in the callback); `(actorSeed >> 8) % 8 == 7` draws dust shares.
  ///         `modeSeed % 16`: 7-9 maxExit quote by the largest holder, 10-11 exact bounds, 12
  ///         maxDebtIn one below, 13 minUnderlyingOut one above, otherwise unbounded.
  function act_exit(uint256 pmSeed, uint256 actorSeed, uint256 sharesSeed, uint256 receiverSeed, uint256 modeSeed)
    external
  {
    ExitCtx memory ctx;
    ctx.idx = pmSeed % 2;
    ctx.pm = pms[ctx.idx];
    uint256 lane = modeSeed % 16;
    bool probe = lane >= 7 && lane <= 9;
    (ctx.who, ctx.kind) = probe ? _largestHolder(ctx.idx) : _holder(ctx.idx, actorSeed % 5);
    if (ctx.who == address(0)) {
      exitNoops++;
      return;
    }
    ctx.receiver = users[receiverSeed % users.length];
    uint256 balance = ctx.pm.balanceOf(ctx.who);
    ctx.shares =
      (actorSeed >> 8) % 8 == 7 ? _bound(sharesSeed, 1, balance.min(DUST_SHARES)) : _bound(sharesSeed, 1, balance);
    ctx.maxDebtIn = type(uint256).max;
    ctx.callback = ctx.kind == KIND_REPAY || (ctx.kind == KIND_EXACT && (modeSeed >> 4) % 2 == 1);

    if (probe) {
      try facility.maxExit(address(ctx.pm)) returns (uint256 quote) {
        // any amount up to the quote fits, so a quote above the balance probes the balance
        if (quote > 0) {
          ctx.shares = quote.min(balance);
          ctx.usesMax = true;
          maxExitProbes++;
        }
      } catch {}
    }
    try facility.previewExit(address(ctx.pm), ctx.shares) returns (uint256 d, uint256 o, uint256, uint256 req) {
      ctx.previewOk = true;
      ctx.previewDebtIn = d;
      ctx.previewOut = o;
      ctx.required = req;
      if (req != _required(d)) previewDesync = true;
    } catch (bytes memory reason) {
      ctx.previewReason = reason;
    }
    if (ctx.kind == KIND_REPAY) ctx.repay = _bound(modeSeed >> 5, 1, ctx.pm.debtAmount() / 20);
    _expectExit(ctx, lane);
    _snapshotValues(ctx.expect, ctx.values);

    (bool ok, uint256 out, uint256 debtIn, bytes memory revertData) = _callExit(ctx);
    if (ok) _onExited(ctx, out, debtIn);
    else _onExitFailed(ctx, revertData);
  }

  /// @dev Sets the caller's bounds for `lane` and predicts the outcome: the preview's revert, then
  ///      maxDebtIn (checked before the cap), then the cap, then minUnderlyingOut.
  function _expectExit(ExitCtx memory ctx, uint256 lane) internal {
    if (!ctx.previewOk) {
      _setExpected(ctx, Expect.GATE, ctx.previewReason);
      return;
    }
    uint256 required = ctx.required;
    if (lane == 12 && required > 0) {
      ctx.maxDebtIn = required - 1;
      _setExpected(
        ctx, Expect.BOUND, abi.encodeWithSelector(IInKindFacility.ExcessiveDebtIn.selector, required, required - 1)
      );
      return;
    }
    if ((lane == 10 || lane == 11) && required > 0) {
      ctx.maxDebtIn = required;
      // a repay in the callback moves burn's figures
      if (ctx.kind != KIND_REPAY) ctx.minOut = ctx.previewOut;
      ctx.exactBound = true;
    }
    bytes memory capError = _exitCapError(ctx);
    if (capError.length > 0) {
      if (ctx.usesMax) maxExitLied = true;
      _setExpected(ctx, Expect.CAP, capError);
      return;
    }
    if (lane == 13 && ctx.kind != KIND_REPAY) {
      ctx.minOut = ctx.previewOut + 1;
      bytes memory bound =
        abi.encodeWithSelector(IInKindFacility.InsufficientUnderlyingOut.selector, ctx.previewOut, ctx.previewOut + 1);
      _setExpected(ctx, Expect.BOUND, bound);
    }
  }

  /// @dev The exit word absorbs the mirrored debt slice: a negative word credits its pools up to
  ///      their hard caps (a dynamic cap ignores it), anything past the summed headroom reverts.
  function _exitCapError(ExitCtx memory ctx) internal view returns (bytes memory) {
    uint256 mirror = ctx.previewDebtIn;
    if (mirror == 0) return "";
    Word memory word = exitModel[ctx.idx];
    uint256 kind = _wordKind(word);
    if (kind == WORD_ABSOLUTE) {
      uint256 cap = ghostExitWord[ctx.idx];
      if (mirror <= cap) return "";
      return
        abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, uint256(uint160(address(ctx.pm))), cap, mirror);
    }
    if (kind == WORD_DYNAMIC_CREDIT) return "";
    if (kind == WORD_POOL_CREDIT) {
      if (_release(mirror, word.multiplier) <= _ghostHeadroom(word.id)) return "";
      return abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, word.id);
    }
    uint256 room = kind == WORD_POOL_DEBIT ? _ghostRoom(word.id) : ghostRemaining(word.id);
    if (_consumption(mirror, word.multiplier) <= room) return "";
    return abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, word.id);
  }

  function _callExit(ExitCtx memory ctx) internal returns (bool ok, uint256 out, uint256 debtIn, bytes memory reason) {
    // exactly the previewed pull: a bigger pull is a mirror lie
    uint256 allowance = ctx.previewOk ? ctx.required : ctx.pm.debtAmount() * 2 + 1;
    ctx.callerDebtBefore = debtToken.balanceOf(ctx.who) + allowance + ctx.repay;
    ctx.receiverUnderlyingBefore = underlyingToken.balanceOf(ctx.receiver);
    debtToken.setBalance(ctx.who, ctx.callerDebtBefore);

    if (ctx.kind == KIND_USER) {
      vm.startPrank(ctx.who);
      debtToken.approve(address(facility), allowance);
      ctx.pm.approve(address(facility), ctx.shares);
      try facility.exit(address(ctx.pm), ctx.shares, ctx.maxDebtIn, ctx.minOut, ctx.receiver, "") returns (
        uint256 o, uint256 d
      ) {
        (ok, out, debtIn) = (true, o, d);
      } catch (bytes memory r) {
        reason = r;
      }
      vm.stopPrank();
      return (ok, out, debtIn, reason);
    }

    bytes memory data;
    if (ctx.kind == KIND_REPAY) data = abi.encode(ctx.repay);
    else if (ctx.callback) data = hex"01";
    else BaseExiter(ctx.who).approveDebt(allowance);
    ctx.callsBefore = BaseExiter(ctx.who).callCount();
    try BaseExiter(ctx.who).exit(ctx.shares, ctx.maxDebtIn, ctx.minOut, ctx.receiver, data) returns (
      uint256 o, uint256 d
    ) {
      (ok, out, debtIn) = (true, o, d);
    } catch (bytes memory r) {
      reason = r;
    }
  }

  function _onExited(ExitCtx memory ctx, uint256 out, uint256 debtIn) internal {
    exitSuccesses++;
    if (ctx.callback) exitCallbackSuccesses++;
    if (ctx.kind == KIND_REPAY) exitRepaySuccesses++;
    if (ctx.exactBound) exitBoundedSuccesses++;
    if (ctx.usesMax) maxExitProbeSuccesses++;
    if (ctx.expect != Expect.SUCCESS) _mismatch(ctx.expect, "");

    // a repay inside the callback moves burn's figures (debt and PM fee shares), nothing else does
    if (ctx.kind != KIND_REPAY && (debtIn != ctx.previewDebtIn || out != ctx.previewOut)) previewDesync = true;
    // the caller paid exactly what burn used (plus its own repay) and kept no allowance, the
    // receiver got `out`, the callback ran iff data was sent and saw debtRequired
    if (ctx.callerDebtBefore - debtToken.balanceOf(ctx.who) != debtIn + ctx.repay) legBroken = true;
    if (debtToken.allowance(ctx.who, address(facility)) != 0) legBroken = true;
    if (underlyingToken.balanceOf(ctx.receiver) - ctx.receiverUnderlyingBefore != out) legBroken = true;
    if (ctx.kind != KIND_USER) {
      BaseExiter exiter = BaseExiter(ctx.who);
      if (exiter.callCount() - ctx.callsBefore != (ctx.callback ? 1 : 0)) legBroken = true;
      if (ctx.callback && exiter.lastDebtIn() != ctx.required) legBroken = true;
    }

    // the exit word absorbs the mirrored debt, whatever burn then pulled
    Word memory word = exitModel[ctx.idx];
    uint256 kind = _wordKind(word);
    exitSuccessesByWord[kind]++;
    if (kind == WORD_ABSOLUTE) {
      if (ctx.previewDebtIn > ghostExitWord[ctx.idx]) capMirrorBroken = true;
      else ghostExitWord[ctx.idx] -= ctx.previewDebtIn;
    } else if (kind == WORD_POOL_DEBIT) {
      _ghostWalk(word.id, _consumption(ctx.previewDebtIn, word.multiplier));
    } else if (kind == WORD_DYNAMIC_DEBIT) {
      _ghostDynamic(word.id, _consumption(ctx.previewDebtIn, word.multiplier));
    } else if (kind == WORD_POOL_CREDIT) {
      _ghostCredit(word.id, _release(ctx.previewDebtIn, word.multiplier));
    }

    if (ctx.expect == Expect.SUCCESS) _checkStayers(ctx.values);
  }

  function _onExitFailed(ExitCtx memory ctx, bytes memory reason) internal {
    if (keccak256(reason) != keccak256(ctx.expected)) _mismatch(ctx.expect, reason);
    if (ctx.expect == Expect.BOUND) exitSlippageReverts++;
    else if (_selectorOf(ctx.expected) == IFacilityCaps.HardCapExceeded.selector) exitHardCapFailures++;
    else if (ctx.expect == Expect.CAP) exitCapFailures++;
    else exitGateFailures++;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TIME AND ADMIN                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Warps 1 second to 2 days (30 days when `deltaSeed % 8 == 7`), materializing Morpho
  ///         interest on odd seeds. Resets the oracle once interest brings a pool to LTV_CEILING.
  function act_warp(uint256 deltaSeed) external {
    uint256 delta = deltaSeed % 8 == 7 ? _bound(deltaSeed, 2 days, 30 days) : _bound(deltaSeed, 1, 2 days);
    vm.warp(block.timestamp + delta);
    if (deltaSeed % 2 == 1) morpho.accrueInterest(marketParams);
    if (oracleNearTarget && _ltv(pms[0]).max(_ltv(pms[1])) >= LTV_CEILING) {
      oracle.setPrice(DEFAULT_PRICE);
      oracleNearTarget = false;
      priceResets++;
    }
    warps++;
  }

  /// @notice `kindSeed % 7`: 0 entry word, 1 exit word, 2 auth, 3 pool top-up, 4 oracle, 5 security
  ///         word, 6 hard-cap raise.
  function act_admin(uint256 kindSeed, uint256 aSeed, uint256 bSeed, uint256 cSeed) external {
    uint256 kind = kindSeed % 7;
    if (kind == 0) _setEntry(aSeed % 2, bSeed, cSeed);
    else if (kind == 1) _setExit(aSeed % 2, bSeed, cSeed);
    else if (kind == 2) _setAuth(aSeed, bSeed, cSeed);
    else if (kind == 3) _refill(aSeed, bSeed);
    else if (kind == 4) _movePrice(aSeed);
    else if (kind == 5) _setSecurity(aSeed);
    else _raiseHardCap(aSeed, bSeed);
  }

  /// @dev Entry word on the PM's own pool and the shared pool: `shapeSeed % 3` picks
  ///      [own, shared], [shared, own] or [own], `shapeSeed / 3` the multiplier.
  function _setEntry(uint256 idx, uint256 shapeSeed, uint256 feeSeed) internal {
    uint16 own = idx == 0 ? POOL_1 : POOL_2;
    uint256 shape = shapeSeed % 3;
    uint64 id = shape == 0 ? _pair(own, SHARED_POOL) : shape == 1 ? _pair(SHARED_POOL, own) : uint64(own);
    Word memory word = Word(address(absoluteCaps), id, _multiplier(shapeSeed / 3));
    uint256 encoded = _encode(word);
    vm.prank(facilitator);
    facility.setEntry(address(pms[idx]), encoded, FAR_EXPIRY, uint24(_bound(feeSeed, 0, MAX_FEE)), false);
    ghostEntryWord[idx] = encoded;
    entryModel[idx] = word;
    entryRearms++;
  }

  /// @dev `shapeSeed % 6`: 0 ABSOLUTE, 1 exit pool, 2 exit dynamic cap, 3 the PM's entry pools
  ///      negated (the netting), 4 the shared or the exit pool negated, 5 exit dynamic cap negated.
  function _setExit(uint256 idx, uint256 shapeSeed, uint256 feeSeed) internal {
    uint256 shape = shapeSeed % 6;
    uint256 rest = shapeSeed / 6;
    int24 multiplier = _multiplier(rest);
    Word memory word;
    uint256 encoded;
    if (shape == 0) {
      encoded = _bound(rest, 50e6, 5_000e6);
    } else {
      if (shape == 1) {
        word = Word(address(absoluteCaps), EXIT_POOL, multiplier);
      } else if (shape == 2) {
        word = Word(address(dynamicCaps), EXIT_DYN, multiplier);
      } else if (shape == 3) {
        word = Word(address(absoluteCaps), entryModel[idx].id, -multiplier);
      } else if (shape == 4) {
        word = Word(address(absoluteCaps), (rest >> 2) % 2 == 0 ? SHARED_POOL : EXIT_POOL, -multiplier);
      } else {
        word = Word(address(dynamicCaps), EXIT_DYN, -multiplier);
      }
      encoded = _encode(word);
    }
    vm.prank(facilitator);
    facility.setExit(address(pms[idx]), encoded, FAR_EXPIRY, uint24(_bound(feeSeed, 0, MAX_FEE)));
    ghostExitWord[idx] = encoded;
    exitModel[idx] = word;
    exitRearms++;
  }

  function _setAuth(uint256 userSeed, uint256 amountSeed, uint256 expirySeed) internal {
    address who = users[userSeed % users.length];
    uint128 amount = uint128(_bound(amountSeed, 0, 10_000e6));
    uint40 expiry = expirySeed % 4 == 0
      ? uint40(block.timestamp - _bound(expirySeed, 0, 1 days))
      : uint40(block.timestamp + _bound(expirySeed, 1 hours, 3 days));
    vm.prank(operator);
    facility.setAuth(address(underlyingToken), who, amount, expiry);
    ghostAuths[who] = Auth({amount: amount, expiry: expiry});
    authRearms++;
  }

  /// @dev Grows a pool by `delta` through adjustCap, which keeps its outstanding consumption.
  function _refill(uint256 poolSeed, uint256 deltaSeed) internal {
    uint16 pool = uint16(poolSeed % 4) + POOL_1;
    uint256 delta = _bound(deltaSeed, 500e6, 5_000e6) * CAPS_SCALE;
    vm.prank(capsManager);
    // forge-lint: disable-next-line(unsafe-typecast)
    absoluteCaps.adjustCap(pool, int256(delta));
    ghostPoolCap[pool] += delta;
    ghostPoolHardCap[pool] += delta;
    refills++;
  }

  /// @dev Raises a pool's hard cap by `delta` through setCap, keeping its cap: the headroom a
  ///      credit blocked on HardCapExceeded needs, which adjustCap never adds.
  function _raiseHardCap(uint256 poolSeed, uint256 deltaSeed) internal {
    uint16 pool = uint16(poolSeed % 4) + POOL_1;
    uint256 delta = _bound(deltaSeed, 1, 1_000e6) * CAPS_SCALE;
    (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(pool);
    vm.prank(capsManager);
    // forge-lint: disable-next-line(unsafe-typecast)
    absoluteCaps.setCap(pool, cap, hardCap + uint128(delta));
    ghostPoolHardCap[pool] += delta;
    hardCapRaises++;
  }

  /// @dev `priceSeed % 4 == 3` puts the higher-LTV pool 30 to 120 bps above the PM target LTV,
  ///      below the modules' safeLtv; otherwise a price in [0.9, 1.5] keeps both well below it.
  function _movePrice(uint256 priceSeed) internal {
    priceMoves++;
    if (priceSeed % 4 != 3) {
      oracle.setPrice(_bound(priceSeed, 0.9e24, 1.5e24));
      oracleNearTarget = false;
      return;
    }
    // both PMs quote on this oracle: the higher debt per collateral is the higher LTV
    (uint256 debt, uint256 collateral) = (pms[0].debtAmount(), pms[0].collateralAmount());
    (uint256 debt2, uint256 collateral2) = (pms[1].debtAmount(), pms[1].collateralAmount());
    PositionManager pm = pms[0];
    if (debt2 * collateral > debt * collateral2) (pm, debt, collateral) = (pms[1], debt2, collateral2);
    (uint256 target,) = pm.config();
    uint256 ltv = target * (BPS + _bound(priceSeed >> 2, ABOVE_TARGET_MIN_BPS, ABOVE_TARGET_MAX_BPS)) / BPS;
    // the quoted collateral is collateral * price / 1e36
    oracle.setPrice(debt.fullMulDiv(1e54, ltv * collateral));
    oracleNearTarget = true;
    aboveTargetMoves++;
  }

  function _setSecurity(uint256 multiplierSeed) internal {
    Word memory word = Word(address(dynamicCaps), SECURITY_DYN, _multiplier(multiplierSeed));
    uint256 encoded = _encode(word);
    vm.prank(operator);
    facility.setSecurityCap(address(underlyingToken), encoded);
    ghostSecurityWord = encoded;
    securityModel = word;
    securityRearms++;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Actor in `slot` for PM `idx`: users 0-2, then the PM's ApproveExact and RepayOnBehalf exiters.
  function _actor(uint256 idx, uint256 slot) internal view returns (address who, uint256 kind) {
    if (slot < 3) return (users[slot], KIND_USER);
    if (slot == 3) return (address(exactExiters[idx]), KIND_EXACT);
    return (address(repayExiters[idx]), KIND_REPAY);
  }

  /// @dev Actor holding the most shares of PM `idx`, zero when none holds any.
  function _largestHolder(uint256 idx) internal view returns (address who, uint256 kind) {
    uint256 best;
    for (uint256 slot = 0; slot < 5; slot++) {
      (address candidate, uint256 candidateKind) = _actor(idx, slot);
      uint256 balance = pms[idx].balanceOf(candidate);
      if (balance > best) (best, who, kind) = (balance, candidate, candidateKind);
    }
  }

  /// @dev First actor holding shares of PM `idx`, scanning from `start`.
  function _holder(uint256 idx, uint256 start) internal view returns (address who, uint256 kind) {
    for (uint256 i = 0; i < 5; i++) {
      (who, kind) = _actor(idx, (start + i) % 5);
      if (pms[idx].balanceOf(who) > 0) return (who, kind);
    }
    return (address(0), 0);
  }

  function _multiplier(uint256 seed) internal pure returns (int24) {
    uint256 pick = seed % 4;
    if (pick == 0) return 4096;
    if (pick == 1) return 3072;
    if (pick == 2) return 5001;
    return 6144;
  }

  function _pair(uint16 first, uint16 second) internal pure returns (uint64) {
    return uint64(first) | (uint64(second) << 16);
  }

  function _encode(Word memory word) internal pure returns (uint256) {
    return LibCaps.encodeExternal(word.caps, word.id, word.multiplier);
  }

  function _wordKind(Word memory word) internal view returns (uint256) {
    if (word.caps == address(0)) return WORD_ABSOLUTE;
    bool pool = word.caps == address(absoluteCaps);
    if (word.multiplier < 0) return pool ? WORD_POOL_CREDIT : WORD_DYNAMIC_CREDIT;
    return pool ? WORD_POOL_DEBIT : WORD_DYNAMIC_DEBIT;
  }

  /// @dev Q12.12 consumption of a positive multiplier on a debt `amount`, rounded up, in caps units.
  function _consumption(uint256 amount, int24 multiplier) internal pure returns (uint256) {
    // forge-lint: disable-next-line(unsafe-typecast)
    return (amount * CAPS_SCALE * uint256(uint24(multiplier)) + 4095) / 4096;
  }

  /// @dev Q12.12 credit of a negative multiplier on a debt `amount`, rounded down, in caps units.
  function _release(uint256 amount, int24 multiplier) internal pure returns (uint256) {
    // forge-lint: disable-next-line(unsafe-typecast)
    return amount * CAPS_SCALE * uint256(uint24(-multiplier)) / 4096;
  }

  /// @dev Debt per quoted collateral, in WAD.
  function _ltv(PositionManager pm) internal view returns (uint256) {
    return pm.debtAmount().mulDiv(1e18, pm.collateralAmountQuoted());
  }

  /// @dev Whether the pool's quoted LTV is above the PM target, and within NEAR_TARGET_UNITS
  ///      debt units of it.
  function _targetSide(PositionManager pm) internal view returns (bool above, bool near) {
    (uint256 target,) = pm.config();
    uint256 debt = pm.debtAmount() * 1e18;
    uint256 targetDebt = pm.collateralAmountQuoted() * target;
    above = debt > targetDebt;
    near = (above ? debt - targetDebt : targetDebt - debt) < NEAR_TARGET_UNITS * 1e18;
  }

  function _borrowCapacityError() internal pure returns (bytes memory) {
    return abi.encodeWithSelector(LibManagerErrors.InsufficientBorrowCapacity.selector);
  }

  /// @dev Debt an exit pulls for a mirrored `debt`: plus 10 bps rounded up and one unit.
  function _required(uint256 debt) internal pure returns (uint256) {
    return debt == 0 ? 0 : debt + (debt * 10 + 9_999) / 10_000 + 1;
  }

  function _ghostAuthAvailable(address who) internal view returns (uint256) {
    Auth memory auth = ghostAuths[who];
    return block.timestamp < auth.expiry ? auth.amount : 0;
  }

  /// @dev Summed caps of the pools a FacilityAbsoluteCaps id lists.
  function _ghostRoom(uint64 id) internal view returns (uint256 room) {
    for (uint256 i = 0; i < 4; i++) {
      room += ghostPoolCap[uint16(id >> (16 * i))];
    }
  }

  /// @dev Summed headroom (hard cap minus cap) of the pools a FacilityAbsoluteCaps id lists.
  function _ghostHeadroom(uint64 id) internal view returns (uint256 headroom) {
    for (uint256 i = 0; i < 4; i++) {
      uint16 pool = uint16(id >> (16 * i));
      headroom += ghostPoolHardCap[pool] - ghostPoolCap[pool];
    }
  }

  function _value(PositionManager pm) internal view returns (Value memory v) {
    (uint256 assets, uint256 supply, uint256 mgmtFeeShares, uint256 perfFeeShares) = pm.pendingFees();
    v.assets = assets;
    v.supply = supply + mgmtFeeShares + perfFeeShares + pm.virtualShareOffset();
  }

  /// @dev Holder values before a flow, only read when it is predicted to succeed.
  function _snapshotValues(Expect expect, Value[2] memory values) internal view {
    if (expect != Expect.SUCCESS) return;
    values[0] = _value(pms[0]);
    values[1] = _value(pms[1]);
  }

  /// @dev The shares held through the flow (the smaller of the two supplies) may lose at most
  ///      STAYER_DUST between the pre-flow and the post-flow share price.
  function _checkStayers(Value[2] memory before) internal {
    for (uint256 i = 0; i < 2; i++) {
      Value memory current = _value(pms[i]);
      uint256 stayers = before[i].supply.min(current.supply);
      uint256 was = stayers.mulDiv(before[i].assets, before[i].supply);
      uint256 held = stayers.mulDivUp(current.assets, current.supply);
      if (held >= was) continue;
      uint256 drop = was - held;
      if (drop > maxStayerDrop[i]) maxStayerDrop[i] = drop;
      if (drop > STAYER_DUST) stayerValueDropped[i] = true;
    }
  }

  /// @dev FacilityAbsoluteCaps.consume: pools from id1, each up to its cap.
  function _ghostWalk(uint64 id, uint256 consumption) internal {
    uint256 left = consumption;
    for (uint256 i = 0; i < 4 && left != 0; i++) {
      uint16 pool = uint16(id >> (16 * i));
      if (pool == 0) continue;
      uint256 moved = left.min(ghostPoolCap[pool]);
      ghostPoolCap[pool] -= moved;
      left -= moved;
    }
    if (left != 0) capMirrorBroken = true;
  }

  /// @dev FacilityAbsoluteCaps.consume under a negative multiplier: pools from id1, each up to
  ///      its hard cap.
  function _ghostCredit(uint64 id, uint256 credit) internal {
    uint256 left = credit;
    for (uint256 i = 0; i < 4 && left != 0; i++) {
      uint16 pool = uint16(id >> (16 * i));
      if (pool == 0) continue;
      uint256 moved = left.min(ghostPoolHardCap[pool] - ghostPoolCap[pool]);
      ghostPoolCap[pool] += moved;
      left -= moved;
    }
    if (left != 0) capMirrorBroken = true;
  }

  /// @dev FacilityDynamicCaps.consume: the origin moves so the capacity becomes the previous one
  ///      minus the consumption, rounded down to whole seconds.
  function _ghostDynamic(uint64 id, uint256 consumption) internal {
    uint256 current = ghostRemaining(id);
    if (consumption > current) {
      capMirrorBroken = true;
      return;
    }
    ghostOrigin[id] = block.timestamp - (current - consumption) * dynRecoveryTime[id] / dynRecovery[id];
  }

  function _setExpected(EnterCtx memory ctx, Expect expect, bytes memory expected) internal pure {
    ctx.expect = expect;
    ctx.expected = expected;
  }

  function _setExpected(ExitCtx memory ctx, Expect expect, bytes memory expected) internal pure {
    ctx.expect = expect;
    ctx.expected = expected;
  }

  function _mismatch(Expect expect, bytes memory reason) internal {
    if (expect == Expect.SUCCESS) unexpectedRevert = true;
    else if (expect == Expect.GATE) gateParityBroken = true;
    else if (expect == Expect.BOUND) slippageBroken = true;
    else capOutcomeBroken = true;
    if (firstMismatch.length == 0) firstMismatch = reason.length > 0 ? reason : bytes("success");
  }

  function _selectorOf(bytes memory reason) internal pure returns (bytes4 selector) {
    if (reason.length < 4) return bytes4(0);
    assembly ("memory-safe") {
      selector := mload(add(reason, 32))
    }
  }

  function _decodeTwo(bytes memory reason) internal pure returns (uint256 a, uint256 b) {
    assembly ("memory-safe") {
      a := mload(add(reason, 36))
      b := mload(add(reason, 68))
    }
  }
}
