// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibCapsMath} from "../../libs/common/LibCapsMath.sol";
import {IFacilityCaps} from "../../interfaces/facility/IFacilityCaps.sol";
import {FacilityCapsBase} from "./FacilityCapsBase.sol";

/// @title FacilityDynamicCaps
/// @author 3F Protocol
/// @notice Time-weighted deposit caps consumed by facilities with DYNAMIC deposit caps.
/// @dev The capacity of a cap is a line starting at zero on `originTime` and rising by
///      `recovery` over `recoveryTime`, then flat at `recovery`. Consuming moves `originTime`
///      forward so the line passes through the remaining capacity now: a cap of 1m per 24h
///      with 500k consumed has its origin 12h in the past. Zero and negative multipliers do
///      nothing, so the cap limits deposit throughput, not outstanding deposits.
///
///      Known limitations:
///      - `originTime` has one-second granularity and is rounded in favor of the cap, so each
///        consumption may forfeit up to one second of recovery (recovery / recoveryTime).
///      - Capacity never exceeds `recovery`; there is no separate hard cap.
///      - Withdrawals and reverted deposits do not give capacity back. Anyone holding
///        recovery / multiplier of the deposit asset can therefore keep a cap drained by
///        depositing and withdrawing every block, at gas cost only, unless the intents using
///        the cap restrict withdrawals.
contract FacilityDynamicCaps is FacilityCapsBase {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a cap is set.
  /// @param id The cap ID.
  /// @param recovery The capacity recovered over `recoveryTime`, also the maximum capacity.
  /// @param recoveryTime The seconds needed to recover from zero to `recovery`.
  /// @param originTime The timestamp at which the capacity is zero.
  event CapSet(uint64 indexed id, uint128 recovery, uint64 recoveryTime, uint64 originTime);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERRORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when setting a cap with a zero recovery time.
  error InvalidRecoveryTime();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage slot of the caps mapping.
  /// @dev Computed as: keccak256("facility.dynamic.caps.storage")
  /// @custom:value 0x1b2fb2c1736efc24f4892d78cbcce2c8f86bbcdf12f08aff6216438d7f08ab6a
  bytes32 internal constant CAPS_STORAGE_SLOT = 0x1b2fb2c1736efc24f4892d78cbcce2c8f86bbcdf12f08aff6216438d7f08ab6a;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  struct CapData {
    /// @notice Capacity recovered over `recoveryTime`, also the maximum capacity.
    uint128 recovery;
    /// @notice Seconds needed to recover from zero to `recovery` (non-zero once set).
    uint64 recoveryTime;
    /// @notice Timestamp at which the capacity is zero. Only consume() and setCap() move it.
    uint64 originTime;
  }

  struct Storage {
    /// @notice Mapping of cap IDs to their cap data.
    mapping(uint64 => CapData) caps;
  }

  function _storage() internal pure returns (Storage storage s) {
    bytes32 slot = CAPS_STORAGE_SLOT;
    assembly ("memory-safe") {
      s.slot := slot
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the raw cap parameters for an ID.
  /// @param id The cap ID.
  /// @return recovery The capacity recovered over `recoveryTime`, also the maximum capacity.
  /// @return recoveryTime The seconds needed to recover from zero to `recovery`.
  /// @return originTime The timestamp at which the capacity is zero.
  function getCap(uint64 id) external view returns (uint128 recovery, uint64 recoveryTime, uint64 originTime) {
    CapData memory data = _storage().caps[id];
    return (data.recovery, data.recoveryTime, data.originTime);
  }

  /// @notice Returns the capacity of a cap at the current timestamp.
  /// @param id The cap ID.
  /// @return The remaining capacity, between zero and `recovery`.
  function remaining(uint64 id) external view returns (uint256) {
    return _remaining(_storage().caps[id]);
  }

  /// @inheritdoc IFacilityCaps
  function available(uint64 id, int24 multiplier) external view returns (uint256 amount) {
    return LibCapsMath.depositable(_remaining(_storage().caps[id]), multiplier);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSUMER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityCaps
  /// @dev Does nothing for a zero or negative multiplier, or a zero consumption. Otherwise moves
  ///      the origin forward so the capacity now equals the previous capacity minus the
  ///      consumption, rounding the origin so the new capacity never exceeds that difference.
  ///      The origin never moves backwards, so a future origin set by the manager holds.
  function consume(uint64 id, uint256 amount, int24 multiplier) external onlyRoles(CAPS_CONSUMER_ROLE) {
    if (multiplier <= 0) return;
    uint256 consumption = LibCapsMath.consumption(amount, multiplier);
    if (consumption == 0) return;
    CapData memory data = _storage().caps[id];
    uint256 current = _remaining(data);
    if (consumption > current) revert InsufficientCap(id);
    uint256 left;
    unchecked {
      left = current - consumption;
    }
    // left <= current <= recovery, so recovery is non-zero whenever left is
    uint256 shift = left == 0 ? 0 : FixedPointMathLib.mulDiv(left, data.recoveryTime, data.recovery);
    // consumption > 0 means current > 0, so the origin is in the past and
    // shift <= elapsed time since the origin <= block.timestamp, which fits in 64 bits
    // forge-lint: disable-next-line(unsafe-typecast)
    uint64 originTime = uint64(block.timestamp - shift);
    _storage().caps[id].originTime = originTime;
    // casting to 'uint128' is safe because left <= recovery, which is a uint128
    // forge-lint: disable-next-line(unsafe-typecast)
    emit CapConsumed(id, amount, multiplier, uint128(left));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the curve of a cap.
  /// @dev Gated by the manager role. Reverts with InvalidRecoveryTime if recoveryTime is zero.
  ///      A zero recovery closes the cap, as does an unset ID. An origin in the future keeps the
  ///      cap at zero until then.
  /// @param id The cap ID.
  /// @param recovery The capacity recovered over `recoveryTime`, also the maximum capacity.
  /// @param recoveryTime The seconds needed to recover from zero to `recovery`.
  /// @param originTime The timestamp at which the capacity is zero.
  function setCap(uint64 id, uint128 recovery, uint64 recoveryTime, uint64 originTime)
    external
    onlyRoles(CAPS_MANAGER_ROLE)
  {
    if (recoveryTime == 0) revert InvalidRecoveryTime();
    _storage().caps[id] = CapData(recovery, recoveryTime, originTime);
    emit CapSet(id, recovery, recoveryTime, originTime);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Capacity of `data` at the current timestamp: zero at or before the origin, then
  ///      recovery * elapsed / recoveryTime (rounded down) until it reaches `recovery`.
  ///      An unset cap has a zero recovery time and always reads as zero capacity.
  function _remaining(CapData memory data) internal view returns (uint256) {
    if (block.timestamp <= data.originTime) return 0;
    uint256 elapsed = block.timestamp - data.originTime;
    if (elapsed >= data.recoveryTime) return data.recovery;
    return FixedPointMathLib.mulDiv(data.recovery, elapsed, data.recoveryTime);
  }
}
