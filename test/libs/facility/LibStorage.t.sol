// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibFacilityStorageHarness} from "test/mock/libs/LibFacilityStorageHarness.sol";
import {Asset} from "src/libs/facility/LibIntent.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title LibStorageTest (Facility)
/// @notice Unit tests for facility LibStorage library
contract LibFacilityStorageTest is Test {
  LibFacilityStorageHarness harness;
  MockERC20 token;

  function setUp() public {
    harness = new LibFacilityStorageHarness();
    token = new MockERC20("Test Token", "TEST", 18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     getIntent TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_getIntent_revertOnZeroId() public {
    // Create an intent first so lastIntentId > 0
    Asset memory depositAsset = Asset({asset: address(token), isPositionManager: false});
    harness.createIntent(depositAsset, 1, true);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, 0));
    harness.getIntent(0);
  }

  function testFuzz_getIntent_revertOnInvalidId(uint8 numIntents, uint256 invalidId) public {
    vm.assume(numIntents > 0 && numIntents <= 10);

    Asset memory depositAsset = Asset({asset: address(token), isPositionManager: false});
    for (uint256 i = 0; i < numIntents; i++) {
      harness.createIntent(depositAsset, 1, true);
    }

    invalidId = bound(invalidId, uint256(numIntents) + 1, type(uint256).max);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    harness.getIntent(invalidId);
  }

  function test_getIntent_success() public {
    Asset memory depositAsset = Asset({asset: address(token), isPositionManager: false});
    uint256 id = harness.createIntent(depositAsset, 1, true);

    harness.getIntent(id); // Should not revert
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    createIntent TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_createIntent_incrementsId(uint8 numIntents) public {
    vm.assume(numIntents > 0 && numIntents <= 50);

    Asset memory depositAsset = Asset({asset: address(token), isPositionManager: false});

    for (uint256 i = 1; i <= numIntents; i++) {
      uint256 id = harness.createIntent(depositAsset, 1, true);
      assertEq(id, i);
      assertEq(harness.lastIntentId(), i);
    }
  }

  function test_createIntent_revertOnEOAAsset() public {
    Asset memory depositAsset = Asset({asset: makeAddr("eoa"), isPositionManager: false});

    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, depositAsset.asset));
    harness.createIntent(depositAsset, 1, true);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   checkNotPaused TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_checkNotPaused_success() public view {
    harness.checkNotPaused(); // Not paused initially
  }

  function test_checkNotPaused_successWhenExpired() public {
    harness.setPausedUntil(uint40(block.timestamp - 1));

    harness.checkNotPaused(); // Should not revert
  }

  function testFuzz_checkNotPaused_revertWhenPaused(uint40 pauseOffset) public {
    pauseOffset = uint40(bound(pauseOffset, 1, type(uint40).max - block.timestamp));
    harness.setPausedUntil(uint40(block.timestamp) + pauseOffset);

    vm.expectRevert(LibCommonErrors.Paused.selector);
    harness.checkNotPaused();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     checkDigest TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_checkDigest_success(bytes32 digest) public {
    assertFalse(harness.isDigestUsed(digest));
    harness.checkDigest(digest);
    assertTrue(harness.isDigestUsed(digest));
  }

  function testFuzz_checkDigest_revertOnReuse(bytes32 digest) public {
    harness.checkDigest(digest);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.SwapDigestUsed.selector, digest));
    harness.checkDigest(digest);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   checkFundIntent TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_checkFundIntent_setsNewFund() public {
    address fund = makeAddr("fund");
    uint256 intentId = 1;

    assertEq(harness.getFundIntent(fund), 0);
    harness.checkFundIntent(fund, intentId);
    assertEq(harness.getFundIntent(fund), intentId);
  }

  function test_checkFundIntent_allowsSameIntentId() public {
    address fund = makeAddr("fund");
    uint256 intentId = 1;

    harness.checkFundIntent(fund, intentId);
    harness.checkFundIntent(fund, intentId); // Should not revert
    assertEq(harness.getFundIntent(fund), intentId);
  }

  function testFuzz_checkFundIntent_revertOnDifferentIntentId(address fund, uint256 intentId1, uint256 intentId2)
    public
  {
    vm.assume(intentId1 != 0 && intentId2 != 0 && intentId1 != intentId2);

    harness.checkFundIntent(fund, intentId1);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.FundAlreadyInUse.selector, fund, intentId1));
    harness.checkFundIntent(fund, intentId2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 checkRequestIntent TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_checkRequestIntent_setsNewRequest() public {
    address request = makeAddr("request");
    uint256 intentId = 1;

    assertEq(harness.getRequestIntent(request), 0);
    harness.checkRequestIntent(request, intentId);
    assertEq(harness.getRequestIntent(request), intentId);
  }

  function test_checkRequestIntent_allowsSameIntentId() public {
    address request = makeAddr("request");
    uint256 intentId = 1;

    harness.checkRequestIntent(request, intentId);
    harness.checkRequestIntent(request, intentId); // Should not revert
    assertEq(harness.getRequestIntent(request), intentId);
  }

  function test_checkRequestIntent_revertOnDifferentIntentId() public {
    address request = makeAddr("request");
    uint256 intentId1 = 1;
    uint256 intentId2 = 2;

    harness.checkRequestIntent(request, intentId1);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.RequestAlreadyInUse.selector, request, intentId1));
    harness.checkRequestIntent(request, intentId2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    abandonFund TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_abandonFund_removesFundMapping() public {
    address fund = makeAddr("fund");
    uint256 intentId = 1;

    harness.checkFundIntent(fund, intentId);
    assertEq(harness.getFundIntent(fund), intentId);

    harness.abandonFund(fund);
    assertEq(harness.getFundIntent(fund), 0);
  }

  function test_abandonFund_allowsReuse() public {
    address fund = makeAddr("fund");
    uint256 intentId1 = 1;
    uint256 intentId2 = 2;

    harness.checkFundIntent(fund, intentId1);
    harness.abandonFund(fund);
    harness.checkFundIntent(fund, intentId2); // Should not revert
    assertEq(harness.getFundIntent(fund), intentId2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   abandonRequest TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_abandonRequest_removesRequestMapping() public {
    address request = makeAddr("request");
    uint256 intentId = 1;

    harness.checkRequestIntent(request, intentId);
    assertEq(harness.getRequestIntent(request), intentId);

    harness.abandonRequest(request);
    assertEq(harness.getRequestIntent(request), 0);
  }

  function test_abandonRequest_allowsReuse() public {
    address request = makeAddr("request");
    uint256 intentId1 = 1;
    uint256 intentId2 = 2;

    harness.checkRequestIntent(request, intentId1);
    harness.abandonRequest(request);
    harness.checkRequestIntent(request, intentId2); // Should not revert
    assertEq(harness.getRequestIntent(request), intentId2);
  }
}
