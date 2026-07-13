// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibRetargetterConstants
/// @author 3F Protocol
/// @notice Shared constants used across the Retargetter contracts.
/// @dev This file contains compile-time constants that are inlined by the compiler for gas
///      efficiency. Constants are defined at the file level (outside of contracts) to enable
///      direct imports as well as use in assembly blocks.

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                           ROLES                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Role for the semi-trusted operator driving retargetting operations (Solady _ROLE_0).
/// @custom:value 1
uint256 constant REBALANCER_ROLE = 1 << 0;

/// @dev Role for the lender-facing surface, allowed to consume offers (Solady _ROLE_1).
/// @custom:value 2
uint256 constant CONSUMER_ROLE = 1 << 1;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                     CONFIGURATION BOUNDS                   */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Minimum yield annualization horizon. Matches the Request's fixed 90-day repayment
///      deadline so that, up to tick quantization, the paid yield fraction cannot reach one
///      before the latest possible repayment.
/// @custom:value 7,776,000 (90 days)
uint32 constant MIN_HORIZON = 90 days;

/// @dev Maximum yield annualization horizon (a leap year).
/// @custom:value 31,622,400 (366 days)
uint32 constant MAX_HORIZON = 366 days;

/// @dev Maximum repayment tick duration.
/// @custom:value 2,592,000 (30 days)
uint24 constant MAX_TICK_DURATION = 30 days;

/// @dev Maximum owner ceiling for per-operation yield caps: 50% (5000 basis points).
/// @custom:value 5,000
uint16 constant MAX_YIELD_CAP_BPS = 5000;

/// @dev Maximum headroom over the computed principal cap: 20% (2000 basis points).
/// @custom:value 2,000
uint16 constant MAX_PRINCIPAL_BUFFER_BPS = 2000;

/// @dev Maximum number of accounts holding a registered mint authorization at once. Bounds
///      every loop over the authorization set (pruning, revocation at the first pull of
///      funds, clearing at resolve), so a consumer handing out dust authorizations cannot
///      grow the set until those loops run out of gas and wedge settlement.
/// @custom:value 16
uint256 constant MAX_AUTHORIZED_ACCOUNTS = 16;

/// @dev Repayment deadline offset applied to every deployed Request (the maximum the
///      Request accepts). Acknowledged limitation: past the deadline the Request auto-expires
///      and bypasses the local repayment checks, so 90 days is sized as an effectively
///      infinite buffer for every supported settlement flow. If an operation ever runs into
///      it regardless, remediation is arranged offchain and delivered only through beacon
///      upgrades governed by an extensive multisig behind its own timelock; if 90 days
///      becomes too short for some assets, the Request and the Retargetter get upgraded
///      with a longer duration.
/// @custom:value 7,776,000 (90 days)
uint256 constant REPAYMENT_DEADLINE_OFFSET = 90 days;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        REBALANCING                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Sentinel amount resolved to the full balance of the corresponding asset: the
///      Retargetter's on rebalance input legs (collateral, debt, SUPPLY, REPAY) and the
///      Request's on pullRequestFunds; see IRetargetter.rebalance for the REPAY debt cap
///      and the snapshot (non-composing) resolution semantics.
/// @custom:value 2^256 - 1
uint256 constant FULL_BALANCE_SENTINEL = type(uint256).max;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      ERC-7201 STORAGE                      */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Storage slot for the init-time asset pair.
///      Computed as: keccak256(abi.encode(uint256(keccak256("retargetter.assets")) - 1)) & ~bytes32(uint256(0xff))
/// @custom:value 0x24294bb27551a4dc2129cd05f6c5dde1f436638e07bff374bea462ca137d9a00
bytes32 constant ASSETS_STORAGE_SLOT = 0x24294bb27551a4dc2129cd05f6c5dde1f436638e07bff374bea462ca137d9a00;

/// @dev Storage slot for the owner-set configuration.
///      Computed as: keccak256(abi.encode(uint256(keccak256("retargetter.config")) - 1)) & ~bytes32(uint256(0xff))
/// @custom:value 0xb4014f385661171358f3d80ac64e35e8d6eb3eefca0474f1309f39e29d9c9300
bytes32 constant CONFIG_STORAGE_SLOT = 0xb4014f385661171358f3d80ac64e35e8d6eb3eefca0474f1309f39e29d9c9300;

/// @dev Storage slot for the fund and flash-loan-module whitelists.
///      Computed as: keccak256(abi.encode(uint256(keccak256("retargetter.whitelists")) - 1)) & ~bytes32(uint256(0xff))
/// @custom:value 0x1bab5c862a4fe493dad09d437fb29b9d361c7b3998798ce3c1e7920f08750a00
bytes32 constant WHITELISTS_STORAGE_SLOT = 0x1bab5c862a4fe493dad09d437fb29b9d361c7b3998798ce3c1e7920f08750a00;

/// @dev Storage slot for the in-flight asynchronous operation.
///      Computed as: keccak256(abi.encode(uint256(keccak256("retargetter.operation")) - 1)) & ~bytes32(uint256(0xff))
/// @custom:value 0x79211724a6a2d25fad538c732b7f9fee62ff1d2c0f69a3839d917040017ef800
bytes32 constant OPERATION_STORAGE_SLOT = 0x79211724a6a2d25fad538c732b7f9fee62ff1d2c0f69a3839d917040017ef800;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                     TRANSIENT STORAGE                      */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Transient slot for the flash-loan window flag (nonzero while a window is open).
///      Computed as: bytes32(uint256(keccak256("retargetter.transient.window")) - 1)
bytes32 constant WINDOW_TSLOT = 0xd6afb5b9c2dc000141f8a98b95795a2e10b482782ed7428b0e955204ff9c2c83;

/// @dev Transient slot for the module expected to call back (zeroed on callback entry).
///      Computed as: bytes32(uint256(keccak256("retargetter.transient.module")) - 1)
bytes32 constant MODULE_TSLOT = 0x3766ddc68b0c7bb3c206ee7037a0b3dd14384ba84828df4ab6c4637a92d70353;

/// @dev Transient slot for the expected flash-loan amount.
///      Computed as: bytes32(uint256(keccak256("retargetter.transient.amount")) - 1)
bytes32 constant AMOUNT_TSLOT = 0xc37562d71acab34fa73520c0ed6a5ead38685eb8f5e228c3c887ece9e742319b;

/// @dev Transient slot for the reentrancy guard flag (nonzero while a guarded call runs).
///      Computed as: bytes32(uint256(keccak256("retargetter.transient.reentrancy")) - 1)
bytes32 constant REENTRANCY_TSLOT = 0x9085860804617f26160a86c0245a6d09a1576cd7c916d029770b32608c92fe70;
