// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {LibCapsMath} from "../../libs/common/LibCapsMath.sol";
import {IFacilityCaps} from "../../interfaces/facility/IFacilityCaps.sol";

/// @title FacilityAbsoluteCaps
/// @author 3F Protocol
/// @notice Shared deposit-cap pools consumed by facilities with EXTERNAL deposit caps.
/// @dev Each pool is a remaining capacity bounded by a constant hard cap. Positive multipliers
///      consume it, negative multipliers credit it back up to the hard cap.
contract FacilityAbsoluteCaps is Initializable, OwnableRoles, IFacilityCaps {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a cap is set.
  /// @param id The cap ID.
  /// @param cap The remaining shared capacity.
  /// @param hardCap The constant upper bound for the cap.
  event CapSet(uint32 indexed id, uint128 cap, uint128 hardCap);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERRORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when setting a cap above its hard cap.
  error CapAboveHardCap();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to manage caps.
  uint256 internal constant CAPS_MANAGER_ROLE = _ROLE_0;
  /// @notice Role for addresses authorized to consume caps.
  uint256 internal constant CAPS_CONSUMER_ROLE = _ROLE_1;

  /// @notice Storage slot of the caps mapping.
  /// @dev Computed as: keccak256("facility.caps.storage")
  /// @custom:value 0xbc861527d65386e519716771f2b70a2ef7a07eed6d546966b8ced602d168b00c
  bytes32 internal constant CAPS_STORAGE_SLOT = 0xbc861527d65386e519716771f2b70a2ef7a07eed6d546966b8ced602d168b00c;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  struct CapData {
    /// @notice Remaining shared capacity (invariant: cap <= hardCap).
    uint128 cap;
    /// @notice Constant upper bound for the cap, only changed by setCap.
    uint128 hardCap;
  }

  struct Storage {
    /// @notice Mapping of cap IDs to their cap data.
    mapping(uint32 => CapData) caps;
  }

  function _storage() internal pure returns (Storage storage s) {
    bytes32 slot = CAPS_STORAGE_SLOT;
    assembly ("memory-safe") {
      s.slot := slot
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  constructor() {
    _disableInitializers();
  }

  function initialize(address _owner, address[] calldata _initialCapsManagers, address[] calldata _initialCapsConsumers)
    external
    initializer
  {
    _initializeOwner(_owner);
    _batchGrantRoles(CAPS_MANAGER_ROLE, _initialCapsManagers);
    _batchGrantRoles(CAPS_CONSUMER_ROLE, _initialCapsConsumers);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the raw cap values for an ID.
  /// @param id The cap ID.
  /// @return cap The remaining shared capacity.
  /// @return hardCap The constant upper bound for the cap.
  function getCap(uint32 id) external view returns (uint128 cap, uint128 hardCap) {
    CapData memory data = _storage().caps[id];
    return (data.cap, data.hardCap);
  }

  /// @inheritdoc IFacilityCaps
  function available(uint32 id, int24 multiplier) external view returns (uint256 amount) {
    CapData memory data = _storage().caps[id];
    if (multiplier < 0) return LibCapsMath.releasable(data.hardCap - data.cap, multiplier);
    return LibCapsMath.depositable(data.cap, multiplier);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSUMER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityCaps
  function consume(uint32 id, uint256 amount, int24 multiplier) external onlyRoles(CAPS_CONSUMER_ROLE) {
    CapData memory data = _storage().caps[id];
    uint128 newCap;
    if (multiplier >= 0) {
      uint256 consumption = LibCapsMath.consumption(amount, multiplier);
      if (consumption > data.cap) revert InsufficientCap(id);
      unchecked {
        // casting to 'uint128' is safe because consumption <= data.cap, which is a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        newCap = uint128(data.cap - consumption);
      }
    } else {
      uint256 raised = uint256(data.cap) + LibCapsMath.release(amount, multiplier);
      if (raised > data.hardCap) revert HardCapExceeded(id);
      unchecked {
        // casting to 'uint128' is safe because raised <= data.hardCap, which is a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        newCap = uint128(raised);
      }
    }
    _storage().caps[id].cap = newCap;
    emit CapConsumed(id, amount, multiplier, newCap);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the remaining capacity and its constant hard cap for an ID.
  /// @dev Gated by the manager role. Reverts with CapAboveHardCap if cap > hardCap.
  /// @param id The cap ID.
  /// @param cap The remaining shared capacity.
  /// @param hardCap The constant upper bound for the cap.
  function setCap(uint32 id, uint128 cap, uint128 hardCap) external onlyRoles(CAPS_MANAGER_ROLE) {
    if (cap > hardCap) revert CapAboveHardCap();
    _storage().caps[id] = CapData(cap, hardCap);
    emit CapSet(id, cap, hardCap);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _batchGrantRoles(uint256 role, address[] calldata accounts) internal {
    uint256 len = accounts.length;
    for (uint256 i = 0; i < len; i++) {
      _grantRoles(accounts[i], role);
    }
  }
}
