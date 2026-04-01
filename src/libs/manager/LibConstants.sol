// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibConstants
/// @author 3F Protocol
/// @notice Shared constants used across the PositionManager contracts.
/// @dev This file contains compile-time constants that are inlined by the compiler for gas efficiency.
///      Constants are defined at the file level (outside of contracts) to enable direct imports
///      and avoid contract deployment overhead as well as enabling use in assembly blocks.

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                     SHARE CALCULATIONS                      */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Virtual assets offset for share calculation.
/// @custom:value 1
uint256 constant VIRTUAL_ASSETS = 1;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        PRECISION                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev WAD precision (1e18 = 100%).
/// @custom:value 1,000,000,000,000,000,000
uint256 constant WAD = 1e18;

/// @dev Seconds in a year for management fee calculation.
/// @custom:value 31,536,000 (365 days)
uint256 constant SECONDS_PER_YEAR = 365 days;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        FEE LIMITS                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Maximum management fee: 2% per year (200 basis points).
/// @custom:value 200
uint256 constant MAX_MANAGEMENT_FEE = 200;

/// @dev Maximum performance fee: 50% (5000 basis points).
/// @custom:value 5,000
uint256 constant MAX_PERFORMANCE_FEE = 5000;

/// @dev Maximum rebalance loss: 10% (1000 basis points).
/// @custom:value 1,000
uint256 constant MAX_REBALANCE_LOSS = 1000;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         STORAGE                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Storage slot for the PositionManager contract's main storage struct.
///      Computed as: keccak256(abi.encode(uint256(keccak256("positionmanager.main")) - 1)) & ~bytes32(uint256(0xff))
/// @custom:value 0x5214b8a11a99e3fe330cebe436fd1668609fe97b04b87c673ddbf614b1920c00
bytes32 constant STORAGE_SLOT = 0x5214b8a11a99e3fe330cebe436fd1668609fe97b04b87c673ddbf614b1920c00;
