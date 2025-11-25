// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibMintAuth} from "../../../src/request/libraries/LibMintAuth.sol";

contract LibMintAuthTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          FIXTURES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // Fixtures for uint128 values (pt and yt mint auth amounts)
  uint128[] public fixturePtAuth = [
    0, // Zero
    1, // Minimum non-zero
    1000 ether, // Normal value
    1e30, // Large value
    type(uint128).max - 1, // Almost max
    type(uint128).max // Max value
  ];

  uint128[] public fixtureYtAuth = [
    0, // Zero
    1, // Minimum non-zero
    2000 ether, // Normal value
    2e30, // Large value
    type(uint128).max - 1, // Almost max
    type(uint128).max // Max value
  ];

  // Fixtures for minter addresses
  address[] public fixtureMinter =
    [address(0x1), address(0x2), address(0x123456789), address(0xdEaD), address(type(uint160).max)];

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   MINT AUTHORIZATION TESTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_mintAuth(address minter, uint128 ptAuth, uint128 ytAuth) public {
    vm.assume(minter != address(0));

    // Update mint auth
    LibMintAuth.updateMintAuth(minter, ptAuth, ytAuth);

    // Read back values
    (uint128 ptResult, uint128 ytResult) = LibMintAuth.mintAuth(minter);

    assertEq(ptResult, ptAuth, "PT mint auth should match");
    assertEq(ytResult, ytAuth, "YT mint auth should match");
  }

  function test_mintAuth_multipleMinters() public {
    address minter1 = address(0x1);
    address minter2 = address(0x2);
    address minter3 = address(0x3);

    // Set different mint auths for each minter
    LibMintAuth.updateMintAuth(minter1, 100, 200);
    LibMintAuth.updateMintAuth(minter2, 300, 400);
    LibMintAuth.updateMintAuth(minter3, 500, 600);

    // Verify each minter has correct mint auth
    (uint128 pt1, uint128 yt1) = LibMintAuth.mintAuth(minter1);
    assertEq(pt1, 100);
    assertEq(yt1, 200);

    (uint128 pt2, uint128 yt2) = LibMintAuth.mintAuth(minter2);
    assertEq(pt2, 300);
    assertEq(yt2, 400);

    (uint128 pt3, uint128 yt3) = LibMintAuth.mintAuth(minter3);
    assertEq(pt3, 500);
    assertEq(yt3, 600);
  }

  function test_mintAuth_storageLayout() public {
    address minter = address(0x123);

    // Test PT and YT are stored independently
    LibMintAuth.updateMintAuth(minter, type(uint128).max, 0);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, type(uint128).max);
    assertEq(yt, 0);

    LibMintAuth.updateMintAuth(minter, 0, type(uint128).max);
    (pt, yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, 0);
    assertEq(yt, type(uint128).max);

    LibMintAuth.updateMintAuth(minter, type(uint128).max, type(uint128).max);
    (pt, yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, type(uint128).max);
    assertEq(yt, type(uint128).max);
  }

  function testFuzz_mintAuth_overwrite(address minter, uint128 pt1, uint128 yt1, uint128 pt2, uint128 yt2) public {
    vm.assume(minter != address(0));

    // Set initial mint auth
    LibMintAuth.updateMintAuth(minter, pt1, yt1);
    (uint128 ptRead, uint128 ytRead) = LibMintAuth.mintAuth(minter);
    assertEq(ptRead, pt1);
    assertEq(ytRead, yt1);

    // Overwrite with new mint auth
    LibMintAuth.updateMintAuth(minter, pt2, yt2);
    (ptRead, ytRead) = LibMintAuth.mintAuth(minter);
    assertEq(ptRead, pt2);
    assertEq(ytRead, yt2);
  }

  function test_mintAuth_defaultValues() public view {
    // Test that uninitialized storage returns zero
    address minter = address(0x999);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, 0, "Default PT mint auth should be 0");
    assertEq(yt, 0, "Default YT mint auth should be 0");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     SLOT COMPUTATION TESTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_mintAuthSlot_uniqueness(address minter1, address minter2) public pure {
    vm.assume(minter1 != minter2);

    // Verify that different minters get different slots
    uint256 slot1 = LibMintAuth.mintAuthSlot(minter1);
    uint256 slot2 = LibMintAuth.mintAuthSlot(minter2);

    assertTrue(slot1 != slot2, "Different minters should have different slots");
  }

  function testFuzz_mintAuthSlot_deterministic(address minter) public pure {
    // Verify that the same minter always gets the same slot
    uint256 slot1 = LibMintAuth.mintAuthSlot(minter);
    uint256 slot2 = LibMintAuth.mintAuthSlot(minter);

    assertEq(slot1, slot2, "Slot computation should be deterministic");
  }

  function test_mintAuthSlot_differentFromZero() public pure {
    // Verify that computed slots are not zero
    address minter = address(0x123);
    uint256 slot = LibMintAuth.mintAuthSlot(minter);
    assertTrue(slot != 0, "Computed slot should not be zero");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTEGRATION TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_isolatedStorage_multipleMinters(
    address minter1,
    address minter2,
    address minter3,
    uint128 auth1Pt,
    uint128 auth1Yt,
    uint128 auth2Pt,
    uint128 auth2Yt,
    uint128 auth3Pt,
    uint128 auth3Yt
  ) public {
    vm.assume(minter1 != address(0) && minter2 != address(0) && minter3 != address(0));
    vm.assume(minter1 != minter2 && minter2 != minter3 && minter1 != minter3);

    // Set mint auths for three different minters
    LibMintAuth.updateMintAuth(minter1, auth1Pt, auth1Yt);
    LibMintAuth.updateMintAuth(minter2, auth2Pt, auth2Yt);
    LibMintAuth.updateMintAuth(minter3, auth3Pt, auth3Yt);

    // Verify all values are independent and correct
    (uint128 auth1PtRead, uint128 auth1YtRead) = LibMintAuth.mintAuth(minter1);
    assertEq(auth1PtRead, auth1Pt, "Minter1 PT auth should match");
    assertEq(auth1YtRead, auth1Yt, "Minter1 YT auth should match");

    (uint128 auth2PtRead, uint128 auth2YtRead) = LibMintAuth.mintAuth(minter2);
    assertEq(auth2PtRead, auth2Pt, "Minter2 PT auth should match");
    assertEq(auth2YtRead, auth2Yt, "Minter2 YT auth should match");

    (uint128 auth3PtRead, uint128 auth3YtRead) = LibMintAuth.mintAuth(minter3);
    assertEq(auth3PtRead, auth3Pt, "Minter3 PT auth should match");
    assertEq(auth3YtRead, auth3Yt, "Minter3 YT auth should match");
  }

  function test_edgeCases_zeroAddress() public {
    // Test that zero address can be used (library doesn't validate)
    address zero = address(0);

    LibMintAuth.updateMintAuth(zero, 100, 200);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(zero);
    assertEq(pt, 100);
    assertEq(yt, 200);
  }

  function test_edgeCases_maxAddress() public {
    // Test with maximum address value
    address maxAddr = address(type(uint160).max);

    LibMintAuth.updateMintAuth(maxAddr, 12345, 67890);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(maxAddr);
    assertEq(pt, 12345);
    assertEq(yt, 67890);
  }

  function test_edgeCases_zeroValues() public {
    address minter = address(0x456);

    // Setting both to zero should work
    LibMintAuth.updateMintAuth(minter, 0, 0);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, 0);
    assertEq(yt, 0);

    // Set to non-zero
    LibMintAuth.updateMintAuth(minter, 100, 200);
    (pt, yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, 100);
    assertEq(yt, 200);

    // Reset back to zero
    LibMintAuth.updateMintAuth(minter, 0, 0);
    (pt, yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, 0);
    assertEq(yt, 0);
  }

  function test_edgeCases_maxUint128Values() public {
    address minter = address(0x789);

    // Test with maximum uint128 values
    LibMintAuth.updateMintAuth(minter, type(uint128).max, type(uint128).max);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, type(uint128).max);
    assertEq(yt, type(uint128).max);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FIXTURE-BASED TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_fixtures_allCombinations() public {
    // Test all fixture combinations
    for (uint256 i = 0; i < fixtureMinter.length; i++) {
      for (uint256 j = 0; j < fixturePtAuth.length; j++) {
        for (uint256 k = 0; k < fixtureYtAuth.length; k++) {
          address minter = fixtureMinter[i];
          uint128 ptAuth = fixturePtAuth[j];
          uint128 ytAuth = fixtureYtAuth[k];

          LibMintAuth.updateMintAuth(minter, ptAuth, ytAuth);
          (uint128 ptRead, uint128 ytRead) = LibMintAuth.mintAuth(minter);

          assertEq(ptRead, ptAuth, "PT auth should match in fixture test");
          assertEq(ytRead, ytAuth, "YT auth should match in fixture test");
        }
      }
    }
  }

  function test_fixtures_sequentialUpdates() public {
    address minter = address(0xABC);

    // Test sequential updates with fixture values
    for (uint256 i = 0; i < fixturePtAuth.length; i++) {
      LibMintAuth.updateMintAuth(minter, fixturePtAuth[i], fixtureYtAuth[i]);
      (uint128 ptRead, uint128 ytRead) = LibMintAuth.mintAuth(minter);

      assertEq(ptRead, fixturePtAuth[i], "PT auth should match in sequential test");
      assertEq(ytRead, fixtureYtAuth[i], "YT auth should match in sequential test");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      BOUNDARY TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_boundary_onlyPtMax() public {
    address minter = address(0x111);
    LibMintAuth.updateMintAuth(minter, type(uint128).max, 0);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, type(uint128).max);
    assertEq(yt, 0);
  }

  function test_boundary_onlyYtMax() public {
    address minter = address(0x222);
    LibMintAuth.updateMintAuth(minter, 0, type(uint128).max);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, 0);
    assertEq(yt, type(uint128).max);
  }

  function test_boundary_bothMax() public {
    address minter = address(0x333);
    LibMintAuth.updateMintAuth(minter, type(uint128).max, type(uint128).max);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, type(uint128).max);
    assertEq(yt, type(uint128).max);
  }

  function test_boundary_almostMax() public {
    address minter = address(0x444);
    uint128 almostMax = type(uint128).max - 1;
    LibMintAuth.updateMintAuth(minter, almostMax, almostMax);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, almostMax);
    assertEq(yt, almostMax);
  }

  function test_boundary_one() public {
    address minter = address(0x555);
    LibMintAuth.updateMintAuth(minter, 1, 1);
    (uint128 pt, uint128 yt) = LibMintAuth.mintAuth(minter);
    assertEq(pt, 1);
    assertEq(yt, 1);
  }
}

