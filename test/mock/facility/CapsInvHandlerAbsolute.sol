// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test, Vm} from "forge-std/Test.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibBit} from "lib/solady/src/utils/LibBit.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";

import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";

/// @title CapsInvHandlerAbsolute
/// @notice Handler for FacilityAbsoluteCapsInvariantTest. Mirrors pools 0 to POOLS from the
///         documented rules and flags any call whose outcome or events differ from the mirror.
contract CapsInvHandlerAbsolute is Test {
  uint16 public constant POOLS = 5;
  uint256 internal constant CONSUMER_ROLE = 1 << 1;
  uint256 internal constant ONE = 1 << 12;
  uint256 internal constant TYPICAL = 1e30;

  FacilityAbsoluteCaps public immutable caps;
  address public immutable owner;
  address public immutable manager;
  address public immutable stranger;
  /// @dev consumers[0] keeps the consumer role, the others are granted and revoked.
  address[3] public consumers;

  /// @dev Outstanding consumption, above the hard cap after a shrink past the remaining cap.
  mapping(uint16 => uint128) public ghostConsumed;
  mapping(uint16 => uint128) public ghostHardCap;
  mapping(address => bool) public ghostConsumer;

  bool public outcomeMismatch;
  bool public eventMismatch;
  bool public quoteMismatch;

  uint256 public consumeCalls;
  uint256 public releaseCalls;
  uint256 public overReleaseCalls;
  uint256 public consumes;
  uint256 public releases;
  uint256 public hardCapRejections;

  constructor(
    FacilityAbsoluteCaps _caps,
    address _owner,
    address _manager,
    address _stranger,
    address[3] memory _consumers
  ) {
    caps = _caps;
    owner = _owner;
    manager = _manager;
    stranger = _stranger;
    consumers = _consumers;
    for (uint16 pool = 0; pool <= POOLS; pool++) {
      (uint128 cap, uint128 hardCap) = _caps.getCap(pool);
      (ghostConsumed[pool], ghostHardCap[pool]) = (hardCap - cap, hardCap);
    }
    for (uint256 i = 0; i < 3; i++) {
      ghostConsumer[_consumers[i]] = _caps.hasAnyRole(_consumers[i], CONSUMER_ROLE);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ACTIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function act_consume(uint256 layoutSeed, uint256 multiplierSeed, uint256 amountSeed) external {
    consumeCalls++;
    _consumeQuoted(layoutSeed, _magnitude(multiplierSeed), amountSeed);
  }

  function act_release(uint256 layoutSeed, uint256 multiplierSeed, uint256 amountSeed) external {
    releaseCalls++;
    _consumeQuoted(layoutSeed, -_magnitude(multiplierSeed), amountSeed);
  }

  /// @dev A release one charge unit past the summed headroom of the layout, or further.
  function act_overRelease(uint256 layoutSeed, uint256 multiplierSeed, uint256 amountSeed) external {
    overReleaseCalls++;
    uint64 id = layoutOf(layoutSeed);
    int24 multiplier = -_magnitude(multiplierSeed);
    uint256 amount = FixedPointMathLib.mulDivUp(roomOf(id, true) + 1, ONE, _abs(multiplier));
    if (amountSeed % 2 == 1) amount += bound(amountSeed, 0, TYPICAL);
    if (_available(id, multiplier) >= amount) quoteMismatch = true;
    _consume(consumers[0], id, amount, multiplier);
  }

  function act_consumeAny(uint256 callerSeed, uint256 layoutSeed, uint256 multiplierSeed, uint256 amountSeed) external {
    address caller = callerSeed % 4 == 3 ? stranger : consumers[callerSeed % 4];
    uint64 id = layoutOf(layoutSeed);
    int24 multiplier = multiplierSeed % 8 == 0 ? int24(0) : _magnitude(multiplierSeed >> 3);
    if (multiplierSeed % 8 > 4) multiplier = -multiplier;
    uint256 quote = _available(id, multiplier);
    uint256 mode = amountSeed % 3;
    uint256 amount = mode == 2 ? bound(amountSeed, 0, 1e34) : mode == 1 && quote < type(uint256).max ? quote + 1 : quote;
    _consume(caller, id, amount, multiplier);
  }

  function act_setCap(uint256 poolSeed, uint256 capSeed, uint256 hardCapSeed) external {
    uint16 pool = _pool(poolSeed);
    uint128 hardCap = uint128(bound(hardCapSeed, 0, hardCapSeed % 8 == 0 ? type(uint128).max : TYPICAL));
    uint128 cap = capSeed % 8 == 0 && hardCap < type(uint128).max ? hardCap + 1 : uint128(bound(capSeed, 0, hardCap));
    bytes memory expected;
    if (pool == 0) expected = abi.encodeWithSelector(FacilityAbsoluteCaps.InvalidCapId.selector);
    else if (cap > hardCap) expected = abi.encodeWithSelector(FacilityAbsoluteCaps.CapAboveHardCap.selector);

    vm.recordLogs();
    vm.prank(manager);
    try caps.setCap(pool, cap, hardCap) {
      _checkCapSet(pool, cap, hardCap, hardCap - cap, expected);
    } catch (bytes memory reason) {
      _checkAdminError(reason, expected);
    }
  }

  /// @dev adjustCap moves the hard cap by `delta` (stopping at zero) and keeps the consumption.
  function act_adjustCap(uint256 poolSeed, int256 delta) external {
    uint16 pool = _pool(poolSeed);
    uint128 consumed = ghostConsumed[pool];
    uint128 hardCap = ghostHardCap[pool];
    uint256 mode = (poolSeed >> 3) % 4;
    if (mode == 1) delta = bound(delta, -2 * int256(TYPICAL), 2 * int256(TYPICAL));
    else if (mode == 2) delta = int256(uint256(type(uint128).max - hardCap)) + (delta & 1);
    else if (mode == 3) delta = -int256(uint256(_capOf(pool))) - (delta & 1);

    uint256 newHardCap;
    if (delta < 0) newHardCap = FixedPointMathLib.zeroFloorSub(hardCap, uint256(-(delta + 1)) + 1);
    else newHardCap = hardCap + uint256(delta);
    uint256 target = FixedPointMathLib.zeroFloorSub(newHardCap, consumed);
    bytes memory expected;
    if (pool == 0) expected = abi.encodeWithSelector(FacilityAbsoluteCaps.InvalidCapId.selector);
    else if (newHardCap > type(uint128).max) expected = abi.encodeWithSelector(SafeCastLib.Overflow.selector);

    vm.recordLogs();
    vm.prank(manager);
    try caps.adjustCap(pool, delta) returns (uint128 newCap, uint128 returnedHardCap) {
      if (newCap != target || returnedHardCap != newHardCap) outcomeMismatch = true;
      _checkCapSet(pool, uint128(target), uint128(newHardCap), consumed, expected);
    } catch (bytes memory reason) {
      _checkAdminError(reason, expected);
    }
  }

  function act_setRole(uint256 accountSeed, bool grant) external {
    address account = consumers[1 + accountSeed % 2];
    vm.prank(owner);
    if (grant) caps.grantRoles(account, CONSUMER_ROLE);
    else caps.revokeRoles(account, CONSUMER_ROLE);
    ghostConsumer[account] = grant;
  }

  function act_stranger(uint256 opSeed, uint128 value) external {
    uint16 pool = uint16(1 + (opSeed >> 2) % POOLS);
    uint256 op = opSeed % 4;
    bytes memory data;
    if (op == 0) data = abi.encodeCall(caps.setCap, (pool, 0, value));
    else if (op == 1) data = abi.encodeCall(caps.adjustCap, (pool, int256(uint256(value))));
    else if (op == 2) data = abi.encodeCall(caps.grantRoles, (stranger, CONSUMER_ROLE));
    else data = abi.encodeCall(caps.revokeRoles, (consumers[0], CONSUMER_ROLE));

    vm.prank(stranger);
    (bool ok, bytes memory reason) = address(caps).call(data);
    if (ok || keccak256(reason) != keccak256(abi.encodeWithSelector(Ownable.Unauthorized.selector))) {
      outcomeMismatch = true;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           MODEL                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Cap ID of 1 to 4 distinct pools in random order, contiguous from id1 or scattered.
  function layoutOf(uint256 seed) public pure returns (uint64 id) {
    uint256 count = 1 + seed % 4;
    seed >>= 2;
    uint16[5] memory pools = [uint16(1), 2, 3, 4, 5];
    for (uint256 i = 0; i < count; i++) {
      uint256 j = i + seed % (POOLS - i);
      seed /= POOLS - i;
      (pools[i], pools[j]) = (pools[j], pools[i]);
    }
    uint256 mask = (1 << count) - 1;
    if (seed % 2 == 1) {
      for (mask = (seed >> 1) % 16; LibBit.popCount(mask) != count; mask = (mask + 1) % 16) {}
    }
    uint256 k = 0;
    for (uint256 slot = 0; slot < 4; slot++) {
      if ((mask >> slot) & 1 == 1) id |= uint64(pools[k++]) << (slot * 16);
    }
  }

  /// @notice available() per the docs: the summed room of the pools divided by |multiplier|.
  function quoteOf(uint64 id, int24 multiplier) public view returns (uint256) {
    if (multiplier == 0) return type(uint256).max;
    return FixedPointMathLib.mulDiv(roomOf(id, multiplier < 0), ONE, _abs(multiplier));
  }

  /// @notice Remaining capacity of a pool: hard cap minus consumption, floored at zero.
  function ghostCap(uint16 pool) public view returns (uint128) {
    return _capOf(pool);
  }

  /// @notice Summed cap (consuming) or consumption (releasing) of the pools of a cap ID.
  function roomOf(uint64 id, bool releasing) public view returns (uint256 room) {
    for (uint256 slot = 0; slot < 4; slot++) {
      uint16 pool = uint16(id >> (slot * 16));
      if (pool != 0) room += _room(pool, releasing);
    }
  }

  /// @dev Falls back to the pool with the most room when the layout has none in that direction.
  function _consumeQuoted(uint256 layoutSeed, int24 multiplier, uint256 amountSeed) internal {
    uint64 id = layoutOf(layoutSeed);
    if (quoteOf(id, multiplier) == 0) id = _roomiestPool(multiplier < 0);
    uint256 quote = _available(id, multiplier);
    uint256 amount = quote == 0 || amountSeed % 2 == 0 ? quote : bound(amountSeed, 1, quote);
    _consume(consumers[0], id, amount, multiplier);
  }

  /// @dev A charge the pools cannot absorb reverts with the whole cap ID and moves nothing:
  ///      InsufficientCap when consuming, HardCapExceeded when releasing.
  function _consume(address caller, uint64 id, uint256 amount, int24 multiplier) internal {
    bool releasing = multiplier < 0;
    uint256 left = releasing
      ? FixedPointMathLib.mulDiv(amount, _abs(multiplier), ONE)
      : FixedPointMathLib.mulDivUp(amount, _abs(multiplier), ONE);
    uint16[4] memory pools;
    uint256[4] memory moved;
    for (uint256 slot = 0; slot < 4; slot++) {
      pools[slot] = uint16(id >> (slot * 16));
      if (pools[slot] == 0) continue;
      moved[slot] = FixedPointMathLib.min(left, _room(pools[slot], releasing));
      left -= moved[slot];
    }
    bytes memory expected;
    if (!ghostConsumer[caller]) expected = abi.encodeWithSelector(Ownable.Unauthorized.selector);
    else if (left != 0 && releasing) expected = abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, id);
    else if (left != 0) expected = abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, id);

    vm.recordLogs();
    vm.prank(caller);
    try caps.consume(id, amount, multiplier) {
      Vm.Log[] memory logs = vm.getRecordedLogs();
      if (expected.length != 0) outcomeMismatch = true;
      uint256 changed = 0;
      for (uint256 slot = 0; slot < 4; slot++) {
        if (moved[slot] == 0) continue;
        uint16 pool = pools[slot];
        ghostConsumed[pool] =
          releasing ? ghostConsumed[pool] - uint128(moved[slot]) : ghostConsumed[pool] + uint128(moved[slot]);
        bytes memory data = abi.encode(amount, multiplier, moved[slot], _capOf(pool));
        if (changed >= logs.length || !_isLog(logs[changed], IFacilityCaps.CapConsumed.selector, pool, data)) {
          eventMismatch = true;
        }
        changed++;
      }
      if (changed != logs.length) eventMismatch = true;
      if (changed != 0 && releasing) releases++;
      else if (changed != 0) consumes++;
    } catch (bytes memory reason) {
      vm.getRecordedLogs();
      if (expected.length == 0 || keccak256(reason) != keccak256(expected)) outcomeMismatch = true;
      else if (releasing && ghostConsumer[caller]) hardCapRejections++;
      for (uint256 slot = 0; slot < 4; slot++) {
        if (pools[slot] == 0) continue;
        (uint128 cap, uint128 hardCap) = caps.getCap(pools[slot]);
        if (cap != _capOf(pools[slot]) || hardCap != ghostHardCap[pools[slot]]) outcomeMismatch = true;
      }
    }
  }

  function _available(uint64 id, int24 multiplier) internal returns (uint256) {
    uint256 quote = quoteOf(id, multiplier);
    try caps.available(id, multiplier) returns (uint256 available) {
      if (available != quote) quoteMismatch = true;
    } catch {
      quoteMismatch = true;
    }
    return quote;
  }

  function _checkCapSet(uint16 pool, uint128 cap, uint128 hardCap, uint128 consumed, bytes memory expected) internal {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    if (expected.length != 0) outcomeMismatch = true;
    bytes memory data = abi.encode(cap, hardCap);
    if (logs.length != 1 || !_isLog(logs[0], FacilityAbsoluteCaps.CapSet.selector, pool, data)) eventMismatch = true;
    ghostConsumed[pool] = consumed;
    ghostHardCap[pool] = hardCap;
  }

  function _checkAdminError(bytes memory reason, bytes memory expected) internal {
    vm.getRecordedLogs();
    if (expected.length == 0 || keccak256(reason) != keccak256(expected)) outcomeMismatch = true;
  }

  function _isLog(Vm.Log memory log, bytes32 topic0, uint256 topic1, bytes memory data) internal view returns (bool) {
    return log.emitter == address(caps) && log.topics.length == 2 && log.topics[0] == topic0
      && log.topics[1] == bytes32(topic1) && keccak256(log.data) == keccak256(data);
  }

  function _roomiestPool(bool releasing) internal view returns (uint64 best) {
    uint256 bestRoom = 0;
    for (uint16 pool = 1; pool <= POOLS; pool++) {
      uint256 room = _room(pool, releasing);
      if (room > bestRoom) (best, bestRoom) = (pool, room);
    }
    if (best == 0) best = 1;
  }

  function _room(uint16 pool, bool releasing) internal view returns (uint256) {
    return releasing ? ghostConsumed[pool] : _capOf(pool);
  }

  function _capOf(uint16 pool) internal view returns (uint128) {
    return uint128(FixedPointMathLib.zeroFloorSub(ghostHardCap[pool], ghostConsumed[pool]));
  }

  function _pool(uint256 seed) internal pure returns (uint16) {
    return seed % 8 == 7 ? 0 : uint16(1 + seed % POOLS);
  }

  /// @dev A positive Q12.12 multiplier: 1x, small and fractional values, or anything up to the max.
  function _magnitude(uint256 seed) internal pure returns (int24) {
    uint256 mode = seed % 4;
    seed >>= 2;
    if (mode == 0) return 4096;
    if (mode == 1) return [int24(1), 2048, 6144, 8192][seed % 4];
    if (mode == 2) return type(int24).max;
    return int24(int256(bound(seed, 1, uint256(int256(type(int24).max)))));
  }

  function _abs(int24 multiplier) internal pure returns (uint256) {
    return multiplier < 0 ? uint256(-int256(multiplier)) : uint256(int256(multiplier));
  }
}
