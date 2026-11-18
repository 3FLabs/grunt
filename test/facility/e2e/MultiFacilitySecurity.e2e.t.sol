// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Vm} from "forge-std/Vm.sol";
import {InKindFacilityBaseTest} from "test/facility/inkind/InKindFacilityBase.t.sol";
import {InKindFacility} from "src/facility/inkind/InKindFacility.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title MultiFacilitySecurityE2ETest
/// @notice Two InKindFacility clones of one implementation, each serving its own PM over the
///         same underlying, share one EXTERNAL absolute security pool: the pool bounds their
///         combined in-kind borrowing while auths stay per clone.
contract MultiFacilitySecurityE2ETest is InKindFacilityBaseTest {
  using FixedPointMathLib for uint256;
  using LibClone for address;

  uint128 constant SHARED_SECURITY = 2_000e6;
  // PM2 runs at a 0.6 debt-per-collateral ratio, PM at 0.5
  uint256 constant SEED_DEBT_2 = 6_000e6;

  InKindFacility facility2;

  function setUp() public override {
    super.setUp();
    facility2 = InKindFacility(address(implementation).clone());
    facility2.initialize(owner, facilitator, feeRecipient);

    vm.startPrank(owner);
    facility2.grantRoles(operator, FACILITY_OPERATOR_ROLE);
    absoluteCaps.grantRoles(address(facility2), CAPS_CONSUMER_ROLE);
    positionManager2.grantRoles(address(facility2), PM_MINTER_ROLE);
    collateralToken.grantRoles(address(facility2), WA_SENDER_ROLE);
    absoluteCaps.setCap(SECURITY_POOL_ID, uint128(_capsUnits(SHARED_SECURITY)), uint128(_capsUnits(SHARED_SECURITY)));
    vm.stopPrank();

    _seedPool(positionManager, SEED_COLLATERAL, SEED_DEBT);
    _seedPool(positionManager2, SEED_COLLATERAL, SEED_DEBT_2);
    _openClone(facility, positionManager);
    _openClone(facility2, positionManager2);
  }

  function test_sharedSecurity_bothClonesChargeOnePool() public {
    uint256 debt1 = _debtFor(positionManager, 1_000e18);
    uint256 debt2 = _debtFor(positionManager2, 1_000e18);

    _fundFor(facility, user, 1_000e18);
    _expectSecurityCharge(debt1, SHARED_SECURITY - debt1);
    _enterFunded(facility, positionManager, user, 1_000e18);
    _fundFor(facility2, user, 1_000e18);
    _expectSecurityCharge(debt2, SHARED_SECURITY - debt1 - debt2);
    _enterFunded(facility2, positionManager2, user, 1_000e18);

    assertEq(_securityLeft(), SHARED_SECURITY - debt1 - debt2, "pool not charged by both clones");
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)), _securityWord(), "clone 1 word rewritten"
    );
    assertEq(
      facility2.getSecurityCap(address(underlyingToken), address(debtToken)), _securityWord(), "clone 2 word rewritten"
    );
    _assertClonesClean();
  }

  function test_sharedSecurity_drainByOneCloneBlocksTheOther() public {
    uint256 debt1 = _debtFor(positionManager, 3_000e18);
    _enterVia(facility, positionManager, user, 3_000e18);
    uint256 left = SHARED_SECURITY - debt1;
    assertGt(_debtFor(positionManager2, 1_000e18), left, "entry must overflow the pool");

    _fundFor(facility2, receiver, 1_000e18);
    vm.prank(receiver);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, uint64(SECURITY_POOL_ID)));
    facility2.enter(address(positionManager2), 1_000e18, 0, type(uint256).max, 0, receiver);
    assertEq(_securityLeft(), left, "reverted entry touched the pool");
    assertEq(facility2.getEntry(address(positionManager2)).capacityCap, LibCaps.MAX_ABSOLUTE, "capacity touched");

    uint256 debt2 = _debtFor(positionManager2, 800e18);
    _expectSecurityCharge(debt2, left - debt2);
    vm.prank(receiver);
    facility2.enter(address(positionManager2), 800e18, debt2, debt2, 0, receiver);
    assertEq(_securityLeft(), left - debt2, "pool after the fitting entry");
  }

  function test_sharedSecurity_maxEnterQuotesWhatTheOtherCloneLeft() public {
    assertEq(
      facility2.maxEnter(address(positionManager2), receiver),
      uint256(SHARED_SECURITY).mulDiv(positionManager2.collateralAmount(), positionManager2.debtAmount()),
      "quote before"
    );
    uint256 debt1 = _debtFor(positionManager, 2_000e18);
    _enterVia(facility, positionManager, user, 2_000e18);

    uint256 quote = facility2.maxEnter(address(positionManager2), receiver);
    assertEq(
      quote,
      (SHARED_SECURITY - debt1).mulDiv(positionManager2.collateralAmount(), positionManager2.debtAmount()),
      "quote after the other clone borrowed"
    );
    uint256 debt2 = _debtFor(positionManager2, quote);
    _enterVia(facility2, positionManager2, receiver, quote);
    assertEq(_securityLeft(), SHARED_SECURITY - debt1 - debt2, "quoted entry did not fit");
  }

  function test_sharedSecurity_authsStayPerClone() public {
    vm.prank(operator);
    facility.setAuth(address(underlyingToken), address(debtToken), user, 400e6, FAR_EXPIRY);

    uint256 debt2 = _debtFor(positionManager2, 1_000e18);
    _fundFor(facility2, user, 1_000e18);
    _expectSecurityCharge(debt2, SHARED_SECURITY - debt2);
    vm.recordLogs();
    _enterFunded(facility2, positionManager2, user, 1_000e18);
    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      assertFalse(
        logs[i].topics.length > 0 && logs[i].topics[0] == IInKindFacility.AuthConsumed.selector,
        "clone 2 consumed an auth"
      );
    }
    assertEq(
      facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 400e6, "clone 2 spent clone 1's auth"
    );
    assertEq(facility2.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "clone 2 auth");

    uint256 debt1 = _debtFor(positionManager, 1_000e18);
    _fundFor(facility, user, 1_000e18);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.AuthConsumed(address(underlyingToken), address(debtToken), user, 400e6, 0);
    _expectSecurityCharge(debt1 - 400e6, SHARED_SECURITY - debt2 - (debt1 - 400e6));
    _enterFunded(facility, positionManager, user, 1_000e18);
  }

  function test_sharedSecurity_exitsOnEitherCloneRefundNothing() public {
    _enterVia(facility, positionManager, user, 1_000e18);
    _enterVia(facility2, positionManager2, receiver, 1_000e18);
    uint256 left = _securityLeft();

    _exitVia(facility, positionManager, user, positionManager.balanceOf(user));
    _exitVia(facility2, positionManager2, receiver, positionManager2.balanceOf(receiver));

    assertEq(positionManager.balanceOf(user), 0, "clone 1 exit");
    assertEq(positionManager2.balanceOf(receiver), 0, "clone 2 exit");
    assertEq(_securityLeft(), left, "an exit refunded the shared pool");
    _assertClonesClean();
  }

  function testFuzz_sharedSecurity_combinedBorrowingNeverExceedsThePool(uint256[6] memory amounts, uint8 routing)
    public
  {
    uint256 borrowed;
    for (uint256 i = 0; i < amounts.length; i++) {
      bool second = (routing >> i) & 1 == 1;
      InKindFacility f = second ? facility2 : facility;
      PositionManager pm = second ? positionManager2 : positionManager;
      address who = makeAddr(string(abi.encodePacked("entrant", i)));
      uint256 amount = bound(amounts[i], 1e18, 2_500e18);
      uint256 debt = _debtFor(pm, amount);

      if (borrowed + debt > SHARED_SECURITY) {
        _fundFor(f, who, amount);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, uint64(SECURITY_POOL_ID)));
        f.enter(address(pm), amount, 0, type(uint256).max, 0, who);
        assertEq(debtToken.balanceOf(who), 0, "reverted entry paid debt");
      } else {
        _enterVia(f, pm, who, amount);
        borrowed += debt;
        assertEq(debtToken.balanceOf(who), debt, "debt leg");
      }
      assertEq(_securityLeft(), SHARED_SECURITY - borrowed, "pool != cap - combined borrowing");
    }
    _assertClonesClean();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _securityWord() internal view returns (uint256) {
    return LibCaps.encodeExternal(address(absoluteCaps), SECURITY_POOL_ID, MULT_1X);
  }

  /// @dev Remaining shared security, in debt units.
  function _securityLeft() internal view returns (uint256) {
    return _absCap(SECURITY_POOL_ID);
  }

  /// @dev Opens both sides of `pm` on `f` with unbounded ABSOLUTE words and the shared security word.
  function _openClone(InKindFacility f, PositionManager pm) internal {
    vm.startPrank(facilitator);
    f.setEntry(address(pm), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
    f.setExit(address(pm), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.stopPrank();
    vm.prank(operator);
    f.setSecurityCap(address(underlyingToken), address(debtToken), _securityWord());
  }

  function _debtFor(PositionManager pm, uint256 amount) internal view returns (uint256) {
    return amount.mulDiv(pm.debtAmount(), pm.collateralAmount());
  }

  function _expectSecurityCharge(uint256 debt, uint256 newCap) internal {
    vm.expectEmit(true, true, true, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(
      SECURITY_POOL_ID, _capsUnits(debt), MULT_1X, _capsUnits(debt), uint128(_capsUnits(newCap))
    );
  }

  function _fundFor(InKindFacility f, address who, uint256 amount) internal {
    underlyingToken.setBalance(who, underlyingToken.balanceOf(who) + amount);
    vm.prank(who);
    underlyingToken.approve(address(f), amount);
  }

  function _enterVia(InKindFacility f, PositionManager pm, address who, uint256 amount) internal {
    _fundFor(f, who, amount);
    _enterFunded(f, pm, who, amount);
  }

  function _enterFunded(InKindFacility f, PositionManager pm, address who, uint256 amount) internal {
    vm.prank(who);
    f.enter(address(pm), amount, 0, type(uint256).max, 0, who);
  }

  function _exitVia(InKindFacility f, PositionManager pm, address who, uint256 shares) internal {
    debtToken.setBalance(who, debtToken.balanceOf(who) + 10_000e6);
    vm.startPrank(who);
    debtToken.approve(address(f), 10_000e6);
    pm.approve(address(f), shares);
    f.exit(address(pm), shares, type(uint256).max, 0, who, "");
    vm.stopPrank();
  }

  function _assertClonesClean() internal view {
    _assertFacilityClean();
    _assertNoAllowances();
    assertEq(underlyingToken.balanceOf(address(facility2)), 0, "clone 2 holds underlying");
    assertEq(collateralToken.balanceOf(address(facility2)), 0, "clone 2 holds wrapper");
    assertEq(debtToken.balanceOf(address(facility2)), 0, "clone 2 holds debt asset");
    assertEq(positionManager.balanceOf(address(facility2)), 0, "clone 2 holds PM shares");
    assertEq(positionManager2.balanceOf(address(facility2)), 0, "clone 2 holds PM2 shares");
    assertEq(underlyingToken.allowance(address(facility2), address(collateralToken)), 0, "clone 2 underlying allowance");
    assertEq(collateralToken.allowance(address(facility2), address(positionManager2)), 0, "clone 2 wrapper allowance");
    assertEq(debtToken.allowance(address(facility2), address(positionManager2)), 0, "clone 2 debt allowance");
  }
}
