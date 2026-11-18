// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title InKindFacilityEnterFuzzTest
/// @notice Fuzzed entries on single-module PMs at 18/6, 18/18, 6/18 and 8/6 decimals, with PM
///         fees, interest and a reprice up to just below the PM's target LTV, or around it.
contract InKindFacilityEnterFuzzTest is InKindFacilityBaseTest {
  using FixedPointMathLib for uint256;
  using MarketParamsLib for MarketParams;
  using LibClone for address;

  /// @dev Over-mint a single-module PM may reach: one unit for the floored debt, one for the module.
  uint256 constant SINGLE_MODULE_UNITS = 2;
  /// @dev Strictly below POSITION_MANAGER_LTV once the oracle price floors.
  uint256 constant MAX_LTV = 0.699e18;
  /// @dev Debt units around the target LTV within which the borrow module's rounding, not the
  ///      quoted LTV, decides whether an entry fits.
  uint256 constant TARGET_ROUNDING_UNITS = 3;

  struct Stack {
    PositionManager pm;
    MockERC20 underlying;
    MockERC20 debt;
    WrappedAsset wrapper;
    OracleMock oracle;
    uint256 unitPrice;
    uint256 collateralUnit;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The base fixture (18/6) or a fresh single-module stack, with open caps and offer.
  function _stack(uint256 seed) internal returns (Stack memory st) {
    seed = bound(seed, 0, 3);
    if (seed == 0) {
      st = Stack(positionManager, underlyingToken, debtToken, collateralToken, oracle, DEFAULT_ORACLE_PRICE, 1e18);
      _setSecurityCap(LibCaps.MAX_ABSOLUTE);
    } else if (seed == 1) {
      st = _deployStack(18, 18);
    } else if (seed == 2) {
      st = _deployStack(6, 18);
    } else {
      st = _deployStack(8, 6);
    }
    _setEntry(st.pm, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
  }

  function _deployStack(uint8 collateralDecimals, uint8 debtDecimals) internal returns (Stack memory st) {
    return _deployStackOn(new MockERC20("Underlying B", "UNDB", collateralDecimals), debtDecimals);
  }

  /// @dev A fresh single-module stack wrapping `underlying` and borrowing a new debt token.
  function _deployStackOn(MockERC20 underlying, uint8 debtDecimals) internal returns (Stack memory st) {
    uint8 collateralDecimals = underlying.decimals();
    st.underlying = underlying;
    st.debt = new MockERC20("Debt B", "DEBTB", debtDecimals);
    st.wrapper = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    st.wrapper.initialize(owner, address(0), address(st.underlying), "wUNDB", "Wrapped UNDB");
    st.unitPrice = 10 ** (36 + uint256(debtDecimals) - uint256(collateralDecimals));
    st.collateralUnit = 10 ** uint256(collateralDecimals);
    st.oracle = new OracleMock();
    st.oracle.setPrice(st.unitPrice);
    MarketParams memory params = MarketParams({
      loanToken: address(st.debt),
      collateralToken: address(st.wrapper),
      oracle: address(st.oracle),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });
    morpho.createMarket(params);

    PositionManagerMetadata memory metadata = PositionManagerMetadata({
      name: "PMB", symbol: "PMB", collateralAsset: address(st.wrapper), debtAsset: address(st.debt)
    });
    st.pm = PositionManager(address(new PositionManager()).clone());
    st.pm.initialize(owner, metadata, POSITION_MANAGER_LTV, address(transferGuard), 0, 0);
    address bp =
      borrowPositionFactory.createBorrowPosition(params.id(), address(st.pm), BP_SAFE_LTV, BP_LIQUIDATION_LTV);

    vm.startPrank(owner);
    st.pm.grantRoles(owner, PM_CURATOR_ROLE);
    st.pm.addBorrowModule(bp);
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](1);
    supplyQueue[0] = SupplyQueueEntry({position: bp, maxBorrow: type(uint96).max});
    st.pm.setSupplyQueue(supplyQueue);
    address[] memory withdrawalQueue = new address[](1);
    withdrawalQueue[0] = bp;
    st.pm.setWithdrawalQueue(withdrawalQueue);
    st.pm.grantRoles(address(facility), PM_MINTER_ROLE);
    st.pm.grantRoles(seeder, PM_MINTER_ROLE);
    st.wrapper.grantRoles(address(st.pm), WA_SENDER_ROLE);
    st.wrapper.grantRoles(bp, WA_SENDER_ROLE);
    st.wrapper.grantRoles(address(morpho), WA_SENDER_ROLE);
    st.wrapper.grantRoles(address(facility), WA_SENDER_ROLE);
    st.wrapper.grantRoles(seeder, WA_SENDER_ROLE);
    vm.stopPrank();

    uint256 liquidity = 1_000_000 * 10 ** uint256(debtDecimals);
    st.debt.setBalance(address(this), liquidity);
    st.debt.approve(address(morpho), liquidity);
    morpho.supply(params, liquidity, 0, address(this), "");

    vm.prank(operator);
    facility.setSecurityCap(address(st.underlying), address(st.debt), LibCaps.MAX_ABSOLUTE);
  }

  /// @dev Seeds 1_000 to 50_000 collateral units at a quoted LTV in [10%, MAX_LTV].
  function _seed(Stack memory st, uint256 collateralSeed, uint256 ltvSeed) internal {
    uint256 collateral = bound(collateralSeed, 1_000 * st.collateralUnit, 50_000 * st.collateralUnit);
    uint256 debt = collateral.mulDiv(st.unitPrice, 1e36).mulDiv(bound(ltvSeed, 0.1e18, MAX_LTV), 1e18);
    st.underlying.setBalance(seeder, collateral);
    vm.startPrank(seeder);
    st.underlying.approve(address(st.wrapper), collateral);
    st.wrapper.mint(seeder, collateral);
    st.wrapper.approve(address(st.pm), collateral);
    st.pm.deposit(collateral, debt);
    vm.stopPrank();
  }

  /// @dev A seeded pool with PM fees and accrued interest, repriced to an LTV in [10%, MAX_LTV].
  function _leveredStack(uint256[7] memory seeds) internal returns (Stack memory st) {
    st = _accruedStack(seeds);
    uint256 ltv = bound(seeds[6], 0.1e18, MAX_LTV);
    st.oracle.setPrice(st.pm.debtAmount().mulDiv(1e54, st.pm.collateralAmount() * ltv));
  }

  /// @dev A seeded pool with PM fees and accrued interest, at its seeding price.
  function _accruedStack(uint256[7] memory seeds) internal returns (Stack memory st) {
    st = _stack(seeds[0]);
    vm.prank(owner);
    st.pm.setFeeData(pmFeeRecipient, uint24(bound(seeds[1], 0, 200)), uint24(bound(seeds[2], 0, 5_000)));
    _seed(st, seeds[3], seeds[4]);
    vm.warp(vm.getBlockTimestamp() + bound(seeds[5], 0, 365 days));
  }

  /// @dev Reprices `st` so the debt sits `headroomMilli` thousandths of a debt unit below what
  ///      the target LTV allows on the exact collateral value.
  function _repriceAroundTarget(Stack memory st, int256 headroomMilli) internal {
    uint256 scaledDebt = uint256(int256(st.pm.debtAmount() * 1_000) + headroomMilli);
    st.oracle.setPrice(scaledDebt.fullMulDiv(1e54, st.pm.collateralAmount() * POSITION_MANAGER_LTV * 1_000));
  }

  /// @dev Share slack of the preview estimate: `2 + a / C` debt-wei of equity, plus one share.
  function _previewSlack(PositionManager pm, uint256 amount) internal view returns (uint256) {
    return _adjustedSupply(pm).mulDivUp(2 + amount.divUp(pm.collateralAmount()), pm.totalAssets() + 1) + 1;
  }

  function _adjustedSupply(PositionManager pm) internal view returns (uint256) {
    (, uint256 supply, uint256 mgmtShares, uint256 perfShares) = pm.pendingFees();
    return supply + mgmtShares + perfShares + pm.virtualShareOffset();
  }

  /// @dev The fair fraction `S_adj * amount / C` plus `units` debt-wei of equity in shares.
  function _fairMintPlus(PositionManager pm, uint256 amount, uint256 units) internal view returns (uint256) {
    uint256 supplyAdj = _adjustedSupply(pm);
    return supplyAdj.mulDiv(amount, pm.collateralAmount()) + supplyAdj.mulDivUp(units, pm.totalAssets() + 1);
  }

  function _fund(Stack memory st, uint256 amount) internal {
    st.underlying.setBalance(user, amount);
    vm.prank(user);
    st.underlying.approve(address(facility), amount);
  }

  /// @dev Enters `amount` as `user` and returns the gross mint (net plus fee shares).
  function _enterGross(Stack memory st, uint256 amount) internal returns (uint256 minted, uint256 debt) {
    _fund(st, amount);
    uint256 feeBefore = st.pm.balanceOf(feeRecipient);
    vm.prank(user);
    (uint256 shares, uint256 debt_) = facility.enter(address(st.pm), amount, 0, type(uint256).max, 0, user);
    return (shares + st.pm.balanceOf(feeRecipient) - feeBefore, debt_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_enter_securityBudgetsAreKeyedByDebtAsset() public {
    // PM B wraps the base fixture's underlying but borrows an 18-decimal debt token
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
    _setSecurityCap(1_000e6);
    _setAuth(user, 100e6, FAR_EXPIRY);
    Stack memory b = _deployStackOn(underlyingToken, 18);
    _setEntry(b.pm, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _seed(b, 10_000e18, 0.5e18);

    // the USDC-sized budget and auth do not open PM B: its pair is unset, so closed
    vm.prank(operator);
    facility.setSecurityCap(address(underlyingToken), address(b.debt), 0);
    uint256 amount = 100e18;
    (uint256 debtB,,) = facility.previewEnter(address(b.pm), amount);
    assertGt(debtB, 0, "levered");
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibFacilityErrors.CapExceeded.selector, uint256(uint160(address(underlyingToken))), 0, debtB
      )
    );
    facility.enter(address(b.pm), amount, 0, type(uint256).max, 0, user);

    // a budget on B's pair is spent in B's units and leaves the base pair untouched
    vm.prank(operator);
    facility.setSecurityCap(address(underlyingToken), address(b.debt), 1_000e18);
    (, uint256 borrowed) = _enter(b.pm, user, amount, user);
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(b.debt)), 1_000e18 - borrowed, "B budget consumed"
    );
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 1_000e6, "base budget untouched");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 100e6, "base auth untouched");
    assertEq(facility.getAuth(address(underlyingToken), address(b.debt), user).amount, 0, "no auth on B's pair");
  }

  /// @notice DustEntry iff `floor(a * D / C) == 0`. Otherwise the entry borrows that debt and
  ///         mints within two units of the fair fraction, or the PM mints nothing on a fair
  ///         fraction below `(2 * S_adj + 1) / TA` and it reverts InsufficientSharesOut(0, 0).
  function testFuzz_enter_dustEntryIffRatioDebtFloorsToZero(uint256[7] memory seeds, uint256 amount) public {
    Stack memory st = _leveredStack(seeds);
    uint256 totalCollateral = st.pm.collateralAmount();
    uint256 totalDebt = st.pm.debtAmount();
    amount = bound(amount, 1, 4 * totalCollateral.divUp(totalDebt));
    uint256 debt = amount.mulDiv(totalDebt, totalCollateral);
    uint256 maxMint = _fairMintPlus(st.pm, amount, SINGLE_MODULE_UNITS);
    uint256 expected = _fairMintPlus(st.pm, amount, 0);
    uint256 zeroMintBound = (2 * _adjustedSupply(st.pm) + 1).divUp(st.pm.totalAssets());
    _fund(st, amount);

    if (debt == 0) {
      vm.prank(user);
      vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DustEntry.selector, amount));
      facility.enter(address(st.pm), amount, 0, type(uint256).max, 0, user);
      return;
    }
    vm.prank(user);
    try facility.enter(address(st.pm), amount, 0, type(uint256).max, 0, user) returns (uint256 shares, uint256 got) {
      assertEq(got, debt, "debt");
      assertEq(st.debt.balanceOf(user), debt, "receiver debt");
      assertLe(shares + st.pm.balanceOf(feeRecipient), maxMint, "over-mint above two units");
    } catch (bytes memory err) {
      assertEq(err, abi.encodeWithSelector(IInKindFacility.InsufficientSharesOut.selector, 0, 0), "revert");
      assertLe(expected, zeroMintBound, "zero mint on a non-dust fair fraction");
    }
  }

  /// @notice The entry succeeds and over-mints by at most two debt-wei of equity, far inside the
  ///         NonNeutralMint gate.
  function testFuzz_enter_neverNonNeutralOnASingleModulePm(uint256[7] memory seeds, uint256 amount) public {
    Stack memory st = _leveredStack(seeds);
    amount = bound(amount, st.pm.collateralAmount() / 1e6 + 1, 5 * st.pm.collateralAmount());
    uint256 maxMint = _fairMintPlus(st.pm, amount, SINGLE_MODULE_UNITS);

    (uint256 minted,) = _enterGross(st, amount);
    assertLe(minted, maxMint, "over-mint above two units");
  }

  /// @notice previewEnter's debt is exact and its gross shares are within `2 + a / C` debt-wei of
  ///         equity of the mint.
  function testFuzz_previewEnter_tracksTheMint(uint256[7] memory seeds, uint256 amount) public {
    Stack memory st = _leveredStack(seeds);
    uint256 totalCollateral = st.pm.collateralAmount();
    amount = bound(amount, totalCollateral / 1e6 + 1, 5 * totalCollateral);
    uint256 slack = _previewSlack(st.pm, amount);
    (uint256 previewDebt, uint256 previewShares, uint256 previewFee) = facility.previewEnter(address(st.pm), amount);

    (uint256 minted, uint256 debt) = _enterGross(st, amount);
    assertEq(previewDebt, debt, "preview debt");
    assertApproxEqAbs(previewShares + previewFee, minted, slack, "preview mint");
  }

  /// @notice previewEnter's (debt, shares) passed as enter's (minDebt, maxDebt, minSharesOut), the
  ///         shares less the estimate slack, always pass, and each field matches the execution.
  function testFuzz_previewEnter_valuesFollowEnterBoundsOrder(uint256[7] memory seeds, uint256 amount) public {
    Stack memory st = _leveredStack(seeds);
    uint256 totalCollateral = st.pm.collateralAmount();
    amount = bound(amount, totalCollateral / 1e6 + 1, 5 * totalCollateral);
    uint256 slack = _previewSlack(st.pm, amount) + 1;
    (uint256 debt, uint256 shares, uint256 feeShares) = facility.previewEnter(address(st.pm), amount);
    _fund(st, amount);
    uint256 feeBefore = st.pm.balanceOf(feeRecipient);

    vm.prank(user);
    (uint256 sharesOut, uint256 debtOut) =
      facility.enter(address(st.pm), amount, debt, debt, shares.zeroFloorSub(slack), user);
    assertEq(debtOut, debt, "debt");
    assertApproxEqAbs(sharesOut, shares, slack, "shares");
    assertApproxEqAbs(st.pm.balanceOf(feeRecipient) - feeBefore, feeShares, slack, "fee shares");
  }

  /// @notice Around the PM target LTV, maxEnter is zero exactly when the quoted LTV is above it,
  ///         where previewEnter reverts InsufficientBorrowCapacity. Clear of the module rounding,
  ///         enter reverts InsufficientBorrowCapacity above the target and fills at
  ///         previewEnter's debt below it.
  function testFuzz_maxEnter_zeroAboveTargetLtvWhereEntriesRevert(
    uint256[7] memory seeds,
    int256 headroomMilli,
    uint256 amount
  ) public {
    Stack memory st = _accruedStack(seeds);
    uint256 totalDebt = st.pm.debtAmount();
    int256 span = seeds[6] % 2 == 0 ? int256(20_000) : int256(totalDebt * 50);
    _repriceAroundTarget(st, bound(headroomMilli, -span, span));
    uint256 totalCollateral = st.pm.collateralAmount();
    amount = bound(amount, (totalCollateral / 1e6 + 1).max(totalCollateral.divUp(totalDebt)), 5 * totalCollateral);
    uint256 room = st.pm.collateralAmountQuoted() * POSITION_MANAGER_LTV;
    bool above = totalDebt * 1e18 > room;
    bool inBand =
      room < (totalDebt + TARGET_ROUNDING_UNITS) * 1e18 && room + TARGET_ROUNDING_UNITS * 1e18 > totalDebt * 1e18;
    bytes memory capacityErr = abi.encodeWithSelector(LibManagerErrors.InsufficientBorrowCapacity.selector);

    assertEq(facility.maxEnter(address(st.pm), user) == 0, above, "maxEnter zero iff above target");
    uint256 previewDebt;
    if (above) {
      vm.expectRevert(capacityErr);
      facility.previewEnter(address(st.pm), amount);
    } else {
      (previewDebt,,) = facility.previewEnter(address(st.pm), amount);
    }
    _fund(st, amount);
    vm.prank(user);
    try facility.enter(address(st.pm), amount, 0, type(uint256).max, 0, user) returns (uint256, uint256 debt) {
      assertTrue(!above || inBand, "entered above target");
      if (!above) assertEq(debt, previewDebt, "debt");
    } catch (bytes memory err) {
      assertEq(err, capacityErr, "revert");
      assertTrue(above || inBand, "reverted below target");
    }
  }
}
