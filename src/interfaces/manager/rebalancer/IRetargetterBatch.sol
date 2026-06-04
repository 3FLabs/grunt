// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Offer} from "../../request/IOfferReceiver.sol";

/// @notice Input descriptor passed to {openBatch}. One entry per PositionManager.
/// @dev Entries with `maxPrincipal == 0` are honoured as "no auction" pin-points: the PM is part
///      of the batch (so proposals may target it) but no Request is deployed and no offers can be
///      consumed against it. Entries with `maxPrincipal > 0` get a freshly deployed Request whose
///      asset is the Retargetter's `debtAsset`.
/// @param positionManager The PM to include in the batch. Must declare the Retargetter's
///        configured (collateral, debt) pair.
/// @param maxPrincipal Maximum PT (= debt asset) that can be issued for this PM via the deployed
///        Request. Zero means no Request is deployed.
/// @param maxYieldBps Per-PM yield cap (basis points, absolute over the horizon). Bounded at open
///        time by the Retargetter's global cap. Ignored when `maxPrincipal == 0`.
struct BatchEntryInput {
  address positionManager;
  uint96 maxPrincipal;
  uint16 maxYieldBps;
}

/// @notice External view of a batch entry.
/// @param positionManager The PM in the batch.
/// @param request The deployed Request (zero when `maxPrincipal == 0`).
/// @param maxPrincipal The cap configured at open time.
/// @param maxYieldBps The per-PM yield cap (basis points).
/// @param consumed The cumulative PT issued (via consume + authorize).
struct BatchEntryView {
  address positionManager;
  address request;
  uint96 maxPrincipal;
  uint16 maxYieldBps;
  uint128 consumed;
}

/// @title IRetargetterBatch
/// @author 3F Protocol
/// @notice Batch open / close + auction surface (consume + authorize-minting + pull-funds).
/// @dev The batch is the unit of "we're rebalancing this group of PMs together". One batch can be
///      open at a time. The Retargetter holds the owner, puller, and consumer roles on every
///      Request the batch deploys, so it (a) decides who can mint, (b) drains funds at proposal
///      execute time, and (c) marks each Request repaid once the rebalance settles.
interface IRetargetterBatch {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new batch is opened.
  /// @param batchOpenedAt The opening timestamp.
  /// @param consumeAvailableAt The earliest timestamp at which auctions can be consumed.
  /// @param repaymentDeadline The Unix timestamp at which the batch's Requests auto-expire if not
  ///        marked repaid by then; chosen by the proposer.
  /// @param fund The optional IFund attached to the batch (zero if none).
  /// @param entryCount The number of PMs in the batch.
  event BatchOpened(
    uint40 batchOpenedAt, uint40 consumeAvailableAt, uint64 repaymentDeadline, address indexed fund, uint256 entryCount
  );

  /// @notice Emitted once per PM in the batch when it is opened.
  /// @param positionManager The PM being added.
  /// @param request The deployed Request (zero when `maxPrincipal == 0`).
  /// @param maxPrincipal The cap configured for this PM.
  /// @param maxYieldBps The per-PM yield cap (basis points).
  event BatchEntryRegistered(
    address indexed positionManager, address indexed request, uint96 maxPrincipal, uint16 maxYieldBps
  );

  /// @notice Emitted when a batch is closed.
  event BatchClosed();

  /// @notice Emitted when a signed offer is consumed against a batch Request.
  /// @param positionManager The PM whose Request was consumed.
  /// @param request The Request consumed.
  /// @param maker The offer maker.
  /// @param ptAmount The PT amount minted.
  /// @param ytAmount The YT amount minted.
  event OfferConsumed(
    address indexed positionManager, address indexed request, address indexed maker, uint256 ptAmount, uint256 ytAmount
  );

  /// @notice Emitted when minting is authorised on a batch Request.
  /// @param positionManager The PM whose Request granted authorisation.
  /// @param request The Request.
  /// @param to The address granted mint authorisation.
  /// @param ptAmount The PT amount authorised.
  /// @param ytAmount The YT amount authorised.
  event MintingAuthorised(
    address indexed positionManager, address indexed request, address indexed to, uint128 ptAmount, uint128 ytAmount
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           BATCH                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Opens a new batch.
  /// @dev REBALANCER-only. No timelock (the operation is non-destructive: it just sets up state and
  ///      deploys Request contracts). Reverts if a batch is already open. For every entry with
  ///      `maxPrincipal > 0`, deploys a fresh Request through the configured factory with the
  ///      Retargetter as `owner`, `puller`, and `consumer`. The Request's `repaymentDeadline` is
  ///      the proposer-supplied `repaymentDeadline` argument; the auction lifecycle is meant to
  ///      end via the rebalance proposal's automatic repayment path, so the deadline is a backstop
  ///      that should sit comfortably far in the future.
  /// @param entries The PMs to include. See {BatchEntryInput}.
  /// @param repaymentDeadline Absolute Unix timestamp handed to every Request the batch deploys.
  ///        Must satisfy `block.timestamp + consumeTimelock < repaymentDeadline
  ///        <= block.timestamp + MAX_REPAYMENT_DEADLINE_OFFSET` (90 days).
  /// @param fund Optional IFund to attach to the batch (pass `address(0)` for none). When set it
  ///        must expose `asset() == debtAsset` and `share() == collateralAsset`. FUND_* proposal
  ///        actions operate exclusively on this fund, and {closeBatch} requires its order (if any)
  ///        to have reached {State.ENDED} before the batch can close.
  /// @param requestName Token name handed to every Request the batch deploys; the Request prefixes
  ///        its PT / YT tokens with "PT-" / "YT-". Off-chain consumers correlate by the
  ///        `RequestCreated` event emitted by the factory.
  /// @param requestSymbol Token symbol handed to every Request the batch deploys.
  function openBatch(
    BatchEntryInput[] calldata entries,
    uint64 repaymentDeadline,
    address fund,
    string calldata requestName,
    string calldata requestSymbol
  ) external;

  /// @notice Closes the current batch.
  /// @dev REBALANCER (or owner) only, callable at any time including while paused. Reverts unless
  ///      every batch Request has either been marked repaid or has zero consumed PT (no auction
  ///      activity), and unless the attached fund (if any) has no live order. A fund order that
  ///      the fund has independently ended ({State.ENDED}) is reconciled and does not block the
  ///      close; an order still in flight does. Clears all batch state so a new batch can open.
  function closeBatch() external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          AUCTION                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Consumes a signed offer against the Request bound to `positionManager`.
  /// @dev CONSUMER-only. Reverts before `consumeAvailableAt`, when paused, when the PM is not in
  ///      the batch, or when the offer's yield / the cumulative PT exceeds policy.
  /// @param positionManager The PM whose Request to consume against.
  /// @param offer The signed offer.
  /// @param signature The maker's EIP-712 signature.
  /// @param ptAmount The PT amount to mint.
  /// @return ytAmount The YT amount minted (proportional to PT).
  function consumeOffer(address positionManager, Offer calldata offer, bytes calldata signature, uint256 ptAmount)
    external
    returns (uint256 ytAmount);

  /// @notice Authorises `to` to call {mint} on the Request bound to `positionManager`.
  /// @dev CONSUMER-only. Same gating as {consumeOffer}. The cumulative cap accounting treats the
  ///      DELTA between current and requested authorisation, so reducing an authorisation
  ///      decreases `consumed` and increasing it adds the difference.
  /// @param positionManager The PM whose Request to authorise minting on.
  /// @param to The address to authorise.
  /// @param ptAmount The PT amount to authorise.
  /// @param ytAmount The YT amount to authorise.
  function authorizeMinting(address positionManager, address to, uint128 ptAmount, uint128 ytAmount) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            VIEWS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the current batch's top-level state in one call.
  /// @return active Whether a batch is currently open.
  /// @return openedAt The timestamp at which the current batch was opened.
  /// @return consumeAvailableAt Earliest timestamp at which {consumeOffer} / {authorizeMinting} run.
  /// @return repaymentDeadline The absolute repayment deadline handed to every Request in the batch.
  /// @return fund The IFund attached to the open batch (zero if none).
  /// @return hasFundOrder Whether the attached fund currently has a live (non-ENDED) order.
  function batchInfo()
    external
    view
    returns (
      bool active,
      uint40 openedAt,
      uint40 consumeAvailableAt,
      uint64 repaymentDeadline,
      address fund,
      bool hasFundOrder
    );

  /// @notice Returns the list of PMs in the current batch.
  function batchPositionManagers() external view returns (address[] memory);

  /// @notice Returns the list of Requests deployed by the current batch.
  function batchRequests() external view returns (address[] memory);

  /// @notice Returns whether `positionManager` is part of the current batch.
  function isBatchPositionManager(address positionManager) external view returns (bool);

  /// @notice Returns whether `request` was deployed by the current batch.
  function isBatchRequest(address request) external view returns (bool);

  /// @notice Returns the full state of the batch entry for `positionManager`.
  function batchEntry(address positionManager) external view returns (BatchEntryView memory);
}
