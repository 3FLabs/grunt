// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/facility/Facility.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

// Word kinds: ABSOLUTE, or EXTERNAL on a cap layout with a multiplier sign.
uint8 constant KIND_ABSOLUTE = 0;
uint8 constant KIND_A = 1; // [POOL_A], positive
uint8 constant KIND_BC = 2; // [POOL_B, POOL_C], positive
uint8 constant KIND_C = 3; // [POOL_C], positive
uint8 constant KIND_D_POS = 4; // [POOL_D], positive
uint8 constant KIND_D_NEG = 5; // [POOL_D], negative
uint8 constant KIND_DYN_POS = 6; // DYN_ID, positive
uint8 constant KIND_DYN_NEG = 7; // DYN_ID, negative
uint8 constant KIND_COUNT = 8;

// Pool groups: GROUP_A and GROUP_BC only see positive multipliers.
uint256 constant GROUP_A = 0;
uint256 constant GROUP_BC = 1;
uint256 constant GROUP_D = 2;
uint256 constant GROUP_COUNT = 3;
uint256 constant NO_GROUP = type(uint256).max;

uint16 constant POOL_A = 1;
uint16 constant POOL_B = 2;
uint16 constant POOL_C = 3;
uint16 constant POOL_D = 4;
uint64 constant DYN_ID = 7;

/// @title FacilitySharedCapsHandler
/// @notice Drives Facility intents whose deposit caps are EXTERNAL words on one
///         FacilityAbsoluteCaps (groups A, [B, C] + [C], and D) and one FacilityDynamicCaps id,
///         next to ABSOLUTE words. Mirrors every cap movement with its own Q12.12 math.
/// @dev Words only change through the documented procedure: an EXTERNAL word with outstanding
///      supply is first set to zero, and a new word is only set once the supply is zero. What
///      the old word's flows left in its pools is moved to the group base.
contract FacilitySharedCapsHandler is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TYPES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  struct IntentGhost {
    uint256 word;
    uint8 kind;
    int24 multiplier;
    // signed hardCap - cap moved by the current word's flows
    int256 net;
    // flows whose amount x |multiplier| is not a multiple of 4096
    uint256 inexactOps;
  }

  struct Flow {
    bool consuming;
    // a credit into FacilityAbsoluteCaps pools
    bool credit;
    bool fits;
    uint256 charge;
    // the exact revert of a flow that does not fit
    bytes err;
  }

  struct Snap {
    uint128[4] caps;
    uint128[4] hardCaps;
    uint64 origin;
    uint256 remaining;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 internal constant ONE = 4096;
  uint256 internal constant POOL_COUNT = 4;
  uint256 internal constant MAX_INTENTS = 16;
  uint256 internal constant USER_COUNT = 3;
  uint256 internal constant MAX_AMOUNT = 200_000e18;
  uint256 internal constant DUST = 10_000;
  uint256 internal constant MAX_ABSOLUTE_WORD = 2_000_000e18;
  uint256 internal constant MAX_INTEGER_MULTIPLIER = 10;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONTRACTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  Facility public facility;
  FacilityAbsoluteCaps public absoluteCaps;
  FacilityDynamicCaps public dynamicCaps;
  MockERC20 public debtToken;
  address public positionManager;
  address public facilitator;
  address public compliance;
  address[] public users;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           GHOSTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256[] internal intentIds;
  mapping(uint256 => IntentGhost) internal ghosts;

  /// @notice Initial hardCap - cap of each group plus what switched-away words left in it.
  int256[3] public groupBase;

  /// @notice Dynamic remaining right after the last consumption, and when it happened.
  uint256 public dynLevel;
  uint256 public dynTime;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           FLAGS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  bool public capErrorMismatch;
  bool public flowRevertedWithRoom;
  bool public facilitatorCallReverted;
  bool public poolsMismatch;
  bool public dynamicCapMismatch;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          COUNTERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 public intentsCreated;
  uint256 public depositSuccesses;
  uint256 public withdrawSuccesses;
  uint256 public revertsWhileDepositing;
  uint256 public revertsWhileResolving;
  uint256 public depositCapFailures;
  uint256 public releaseCapFailures;
  uint256 public creditFailures;
  uint256 public dynamicConsumptions;
  uint256 public locks;
  uint256 public wordsClosed;
  uint256 public wordsSwitched;
  uint256 public absoluteWordsSet;
  uint256 public warps;

  constructor(
    Facility facility_,
    FacilityAbsoluteCaps absoluteCaps_,
    FacilityDynamicCaps dynamicCaps_,
    MockERC20 debtToken_,
    address positionManager_,
    address facilitator_,
    address compliance_
  ) {
    facility = facility_;
    absoluteCaps = absoluteCaps_;
    dynamicCaps = dynamicCaps_;
    debtToken = debtToken_;
    positionManager = positionManager_;
    facilitator = facilitator_;
    compliance = compliance_;

    for (uint256 i = 0; i < USER_COUNT; i++) {
      address user = makeAddr(string.concat("shared_caps_user", vm.toString(i)));
      users.push(user);
      vm.prank(user);
      debtToken_.approve(address(facility_), type(uint256).max);
    }
    for (uint256 g = 0; g < GROUP_COUNT; g++) {
      groupBase[g] = int256(groupHeadroom(g));
    }
    dynLevel = dynamicCaps_.remaining(DYN_ID);
    dynTime = block.timestamp;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ACTIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function act_createIntent(uint256 kindSeed, uint256 multSeed, uint256 capSeed, uint256 delaySeed) public {
    if (intentIds.length >= MAX_INTENTS) return;
    uint8 kind = uint8(kindSeed % KIND_COUNT);
    (uint256 word, int24 multiplier) = _newWord(kind, multSeed, capSeed);
    IntentProperties memory props = IntentProperties({
      depositAsset: Asset({asset: address(debtToken), isPositionManager: false}),
      targetAsset: Asset({asset: positionManager, isPositionManager: true}),
      depositCap: word,
      guardKey: positionManager,
      resolveStart: uint40(block.timestamp + bound(delaySeed, 1 days, 30 days)),
      quorum: 1,
      transferableIntent: true
    });
    vm.prank(facilitator);
    try facility.createIntent(props) returns (uint256 id) {
      intentIds.push(id);
      _bind(ghosts[id], word, kind, multiplier);
      intentsCreated++;
    } catch {
      facilitatorCallReverted = true;
    }
  }

  function act_deposit(uint256 intentSeed, uint256 userSeed, uint256 amountSeed) public {
    (bool found, uint256 id) = _pick(intentSeed, true, false);
    if (!found) return;
    IntentGhost storage g = ghosts[id];
    address depositor = users[userSeed % USER_COUNT];
    uint256 amount = _depositAmount(id, g, amountSeed);
    Flow memory f = _preview(id, g, amount, true);
    debtToken.mint(depositor, amount);
    Snap memory s = _snap();

    vm.prank(depositor);
    try facility.deposit(id, amount) {
      _afterFlow(g, f, s, amount);
      depositSuccesses++;
    } catch (bytes memory reason) {
      if (_afterRevert(f, s, reason)) depositCapFailures++;
    }
  }

  function act_withdraw(uint256 intentSeed, uint256 userSeed, uint256 amountSeed) public {
    (bool found, uint256 id) = _pick(intentSeed, true, true);
    if (!found) return;
    (address holder, uint256 balance) = _pickHolder(id, userSeed);
    if (balance == 0) return;
    uint256 amount = amountSeed % 4 == 0 ? balance : bound(amountSeed, 1, balance);
    IntentGhost storage g = ghosts[id];
    Flow memory f = _preview(id, g, amount, false);
    Snap memory s = _snap();

    vm.prank(holder);
    try facility.withdraw(id, holder, holder, amount) {
      _afterFlow(g, f, s, amount);
      withdrawSuccesses++;
    } catch (bytes memory reason) {
      if (_afterRevert(f, s, reason)) releaseCapFailures++;
    }
  }

  function act_revertDeposit(uint256 intentSeed, uint256 userSeed) public {
    (bool found, uint256 id) = _pick(intentSeed, false, true);
    if (!found) return;
    (address holder, uint256 balance) = _pickHolder(id, userSeed);
    if (balance == 0) return;
    bool depositing = _isDepositing(id);
    IntentGhost storage g = ghosts[id];
    Flow memory f = _preview(id, g, balance, false);
    Snap memory s = _snap();

    vm.prank(compliance);
    try facility.revertDeposit(id, holder, holder) {
      _afterFlow(g, f, s, balance);
      if (depositing) revertsWhileDepositing++;
      else revertsWhileResolving++;
    } catch (bytes memory reason) {
      if (_afterRevert(f, s, reason)) releaseCapFailures++;
    }
  }

  function act_lock(uint256 intentSeed) public {
    (bool found, uint256 id) = _pick(intentSeed, true, true);
    if (!found) return;
    vm.prank(facilitator);
    try facility.lock(id) {
      locks++;
    } catch {
      facilitatorCallReverted = true;
    }
  }

  function act_setDepositCap(uint256 intentSeed, uint256 kindSeed, uint256 multSeed, uint256 capSeed) public {
    if (intentIds.length == 0) return;
    uint256 id = intentIds[intentSeed % intentIds.length];
    IntentGhost storage g = ghosts[id];
    uint256 supply = facility.totalSupply(id);
    uint8 kind = KIND_ABSOLUTE;
    uint256 word;
    int24 multiplier;
    if (supply == 0) {
      kind = uint8(kindSeed % KIND_COUNT);
      (word, multiplier) = _newWord(kind, multSeed, capSeed);
    } else if (g.kind == KIND_ABSOLUTE) {
      word = _absoluteWord(capSeed);
    }
    // otherwise an EXTERNAL word with outstanding supply: close it with a zero word first

    bool wasExternal = g.kind != KIND_ABSOLUTE;
    vm.prank(facilitator);
    try facility.setDepositCap(id, word) {
      _unbind(g);
      _bind(g, word, kind, multiplier);
      if (supply == 0) wordsSwitched++;
      else if (wasExternal) wordsClosed++;
      else absoluteWordsSet++;
    } catch {
      facilitatorCallReverted = true;
    }
  }

  function act_warp(uint256 seed) public {
    vm.warp(block.timestamp + bound(seed, 1, 3 days));
    warps++;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function getIntentIds() external view returns (uint256[] memory) {
    return intentIds;
  }

  function ghostOf(uint256 id) external view returns (IntentGhost memory) {
    return ghosts[id];
  }

  function groupOf(uint8 kind) public pure returns (uint256) {
    if (kind == KIND_A) return GROUP_A;
    if (kind == KIND_BC || kind == KIND_C) return GROUP_BC;
    if (kind == KIND_D_POS || kind == KIND_D_NEG) return GROUP_D;
    return NO_GROUP;
  }

  /// @notice Sum of hardCap - cap over the pools of a group.
  function groupHeadroom(uint256 group) public view returns (uint256) {
    if (group == GROUP_A) return _room(POOL_A, false);
    if (group == GROUP_BC) return _room(_pair(POOL_B, POOL_C), false);
    return _room(POOL_D, false);
  }

  /// @notice Group base plus the mirrored net of every intent bound to the group.
  function groupGhost(uint256 group) external view returns (int256 total) {
    total = groupBase[group];
    for (uint256 i = 0; i < intentIds.length; i++) {
      IntentGhost storage g = ghosts[intentIds[i]];
      if (groupOf(g.kind) == group) total += g.net;
    }
  }

  /// @notice Dust bounds of a positive group's outstanding consumption from the bound intents'
  ///         supplies: sum ceil(S * m) and sum floor(S * m + inexactOps * 4095), in Q12.12.
  function supplyBounds(uint256 group) external view returns (uint256 lo, uint256 hi) {
    for (uint256 i = 0; i < intentIds.length; i++) {
      IntentGhost storage g = ghosts[intentIds[i]];
      if (groupOf(g.kind) != group) continue;
      uint256 scaled = facility.totalSupply(intentIds[i]) * _abs(g.multiplier);
      lo += (scaled + ONE - 1) / ONE;
      hi += (scaled + g.inexactOps * (ONE - 1)) / ONE;
    }
  }

  /// @notice Dynamic remaining reachable from the last consumption at the recovery rate,
  ///         rounded down and up.
  function dynamicBounds() external view returns (uint256 lo, uint256 hi) {
    (uint128 recovery, uint64 recoveryTime,) = dynamicCaps.getCap(DYN_ID);
    uint256 scaled = uint256(recovery) * (block.timestamp - dynTime);
    lo = _min(dynLevel + scaled / recoveryTime, recovery);
    hi = _min(dynLevel + (scaled + recoveryTime - 1) / recoveryTime, recovery);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          INTERNAL                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev A flow without room reverts with the exact cap error: DepositCapExceeded for an
  ///      ABSOLUTE deposit, InsufficientCap for a consumption, HardCapExceeded for a credit.
  function _preview(uint256 id, IntentGhost storage g, uint256 amount, bool isDeposit)
    internal
    view
    returns (Flow memory f)
  {
    if (g.kind == KIND_ABSOLUTE) {
      f.fits = true;
      if (!isDeposit) return f;
      uint256 attempted = facility.totalSupply(id) + amount;
      f.fits = attempted <= g.word;
      f.err = abi.encodeWithSelector(LibFacilityErrors.DepositCapExceeded.selector, id, g.word, attempted);
      return f;
    }
    uint256 m = _abs(g.multiplier);
    f.consuming = (g.multiplier > 0) == isDeposit;
    f.charge = f.consuming ? (amount * m + ONE - 1) / ONE : amount * m / ONE;
    if (_isDynamic(g.kind)) {
      f.fits = !f.consuming || f.charge <= dynamicCaps.remaining(DYN_ID);
      f.err = abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, DYN_ID);
      return f;
    }
    uint64 capId = _capId(g.kind);
    f.credit = !f.consuming;
    f.fits = f.charge <= _room(capId, f.consuming);
    f.err = abi.encodeWithSelector(
      f.consuming ? IFacilityCaps.InsufficientCap.selector : IFacilityCaps.HardCapExceeded.selector, capId
    );
  }

  function _afterFlow(IntentGhost storage g, Flow memory f, Snap memory s, uint256 amount) internal {
    if (!f.fits) capErrorMismatch = true;
    uint256 group = groupOf(g.kind);
    if (group == NO_GROUP) {
      _checkPools(s, 0, 0, true);
    } else {
      _checkPools(s, _capId(g.kind), f.charge, f.consuming);
      g.net += f.consuming ? int256(f.charge) : -int256(f.charge);
    }
    if (group != NO_GROUP && (amount * _abs(g.multiplier)) % ONE != 0) g.inexactOps++;
    _checkDynamic(s, _isDynamic(g.kind) && f.consuming, f.charge);
  }

  /// @dev Returns whether the revert is the flow's cap error. A rejected credit must leave
  ///      every pool as it was.
  function _afterRevert(Flow memory f, Snap memory s, bytes memory reason) internal returns (bool) {
    if (f.fits) {
      flowRevertedWithRoom = true;
      return false;
    }
    if (keccak256(reason) != keccak256(f.err)) {
      capErrorMismatch = true;
      return false;
    }
    if (f.credit) {
      _checkPools(s, 0, 0, true);
      creditFailures++;
    }
    return true;
  }

  function _snap() internal view returns (Snap memory s) {
    for (uint16 pool = POOL_A; pool <= POOL_D; pool++) {
      (s.caps[pool - 1], s.hardCaps[pool - 1]) = absoluteCaps.getCap(pool);
    }
    (,, s.origin) = dynamicCaps.getCap(DYN_ID);
    s.remaining = dynamicCaps.remaining(DYN_ID);
  }

  /// @dev A flow walks the pools of `capId` from id1, each taking up to its cap when consuming
  ///      or up to its headroom when crediting. Other pools and every hard cap never move.
  function _checkPools(Snap memory s, uint64 capId, uint256 charge, bool consuming) internal {
    uint128[4] memory expected;
    for (uint256 i = 0; i < POOL_COUNT; i++) {
      expected[i] = s.caps[i];
    }
    for (uint256 slot = 0; slot < POOL_COUNT; slot++) {
      uint16 pool = uint16(capId >> (16 * slot));
      if (pool == 0) break;
      uint128 before = s.caps[pool - 1];
      uint256 moved = _min(charge, consuming ? before : s.hardCaps[pool - 1] - before);
      expected[pool - 1] = uint128(consuming ? before - moved : before + moved);
      charge -= moved;
    }
    if (charge != 0) poolsMismatch = true;
    for (uint16 pool = POOL_A; pool <= POOL_D; pool++) {
      (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(pool);
      if (cap != expected[pool - 1] || hardCap != s.hardCaps[pool - 1]) poolsMismatch = true;
    }
  }

  /// @dev A consumption must take its charge plus at most one second of recovery (origin
  ///      rounding) and never move the origin back. Anything else must leave the origin as is.
  function _checkDynamic(Snap memory s, bool consumed, uint256 charge) internal {
    (uint128 recovery, uint64 recoveryTime, uint64 origin) = dynamicCaps.getCap(DYN_ID);
    if (!consumed) {
      if (origin != s.origin) dynamicCapMismatch = true;
      return;
    }
    uint256 remaining = dynamicCaps.remaining(DYN_ID);
    uint256 forfeit = (uint256(recovery) + recoveryTime - 1) / recoveryTime;
    if (origin < s.origin || remaining + charge > s.remaining || remaining + charge + forfeit < s.remaining) {
      dynamicCapMismatch = true;
    }
    dynLevel = remaining;
    dynTime = block.timestamp;
    dynamicConsumptions++;
  }

  function _bind(IntentGhost storage g, uint256 word, uint8 kind, int24 multiplier) internal {
    g.word = word;
    g.kind = kind;
    g.multiplier = multiplier;
    g.net = 0;
    g.inexactOps = 0;
  }

  /// @dev The released word's net stays in its pools (releases now follow the new word).
  function _unbind(IntentGhost storage g) internal {
    uint256 group = groupOf(g.kind);
    if (group != NO_GROUP) groupBase[group] += g.net;
  }

  /// @dev Multiplier seeds: 7 mod 8 = type(int24).max, else even = integer, odd = raw Q12.12.
  function _newWord(uint8 kind, uint256 multSeed, uint256 capSeed) internal view returns (uint256, int24) {
    if (kind == KIND_ABSOLUTE) return (_absoluteWord(capSeed), 0);
    int24 multiplier;
    if (multSeed % 8 == 7) multiplier = type(int24).max;
    else if (multSeed % 2 == 0) multiplier = int24(int256(bound(multSeed >> 1, 1, MAX_INTEGER_MULTIPLIER) * ONE));
    else multiplier = int24(int256(bound(multSeed >> 1, 1, MAX_INTEGER_MULTIPLIER * ONE)));
    if (kind == KIND_D_NEG || kind == KIND_DYN_NEG) multiplier = -multiplier;
    address caps = _isDynamic(kind) ? address(dynamicCaps) : address(absoluteCaps);
    return (_encodeExternal(caps, _capId(kind), multiplier), multiplier);
  }

  /// @dev | 8 bits type = 1 | 24 bits multiplier | 64 bits id | 160 bits caps address |
  function _encodeExternal(address caps, uint64 capId, int24 multiplier) internal pure returns (uint256) {
    return (1 << 248) | (uint256(uint24(multiplier)) << 224) | (uint256(capId) << 160) | uint256(uint160(caps));
  }

  function _absoluteWord(uint256 capSeed) internal pure returns (uint256) {
    return capSeed % 4 == 0 ? 0 : bound(capSeed, 1, MAX_ABSOLUTE_WORD);
  }

  function _depositAmount(uint256 id, IntentGhost storage g, uint256 seed) internal view returns (uint256) {
    uint256 mode = seed % 8;
    if (mode == 0) return bound(seed, 1, DUST);
    if (mode <= 2) {
      uint256 available = _available(id, g);
      if (available < MAX_AMOUNT) {
        if (mode == 2) return available + 1;
        return available == 0 ? 1 : available;
      }
    }
    return bound(seed, 1, MAX_AMOUNT);
  }

  /// @dev Largest deposit whose charge fits, from the pool state and the word alone.
  function _available(uint256 id, IntentGhost storage g) internal view returns (uint256) {
    if (g.kind == KIND_ABSOLUTE) {
      uint256 supply = facility.totalSupply(id);
      return supply < g.word ? g.word - supply : 0;
    }
    uint256 m = _abs(g.multiplier);
    if (_isDynamic(g.kind)) {
      return g.multiplier < 0 ? type(uint256).max : dynamicCaps.remaining(DYN_ID) * ONE / m;
    }
    return _room(_capId(g.kind), g.multiplier > 0) * ONE / m;
  }

  function _room(uint64 capId, bool consuming) internal view returns (uint256 room) {
    for (uint256 slot = 0; slot < POOL_COUNT; slot++) {
      uint16 pool = uint16(capId >> (16 * slot));
      if (pool == 0) break;
      (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(pool);
      room += consuming ? cap : hardCap - cap;
    }
  }

  function _capId(uint8 kind) internal pure returns (uint64) {
    if (kind == KIND_A) return POOL_A;
    if (kind == KIND_BC) return _pair(POOL_B, POOL_C);
    if (kind == KIND_C) return POOL_C;
    if (kind == KIND_D_POS || kind == KIND_D_NEG) return POOL_D;
    return DYN_ID;
  }

  function _pair(uint16 first, uint16 second) internal pure returns (uint64) {
    return uint64(first) | (uint64(second) << 16);
  }

  function _isDynamic(uint8 kind) internal pure returns (bool) {
    return kind == KIND_DYN_POS || kind == KIND_DYN_NEG;
  }

  function _abs(int24 multiplier) internal pure returns (uint256) {
    return uint256(multiplier < 0 ? -int256(multiplier) : int256(multiplier));
  }

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

  function _isDepositing(uint256 id) internal view returns (bool) {
    (IntentProperties memory props,,, bool resolved) = facility.getIntent(id);
    return !resolved && props.resolveStart > block.timestamp;
  }

  function _pick(uint256 seed, bool depositing, bool withSupply) internal view returns (bool found, uint256 id) {
    uint256[] memory candidates = new uint256[](intentIds.length);
    uint256 count = 0;
    for (uint256 i = 0; i < intentIds.length; i++) {
      uint256 candidate = intentIds[i];
      if (depositing && !_isDepositing(candidate)) continue;
      if (withSupply && facility.totalSupply(candidate) == 0) continue;
      candidates[count++] = candidate;
    }
    if (count == 0) return (false, 0);
    return (true, candidates[seed % count]);
  }

  function _pickHolder(uint256 id, uint256 seed) internal view returns (address holder, uint256 balance) {
    for (uint256 k = 0; k < USER_COUNT; k++) {
      holder = users[(seed % USER_COUNT + k) % USER_COUNT];
      balance = facility.balanceOf(holder, id);
      if (balance != 0) return (holder, balance);
    }
  }
}
