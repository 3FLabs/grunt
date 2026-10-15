// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";
import {LibCapsMath} from "../../libs/common/LibCapsMath.sol";
import {IFacilityCaps} from "../../interfaces/facility/IFacilityCaps.sol";
import {FacilityCapsBase} from "./FacilityCapsBase.sol";

/// @title FacilityAbsoluteCaps
/// @author 3F Protocol
/// @notice Shared deposit-cap pools consumed by facilities with EXTERNAL deposit caps.
/// @dev Each pool is a remaining capacity bounded by a hard cap. Positive multipliers consume
///      it, negative multipliers credit it back up to the hard cap.
///
///      A cap ID packs up to four additive 16-bit pool IDs (id1 in the low bits, 0 = empty).
///      Consumption and release both walk id1 to id4, so with [asset pool, shared pool] a
///      release refills the asset pool before the shared one. validate() requires id1 set, no
///      gap and no repeat.
///
///      Known limitations:
///      - Pools do not track consumers, so a release may refill pools another consumer drained.
///      - A credit above the headroom reverts HardCapExceeded. On a shared pool anyone can push
///        it there by crediting capacity they never consumed (a negative word, or a word listing
///        other pools first), blocking other consumers' releases until setCap or a word change.
///        Words sharing a pool should list the same pools after it.
contract FacilityAbsoluteCaps is FacilityCapsBase {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a cap is set or adjusted.
  /// @param id The cap ID.
  /// @param cap The remaining shared capacity.
  /// @param hardCap The constant upper bound for the cap.
  event CapSet(uint16 indexed id, uint128 cap, uint128 hardCap);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERRORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when setting a cap above its hard cap.
  error CapAboveHardCap();

  /// @notice Thrown when setting pool ID 0, or for a cap ID validate() rejects.
  error InvalidCapId();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage slot of the caps mapping.
  /// @dev Computed as: keccak256("facility.caps.storage")
  /// @custom:value 0xbc861527d65386e519716771f2b70a2ef7a07eed6d546966b8ced602d168b00c
  bytes32 internal constant CAPS_STORAGE_SLOT = 0xbc861527d65386e519716771f2b70a2ef7a07eed6d546966b8ced602d168b00c;

  /// @notice Bit width of a pool ID within a cap ID.
  uint256 internal constant POOL_ID_BITS = 16;
  /// @notice Number of pool IDs in a cap ID.
  uint256 internal constant POOL_COUNT = 4;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  struct CapData {
    /// @notice Remaining shared capacity (invariant: cap <= hardCap).
    uint128 cap;
    /// @notice Upper bound for the cap, only changed by setCap and adjustCap.
    uint128 hardCap;
  }

  struct Storage {
    /// @notice Mapping of pool IDs to their cap data.
    mapping(uint16 => CapData) caps;
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

  /// @notice Returns the raw cap values of a pool.
  /// @param id The pool ID.
  /// @return cap The remaining shared capacity.
  /// @return hardCap The constant upper bound for the cap.
  function getCap(uint16 id) external view returns (uint128 cap, uint128 hardCap) {
    CapData memory data = _storage().caps[id];
    return (data.cap, data.hardCap);
  }

  /// @inheritdoc IFacilityCaps
  /// @dev Quotes the summed room of the pools (see _room). Returns zero for a cap ID with no
  ///      pool ID, which consume() rejects. Assumes distinct pool IDs, as validate() enforces:
  ///      a repeated one is counted twice.
  function available(uint64 id, int24 multiplier) external view returns (uint256 amount) {
    if (id == 0) return 0;
    bool releasing = multiplier < 0;
    uint256 room = 0;
    for (uint256 slot = 0; slot < POOL_COUNT; slot++) {
      uint16 poolId = _poolId(id, slot);
      if (poolId == 0) continue;
      // four uint128 rooms cannot overflow a uint256
      unchecked {
        room += _room(_storage().caps[poolId], releasing);
      }
    }
    return LibCapsMath.quote(room, multiplier);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSUMER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityCaps
  /// @dev Spreads the charge over the pools from the first pool ID, each taking up to its room
  ///      (see _room). Emits CapConsumed for each pool it changes, with the capacity that pool
  ///      moved and its new cap. Reverts with
  ///      InsufficientCap or HardCapExceeded carrying the whole cap ID when the pools together
  ///      cannot absorb it, and with InvalidCapId if the cap ID holds no pool ID.
  function consume(uint64 id, uint256 amount, int24 multiplier) external onlyRoles(CAPS_CONSUMER_ROLE) {
    if (id == 0) revert InvalidCapId();
    bool releasing = multiplier < 0;
    uint256 left = LibCapsMath.charge(amount, multiplier);
    for (uint256 i = 0; left != 0 && i < POOL_COUNT; i++) {
      uint16 poolId = _poolId(id, i);
      if (poolId == 0) continue;
      CapData memory data = _storage().caps[poolId];
      uint256 moved = FixedPointMathLib.min(left, _room(data, releasing));
      if (moved == 0) continue;
      uint128 newCap;
      unchecked {
        // casting to 'uint128' is safe because moved <= room, which fits in 128 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        newCap = releasing ? data.cap + uint128(moved) : data.cap - uint128(moved);
        left -= moved;
      }
      _storage().caps[poolId].cap = newCap;
      emit CapConsumed(poolId, amount, multiplier, moved, newCap);
    }
    if (left == 0) return;
    if (releasing) revert HardCapExceeded(id);
    revert InsufficientCap(id);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the remaining capacity and the hard cap of a pool.
  /// @dev Gated by the manager role. Reverts with InvalidCapId for pool ID 0 and with
  ///      CapAboveHardCap if cap > hardCap. Overwrites consumption landing between reading the
  ///      pool and this call, see adjustCap for updates on a live pool.
  /// @param id The pool ID.
  /// @param cap The remaining shared capacity.
  /// @param hardCap The constant upper bound for the cap.
  function setCap(uint16 id, uint128 cap, uint128 hardCap) external onlyRoles(CAPS_MANAGER_ROLE) {
    if (id == 0) revert InvalidCapId();
    if (cap > hardCap) revert CapAboveHardCap();
    _storage().caps[id] = CapData(cap, hardCap);
    emit CapSet(id, cap, hardCap);
  }

  /// @notice Grows or shrinks a pool by `delta`, keeping its outstanding consumption.
  /// @dev Gated by the manager role. Reverts with InvalidCapId for pool ID 0. Moves the cap by
  ///      `delta` and keeps hardCap - cap, so consumption landing before this call is kept
  ///      and stays releasable. A shrink past the remaining cap stops at zero.
  /// @param id The pool ID.
  /// @param delta The signed change of the remaining capacity.
  /// @return cap The new remaining capacity.
  /// @return hardCap The new hard cap.
  function adjustCap(uint16 id, int256 delta)
    external
    onlyRoles(CAPS_MANAGER_ROLE)
    returns (uint128 cap, uint128 hardCap)
  {
    if (id == 0) revert InvalidCapId();
    CapData memory data = _storage().caps[id];
    uint256 newCap;
    if (delta < 0) {
      newCap = FixedPointMathLib.zeroFloorSub(data.cap, FixedPointMathLib.abs(delta));
    } else {
      // casting to 'uint256' is safe because delta is non-negative in this branch
      // forge-lint: disable-next-line(unsafe-typecast)
      newCap = data.cap + uint256(delta);
    }
    cap = SafeCastLib.toUint128(newCap);
    hardCap = SafeCastLib.toUint128(newCap + (data.hardCap - data.cap));
    _storage().caps[id] = CapData(cap, hardCap);
    emit CapSet(id, cap, hardCap);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts with InvalidCapId unless id1 is set, the pool IDs are contiguous from id1 and
  ///      none repeats.
  function _validateId(uint64 id) internal pure override {
    uint256 count = 0;
    for (; count < POOL_COUNT; count++) {
      uint16 poolId = _poolId(id, count);
      if (poolId == 0) break;
      for (uint256 j = 0; j < count; j++) {
        if (_poolId(id, j) == poolId) revert InvalidCapId();
      }
    }
    // a non-zero pool ID past the first empty slot is a gap
    if (count == 0 || id >> (count * POOL_ID_BITS) != 0) revert InvalidCapId();
  }

  /// @dev Pool ID in `slot` of a cap ID, slot 0 being id1.
  function _poolId(uint64 id, uint256 slot) internal pure returns (uint16) {
    // casting to 'uint16' is safe because it keeps the pool ID at `slot` on purpose
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint16(id >> (slot * POOL_ID_BITS));
  }

  /// @dev Capacity a pool can take in a direction: its cap when consuming, its headroom up to
  ///      the hard cap when releasing.
  function _room(CapData memory data, bool releasing) internal pure returns (uint256) {
    return releasing ? data.hardCap - data.cap : data.cap;
  }
}
