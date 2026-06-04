// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IRetargetter} from "../../interfaces/manager/rebalancer/IRetargetter.sol";
import {RetargetterAdmin} from "./base/RetargetterAdmin.sol";
import {RetargetterBatch} from "./base/RetargetterBatch.sol";
import {RetargetterProposals} from "./base/RetargetterProposals.sol";
import {LibRetargetter, RetargetterStorage, RetargetterConfig} from "../../libs/manager/rebalancer/LibRetargetter.sol";
import {LibRetargetterErrors} from "../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {
  REBALANCER_ROLE,
  CONSUMER_ROLE,
  PAUSER_ROLE,
  MAX_CONSUME_TIMELOCK,
  MAX_PROPOSAL_TIMELOCK,
  MAX_HORIZON,
  MIN_HORIZON,
  MAX_MINT_TO_REPAID_DELAY,
  MAX_MAX_YIELD_BPS,
  MIN_TICK_DURATION,
  MAX_TICK_DURATION
} from "../../libs/manager/rebalancer/LibRetargetterConstants.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

/// @notice Initialisation parameters for the {Retargetter}.
/// @dev Empty role arrays are allowed; the owner can grant later. The static policy lives in a
///      nested {RetargetterConfig} so the initialiser copies it straight into storage in one
///      assignment rather than field-by-field.
/// @param config Static policy configuration (assets, factory, timelocks, horizon, yield gate). See
///        {RetargetterConfig}.
/// @param owner Owner with admin privileges.
/// @param rebalancers Addresses receiving REBALANCER_ROLE.
/// @param consumers Addresses receiving CONSUMER_ROLE.
/// @param pausers Addresses receiving PAUSER_ROLE.
/// @param modulesInit Flash-loan / orchestration modules whitelisted at init.
struct RetargetterInitParams {
  RetargetterConfig config;
  address owner;
  address[] rebalancers;
  address[] consumers;
  address[] pausers;
  address[] modulesInit;
}

/// @title Retargetter
/// @author 3F Protocol
/// @notice Orchestrates LTV rebalancing across a group of PositionManagers sharing a common
///         (collateral, debt) pair. Pairs a non-timelocked batch lifecycle (open Requests, consume
///         signed offers, authorise minting) with a hash-committed, timelocked proposal lifecycle
///         that executes arbitrary action sequences: PM rebalances, IFund commit/unlock cycles,
///         Request pulls / repayments, and flash-loan-driven orchestration via whitelisted modules.
/// @dev Designed for beacon-proxy deployment: the constructor disables the implementation's
///      initialiser. Storage is ERC-7201 namespaced through {LibRetargetter}.
///
///      System overview:
///        1. Owner configures policy (timelocks, horizon, yield cap, mint-to-repaid delay,
///           module whitelist) and grants roles.
///        2. REBALANCER opens a batch: declares (PM, maxPrincipal, maxYieldBps) tuples; the
///           Retargetter validates each PM's asset pair and deploys one Request per PM whose
///           `maxPrincipal > 0`. The Retargetter is owner + puller + consumer on every Request.
///        3. After `consumeTimelock` elapses, CONSUMER consumes signed offers and/or authorises
///           minting against the batch's Requests; PT/YT is minted, debt asset accrues on each
///           Request.
///        4. REBALANCER hash-commits a {Proposal} via {propose}; after `proposalTimelock` elapses,
///           {executeProposal} runs the proposal. Proposals are arbitrary ordered action sequences
///           (rebalance / pull / repay / fund / transfer / approve), optionally wrapped in a
///           flash-loan or synchronous-IFund module.
///        5. Once every Request in the batch is repaid (or untouched), REBALANCER closes the batch
///           and a new one can open.
///
///      Role layering:
///        - Owner: policy setters, role grants/revokes, pause/unpause, can cancel any in-flight
///          proposal and close the batch.
///        - REBALANCER: opens/closes batches, proposes/cancels/executes proposals.
///        - CONSUMER: consumes offers, authorises minting on batch Requests.
///        - PAUSER: held for downstream automation; pause is still owner-gated through {pause}
///          and emergency cancel paths.
contract Retargetter is IRetargetter, RetargetterAdmin, RetargetterBatch, RetargetterProposals, Initializable {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using LibChecks for address;

  constructor() {
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALISATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initialises the Retargetter behind its proxy.
  /// @dev Validates every policy parameter eagerly so a misconfigured deployment cannot reach the
  ///      operational state. Empty role arrays are allowed.
  /// @param params The init params. See {RetargetterInitParams}.
  function initialize(RetargetterInitParams calldata params) external initializer {
    params.owner.checkNotZero();

    RetargetterConfig calldata c = params.config;
    c.collateralAsset.checkContract();
    c.debtAsset.checkContract();
    c.requestFactory.checkContract();
    if (c.collateralAsset == c.debtAsset) revert LibRetargetterErrors.CollateralEqualsDebt();
    if (c.consumeTimelock > MAX_CONSUME_TIMELOCK) revert LibRetargetterErrors.TimelockTooLong();
    if (c.proposalTimelock > MAX_PROPOSAL_TIMELOCK) revert LibRetargetterErrors.TimelockTooLong();
    if (c.horizon < MIN_HORIZON || c.horizon > MAX_HORIZON) revert LibRetargetterErrors.HorizonOutOfRange();
    if (c.mintToRepaidDelay > MAX_MINT_TO_REPAID_DELAY) revert LibRetargetterErrors.MintToRepaidDelayTooLong();
    if (uint256(c.maxYieldBps) > MAX_MAX_YIELD_BPS) revert LibRetargetterErrors.MaxYieldTooHigh();
    if (c.tickDuration < MIN_TICK_DURATION || c.tickDuration > MAX_TICK_DURATION) {
      revert LibRetargetterErrors.TickDurationOutOfRange();
    }
    if (c.tickThreshold > c.tickDuration) revert LibRetargetterErrors.TickThresholdTooLong();

    _initializeOwner(params.owner);

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    // Single calldata->storage copy of the validated config, instead of writing each field (and
    // re-masking the shared packed slot) one at a time.
    s.config = c;

    _grantRolesBatch(params.rebalancers, REBALANCER_ROLE);
    _grantRolesBatch(params.consumers, CONSUMER_ROLE);
    _grantRolesBatch(params.pausers, PAUSER_ROLE);

    uint256 modulesLen = params.modulesInit.length;
    for (uint256 i; i < modulesLen; ++i) {
      address module = params.modulesInit[i];
      module.checkContract();
      if (!s.modules.add(module)) revert LibRetargetterErrors.ModuleAlreadyRegistered();
      emit ModuleAdded(module);
    }

    emit TimelocksSet(c.consumeTimelock, c.proposalTimelock);
    emit AuctionParamsSet(c.horizon, c.tickDuration, c.tickThreshold, c.mintToRepaidDelay, c.maxYieldBps);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          INTERNAL                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Grants `role` to every non-zero address in `accounts`. Skips zero entries defensively.
  /// @param accounts The addresses to grant the role to.
  /// @param role The role bit-mask to grant.
  function _grantRolesBatch(address[] calldata accounts, uint256 role) internal {
    uint256 len = accounts.length;
    for (uint256 i; i < len; ++i) {
      address account = accounts[i];
      if (account == address(0)) continue;
      _grantRoles(account, role);
    }
  }
}
