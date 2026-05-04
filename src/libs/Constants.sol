// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title Constants
/// @author 3F Protocol
/// @notice Shared constants used across the request module libraries.
/// @dev This file contains compile-time constants that are inlined by the compiler for gas efficiency.
///      Constants are defined at the file level (outside of contracts) to enable direct imports
///      and avoid contract deployment overhead as well as enabling use in assembly blocks.

/// @dev Bitmask for extracting the lower 128 bits of a uint256 value.
///      Also represents the maximum value of a uint128 (type(uint128).max).
///
///      Binary representation: 128 ones followed by 128 zeros (in the context of masking)
///      Hex: 0xffffffffffffffffffffffffffffffff (32 'f' characters = 128 bits set to 1)
///
///      Usage in Lib128Fields:
///      - `value & MAX_128_BITS` extracts the lower 128 bits (ptField)
///      - Combined with `shr(128, value)` to extract the upper 128 bits (ytField)
///
///      Usage in LibAllowance:
///      - Represents infinite allowance threshold (type(uint128).max)
///      - `consume()`: Skips subtraction when allowance equals MAX_128_BITS (infinite approval)
///
/// @custom:value 2^128 - 1 = 340,282,366,920,938,463,463,374,607,431,768,211,455
uint256 constant MAX_128_BITS = 0xffffffffffffffffffffffffffffffff;

/// @dev Basis points precision (10000 = 100%).
/// @custom:value 10,000
uint256 constant BPS = 10_000;
