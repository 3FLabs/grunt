// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibConstants
/// @author 3F Protocol
/// @notice Shared constants used across the Facility contracts.
/// @dev This file contains compile-time constants that are inlined by the compiler for gas efficiency.
///      Constants are defined at the file level (outside of contracts) to enable direct imports
///      and avoid contract deployment overhead as well as enabling use in assembly blocks.

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         STORAGE                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Storage slot for the Facility contract's main storage struct.
///      Computed as: keccak256(abi.encode(uint256(keccak256("facility")) - 1)) & ~bytes32(uint256(0xff))
///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
/// @custom:value 0x17225e1ce54a2d38eb42db16fff6bda9e819f9fc11384a092e92905d7c79a900
bytes32 constant STORAGE_SLOT = 0x17225e1ce54a2d38eb42db16fff6bda9e819f9fc11384a092e92905d7c79a900;
