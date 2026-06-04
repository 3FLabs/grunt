// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {
  IRetargetterBatch,
  BatchEntryInput,
  BatchEntryView
} from "../../../interfaces/manager/rebalancer/IRetargetterBatch.sol";
import {IPositionManager} from "../../../interfaces/manager/IPositionManager.sol";
import {IRequest} from "../../../interfaces/request/IRequest.sol";
import {IRequestFactory} from "../../../interfaces/request/IRequestFactory.sol";
import {IFund} from "../../../interfaces/funds/IFund.sol";
import {Offer} from "../../../interfaces/request/IOfferReceiver.sol";
import {RetargetterBase} from "./RetargetterBase.sol";
import {
  LibRetargetter,
  RetargetterStorage,
  BatchState,
  BatchEntry
} from "../../../libs/manager/rebalancer/LibRetargetter.sol";
import {LibRetargetterErrors} from "../../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {
  REBALANCER_ROLE,
  CONSUMER_ROLE,
  MAX_BATCH_SIZE,
  MAX_REPAYMENT_DEADLINE_OFFSET
} from "../../../libs/manager/rebalancer/LibRetargetterConstants.sol";
import {LibChecks} from "../../../libs/common/LibChecks.sol";
import {BPS} from "../../../libs/Constants.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";

/// @title RetargetterBatch
/// @author 3F Protocol
/// @notice Batch open / close + auction surface (consume + authorise-minting).
/// @dev See {IRetargetterBatch}. The Retargetter takes `owner`, `puller`, and `consumer` roles on
///      every Request the batch deploys, so it (a) controls who can mint, (b) drains funds during
///      proposal execution, and (c) marks each Request repaid once the rebalance settles.
abstract contract RetargetterBatch is IRetargetterBatch, RetargetterBase {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           OPEN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterBatch
  function openBatch(
    BatchEntryInput[] calldata entries,
    uint64 repaymentDeadline,
    address fund,
    string calldata requestName,
    string calldata requestSymbol
  ) external override onlyRoles(REBALANCER_ROLE) whenNotPaused {
    if (entries.length == 0 || entries.length > MAX_BATCH_SIZE) {
      revert LibRetargetterErrors.InvalidBatchSize();
    }

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (s.batch.active) revert LibRetargetterErrors.BatchAlreadyOpen();

    // Validate batch-level params, write the batch scalars + optional fund, and emit BatchOpened.
    // Extracted so its locals (timestamps, fund-check temporaries) don't co-exist with the
    // per-entry loop's stack: with two extra calldata strings flowing into the loop, keeping
    // everything in one frame overflows Solidity's 16-slot stack budget without via-IR.
    _openBatchHeader(s, repaymentDeadline, fund, entries.length);

    // The per-entry path reads the now-written `repaymentDeadline` off `s.batch` (see
    // {_deployRequest}), keeping it out of the loop's argument list so the stack stays shallow.
    for (uint256 i; i < entries.length; ++i) {
      _openBatchEntry(s, entries[i], requestName, requestSymbol);
    }
  }

  /// @dev Validates the batch-level parameters, writes the batch scalars and optional fund binding,
  ///      and emits {BatchOpened}. See {openBatch} for why this is a separate frame.
  /// @param s The Retargetter storage pointer.
  /// @param repaymentDeadline Absolute Unix timestamp handed to every Request the batch deploys.
  /// @param fund Optional IFund to attach to the batch (`address(0)` for none).
  /// @param entryCount The number of PMs in the batch (for the {BatchOpened} event).
  function _openBatchHeader(RetargetterStorage storage s, uint64 repaymentDeadline, address fund, uint256 entryCount)
    private
  {
    // Safe: block.timestamp fits in uint40 for ~35,000 years; consumeTimelock is bounded by
    // MAX_CONSUME_TIMELOCK.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint40 nowU40 = uint40(block.timestamp);
    uint40 consumeAvailableAt_ = nowU40 + s.config.consumeTimelock;

    // Deadline gate: the proposer picks the absolute deadline directly. The lower bound is
    // strictly after `consumeAvailableAt` so a consume window actually opens; the upper bound
    // matches the Request's own 90-day cap so the Request's constructor-time validation also
    // passes downstream. Repayment is meant to happen through the rebalance proposal path; the
    // deadline is the auto-expire backstop and should sit comfortably far in the future.
    if (repaymentDeadline <= uint64(consumeAvailableAt_)) revert LibRetargetterErrors.RepaymentDeadlineOutOfRange();
    if (repaymentDeadline > uint64(block.timestamp) + MAX_REPAYMENT_DEADLINE_OFFSET) {
      revert LibRetargetterErrors.RepaymentDeadlineOutOfRange();
    }

    s.batch.active = true;
    s.batch.openedAt = nowU40;
    s.batch.consumeAvailableAt = consumeAvailableAt_;
    s.batch.repaymentDeadline = repaymentDeadline;

    // Optional fund: bound once at open time so FUND_* proposal actions cannot target an
    // arbitrary address later. Orientation mirrors the Facility: the fund's `asset` is the debt
    // asset (what we deposit / receive on redemption) and its `share` is the collateral asset
    // (what we receive on deposit / redeem). A fresh batch always starts with no live order.
    if (fund != address(0)) {
      fund.checkContract();
      if (IFund(fund).asset() != s.config.debtAsset || IFund(fund).share() != s.config.collateralAsset) {
        revert LibRetargetterErrors.FundAssetMismatch();
      }
      s.batch.fund = fund;
    }

    emit BatchOpened(nowU40, consumeAvailableAt_, repaymentDeadline, fund, entryCount);
  }

  /// @dev Extracted from {openBatch} to keep the loop body legible. Reads its config off `s`
  ///      directly because passing every parameter through the call would blow the 16-slot stack.
  ///      `requestName` / `requestSymbol` are the caller-supplied PT/YT token metadata for the
  ///      Request this entry deploys.
  function _openBatchEntry(
    RetargetterStorage storage s,
    BatchEntryInput calldata input,
    string calldata requestName,
    string calldata requestSymbol
  ) private {
    input.positionManager.checkContract();
    if (!s.batch.positionManagers.add(input.positionManager)) revert LibRetargetterErrors.InvalidBatchSize();

    (address pmCollateral, address pmDebt) = IPositionManager(input.positionManager).assets();
    if (pmCollateral != s.config.collateralAsset || pmDebt != s.config.debtAsset) {
      revert LibRetargetterErrors.PositionManagerAssetMismatch();
    }

    address request = address(0);
    if (input.maxPrincipal > 0) {
      if (input.maxYieldBps > s.config.maxYieldBps) revert LibRetargetterErrors.PerPMYieldExceedsCap();
      request = _deployRequest(s, requestName, requestSymbol);
      s.batch.requests.add(request);
    }

    BatchEntry storage entry = s.batch.entries[input.positionManager];
    entry.request = request;
    entry.maxPrincipal = input.maxPrincipal;
    entry.maxYieldBps = input.maxYieldBps;
    entry.consumed = 0;

    emit BatchEntryRegistered(input.positionManager, request, input.maxPrincipal, input.maxYieldBps);
  }

  /// @dev Deploys one auction Request through the factory with the Retargetter as owner / puller /
  ///      consumer. Split out of {_openBatchEntry} so the eight-argument factory call sits in its
  ///      own shallow frame. Reads `repaymentDeadline` off `s.batch` (written by {_openBatchHeader}
  ///      before the entry loop runs) so it need not be threaded through the loop's argument list.
  ///      Takes the name / symbol as `memory` (one stack slot each, like the former constants):
  ///      `calldata` strings cost two slots apiece and tip the encode over the stack limit.
  function _deployRequest(RetargetterStorage storage s, string memory requestName, string memory requestSymbol)
    private
    returns (address request)
  {
    (request,,) = IRequestFactory(s.config.requestFactory)
      .createRequest(
        address(this),
        address(this),
        address(this),
        s.config.debtAsset,
        requestName,
        requestSymbol,
        s.batch.repaymentDeadline,
        s.config.mintToRepaidDelay
      );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CLOSE                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterBatch
  /// @dev Owner or REBALANCER can close. Allowed while paused. Two gates, both mirroring the
  ///      Facility's conditions for resolving an intent / abandoning a fund:
  ///        - Each Request blocks close while it has a non-zero `consumed` counter (PT issued) and
  ///          is not yet repaid. `syncRepaidStatus()` is called first so a Request whose deadline
  ///          has passed auto-resolves instead of wedging the close.
  ///        - The attached fund (if any) blocks close while it has a live order. An order the fund
  ///          has independently ended is reconciled via {LibRetargetter.syncFundOrder} and does
  ///          not block; an order still in flight reverts with {FundOrderPending}.
  function closeBatch() external override {
    if (msg.sender != owner() && !hasAnyRole(msg.sender, REBALANCER_ROLE)) _checkOwner();

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (!s.batch.active) revert LibRetargetterErrors.NoActiveBatch();

    // Fund gate: reconcile a force-ended order, then require nothing in flight.
    if (s.batch.fund != address(0)) {
      LibRetargetter.syncFundOrder(s);
      if (LibRetargetter.hasFundOrder(s)) revert LibRetargetterErrors.FundOrderPending();
    }

    address[] memory pms = s.batch.positionManagers.values();
    uint256 len = pms.length;
    for (uint256 i; i < len; ++i) {
      address pm = pms[i];
      BatchEntry storage entry = s.batch.entries[pm];
      address request = entry.request;
      if (request != address(0) && entry.consumed != 0 && !IRequest(request).syncRepaidStatus()) {
        revert LibRetargetterErrors.BatchNotFullyRepaid();
      }
      delete s.batch.entries[pm];
      s.batch.positionManagers.remove(pm);
      if (request != address(0)) s.batch.requests.remove(request);
    }

    s.batch.active = false;
    s.batch.openedAt = 0;
    s.batch.consumeAvailableAt = 0;
    s.batch.repaymentDeadline = 0;
    s.batch.fund = address(0);
    delete s.batch.order;

    emit BatchClosed();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSUME OFFER                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterBatch
  function consumeOffer(address positionManager, Offer calldata offer, bytes calldata signature, uint256 ptAmount)
    external
    override
    onlyOwnerOrRoles(CONSUMER_ROLE)
    whenNotPaused
    nonReentrant
    returns (uint256 ytAmount)
  {
    if (ptAmount == 0) revert LibRetargetterErrors.InvalidPtAmount();

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (block.timestamp < s.batch.consumeAvailableAt) revert LibRetargetterErrors.ConsumeTimelockNotElapsed();
    if (!s.batch.positionManagers.contains(positionManager)) revert LibRetargetterErrors.PMNotInBatch();

    BatchEntry storage entry = s.batch.entries[positionManager];
    address request = entry.request;
    if (request == address(0)) revert LibRetargetterErrors.PMHasNoRequest();

    // Yield cap, tick-rounded: the maker's yield-per-principal-over-horizon must not exceed the
    // current cap, which ramps with the tick-rounded "paid duration" of the batch.
    //
    //   expectedReturn / amount  <=  (maxYieldBps / BPS) * (paidDuration / horizon)
    //
    // Cross-multiplied to avoid division and keep the comparison exact. `paidDuration` is the
    // tick-rounded elapsed time since {openBatch}; see {LibRetargetter.paidDuration} for the
    // formula and worked examples.
    uint256 paidDuration_ = LibRetargetter.paidDuration(block.timestamp - uint256(s.batch.openedAt));
    if (
      offer.expectedReturn * BPS * uint256(s.config.horizon) > offer.amount * uint256(entry.maxYieldBps) * paidDuration_
    ) {
      revert LibRetargetterErrors.YieldTooHigh();
    }

    uint256 newConsumed = uint256(entry.consumed) + ptAmount;
    if (newConsumed > uint256(entry.maxPrincipal)) revert LibRetargetterErrors.PrincipalCapExceeded();
    // Effects: bump consumed before the external call. Safe to cast back to uint128 because
    // `newConsumed <= maxPrincipal <= type(uint96).max`.
    // forge-lint: disable-next-line(unsafe-typecast)
    entry.consumed = uint128(newConsumed);

    // Interactions: forward to the bound Request. The Request validates the EIP-712 signature,
    // pulls `ptAmount` debt asset from the maker, and mints PT/YT.
    ytAmount = IRequest(request).consume(offer, signature, ptAmount);

    emit OfferConsumed(positionManager, request, offer.maker, ptAmount, ytAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     AUTHORIZE MINTING                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterBatch
  function authorizeMinting(address positionManager, address to, uint128 ptAmount, uint128 ytAmount)
    external
    override
    onlyOwnerOrRoles(CONSUMER_ROLE)
    whenNotPaused
    nonReentrant
  {
    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (block.timestamp < s.batch.consumeAvailableAt) revert LibRetargetterErrors.ConsumeTimelockNotElapsed();
    if (!s.batch.positionManagers.contains(positionManager)) revert LibRetargetterErrors.PMNotInBatch();

    BatchEntry storage entry = s.batch.entries[positionManager];
    address request = entry.request;
    if (request == address(0)) revert LibRetargetterErrors.PMHasNoRequest();

    // Yield cap on the *new* state, tick-rounded against the current batch progress. The yield
    // ratio is `ytAmount / ptAmount` over the horizon; the cap is
    // `maxYieldBps * paidDuration / (BPS * horizon)`. ptAmount == 0 with ytAmount > 0 implies
    // infinite yield (reject); ptAmount == 0 with ytAmount == 0 is a pure revocation (allow).
    if (ptAmount == 0) {
      if (ytAmount != 0) revert LibRetargetterErrors.YieldTooHigh();
    } else {
      uint256 paidDuration_ = LibRetargetter.paidDuration(block.timestamp - uint256(s.batch.openedAt));
      if (
        uint256(ytAmount) * BPS * uint256(s.config.horizon)
          > uint256(ptAmount) * uint256(entry.maxYieldBps) * paidDuration_
      ) {
        revert LibRetargetterErrors.YieldTooHigh();
      }
    }

    // Cap-tracking: the Request stores ALL authorisations replace-style (the latest call
    // overwrites the previous). To keep `consumed` consistent with "max PT that could ever be
    // minted via this batch", we mirror the delta between the current authorisation and the
    // requested one. Once a maker mints, their stored auth is reset to zero, so subsequent calls
    // count as fresh authorisations on top of what was already minted.
    (uint128 currentPt,) = IRequest(request).mintAuthorization(to);
    if (ptAmount > currentPt) {
      uint128 delta = ptAmount - currentPt;
      uint256 newConsumed = uint256(entry.consumed) + uint256(delta);
      if (newConsumed > uint256(entry.maxPrincipal)) revert LibRetargetterErrors.PrincipalCapExceeded();
      // forge-lint: disable-next-line(unsafe-typecast)
      entry.consumed = uint128(newConsumed);
    } else if (ptAmount < currentPt) {
      // Safe: (currentPt - ptAmount) <= currentPt <= entry.consumed by induction.
      entry.consumed -= (currentPt - ptAmount);
    }

    IRequest(request).authorizeMinting(to, ptAmount, ytAmount);

    emit MintingAuthorised(positionManager, request, to, ptAmount, ytAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            VIEWS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterBatch
  function batchInfo()
    external
    view
    override
    returns (
      bool active,
      uint40 openedAt,
      uint40 consumeAvailableAt,
      uint64 repaymentDeadline,
      address fund,
      bool hasFundOrder
    )
  {
    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    BatchState storage b = s.batch;
    return (b.active, b.openedAt, b.consumeAvailableAt, b.repaymentDeadline, b.fund, LibRetargetter.hasFundOrder(s));
  }

  /// @inheritdoc IRetargetterBatch
  function batchPositionManagers() external view override returns (address[] memory) {
    return LibRetargetter.retargetterStorage().batch.positionManagers.values();
  }

  /// @inheritdoc IRetargetterBatch
  function batchRequests() external view override returns (address[] memory) {
    return LibRetargetter.retargetterStorage().batch.requests.values();
  }

  /// @inheritdoc IRetargetterBatch
  function isBatchPositionManager(address positionManager) external view override returns (bool) {
    return LibRetargetter.retargetterStorage().batch.positionManagers.contains(positionManager);
  }

  /// @inheritdoc IRetargetterBatch
  function isBatchRequest(address request) external view override returns (bool) {
    return LibRetargetter.retargetterStorage().batch.requests.contains(request);
  }

  /// @inheritdoc IRetargetterBatch
  function batchEntry(address positionManager) external view override returns (BatchEntryView memory) {
    BatchEntry storage entry = LibRetargetter.retargetterStorage().batch.entries[positionManager];
    return BatchEntryView({
      positionManager: positionManager,
      request: entry.request,
      maxPrincipal: entry.maxPrincipal,
      maxYieldBps: entry.maxYieldBps,
      consumed: entry.consumed
    });
  }
}
