// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";

import {FacilityCapsWhitelist} from "src/facility/caps/FacilityCapsWhitelist.sol";
import {IFacilityCapsWhitelist} from "src/interfaces/facility/IFacilityCapsWhitelist.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";

/// @title FacilityCapsWhitelistTest
/// @notice Unit tests for the caps contract registry
contract FacilityCapsWhitelistTest is Test {
  FacilityCapsWhitelist public whitelist;

  address owner = makeAddr("owner");
  address stranger = makeAddr("stranger");
  address caps;

  function setUp() public {
    whitelist = new FacilityCapsWhitelist(owner);
    caps = address(new FacilityCapsWhitelist(owner));
  }

  function test_constructor_setsOwner() public view {
    assertEq(whitelist.owner(), owner, "Owner should be set");
  }

  function test_constructor_revertOnZeroOwner() public {
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    new FacilityCapsWhitelist(address(0));
  }

  function test_isAllowed_defaultsToFalse() public view {
    assertFalse(whitelist.isAllowed(caps), "Nothing should be allowed by default");
    assertFalse(whitelist.isAllowed(address(0)), "Zero address should not be allowed");
  }

  function test_setAllowed_allowsAndEmits() public {
    vm.expectEmit(true, true, true, true, address(whitelist));
    emit IFacilityCapsWhitelist.CapsAllowed(caps, true);
    vm.prank(owner);
    whitelist.setAllowed(caps, true);
    assertTrue(whitelist.isAllowed(caps), "Caps should be allowed");
  }

  function test_setAllowed_disallows() public {
    vm.startPrank(owner);
    whitelist.setAllowed(caps, true);
    vm.expectEmit(true, true, true, true, address(whitelist));
    emit IFacilityCapsWhitelist.CapsAllowed(caps, false);
    whitelist.setAllowed(caps, false);
    vm.stopPrank();
    assertFalse(whitelist.isAllowed(caps), "Caps should be disallowed");
  }

  function test_setAllowed_revertOnCodelessAddress() public {
    address eoa = makeAddr("eoa");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, eoa));
    whitelist.setAllowed(eoa, true);

    // disallowing never needs code, so a contract that self-destructed can still be removed
    vm.prank(owner);
    whitelist.setAllowed(eoa, false);
    assertFalse(whitelist.isAllowed(eoa), "Codeless address should stay disallowed");
  }

  function test_setAllowed_revertOnUnauthorized() public {
    vm.prank(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    whitelist.setAllowed(caps, true);
  }

  function testFuzz_setAllowed_roundTrip(address target, bool allowed) public {
    vm.assume(target.code.length > 0 || !allowed);
    vm.prank(owner);
    whitelist.setAllowed(target, allowed);
    assertEq(whitelist.isAllowed(target), allowed, "Stored flag should match");
  }
}
