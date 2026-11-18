// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test, Vm} from "forge-std/Test.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";

/// @title CapsInvHandlerDynamic
/// @notice Handler for FacilityDynamicCapsInvariantTest. Mirrors each curve from the documented
///         rules, tracks the consumption since the last setCap and flags any call whose outcome,
///         events or origin move differ.
contract CapsInvHandlerDynamic is Test {
  uint256 internal constant ONE = 1 << 12;
  uint256 internal constant TYPICAL = 1e30;

  struct Curve {
    uint128 recovery;
    uint64 recoveryTime;
    uint64 originTime;
  }

  FacilityDynamicCaps public immutable caps;
  address public immutable manager;
  address public immutable consumer;
  uint64[4] public ids;

  mapping(uint64 => Curve) internal _ghost;
  /// @dev recovery * min(max(now - origin, 0), recoveryTime) at the last setCap.
  mapping(uint64 => uint256) public startCredit;
  mapping(uint64 => uint256) public setTime;
  mapping(uint64 => uint256) public consumed;

  bool public outcomeMismatch;
  bool public eventMismatch;
  bool public quoteMismatch;
  bool public originMovedBack;
  bool public noopChangedState;
  bool public roundingOutOfBounds;

  uint256 public consumeCalls;
  uint256 public consumes;

  constructor(FacilityDynamicCaps _caps, address _manager, address _consumer, uint64[4] memory _ids) {
    caps = _caps;
    manager = _manager;
    consumer = _consumer;
    ids = _ids;
    for (uint256 i = 0; i < _ids.length; i++) {
      _record(_ids[i], _read(_ids[i]));
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ACTIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function act_warp(uint256 seed) external {
    vm.warp(vm.getBlockTimestamp() + (seed % 4 == 0 ? bound(seed, 1 days, 400 days) : bound(seed, 1, 6 hours)));
  }

  /// @dev Consumes an amount the quote covers on the first ID from the seeded one with capacity.
  function act_consume(uint256 idSeed, uint256 multiplierSeed, uint256 amountSeed) external {
    consumeCalls++;
    idSeed %= ids.length;
    uint64 id = ids[idSeed];
    for (uint256 i = 1; i < ids.length && remainingOf(id) == 0; i++) {
      id = ids[(idSeed + i) % ids.length];
    }
    int24 multiplier = _magnitude(multiplierSeed);
    uint256 quote = _available(id, multiplier);
    uint256 amount = quote == 0 || amountSeed % 2 == 0 ? quote : bound(amountSeed, 1, quote);
    _consume(id, amount, multiplier);
  }

  function act_consumeAny(uint256 idSeed, uint256 multiplierSeed, uint256 amountSeed) external {
    uint64 id = ids[idSeed % ids.length];
    uint256 sign = multiplierSeed % 8;
    int24 multiplier = sign == 0 ? int24(0) : _magnitude(multiplierSeed >> 3);
    if (sign > 5) multiplier = -multiplier;
    uint256 quote = _available(id, multiplier);
    uint256 mode = amountSeed % 4;
    uint256 amount;
    if (mode == 3) amount = bound(amountSeed, 0, 2 * uint256(_ghost[id].recovery) + 1);
    else if (mode == 2 && quote < type(uint256).max) amount = quote + 1;
    else amount = quote;
    _consume(id, amount, multiplier);
  }

  function act_setCap(uint256 idSeed, uint256 recoverySeed, uint256 timeSeed, uint256 originSeed) external {
    uint64 id = ids[idSeed % ids.length];
    uint128 recovery =
      recoverySeed % 8 == 0 ? 0 : uint128(bound(recoverySeed, 1, recoverySeed % 8 == 1 ? type(uint128).max : TYPICAL));
    uint64 recoveryTime =
      timeSeed % 8 == 0 ? 0 : uint64(bound(timeSeed, 1, timeSeed % 8 == 1 ? type(uint64).max : 30 days));
    uint256 mode = originSeed % 3;
    uint64 originTime = uint64(
      mode == 0
        ? bound(originSeed, 0, vm.getBlockTimestamp())
        : mode == 1 ? vm.getBlockTimestamp() : vm.getBlockTimestamp() + bound(originSeed, 1, 30 days)
    );

    vm.recordLogs();
    vm.prank(manager);
    try caps.setCap(id, recovery, recoveryTime, originTime) {
      Vm.Log[] memory logs = vm.getRecordedLogs();
      if (recoveryTime == 0) outcomeMismatch = true;
      bytes memory data = abi.encode(recovery, recoveryTime, originTime);
      if (logs.length != 1 || !_isLog(logs[0], FacilityDynamicCaps.CapSet.selector, id)) eventMismatch = true;
      else if (keccak256(logs[0].data) != keccak256(data)) eventMismatch = true;
      _record(id, Curve(recovery, recoveryTime, originTime));
    } catch (bytes memory reason) {
      vm.getRecordedLogs();
      bytes memory expected = abi.encodeWithSelector(FacilityDynamicCaps.InvalidRecoveryTime.selector);
      if (recoveryTime != 0 || keccak256(reason) != keccak256(expected)) outcomeMismatch = true;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           MODEL                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function ghost(uint64 id) external view returns (Curve memory) {
    return _ghost[id];
  }

  /// @notice The documented curve: zero up to the origin, then recovery * elapsed / recoveryTime
  ///         rounded down, flat at recovery.
  function remainingOf(uint64 id) public view returns (uint256) {
    Curve memory curve = _ghost[id];
    if (vm.getBlockTimestamp() <= curve.originTime) return 0;
    uint256 elapsed = vm.getBlockTimestamp() - curve.originTime;
    if (elapsed >= curve.recoveryTime) return curve.recovery;
    return FixedPointMathLib.mulDiv(curve.recovery, elapsed, curve.recoveryTime);
  }

  function quoteOf(uint64 id, int24 multiplier) public view returns (uint256) {
    if (multiplier <= 0) return type(uint256).max;
    return FixedPointMathLib.mulDiv(remainingOf(id), ONE, uint256(int256(multiplier)));
  }

  /// @dev CapConsumed reports the capacity left at the rounded origin and moved = current - newCap.
  function _consume(uint64 id, uint256 amount, int24 multiplier) internal {
    uint256 consumption = multiplier <= 0 ? 0 : FixedPointMathLib.mulDivUp(amount, uint256(int256(multiplier)), ONE);
    uint256 current = remainingOf(id);
    bool rejected = consumption > current;
    Curve memory before = _read(id);

    vm.recordLogs();
    vm.prank(consumer);
    try caps.consume(id, amount, multiplier) {
      Vm.Log[] memory logs = vm.getRecordedLogs();
      Curve memory after_ = _read(id);
      if (rejected) {
        outcomeMismatch = true;
        return;
      }
      if (after_.originTime < before.originTime) originMovedBack = true;
      if (consumption == 0) {
        if (logs.length != 0 || keccak256(abi.encode(after_)) != keccak256(abi.encode(before))) {
          noopChangedState = true;
        }
        return;
      }
      uint256 left = current - consumption;
      _checkRounding(id, left);
      uint256 newCap = _moveOrigin(id, left);
      bytes memory data = abi.encode(amount, multiplier, current - newCap, uint128(newCap));
      if (logs.length != 1 || !_isLog(logs[0], IFacilityCaps.CapConsumed.selector, id)) eventMismatch = true;
      else if (keccak256(logs[0].data) != keccak256(data) || caps.remaining(id) != newCap) eventMismatch = true;
      consumed[id] += consumption;
      consumes++;
    } catch (bytes memory reason) {
      vm.getRecordedLogs();
      bytes memory expected = abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, id);
      if (!rejected || keccak256(reason) != keccak256(expected)) outcomeMismatch = true;
      if (keccak256(abi.encode(_read(id))) != keccak256(abi.encode(before))) outcomeMismatch = true;
    }
  }

  /// @dev Moves the mirrored origin to now - floor(left * recoveryTime / recovery) and returns
  ///      the capacity left there, floor(recovery * shift / recoveryTime).
  function _moveOrigin(uint64 id, uint256 left) internal returns (uint256) {
    Curve storage curve = _ghost[id];
    uint256 shift = left == 0 ? 0 : FixedPointMathLib.mulDiv(left, curve.recoveryTime, curve.recovery);
    curve.originTime = uint64(vm.getBlockTimestamp() - shift);
    return FixedPointMathLib.mulDiv(curve.recovery, shift, curve.recoveryTime);
  }

  /// @dev The rounded origin leaves at most `left` now and at least `left` one second later.
  function _checkRounding(uint64 id, uint256 left) internal {
    uint256 time = vm.getBlockTimestamp();
    uint256 rounded = caps.remaining(id);
    vm.warp(time + 1);
    uint256 next = caps.remaining(id);
    vm.warp(time);
    if (rounded > left || next < left) roundingOutOfBounds = true;
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

  function _record(uint64 id, Curve memory curve) internal {
    _ghost[id] = curve;
    setTime[id] = vm.getBlockTimestamp();
    uint256 elapsed = vm.getBlockTimestamp() > curve.originTime ? vm.getBlockTimestamp() - curve.originTime : 0;
    startCredit[id] = uint256(curve.recovery) * FixedPointMathLib.min(elapsed, curve.recoveryTime);
    consumed[id] = 0;
  }

  function _read(uint64 id) internal view returns (Curve memory curve) {
    (curve.recovery, curve.recoveryTime, curve.originTime) = caps.getCap(id);
  }

  function _isLog(Vm.Log memory log, bytes32 topic0, uint64 id) internal view returns (bool) {
    return log.emitter == address(caps) && log.topics.length == 2 && log.topics[0] == topic0
      && log.topics[1] == bytes32(uint256(id));
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
}
