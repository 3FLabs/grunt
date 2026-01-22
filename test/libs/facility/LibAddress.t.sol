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

  /// @notice Test that matching assets do not revert
  function test_checkAssetsMatch_success() public view {
    address asset = address(0x1234);
    harness.checkAssetsMatch(asset, asset);
  }

  /// @notice Test that mismatched assets revert with AssetMismatch
  function test_checkAssetsMatch_revertOnMismatch() public {
    address asset1 = address(0x1234);
    address asset2 = address(0x5678);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AssetMismatch.selector, asset1, asset2));
    harness.checkAssetsMatch(asset1, asset2);
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

  /// @notice Test with zero addresses
  function test_checkAssetsMatch_zeroAddresses() public view {
    harness.checkAssetsMatch(address(0), address(0));
  }

  /// @notice Test zero vs non-zero address
  function test_checkAssetsMatch_zeroVsNonZero() public {
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AssetMismatch.selector, address(0), address(1)));
    harness.checkAssetsMatch(address(0), address(1));
  }
}
