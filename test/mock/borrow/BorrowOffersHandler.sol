// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BorrowOffersHarness} from "test/mock/borrow/BorrowOffersHarness.sol";
import {LibBorrowOffers} from "src/libs/borrow/LibBorrowOffers.sol";
import {IBorrowOffers, Offer} from "src/interfaces/borrow/IBorrowOffers.sol";
import {MAX_OFFERS} from "src/libs/borrow/LibBorrowOffersConstants.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";

/// @title BorrowOffersHandler
/// @author 3F Protocol
/// @notice Invariant-test handler that drives random insert / revoke / consume / time-warp actions
///         against a {BorrowOffersHarness}, so the slab + liveness bitmap are pushed through long,
///         adversarial operation sequences while the structural invariants are checked.
/// @dev The actions feed only states the real {MorphoBorrowPosition.proposeOffer} can reach:
///      amounts are bounded `> 0`, `expiresAt > activeAt`, and `activeAt = now + timelock`.
///
///      The consume actions use a fixed, deliberately favorable market snapshot (unit price, 1:1
///      share:asset totals, a position whose collateral/share ratio sits above every offer's) so
///      that profitable, strictly-de-risking fills actually happen and the consume removal paths
///      (partial fill, exhaust + unlink + free, expired-prune) get real coverage. The position
///      snapshot is intentionally NOT decremented across calls: the structural invariants must hold
///      regardless of the economics, and a fixed snapshot keeps every offer consumable so the list
///      genuinely drains.
///
///      Every consume action additionally checks the per-fill price invariant against the
///      OfferConsumed events (see {_consumeChecked}): no fill may pay fewer debt shares per
///      collateral unit than the offer's fixed ratio.
contract BorrowOffersHandler is Test {
  BorrowOffersHarness public h;

  /// @dev Fixed veto window applied to every proposed offer (the timelock configuration itself
  ///      lives on the shared registry, outside this data-structure suite).
  uint40 internal constant OFFER_TIMELOCK = 1 hours;
  /// @dev Unit oracle price: 1 collateral token is worth 1 borrow asset.
  uint256 internal constant PRICE = ORACLE_PRICE_SCALE;
  /// @dev Equal totals => `toAssetsUp(shares) == shares` exactly (no share-conversion rounding).
  uint256 internal constant TOTAL_BORROW_ASSETS = 1e27;
  uint256 internal constant TOTAL_BORROW_SHARES = 1e27;
  /// @dev Position collateral/share ratio = 4, strictly above the max offer ratio (3), so every
  ///      profitable offer is also strictly de-risking; consuming low-ratio chunks only raises the
  ///      ratio, so the position stays consumable and the active list drains under a large target.
  uint256 internal constant POSITION_COLLATERAL = 4e24;
  uint256 internal constant POSITION_BORROW_SHARES = 1e24;

  /// @dev Fixed proposer set (accountability only; not part of the structure).
  address[4] internal proposers;

  // --- ghost counters (sanity / coverage signal) ---
  uint256 public ghostInserts;
  uint256 public ghostRevokes;
  uint256 public ghostConsumeCalls;
  uint256 public ghostSeized;
  uint256 public ghostRepaid;

  constructor(BorrowOffersHarness harness) {
    h = harness;
    proposers[0] = makeAddr("proposerA");
    proposers[1] = makeAddr("proposerB");
    proposers[2] = makeAddr("proposerC");
    proposers[3] = makeAddr("proposerD");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      HANDLER ACTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Proposes a new offer (recycling a freed slab slot when one exists), unless the slab is
  ///         full. Amounts and lifespan mirror `proposeOffer`'s guarantees.
  function act_propose(uint256 collSeed, uint256 shareSeed, uint256 lifeSeed, uint256 proposerSeed) external {
    if (h.count() >= MAX_OFFERS) return; // slab full: a real proposeOffer would revert TooManyOffers

    uint128 debtShares = uint128(_bound(shareSeed, 1, 1e21));
    // collateral strictly in (debtShares, 3*debtShares] => ratio in (1, 3]: profitable and
    // strictly de-risking against the fixed position (ratio 4).
    uint128 collateral = uint128(_bound(collSeed, uint256(debtShares) + 1, uint256(debtShares) * 3));

    uint40 activeAt = uint40(block.timestamp) + OFFER_TIMELOCK;
    uint40 lifespan = uint40(_bound(lifeSeed, 1, 365 days));
    uint40 expiresAt = activeAt + lifespan;

    address proposer = proposers[proposerSeed % proposers.length];
    h.insert(proposer, activeAt, expiresAt, collateral, debtShares);
    ghostInserts++;
  }

  /// @notice Revokes the nth live offer (picked from the bitmap), exercising removals at low,
  ///         middle and high slab ids across the run.
  function act_revoke(uint256 idxSeed) external {
    uint256 liveCount = h.count();
    if (liveCount == 0) return;
    uint8 nth = uint8(_bound(idxSeed, 0, liveCount - 1));
    h.removeOffer(_liveIdAt(nth));
    ghostRevokes++;
  }

  /// @notice Consumes against a seized-collateral target.
  function act_consumeSeized(uint256 targetSeed) external {
    // Range spans single-offer partial fills through draining several offers in one call.
    uint256 target = _bound(targetSeed, 1, 1e22);
    (uint256 seized, uint256 repaid) = _consumeChecked(_input(target, 0));
    ghostConsumeCalls++;
    ghostSeized += seized;
    ghostRepaid += repaid;
  }

  /// @notice Consumes against a repaid-shares target.
  function act_consumeShares(uint256 targetSeed) external {
    uint256 target = _bound(targetSeed, 1, 5e21);
    (uint256 seized, uint256 repaid) = _consumeChecked(_input(0, target));
    ghostConsumeCalls++;
    ghostSeized += seized;
    ghostRepaid += repaid;
  }

  /// @notice Consumes against a position whose ratio (1.5) sits between offer ratios, so the walk
  ///         de-risks the cheap portion then hits an over-max-price offer (one that would no
  ///         longer strictly lower the LTV) and stops mid-book. Exercises a partial drain that
  ///         leaves live offers behind.
  function act_consumeLowRatioPosition(uint256 targetSeed) external {
    uint256 target = _bound(targetSeed, 1, 1e22);
    (uint256 seized, uint256 repaid) = _consumeChecked(_inputFull(target, 0, PRICE, 1.5e24, POSITION_BORROW_SHARES));
    ghostConsumeCalls++;
    ghostSeized += seized;
    ghostRepaid += repaid;
  }

  /// @notice Consumes at a crashed price, so every offer is unprofitable and is skipped:
  ///         the walk traverses the whole active list, pruning only expired slots, and the structure
  ///         must be untouched otherwise. Exercises the full-list Skip-and-keep traversal.
  function act_consumeLowPrice(uint256 targetSeed) external {
    uint256 target = _bound(targetSeed, 1, 1e22);
    (uint256 seized, uint256 repaid) =
      _consumeChecked(_inputFull(target, 0, PRICE / 1000, POSITION_COLLATERAL, POSITION_BORROW_SHARES));
    ghostConsumeCalls++;
    ghostSeized += seized;
    ghostRepaid += repaid;
  }

  /// @notice Consumes against a position small enough that the position-shares clamp can bind
  ///         mid-walk: per-offer debt shares go up to 1e21, so bounding the position's shares into
  ///         the same range makes the clamp-and-rescale branch of the fill math reachable (the
  ///         fixed 1e24-share position never triggers it). Collateral is kept at 4x the shares
  ///         (the fixed position's ratio), so profitable fills stay strictly de-risking, and the
  ///         per-fill price invariant in {_consumeChecked} covers the rescaled fills.
  function act_consumeSmallPosition(uint256 targetSeed, uint256 shareSeed) external {
    uint256 positionShares = _bound(shareSeed, 1, 1e21);
    uint256 positionCollateral = 4 * positionShares;
    uint256 target = _bound(targetSeed, 1, 1e22);
    (uint256 seized, uint256 repaid) = _consumeChecked(_inputFull(target, 0, PRICE, positionCollateral, positionShares));
    ghostConsumeCalls++;
    ghostSeized += seized;
    ghostRepaid += repaid;
  }

  /// @notice Advances time so fresh offers activate and standing offers eventually expire.
  function act_warp(uint256 dtSeed) external {
    uint256 dt = _bound(dtSeed, 1, 30 days);
    vm.warp(block.timestamp + dt);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Runs a consume with the per-fill price invariant checked against every OfferConsumed
  ///      event: `sharesFilled * remainingCollateralBefore >= collateralFilled *
  ///      remainingDebtSharesBefore`, so the liquidator never pays fewer debt shares per collateral
  ///      unit than the offer's fixed ratio (the position-shares clamp rescales collateral down,
  ///      never the shares).
  function _consumeChecked(LibBorrowOffers.ConsumeInput memory inp) internal returns (uint256 seized, uint256 repaid) {
    Offer[] memory before = new Offer[](MAX_OFFERS);
    for (uint8 id; id < MAX_OFFERS; ++id) {
      before[id] = h.slabAt(id);
    }

    vm.recordLogs();
    (seized, repaid) = h.consume(inp);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics[0] != IBorrowOffers.OfferConsumed.selector) continue;
      uint256 id = uint256(logs[i].topics[1]);
      (uint128 collFilled, uint128 sharesFilled,) = abi.decode(logs[i].data, (uint128, uint128, bool));
      assertGe(
        uint256(sharesFilled) * before[id].remainingCollateral,
        uint256(collFilled) * before[id].remainingDebtShares,
        "fill price below the offer's fixed ratio"
      );
    }
  }

  function _input(uint256 seizedTarget, uint256 repaidSharesTarget)
    internal
    pure
    returns (LibBorrowOffers.ConsumeInput memory)
  {
    return _inputFull(seizedTarget, repaidSharesTarget, PRICE, POSITION_COLLATERAL, POSITION_BORROW_SHARES);
  }

  function _inputFull(
    uint256 seizedTarget,
    uint256 repaidSharesTarget,
    uint256 price,
    uint256 positionCollateral,
    uint256 positionBorrowShares
  ) internal pure returns (LibBorrowOffers.ConsumeInput memory) {
    return LibBorrowOffers.ConsumeInput({
      seizedTarget: seizedTarget,
      repaidSharesTarget: repaidSharesTarget,
      price: price,
      totalBorrowAssets: TOTAL_BORROW_ASSETS,
      totalBorrowShares: TOTAL_BORROW_SHARES,
      positionCollateral: positionCollateral,
      positionBorrowShares: positionBorrowShares,
      // Invariant handler drives the raw list/consume mechanics with the bonus floor disabled (0).
      minOfferBonusBps: 0
    });
  }

  /// @dev Returns the nth (0-based, ascending id) live slab id from the bitmap.
  function _liveIdAt(uint8 nth) internal view returns (uint8) {
    uint256 seen;
    for (uint8 id = 0; id < MAX_OFFERS; ++id) {
      if (!h.isLive(id)) continue;
      if (seen == nth) return id;
      ++seen;
    }
    revert("nth live offer out of range");
  }
}
