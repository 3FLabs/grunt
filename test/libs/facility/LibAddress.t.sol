// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibAddressHarness} from "test/mock/libs/LibAddressHarness.sol";

/// @title LibAddressTest
/// @notice Tests for LibAddress library
contract LibAddressTest is Test {
  LibAddressHarness harness;

  function setUp() public {
    harness = new LibAddressHarness();
  }

  /// @notice Fuzz test: matching assets never revert
  function testFuzz_checkAssetsMatch_success(address asset) public view {
    harness.checkAssetsMatch(asset, asset);
  }

  /// @notice Fuzz test: mismatched assets always revert
  function testFuzz_checkAssetsMatch_revertOnMismatch(address asset1, address asset2) public {
    vm.assume(asset1 != asset2);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AssetMismatch.selector, asset1, asset2));
    harness.checkAssetsMatch(asset1, asset2);
  }
}
