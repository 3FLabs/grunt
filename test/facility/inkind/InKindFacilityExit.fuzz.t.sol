// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibInKindView} from "src/libs/facility/inkind/LibInKindView.sol";
import {InKindFacilityExitHelpers} from "./InKindFacilityExit.t.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {RepayOnBehalfExiter} from "test/mock/facility/InKindExiters.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract InKindFacilityExitFuzzTest is InKindFacilityExitHelpers {
  using FixedPointMathLib for uint256;

  uint256 constant MULTIPLIER_ONE = 4096;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Burn's debt and collateral slices for `burnShares` after `repay` lands on the module.
  function _slicesAfterRepay(uint256 burnShares, uint256 repay) internal returns (uint256 pulled, uint256 out) {
    uint256 snap = vm.snapshotState();
    debtToken.setBalance(address(this), repay);
    debtToken.approve(address(morpho), repay);
    morpho.repay(marketParams, repay, 0, address(borrowPosition), "");
    pulled = _mirrorDebt(burnShares);
    out = _mirrorOut(burnShares);
    vm.revertToState(snap);
  }

  /// @dev Sets the exit word of kind 0 (ABSOLUTE `cap`), 1 (absolute pool `cap` at `multiplier`),
  ///      2 (dynamic `cap` fully recovered over a day, at `multiplier`) or 3 (absolute pool with
  ///      `cap` of release headroom, at `-multiplier`) and returns the caps contract (zero for
  ///      kind 0) and the debt the word lets through.
  function _setExitWord(uint256 kind, uint128 cap, int24 multiplier, uint24 feeBps)
    internal
    returns (address caps, uint256 available)
  {
    if (kind == 0) {
      _setExit(positionManager, cap, FAR_EXPIRY, feeBps);
      return (address(0), cap);
    }
    uint128 capsCap = uint128(_capUnits(kind, cap));
    vm.startPrank(owner);
    if (kind == 1) absoluteCaps.setCap(POOL_ID, capsCap, capsCap);
    else if (kind == 2) dynamicCaps.setCap(POOL_ID, capsCap, uint64(1 days), uint64(block.timestamp - 1 days));
    else absoluteCaps.setCap(POOL_ID, 0, capsCap);
    vm.stopPrank();
    caps = kind == 2 ? address(dynamicCaps) : address(absoluteCaps);
    _setExit(positionManager, _externalWord(caps, POOL_ID, kind == 3 ? -multiplier : multiplier), FAR_EXPIRY, feeBps);
    available = uint256(capsCap).mulDiv(MULTIPLIER_ONE, uint256(uint24(multiplier))) / CAPS_SCALE;
  }

  /// @dev A debt-unit `cap` in the units of the word of `kind`: caps contracts count in 18
  ///      decimals, an ABSOLUTE word in the debt's own.
  function _capUnits(uint256 kind, uint256 cap) internal pure returns (uint256) {
    return kind == 0 ? cap : cap * CAPS_SCALE;
  }

  /// @dev Capacity left on the exit word of `kind` (release headroom for kind 3).
  function _capLeft(uint256 kind) internal view returns (uint256) {
    if (kind == 0) return facility.getExit(address(positionManager)).cap;
    if (kind == 2) return dynamicCaps.remaining(POOL_ID);
    (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(POOL_ID);
    return kind == 1 ? cap : hardCap - cap;
  }

  /// @dev Expected capacity left on the exit word of `kind` after consuming `charge` from `cap`.
  ///      The dynamic origin moves back by floor(left * T / R) whole seconds.
  function _expectedCapLeft(uint256 kind, uint256 cap, uint256 charge) internal pure returns (uint256) {
    uint256 left = cap - charge;
    if (kind != 2 || left == 0) return left;
    return cap.mulDiv(left.mulDiv(1 days, cap), 1 days);
  }

  /// @dev What the word of `kind` charges for a mirrored `debt`, in its units (see _capUnits):
  ///      consumption rounds up, a release (kind 3) rounds down.
  function _charge(uint256 kind, uint256 debt, int24 multiplier) internal pure returns (uint256) {
    if (kind == 0) return debt;
    uint256 m = uint256(uint24(multiplier));
    debt *= CAPS_SCALE;
    return kind == 3 ? debt.mulDiv(m, MULTIPLIER_ONE) : debt.mulDivUp(m, MULTIPLIER_ONE);
  }

  /// @dev Smallest mirrored debt whose charge exceeds the debt-unit `cap` on the word of `kind`.
  function _overflowingDebt(uint256 kind, uint256 cap, int24 multiplier) internal pure returns (uint256) {
    if (kind == 0) return cap + 1;
    uint256 m = uint256(uint24(multiplier));
    return
      kind == 3 ? (cap * CAPS_SCALE + 1).mulDivUp(MULTIPLIER_ONE, m * CAPS_SCALE) : cap.mulDiv(MULTIPLIER_ONE, m) + 1;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        DEBT HEADROOM                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_previewExit_debtRequiredFormula(uint256 debt) public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    debt = bound(debt, 0, type(uint128).max);
    uint256 supplyAdj = _adjustedSupply();
    _mockDebtAmount(debt);

    (,,, uint256 debtRequired) = facility.previewExit(address(positionManager), supplyAdj);

    assertEq(debtRequired, _expectedPull(debt), "debtRequired");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      CALLBACK REFUNDS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_exit_repayInCallbackRefundsExactly(uint256 repaySeed, uint256 sharesSeed, uint256 elapsed) public {
    uint256 exitCap = 10_000e6;
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
    _setPmFees(100, 1000);
    _setExit(positionManager, exitCap, FAR_EXPIRY, DEFAULT_FEE_BPS);
    RepayOnBehalfExiter r =
      new RepayOnBehalfExiter(facility, positionManager, debtToken, morpho, marketParams, address(borrowPosition));
    (uint256 userShares,) = _enter(user, ENTER_AMOUNT, address(r));
    vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
    uint256 shares = bound(sharesSeed, 2, userShares);
    uint256 repay = bound(repaySeed, 1, positionManager.debtAmount() - 1);
    uint256 burnShares = _burnShares(shares, DEFAULT_FEE_BPS);
    uint256 mirror = _mirrorDebt(burnShares);
    uint256 pull = _expectedPull(mirror);
    (uint256 pulled, uint256 out) = _slicesAfterRepay(burnShares, repay);
    debtToken.setBalance(address(r), pull + repay);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Exited(
      address(positionManager), address(r), receiver, out, pulled, burnShares, shares - burnShares
    );
    r.exit(shares, pull, out, receiver, abi.encode(repay));

    assertEq(debtToken.balanceOf(address(r)), pull - pulled, "refund");
    assertEq(facility.getExit(address(positionManager)).cap, exitCap - pulled, "exit cap charged with burn's pull");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          MAX EXIT                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_maxExit_exitFitsAcrossFeesAndWords(
    uint256 debtSeed,
    uint256 feeSeed,
    uint256 kindSeed,
    uint256 capSeed,
    uint256 multiplierSeed,
    uint256 elapsed
  ) public {
    _seedPool(SEED_COLLATERAL, bound(debtSeed, 1_000e6, 4_500e6));
    _openOffers();
    _setPmFees(100, 1000);
    (uint256 userShares,) = _enter(user, ENTER_AMOUNT, user);
    vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
    uint24 feeBps = uint24(bound(feeSeed, 0, MAX_FEE));
    uint256 kind = bound(kindSeed, 0, 3);
    uint128 cap = uint128(bound(capSeed, 1, 1_000e6));
    int24 multiplier = int24(int256(bound(multiplierSeed, 1, 4 * MULTIPLIER_ONE)));
    (address caps, uint256 available) = _setExitWord(kind, cap, multiplier, feeBps);
    uint256 supplyAdj = _adjustedSupply();
    uint256 totalDebt = positionManager.debtAmount();

    uint256 max = facility.maxExit(address(positionManager));
    assertEq(max, LibInKindView.grossForNet(available.mulDiv(supplyAdj, totalDebt), feeBps), "maxExit");
    if (max < userShares) _assertOvershootReverts(kind, cap, multiplier, feeBps, userShares);
    uint256 shares = max.min(userShares);
    if (shares == 0) return;
    uint256 mirror = _mirrorDebt(_burnShares(shares, feeBps));
    uint256 charge = _charge(kind, mirror, multiplier);
    _fundExit(user, shares, _expectedPull(mirror));

    if (kind != 0) {
      int24 wordMultiplier = kind == 3 ? -multiplier : multiplier;
      vm.expectCall(caps, abi.encodeCall(IFacilityCaps.consume, (POOL_ID, mirror * CAPS_SCALE, wordMultiplier)), 1);
    }
    vm.prank(user);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, user, "");

    assertEq(_capLeft(kind), _expectedCapLeft(kind, _capUnits(kind, cap), charge), "cap consumed");
    assertEq(positionManager.balanceOf(user), userShares - shares, "shares pulled");
    _assertFacilityClean();
  }

  /// @dev An exit just past the word's room reverts with the word's error. The cap is charged
  ///      after burn, so the overshoot is funded and skipped when it exceeds the balance.
  function _assertOvershootReverts(uint256 kind, uint128 cap, int24 multiplier, uint24 feeBps, uint256 userShares)
    internal
  {
    uint256 overBurn = _overflowingDebt(kind, cap, multiplier).mulDivUp(_adjustedSupply(), positionManager.debtAmount());
    uint256 over = overBurn.mulDivUp(BPS, BPS - feeBps) + 1;
    if (over > userShares) return;
    uint256 overMirror = _mirrorDebt(_burnShares(over, feeBps));
    assertGt(_charge(kind, overMirror, multiplier), _capUnits(kind, cap), "overshoot");
    _fundExit(user, over, _expectedPull(overMirror));
    vm.prank(user);
    if (kind == 0) {
      vm.expectRevert(
        abi.encodeWithSelector(
          LibFacilityErrors.CapExceeded.selector, uint256(uint160(address(positionManager))), cap, overMirror
        )
      );
    } else {
      vm.expectRevert(
        abi.encodeWithSelector(
          kind == 3 ? IFacilityCaps.HardCapExceeded.selector : IFacilityCaps.InsufficientCap.selector, uint64(POOL_ID)
        )
      );
    }
    facility.exit(address(positionManager), over, type(uint256).max, 0, user, "");
  }
}
