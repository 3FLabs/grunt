// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {Order, State} from "../../funds/Order.sol";
import {IFund} from "../../../interfaces/funds/IFund.sol";
import {RETARGETTER_STORAGE_SLOT, MODULE_CONTEXT_TSLOT} from "./LibRetargetterConstants.sol";

/// @notice Per-PM batch state for the in-flight rebalancing batch.
/// @dev Slot-packed: (request, maxPrincipal, maxYieldBps) take one slot (20 + 12 + 2 = 34 bytes:
///      so the struct actually spans two slots; we don't pretend otherwise but tight-pack what we
///      can). `consumed` accumulates PT issued via {consumeOffer} and {authorizeMinting}; it is a
///      strict monotone-increasing counter for the lifetime of the batch.
/// @param request The Request contract deployed for this PM (or `address(0)` if `maxPrincipal == 0`).
/// @param maxPrincipal Maximum PT (= debt asset) that can be issued against the Request.
/// @param maxYieldBps Per-PM yield cap (absolute, over the horizon). Bounded at open time by the
///        Retargetter-level `maxYieldBps`.
/// @param consumed Cumulative PT issued (via consume + authorizeMinting) for this PM, ever.
struct BatchEntry {
  address request;
  uint96 maxPrincipal;
  uint16 maxYieldBps;
  uint128 consumed;
}

/// @notice Static policy configuration: set at init, individually mutable by the owner.
/// @dev Grouped into its own struct so {Retargetter.initialize} assigns the whole block in one copy
///      (`s.config = params.config`) instead of field-by-field. That keeps the initialiser's
///      bytecode small: a single calldata->storage copy replaces ~7 packed read-modify-write
///      sequences. Field order packs the six `uint40`s and the `uint16` into one slot (6 * 5 + 2 =
///      32 bytes) after the three address slots. `pauseUntil` is deliberately excluded: it is
///      runtime state (never set at init) and lives top-level in {RetargetterStorage}.
/// @param collateralAsset The common collateral asset every batch PM must declare.
/// @param debtAsset The common debt asset every batch PM must declare; also the auction asset for
///        every Request the Retargetter deploys.
/// @param requestFactory The factory through which auction Requests are deployed at {openBatch}.
/// @param consumeTimelock Seconds between {openBatch} and the first {consumeOffer} window.
/// @param proposalTimelock Seconds between {propose} and {executeProposal}.
/// @param mintToRepaidDelay Seconds between the last mint/consume on a Request and the earliest
///        time the Retargetter can mark it repaid.
/// @param horizon Seconds defining each Request's lifetime (the auction horizon).
/// @param tickDuration Granularity of the yield gate's tick-rounded paid duration (seconds, > 0).
/// @param tickThreshold Grace period (seconds, `<= tickDuration`) inside a tick before the gate
///        promotes the paid duration to the next tick.
/// @param maxYieldBps Global cap (basis points, over the horizon) on per-PM `maxYieldBps`.
struct RetargetterConfig {
  address collateralAsset;
  address debtAsset;
  address requestFactory;
  uint40 consumeTimelock;
  uint40 proposalTimelock;
  uint40 mintToRepaidDelay;
  uint40 horizon;
  uint40 tickDuration;
  uint40 tickThreshold;
  uint16 maxYieldBps;
}

/// @notice State for the single in-flight rebalancing batch.
/// @dev Scalars pack across two slots; the sets, entry mapping, and fund order follow. Cleared
///      field-by-field at {closeBatch} rather than with a struct `delete`, because the nested
///      EnumerableSet / mapping members must be drained per element, not blanket-reset.
/// @param fund The optional IFund attached at {openBatch} (zero if none).
/// @param repaymentDeadline Absolute Unix timestamp handed to every Request the batch deploys.
/// @param active True while a batch is open.
/// @param openedAt The timestamp the batch was opened.
/// @param consumeAvailableAt Earliest timestamp at which {consumeOffer} / {authorizeMinting} run.
/// @param positionManagers The PMs in the batch.
/// @param requests The Requests deployed by the batch (one per PM with `maxPrincipal > 0`).
/// @param entries Per-PM batch entry: Request binding, caps, and the cumulative `consumed` counter.
/// @param order The batch's single in-flight fund order (`owner == address(0)` when none).
struct BatchState {
  address fund;
  uint64 repaymentDeadline;
  bool active;
  uint40 openedAt;
  uint40 consumeAvailableAt;
  EnumerableSetLib.AddressSet positionManagers;
  EnumerableSetLib.AddressSet requests;
  mapping(address positionManager => BatchEntry) entries;
  Order order;
}

/// @notice State for the single pending proposal.
/// @dev All value-typed, so {RetargetterProposals} commits it with one struct assignment at
///      {propose} and clears it with a single `delete` at cancel / execute.
/// @param hash `keccak256(abi.encode(proposal))` committed at {propose}.
/// @param active True while a proposal is pending.
/// @param executableAt Earliest timestamp at which {executeProposal} can run.
struct ProposalState {
  bytes32 hash;
  bool active;
  uint40 executableAt;
}

/// @notice Retargetter main storage (ERC-7201 namespaced).
/// @dev Grouped into sub-structs (mirroring {LibStorage}'s FeeData / RebalanceConfig grouping) so
///      related fields are set / cleared together and the initialiser can copy {RetargetterConfig}
///      wholesale. Callers still reach everything through the single {retargetterStorage} pointer.
/// @param config Static policy configuration (see {RetargetterConfig}).
/// @param pauseUntil Pause-until timestamp (0 = unpaused). Runtime state, kept out of {config}.
/// @param modules Flash-loan / orchestration module whitelist.
/// @param batch The single in-flight batch (see {BatchState}).
/// @param proposal The single pending proposal (see {ProposalState}).
struct RetargetterStorage {
  RetargetterConfig config;
  uint40 pauseUntil;
  EnumerableSetLib.AddressSet modules;
  BatchState batch;
  ProposalState proposal;
}

/// @title LibRetargetter
/// @author 3F Protocol
/// @notice Storage accessor and transient-context helpers for the Retargetter system.
/// @dev Pure plumbing: every contract / library in the system that touches state goes through
///      {retargetterStorage}. The transient helpers expose the module-context slot used to
///      authenticate {executeProposalCallback} re-entry.
library LibRetargetter {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /// @dev Returns the Retargetter's main storage pointer.
  function retargetterStorage() internal pure returns (RetargetterStorage storage s) {
    bytes32 slot = RETARGETTER_STORAGE_SLOT;
    assembly ("memory-safe") {
      s.slot := slot
    }
  }

  /// @dev Reads the transient module-context: the address authorised to call
  ///      {RetargetterProposals.executeProposalCallback} during the current top-level execution.
  function moduleContext() internal view returns (address module) {
    bytes32 slot = MODULE_CONTEXT_TSLOT;
    assembly ("memory-safe") {
      module := tload(slot)
    }
  }

  /// @dev Writes the transient module-context. Pass `address(0)` to clear.
  function setModuleContext(address module) internal {
    bytes32 slot = MODULE_CONTEXT_TSLOT;
    assembly ("memory-safe") {
      tstore(slot, module)
    }
  }

  /// @dev Computes the tick-rounded "paid duration" used by the yield gate. Reads `tickDuration`
  ///      and `tickThreshold` from storage so callers do not have to fetch them separately.
  ///
  ///      Formula:
  ///        paidTicks    = max(1, (elapsed + tickThreshold) / tickDuration)
  ///        paidDuration = paidTicks * tickDuration
  ///
  ///      Worked example (tickDuration = 1 day, tickThreshold = 12h):
  ///        - elapsed =  0           -> paidDuration =  1 day (minimum)
  ///        - elapsed = 20 days      -> paidDuration = 20 days
  ///        - elapsed = 20d + 12h    -> paidDuration = 21 days (threshold crossed)
  ///        - elapsed = 30d + 11h59m -> paidDuration = 30 days
  ///        - elapsed = 30d + 12h    -> paidDuration = 31 days
  ///
  ///      `elapsed` is `block.timestamp - batchOpenedAt`. Returns a `uint256` in seconds.
  ///
  ///      Invariants enforced at admin time (so this function does not need to re-check):
  ///        - `tickDuration > 0`
  ///        - `tickThreshold <= tickDuration`
  /// @param elapsed Time (seconds) since the batch was opened.
  /// @return paidDuration_ The tick-rounded duration (seconds) used by the yield gate.
  function paidDuration(uint256 elapsed) internal view returns (uint256 paidDuration_) {
    RetargetterConfig storage c = retargetterStorage().config;
    uint256 tickDuration_ = uint256(c.tickDuration);
    uint256 ticks = (elapsed + uint256(c.tickThreshold)) / tickDuration_;
    if (ticks == 0) ticks = 1;
    paidDuration_ = ticks * tickDuration_;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     BATCH FUND ORDER                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Mirrors the Facility's notion of an "active order": the batch holds an in-flight order
  ///      iff its stored `owner` is non-zero. {Order} is cleared with `delete` when an order is
  ///      cancelled or reaches the terminal {State.ENDED}.
  /// @param s The Retargetter storage pointer.
  /// @return True if the batch has a live fund order.
  function hasFundOrder(RetargetterStorage storage s) internal view returns (bool) {
    return s.batch.order.owner != address(0);
  }

  /// @dev Reconciles an order the fund ended out-of-band (e.g. a force-end on the fund side).
  ///      If the batch has a live order whose fund-reported state is {State.ENDED}, the stale
  ///      order binding is cleared so the fund can be detached at {closeBatch}. Mirrors the
  ///      Facility's `syncEndedOrder`. No-op when there is no fund or no live order.
  /// @param s The Retargetter storage pointer.
  function syncFundOrder(RetargetterStorage storage s) internal {
    if (s.batch.fund == address(0)) return;
    if (!hasFundOrder(s)) return;
    if (IFund(s.batch.fund).state(s.batch.order) == State.ENDED) delete s.batch.order;
  }
}
