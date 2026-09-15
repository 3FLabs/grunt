// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {BorrowOffersRegistry} from "src/borrow/BorrowOffersRegistry.sol";
import {IBorrowOffersRegistry} from "src/interfaces/borrow/IBorrowOffersRegistry.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title BorrowOffersRegistryTest
/// @notice Unit test suite for the BorrowOffersRegistry contract (roles and per-collateral
///         offer configuration behind an ERC1967 proxy).
contract BorrowOffersRegistryTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  BorrowOffersRegistry public registry;
  BorrowOffersRegistry public implementation;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public proposer;
  address public guardian;
  address public stranger;
  address public collateralA;
  address public collateralB;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ERROR SELECTORS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // LibCommonErrors
  error AddressZero();

  // LibBorrowErrors
  error OfferTimelockOutOfRange();
  error MinOfferBonusOutOfRange();

  // Solady Initializable errors
  error InvalidInitialization();

  // Solady Ownable errors
  error Unauthorized();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    // Create test addresses
    owner = makeAddr("owner");
    proposer = makeAddr("proposer");
    guardian = makeAddr("guardian");
    stranger = makeAddr("stranger");
    collateralA = makeAddr("collateralA");
    collateralB = makeAddr("collateralB");

    // Deploy the registry behind an ERC1967 proxy, as in production
    implementation = new BorrowOffersRegistry();
    registry = BorrowOffersRegistry(LibClone.deployERC1967(address(implementation)));
    registry.initialize(owner);

    // Label contracts
    vm.label(address(registry), "BorrowOffersRegistry");
    vm.label(address(implementation), "RegistryImplementation");
    vm.label(owner, "Owner");
    vm.label(proposer, "Proposer");
    vm.label(guardian, "Guardian");
    vm.label(stranger, "Stranger");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INITIALIZATION TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_SetsOwner() public view {
    assertEq(registry.owner(), owner, "owner should be set by initialize");
  }

  function test_Initialize_RevertsOnZeroOwner() public {
    BorrowOffersRegistry fresh = BorrowOffersRegistry(LibClone.deployERC1967(address(implementation)));
    vm.expectRevert(AddressZero.selector);
    fresh.initialize(address(0));
  }

  function test_Initialize_RevertsOnDoubleInitialize() public {
    vm.expectRevert(InvalidInitialization.selector);
    registry.initialize(stranger);
  }

  function test_Initialize_DisabledOnImplementation() public {
    // The raw implementation has its initializers disabled in the constructor
    vm.expectRevert(InvalidInitialization.selector);
    implementation.initialize(owner);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ROLE TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_SetProposer_OnlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert(Unauthorized.selector);
    registry.setProposer(proposer, true);
  }

  function test_SetProposer_ProposerCannotSelfManage() public {
    vm.prank(owner);
    registry.setProposer(proposer, true);

    // Holding the proposer role grants no admin power over the role book
    vm.prank(proposer);
    vm.expectRevert(Unauthorized.selector);
    registry.setProposer(stranger, true);
  }

  function test_SetProposer_RevertsOnZeroAccount() public {
    vm.prank(owner);
    vm.expectRevert(AddressZero.selector);
    registry.setProposer(address(0), true);
  }

  function test_SetGuardian_OnlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert(Unauthorized.selector);
    registry.setGuardian(guardian, true);
  }

  function test_SetGuardian_GuardianCannotSelfManage() public {
    vm.prank(owner);
    registry.setGuardian(guardian, true);

    vm.prank(guardian);
    vm.expectRevert(Unauthorized.selector);
    registry.setGuardian(stranger, true);
  }

  function test_SetGuardian_RevertsOnZeroAccount() public {
    vm.prank(owner);
    vm.expectRevert(AddressZero.selector);
    registry.setGuardian(address(0), true);
  }

  function test_CheckCanCreateOffer_ProposerRoundTrip() public {
    // Not a proposer yet: rejected
    vm.expectRevert(Unauthorized.selector);
    registry.checkCanCreateOffer(proposer);

    // Enabled: passes (no revert)
    vm.prank(owner);
    registry.setProposer(proposer, true);
    registry.checkCanCreateOffer(proposer);
    assertTrue(registry.hasAnyRole(proposer, registry.PROPOSER_ROLE()), "proposer role bit should be set");

    // Disabled again: rejected
    vm.prank(owner);
    registry.setProposer(proposer, false);
    vm.expectRevert(Unauthorized.selector);
    registry.checkCanCreateOffer(proposer);
  }

  function test_CanRevokeOffer_GuardianRoundTrip() public {
    // Not a guardian yet: no revoke power
    assertFalse(registry.canRevokeOffer(guardian), "non-guardian should have no revoke power");

    // Enabled: revoke power granted
    vm.prank(owner);
    registry.setGuardian(guardian, true);
    assertTrue(registry.canRevokeOffer(guardian), "guardian should have revoke power");
    assertTrue(registry.hasAnyRole(guardian, registry.GUARDIAN_ROLE()), "guardian role bit should be set");

    // Disabled again: revoke power revoked
    vm.prank(owner);
    registry.setGuardian(guardian, false);
    assertFalse(registry.canRevokeOffer(guardian), "removed guardian should lose revoke power");
  }

  function test_Checks_OwnerPassesWithoutRoles() public view {
    // The owner is authorized by derivation, without holding any role bit
    assertEq(registry.rolesOf(owner), 0, "owner should hold no explicit role");
    registry.checkCanCreateOffer(owner);
    assertTrue(registry.canRevokeOffer(owner), "owner should have revoke power by derivation");
  }

  function test_Checks_StrangerRejected() public {
    vm.expectRevert(Unauthorized.selector);
    registry.checkCanCreateOffer(stranger);

    assertFalse(registry.canRevokeOffer(stranger), "stranger should have no revoke power");
  }

  function test_Checks_RoleSeparation() public {
    vm.startPrank(owner);
    registry.setProposer(proposer, true);
    registry.setGuardian(guardian, true);
    vm.stopPrank();

    // A proposer holds no batch-wide revoke power (it may still revoke its own offers)
    assertFalse(registry.canRevokeOffer(proposer), "proposer should have no revoke power");

    // A guardian cannot create offers
    vm.expectRevert(Unauthorized.selector);
    registry.checkCanCreateOffer(guardian);
  }

  function test_ConfigSetters_RoleHoldersRejected() public {
    vm.startPrank(owner);
    registry.setProposer(proposer, true);
    registry.setGuardian(guardian, true);
    vm.stopPrank();

    // Offer roles confer no configuration power: only the owner may configure collaterals
    vm.startPrank(proposer);
    vm.expectRevert(Unauthorized.selector);
    registry.setOfferTimelock(collateralA, 1 hours);
    vm.expectRevert(Unauthorized.selector);
    registry.setMinOfferBonus(collateralA, 500);
    vm.stopPrank();

    vm.startPrank(guardian);
    vm.expectRevert(Unauthorized.selector);
    registry.setOfferTimelock(collateralA, 1 hours);
    vm.expectRevert(Unauthorized.selector);
    registry.setMinOfferBonus(collateralA, 500);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    OFFER TIMELOCK TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_SetOfferTimelock_OnlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert(Unauthorized.selector);
    registry.setOfferTimelock(collateralA, 1 hours);
  }

  function test_SetOfferTimelock_RevertsOnZeroCollateral() public {
    vm.prank(owner);
    vm.expectRevert(AddressZero.selector);
    registry.setOfferTimelock(address(0), 1 hours);
  }

  function test_SetOfferTimelock_RevertsBelowMin() public {
    uint40 belowMin = registry.MIN_OFFER_TIMELOCK() - 1;
    vm.prank(owner);
    vm.expectRevert(OfferTimelockOutOfRange.selector);
    registry.setOfferTimelock(collateralA, belowMin);
  }

  function test_SetOfferTimelock_RevertsAboveMax() public {
    uint40 aboveMax = registry.MAX_OFFER_TIMELOCK() + 1;
    vm.prank(owner);
    vm.expectRevert(OfferTimelockOutOfRange.selector);
    registry.setOfferTimelock(collateralA, aboveMax);
  }

  function test_SetOfferTimelock_AcceptsBounds() public {
    vm.startPrank(owner);
    registry.setOfferTimelock(collateralA, registry.MIN_OFFER_TIMELOCK());
    registry.setOfferTimelock(collateralB, registry.MAX_OFFER_TIMELOCK());
    vm.stopPrank();

    // First sets are delayed by the floored (minimum) current timelock
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK());
    (uint40 timelockA,) = registry.offerConfig(collateralA);
    (uint40 timelockB,) = registry.offerConfig(collateralB);
    assertEq(timelockA, registry.MIN_OFFER_TIMELOCK(), "min bound should be accepted");
    assertEq(timelockB, registry.MAX_OFFER_TIMELOCK(), "max bound should be accepted");
  }

  function test_SetOfferTimelock_FirstSetDelayedByFloor() public {
    // A never-configured collateral reads the floored minimum timelock, and the change delay is
    // re-based on that same floor: even the first set waits out MIN_OFFER_TIMELOCK
    uint40 floorTimelock = registry.MIN_OFFER_TIMELOCK();
    uint40 expectedEffectiveAt = uint40(block.timestamp + floorTimelock);
    vm.expectEmit(true, false, false, true, address(registry));
    emit IBorrowOffersRegistry.OfferTimelockScheduled(collateralA, 1 hours, expectedEffectiveAt);
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 1 hours);

    // Until the change lands, readers keep seeing the floor
    (uint40 timelock,) = registry.offerConfig(collateralA);
    assertEq(timelock, floorTimelock, "floor should hold until the first set lands");

    vm.warp(expectedEffectiveAt);
    (timelock,) = registry.offerConfig(collateralA);
    assertEq(timelock, 1 hours, "first set should land after the floor delay");
  }

  function test_SetOfferTimelock_SecondSetDelayedByCurrentTimelock() public {
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 1 hours);
    // Let the first set (delayed by the floor) land before scheduling the change under test
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK());

    // Schedule a change: it must wait out the current 1 hour timelock
    uint40 expectedEffectiveAt = uint40(block.timestamp + 1 hours);
    vm.expectEmit(true, false, false, true, address(registry));
    emit IBorrowOffersRegistry.OfferTimelockScheduled(collateralA, 2 hours, expectedEffectiveAt);
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 2 hours);

    // The raw pending pair is exposed
    (uint40 pendingValue, uint40 pendingAt) = registry.pendingOfferTimelock(collateralA);
    assertEq(pendingValue, 2 hours, "pending value should be the scheduled timelock");
    assertEq(pendingAt, expectedEffectiveAt, "pending effectiveAt should be now + current timelock");

    // Old value still effective just before the deadline
    vm.warp(expectedEffectiveAt - 1);
    (uint40 timelock,) = registry.offerConfig(collateralA);
    assertEq(timelock, 1 hours, "old timelock should hold until effectiveAt");

    // New value observed at the deadline without any write
    vm.warp(expectedEffectiveAt);
    (timelock,) = registry.offerConfig(collateralA);
    assertEq(timelock, 2 hours, "due pending timelock should be observed by the view");
  }

  function test_SetOfferTimelock_RebasesFromCurrentEffectiveTimelock() public {
    // Configure at the maximum (letting the floor-delayed first set land), then try to rush a
    // reduction through
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 7 days);
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK());
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 15 minutes);

    (, uint40 firstAt) = registry.pendingOfferTimelock(collateralA);
    assertEq(firstAt, uint40(block.timestamp + 7 days), "reduction should wait out the full current timelock");

    // Re-scheduling before the pending change lands re-bases from the CURRENT
    // effective timelock (still 7 days), so the reduction cannot be accelerated
    vm.warp(block.timestamp + 6 days);
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 15 minutes);

    (uint40 pendingValue, uint40 pendingAt) = registry.pendingOfferTimelock(collateralA);
    assertEq(pendingValue, 15 minutes, "pending value should be the re-scheduled timelock");
    assertEq(pendingAt, uint40(block.timestamp + 7 days), "re-scheduling should re-base from the current timelock");

    (uint40 timelock,) = registry.offerConfig(collateralA);
    assertEq(timelock, 7 days, "current timelock should be unchanged until the pending change lands");
  }

  function test_SetOfferTimelock_RebasesFromDuePendingTimelock() public {
    // A due pending change is promoted on the next write, so the new schedule
    // is based on the just-landed value rather than the stale stored one
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 1 hours);
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK()); // the 1 hour config lands
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 2 hours);

    vm.warp(block.timestamp + 1 hours); // the 2 hours change is now due
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 3 hours);

    (uint40 pendingValue, uint40 pendingAt) = registry.pendingOfferTimelock(collateralA);
    assertEq(pendingValue, 3 hours, "pending value should be the newly scheduled timelock");
    assertEq(pendingAt, uint40(block.timestamp + 2 hours), "schedule should be based on the promoted timelock");

    (uint40 timelock,) = registry.offerConfig(collateralA);
    assertEq(timelock, 2 hours, "promoted timelock should be effective");
  }

  function test_PendingOfferTimelock_MasksDueEntry() public {
    // Let the floor-delayed first set land so the change under test has a clean baseline
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 1 hours);
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK());

    // Schedule a change: the still-future pending pair is reported
    uint40 expectedEffectiveAt = uint40(block.timestamp + 1 hours);
    vm.prank(owner);
    registry.setOfferTimelock(collateralA, 2 hours);
    (uint40 pendingValue, uint40 pendingAt) = registry.pendingOfferTimelock(collateralA);
    assertEq(pendingValue, 2 hours, "future pending value should be reported");
    assertEq(pendingAt, expectedEffectiveAt, "future pending effectiveAt should be reported");

    // Once due, the entry is masked without any further write: the pending view reads empty
    // while the config view already reports the landed value
    vm.warp(expectedEffectiveAt);
    (pendingValue, pendingAt) = registry.pendingOfferTimelock(collateralA);
    assertEq(pendingValue, 0, "due pending value should be masked");
    assertEq(pendingAt, 0, "due pending effectiveAt should be masked");
    (uint40 timelock,) = registry.offerConfig(collateralA);
    assertEq(timelock, 2 hours, "due pending timelock should already be effective");

    // Still masked well past the deadline
    vm.warp(expectedEffectiveAt + 1 days);
    (pendingValue, pendingAt) = registry.pendingOfferTimelock(collateralA);
    assertEq(pendingValue, 0, "stale pending value should stay masked");
    assertEq(pendingAt, 0, "stale pending effectiveAt should stay masked");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   MIN OFFER BONUS TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_SetMinOfferBonus_OnlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert(Unauthorized.selector);
    registry.setMinOfferBonus(collateralA, 100);
  }

  function test_SetMinOfferBonus_RevertsOnZeroCollateral() public {
    vm.prank(owner);
    vm.expectRevert(AddressZero.selector);
    registry.setMinOfferBonus(address(0), 100);
  }

  function test_SetMinOfferBonus_RevertsAboveMax() public {
    uint16 aboveMax = registry.MAX_MIN_OFFER_BONUS_BPS() + 1;
    vm.prank(owner);
    vm.expectRevert(MinOfferBonusOutOfRange.selector);
    registry.setMinOfferBonus(collateralA, aboveMax);
  }

  function test_SetMinOfferBonus_InstantAndEmits() public {
    vm.expectEmit(true, false, false, true, address(registry));
    emit IBorrowOffersRegistry.MinOfferBonusSet(collateralA, 250);
    vm.prank(owner);
    registry.setMinOfferBonus(collateralA, 250);

    // Effective immediately, no timelock
    (, uint16 minBonus) = registry.offerConfig(collateralA);
    assertEq(minBonus, 250, "minimum offer bonus should be effective immediately");
  }

  function test_SetMinOfferBonus_ZeroAndMaxAllowed() public {
    vm.startPrank(owner);
    registry.setMinOfferBonus(collateralA, registry.MAX_MIN_OFFER_BONUS_BPS());
    vm.stopPrank();
    (, uint16 minBonus) = registry.offerConfig(collateralA);
    assertEq(minBonus, registry.MAX_MIN_OFFER_BONUS_BPS(), "max bound should be accepted");

    // Zero disables the floor
    vm.prank(owner);
    registry.setMinOfferBonus(collateralA, 0);
    (, minBonus) = registry.offerConfig(collateralA);
    assertEq(minBonus, 0, "zero floor should be accepted");
  }

  function test_SetMinOfferBonus_NeverSetReadsDefault_ExplicitZeroDisables() public {
    // A never-set collateral reads the default anti-griefing floor
    (, uint16 minBonus) = registry.offerConfig(collateralA);
    assertEq(minBonus, registry.DEFAULT_MIN_OFFER_BONUS_BPS(), "never-set collateral should read the default floor");

    // An explicitly-set zero disables the floor (distinct from never-set)
    vm.prank(owner);
    registry.setMinOfferBonus(collateralA, 0);
    (, minBonus) = registry.offerConfig(collateralA);
    assertEq(minBonus, 0, "explicit zero should disable the floor");

    // A non-zero floor reads back as set
    vm.prank(owner);
    registry.setMinOfferBonus(collateralA, 250);
    (, minBonus) = registry.offerConfig(collateralA);
    assertEq(minBonus, 250, "explicit floor should read back");

    // Setting back to zero disables again (explicit disable round-trips)
    vm.prank(owner);
    registry.setMinOfferBonus(collateralA, 0);
    (, minBonus) = registry.offerConfig(collateralA);
    assertEq(minBonus, 0, "explicit zero should round-trip");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  PER-COLLATERAL ISOLATION                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_OfferConfig_PerCollateralIsolation() public {
    vm.startPrank(owner);
    registry.setOfferTimelock(collateralA, 1 hours);
    registry.setMinOfferBonus(collateralA, 300);
    vm.stopPrank();
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK()); // the timelock config lands

    (uint40 timelockA, uint16 minBonusA) = registry.offerConfig(collateralA);
    assertEq(timelockA, 1 hours, "collateral A timelock should be configured");
    assertEq(minBonusA, 300, "collateral A floor should be configured");

    // Collateral B stays unconfigured: floored timelock, default bonus floor
    (uint40 timelockB, uint16 minBonusB) = registry.offerConfig(collateralB);
    assertEq(timelockB, registry.MIN_OFFER_TIMELOCK(), "collateral B should read the floor");
    assertEq(minBonusB, registry.DEFAULT_MIN_OFFER_BONUS_BPS(), "collateral B should read the default floor");
  }

  function test_OfferConfig_UnconfiguredCollateralReadsFloor() public view {
    // Fail-safe defaults: a never-configured collateral has the minimum veto window (the offer
    // band is open by default, not disabled) and the default anti-griefing bonus floor
    (uint40 timelock, uint16 minBonus) = registry.offerConfig(collateralA);
    assertEq(timelock, registry.MIN_OFFER_TIMELOCK(), "unconfigured collateral should read the floor");
    assertEq(minBonus, registry.DEFAULT_MIN_OFFER_BONUS_BPS(), "unconfigured collateral should read the default floor");

    (uint40 pendingValue, uint40 pendingAt) = registry.pendingOfferTimelock(collateralA);
    assertEq(pendingValue, 0, "unconfigured collateral should have no pending value");
    assertEq(pendingAt, 0, "unconfigured collateral should have no pending deadline");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   OWNERSHIP HANDOVER TESTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_OwnershipHandover_TwoStepTransfer() public {
    address newOwner = makeAddr("newOwner");

    // Step 1: the incoming owner requests the handover
    vm.prank(newOwner);
    registry.requestOwnershipHandover();

    // Step 2: the current owner completes it
    vm.prank(owner);
    registry.completeOwnershipHandover(newOwner);

    assertEq(registry.owner(), newOwner, "ownership should transfer to the new owner");

    // The new owner is authorized by derivation
    registry.checkCanCreateOffer(newOwner);
    assertTrue(registry.canRevokeOffer(newOwner), "new owner should have revoke power");

    // The old owner has no lingering powers
    vm.expectRevert(Unauthorized.selector);
    registry.checkCanCreateOffer(owner);
    assertFalse(registry.canRevokeOffer(owner), "old owner should lose revoke power");

    vm.prank(owner);
    vm.expectRevert(Unauthorized.selector);
    registry.setOfferTimelock(collateralA, 1 hours);

    // The new owner administers the registry (the first set lands after the floor delay)
    vm.prank(newOwner);
    registry.setOfferTimelock(collateralA, 1 hours);
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK());
    (uint40 timelock,) = registry.offerConfig(collateralA);
    assertEq(timelock, 1 hours, "new owner should be able to configure collaterals");
  }
}
