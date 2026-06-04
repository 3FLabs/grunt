// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibRetargetterConstants
/// @author 3F Protocol
/// @notice Compile-time constants for the Retargetter system.
/// @dev Constants are declared at file scope (outside any contract) so they inline at the call site
///      without any runtime dispatch overhead. Roles use bit-flags compatible with Solady's
///      OwnableRoles. Storage / transient slots follow ERC-7201 derivation rules.

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                           ROLES                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Role authorised to open / close batches and to propose, cancel, and execute proposals.
uint256 constant REBALANCER_ROLE = 1 << 0;

/// @dev Role authorised to consume signed offers and authorise minting on the batch's Requests.
///      Only effective once the consume timelock has elapsed for the current batch.
uint256 constant CONSUMER_ROLE = 1 << 1;

/// @dev Role authorised to pause / unpause the Retargetter.
uint256 constant PAUSER_ROLE = 1 << 2;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                          POLICY                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Maximum value accepted for `maxYieldBps` policy parameters (50% over the horizon).
///      Each per-PM yield cap is additionally capped by the Retargetter-level value at open time.
uint256 constant MAX_MAX_YIELD_BPS = 5_000;

/// @dev Maximum value accepted for the `consumeTimelock`. The consume timelock is the delay between
///      `openBatch` and the moment {consumeOffer} / {authorizeMinting} become callable.
uint40 constant MAX_CONSUME_TIMELOCK = 30 days;

/// @dev Maximum value accepted for the `proposalTimelock`. The proposal timelock is the delay
///      between `propose` and the moment {executeProposal} becomes callable.
uint40 constant MAX_PROPOSAL_TIMELOCK = 30 days;

/// @dev Maximum value accepted for the auction `horizon` (the lifetime of every Request the batch
///      deploys). Bounded by the Request's own `_MAX_REPAYMENT_DEADLINE_OFFSET` (90 days) so this
///      constant must remain at or below that bound.
uint40 constant MAX_HORIZON = 90 days;

/// @dev Minimum value accepted for the auction `horizon`. Set to one day so PT/YT holders have a
///      meaningful redemption window in the worst case.
uint40 constant MIN_HORIZON = 1 days;

/// @dev Maximum value accepted for the `mintToRepaidDelay`. The mint-to-repaid delay caps how soon
///      after the last mint/consume the Request can be marked repaid.
uint40 constant MAX_MINT_TO_REPAID_DELAY = 30 days;

/// @dev Maximum duration the Retargetter can be paused for in a single call.
uint40 constant MAX_PAUSE_DURATION = 90 days;

/// @dev Maximum number of PMs a single batch can open with. Bounds the storage / gas footprint of
///      {openBatch}, {closeBatch}, and proposal validation that iterates over batch members.
uint256 constant MAX_BATCH_SIZE = 32;

/// @dev Minimum value accepted for `tickDuration` (1 second). The tick logic divides elapsed time
///      by this value so zero is rejected to avoid division-by-zero.
uint40 constant MIN_TICK_DURATION = 1;

/// @dev Maximum value accepted for `tickDuration`. A tick wider than the horizon is meaningless;
///      the cap matches `MAX_HORIZON` so a misconfigured tick can never out-step the auction.
uint40 constant MAX_TICK_DURATION = MAX_HORIZON;

/// @dev Maximum `repaymentDeadline` offset from `block.timestamp` accepted at {openBatch} time.
///      Mirrors the Request's own `_MAX_REPAYMENT_DEADLINE_OFFSET` (90 days) so a value that
///      passes this gate also passes the Request's constructor-time validation. The deadline is
///      meant as a backstop; the Retargetter's rebalance proposal handles repayment automatically.
uint64 constant MAX_REPAYMENT_DEADLINE_OFFSET = 90 days;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       STORAGE SLOTS                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev ERC-7201 storage slot for the Retargetter main storage.
///      Derivation: `keccak256(abi.encode(uint256(keccak256("retargetter.main")) - 1)) & ~bytes32(uint256(0xff))`.
bytes32 constant RETARGETTER_STORAGE_SLOT = 0xf9f00ffd8a980ef5e7decb5057950288155f26ca104dbde71cd84b6d0559f600;

/// @dev Transient storage slot holding the module address authorised to call
///      {executeProposalCallback} for the current execution. Zero outside an execution window.
///      Derivation: `keccak256("retargetter.module.tslot")`.
bytes32 constant MODULE_CONTEXT_TSLOT = 0x2dceae3140c37b44a76d5a4a759635a312c3bdaf0f2a5eb31c50244c49f66915;
