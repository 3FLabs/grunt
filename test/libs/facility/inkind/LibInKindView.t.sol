// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibInKindView} from "src/libs/facility/inkind/LibInKindView.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";

/// @dev Exposes the library's pure helpers and the PM-reading helpers over a stub.
contract LibInKindViewHarness {
  function splitFee(uint256 shares, uint24 feeBps) external pure returns (uint256 net, uint256 fee) {
    return LibInKindView.splitFee(shares, feeBps);
  }

  function exitDebtRequired(uint256 debt) external pure returns (uint256) {
    return LibInKindView.exitDebtRequired(debt);
  }

  function entryPoolState(address pm, bool allowUnlevered)
    external
    view
    returns (uint256 totalCollateral, uint256 totalDebt)
  {
    return LibInKindView.entryPoolState(IPositionManager(pm), allowUnlevered);
  }

  function fairMint(address pm, uint256 amount, uint256 totalCollateral)
    external
    view
    returns (uint256 expected, uint256 tolerance)
  {
    return LibInKindView.fairMint(IPositionManager(pm), amount, totalCollateral);
  }

  function estimateShares(address pm, uint256 amount, uint256 totalCollateral, uint256 debt)
    external
    view
    returns (uint256)
  {
    return LibInKindView.estimateShares(IPositionManager(pm), amount, totalCollateral, debt);
  }
}

/// @dev PM stub serving the views the library reads from settable values.
contract ViewPmStub {
  bool public hasBadDebt;
  uint256 public collateralAmount;
  uint256 public debtAmount;
  uint256 public totalAssets;
  uint256 public collateralAmountQuoted;
  uint256 public virtualShareOffset;
  uint256 internal _feeAssets;
  uint256 internal _supply;
  uint256 internal _mgmtFeeShares;
  uint256 internal _perfFeeShares;

  function setPool(bool badDebt, uint256 collateral, uint256 debt) external {
    hasBadDebt = badDebt;
    collateralAmount = collateral;
    debtAmount = debt;
  }

  function setPendingFees(uint256 assets_, uint256 supply, uint256 mgmtFeeShares, uint256 perfFeeShares) external {
    _feeAssets = assets_;
    _supply = supply;
    _mgmtFeeShares = mgmtFeeShares;
    _perfFeeShares = perfFeeShares;
  }

  function setTotalAssets(uint256 value) external {
    totalAssets = value;
  }

  function setCollateralAmountQuoted(uint256 value) external {
    collateralAmountQuoted = value;
  }

  function setVirtualShareOffset(uint256 value) external {
    virtualShareOffset = value;
  }

  function pendingFees() external view returns (uint256, uint256, uint256, uint256) {
    return (_feeAssets, _supply, _mgmtFeeShares, _perfFeeShares);
  }
}

/// @title LibInKindViewTest
/// @notice Unit and fuzz tests for LibInKindView: fee split rounding, the exit debt headroom,
///         the entry pool gates and the fair-mint and share-estimate formulas.
contract LibInKindViewTest is Test {
  LibInKindViewHarness harness;

  uint24 constant MAX_FEE = 1_000;
  uint256 constant BPS = 10_000;

  function setUp() public {
    harness = new LibInKindViewHarness();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         SPLIT FEE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_splitFee_oneBpsRoundsTheFeeUp() public view {
    _assertSplit(0, 1, 0, 0);
    _assertSplit(1, 1, 0, 1);
    _assertSplit(9_999, 1, 9_998, 1);
    _assertSplit(10_000, 1, 9_999, 1);
    _assertSplit(10_001, 1, 9_999, 2);
  }

  function test_splitFee_maxFeeRoundsTheFeeUp() public view {
    _assertSplit(1, MAX_FEE, 0, 1);
    _assertSplit(10, MAX_FEE, 9, 1);
    _assertSplit(11, MAX_FEE, 9, 2);
    _assertSplit(1e18, MAX_FEE, 0.9e18, 0.1e18);
    _assertSplit(1e18 + 1, MAX_FEE, 0.9e18, 0.1e18 + 1);
  }

  function testFuzz_splitFee_feeIsTheCeilAndNetTheRest(uint256 shares, uint256 feeBps) public view {
    shares = bound(shares, 0, type(uint256).max / BPS);
    uint24 bps = uint24(bound(feeBps, 0, BPS));
    uint256 expectedFee = (shares / BPS) * bps + ((shares % BPS) * bps + BPS - 1) / BPS;
    (uint256 net, uint256 fee) = harness.splitFee(shares, bps);
    assertEq(fee, expectedFee, "fee");
    assertEq(net, shares - expectedFee, "net");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     EXIT DEBT REQUIRED                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exitDebtRequired_exactHeadroom() public view {
    assertEq(harness.exitDebtRequired(0), 0, "zero debt");
    assertEq(harness.exitDebtRequired(1), 3, "1");
    assertEq(harness.exitDebtRequired(999), 1_001, "999");
    assertEq(harness.exitDebtRequired(1_000), 1_002, "1_000");
    assertEq(harness.exitDebtRequired(1_001), 1_004, "1_001");
    assertEq(harness.exitDebtRequired(1_003), 1_006, "1_003");
    assertEq(harness.exitDebtRequired(10_000), 10_011, "10_000");
    assertEq(harness.exitDebtRequired(500e6), 500e6 + 0.5e6 + 1, "500e6");
  }

  function testFuzz_exitDebtRequired_isDebtPlusTenBpsUpPlusOne(uint256 debt) public view {
    debt = bound(debt, 1, type(uint256).max / 10);
    assertEq(harness.exitDebtRequired(debt), debt + (debt + 999) / 1_000 + 1, "required");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      ENTRY POOL STATE                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_entryPoolState_badDebtThenEmptyThenUnlevered(
    bool badDebt,
    bool empty,
    bool unlevered,
    bool allowUnlevered,
    uint256 collateral,
    uint256 debt
  ) public {
    collateral = empty ? 0 : bound(collateral, 1, type(uint256).max);
    debt = unlevered ? 0 : bound(debt, 1, type(uint256).max);
    ViewPmStub pm = new ViewPmStub();
    pm.setPool(badDebt, collateral, debt);

    bytes memory err;
    if (badDebt) {
      err = abi.encodeWithSelector(IInKindFacility.BadDebtState.selector, address(pm));
    } else if (empty) {
      err = abi.encodeWithSelector(IInKindFacility.EmptyPool.selector, address(pm));
    } else if (unlevered && !allowUnlevered) {
      err = abi.encodeWithSelector(IInKindFacility.UnleveredEntryDisabled.selector, address(pm));
    }

    if (err.length > 0) vm.expectRevert(err);
    (uint256 totalCollateral, uint256 totalDebt) = harness.entryPoolState(address(pm), allowUnlevered);
    if (err.length == 0) {
      assertEq(totalCollateral, collateral, "totalCollateral");
      assertEq(totalDebt, debt, "totalDebt");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         SHARE MATH                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_fairMint_exactExpectedAndTolerance() public {
    ViewPmStub pm = new ViewPmStub();
    pm.setPendingFees(31_999_999, 1_000e18 + 1, 2e18, 3e18);
    pm.setTotalAssets(31_999_999);
    pm.setVirtualShareOffset(1e12);
    // supplyAdj = 1_005_000_001_000_000_000_001
    (uint256 expected, uint256 tolerance) = harness.fairMint(address(pm), 250e18, 10_000e18);
    assertEq(expected, 25_125_000_025_000_000_000, "expected = floor(supplyAdj * amount / C)");
    assertEq(tolerance, 1_005_000_001_000_002, "tolerance = ceil(supplyAdj * 32 / (TA + 1)) + 1");
  }

  function test_estimateShares_countsPendingFeeShares() public {
    ViewPmStub pm = new ViewPmStub();
    pm.setPendingFees(5_000e6, 5_000e18, 10e18, 20e18);
    pm.setCollateralAmountQuoted(10_000e6);
    pm.setVirtualShareOffset(1e12);
    // floor(600e6 equity * (5_030e18 + 1e12) / (5_000e6 + 1))
    assertEq(harness.estimateShares(address(pm), 1_000e18, 10_000e18, 400e6), 603_599_999_999_280_000_000, "shares");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _assertSplit(uint256 shares, uint24 bps, uint256 expectedNet, uint256 expectedFee) internal view {
    (uint256 net, uint256 fee) = harness.splitFee(shares, bps);
    assertEq(net, expectedNet, "net");
    assertEq(fee, expectedFee, "fee");
  }
}
