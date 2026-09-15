// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {MorphoBorrowPositionOffersTest} from "./MorphoBorrowPositionOffers.t.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {IPreLiquidationCallback} from "src/interfaces/borrow/IPreliquidationCallback.sol";
import {LibBorrowErrors} from "src/libs/borrow/LibBorrowErrors.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";

/// @notice Regression test for the Cantina reentrancy finding on the band settlement guard.
///         The reviewer's exploit ran end-to-end against the real Morpho + MorphoBorrowPosition: a
///         liquidator's `onPreLiquidate` callback re-entered the PROPORTIONAL path, repaid all
///         remaining shares (seizing the rest of the collateral), supplied a few collateral atoms
///         back on behalf of the position, and returned with `exitDebt = 0`, so a post-repay live
///         `_checkLtvReduced` passed and the whole owner position was drained at the proportional
///         discount.
///
///         Precondition: the position sits at `margin == 0` (its floored borrowing capacity at
///         `liquidationLtv` exactly equals its debt, i.e. it is at the offer-band/proportional
///         boundary). At `margin == 0` a one-atom "flat LTV" offer fill (the 3F-469 residual) ticks
///         the floored `_isHealthy(liquidationLtv)` check false at the callback point, which is what
///         made the reentrant proportional path reachable.
///
///         The fix ({_checkLtvStrictlyReduced}) evaluates the guard BEFORE the repay on a frame
///         derived from the fill amounts, so the non-de-risking dust fill is rejected up front and
///         the callback never runs. This test asserts the exploit is blocked.
contract ReentrancyGuardBypassPoC is MorphoBorrowPositionOffersTest {
  using SharesMathLib for uint256;

  function test_poc_confirmExploitAtBoundaryPrice() public {
    _enterBand(0.7e18); // establish the position (collateral + borrow)

    // Binary-search the smallest price that dispatches to the offer band (isHealthy at
    // liquidationLtv). At that price the floored borrowing capacity first reaches the debt, so
    // `margin == 0`. Higher price => lower LTV => healthier, so isHealthy(liqLtv) is monotonic.
    uint256 lo = BORROW * SCALE / COLLATERAL * 1e18 / uint256(LIQ_LTV);
    uint256 hi = lo * 2;
    for (uint256 it; it < 256 && hi - lo > 1; ++it) {
      uint256 mid = lo + (hi - lo) / 2;
      oracle.setPrice(mid);
      if (pos.isHealthy(uint256(LIQ_LTV))) hi = mid;
      else lo = mid;
    }
    oracle.setPrice(hi); // offer-band dispatch, closest to the boundary
    assertTrue(pos.isHealthy(uint256(LIQ_LTV)) && !pos.isHealthy(uint256(SAFE_LTV)), "offer band at entry");

    _proposeAtPrice(_positionShares() / 2, 1.2e18);
    _warpActive();

    uint256 ownerCollBefore = _positionCollateral();
    PureExploitLiquidator attacker =
      new PureExploitLiquidator(pos, morpho, marketParams, marketId, loanToken, collateralToken, LIQ_LTV);
    loanToken.setBalance(address(attacker), 100_000_000e18);
    collateralToken.setBalance(address(attacker), 1_000e18);

    uint256 attackerCollBefore = collateralToken.balanceOf(address(attacker));

    (bool ok, bytes4 sel) = attacker.attackSeize(1); // one-atom seize target => the 3F-469 residual fill

    uint256 collGained = collateralToken.balanceOf(address(attacker)) - attackerCollBefore;

    console2.log("outerOk=%s exploitRan=%s", ok, attacker.exploitRan());
    console2.log(
      "ownerCollBefore=%e ownerCollAfter=%e ownerDebtAfter=%e",
      ownerCollBefore,
      _positionCollateral(),
      _positionShares()
    );
    console2.log("attacker collateralGained=%e", collGained);

    // Fix regression: the settlement guard now runs BEFORE the repay on a derived frame, so the
    // non-de-risking dust fill is rejected up front. The outer call reverts LtvNotReduced, the
    // callback (and its reentrant proportional drain) never runs, and the owner is untouched.
    assertFalse(ok, "exploit blocked: outer preLiquidate reverts");
    assertEq(sel, LibBorrowErrors.LtvNotReduced.selector, "reverts with LtvNotReduced before settlement");
    assertFalse(attacker.exploitRan(), "callback never reached: guard runs before the repay");
    assertEq(_positionCollateral(), ownerCollBefore, "owner position untouched");
    assertEq(collGained, 0, "attacker seized nothing");
  }
}

/// @notice Liquidator that runs the reviewer's exploit steps: if the reentrant proportional path is
///         reachable at the callback (position unhealthy at liquidationLtv), repay all remaining
///         shares (seizing the rest of the collateral) then supply a few collateral atoms back on
///         behalf of the position so the outer exit frame reads (debt=0, collateral>0).
contract PureExploitLiquidator is IPreLiquidationCallback {
  MorphoBorrowPosition internal pos;
  IMorpho internal morpho;
  MarketParams internal mp;
  Id internal id;
  MockERC20 internal loanToken;
  MockERC20 internal collateralToken;
  uint128 internal liqLtv;
  bool internal entered;
  bool public exploitRan;

  constructor(
    MorphoBorrowPosition _pos,
    IMorpho _morpho,
    MarketParams memory _mp,
    Id _id,
    MockERC20 _loan,
    MockERC20 _coll,
    uint128 _liqLtv
  ) {
    pos = _pos;
    morpho = _morpho;
    mp = _mp;
    id = _id;
    loanToken = _loan;
    collateralToken = _coll;
    liqLtv = _liqLtv;
    loanToken.approve(address(_pos), type(uint256).max);
    loanToken.approve(address(_morpho), type(uint256).max);
    collateralToken.approve(address(_morpho), type(uint256).max);
  }

  function attackSeize(uint256 seizeTarget) external returns (bool ok, bytes4 sel) {
    try pos.preLiquidate(address(pos), seizeTarget, 0, abi.encode("go")) {
      ok = true;
    } catch (bytes memory reason) {
      if (reason.length >= 4) sel = bytes4(reason);
    }
  }

  function onPreLiquidate(uint256, bytes calldata) external override {
    if (entered) return;
    entered = true;
    if (pos.isHealthy(uint256(liqLtv))) return; // proportional path NOT reachable
    uint256 rem = uint256(morpho.position(id, address(pos)).borrowShares);
    pos.preLiquidate(address(pos), 0, rem, ""); // reentrant proportional: drain all collateral
    // Supply enough atoms that the exit-collateral VALUE is strictly positive (one atom rounds to
    // zero value when price/scale < 1, which would trip the guard's 0 >= 0 branch).
    morpho.supplyCollateral(mp, 1e9, address(pos), "");
    exploitRan = true;
  }
}
