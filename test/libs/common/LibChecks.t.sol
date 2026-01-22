// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibChecksHarness} from "test/mock/libs/LibChecksHarness.sol";

/// @title LibChecksTest
/// @notice Unit tests for LibChecks library
contract LibChecksTest is Test {
  LibChecksHarness harness;

  function setUp() public {
    harness = new LibChecksHarness();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  checkNotZero(address) TESTS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_checkNotZeroAddress_success() public view {
    harness.checkNotZeroAddress(address(1));
    harness.checkNotZeroAddress(address(this));
  }

  function test_checkNotZeroAddress_revertOnZero() public {
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    harness.checkNotZeroAddress(address(0));
  }

  function testFuzz_checkNotZeroAddress_success(address addr) public view {
    vm.assume(addr != address(0));
    harness.checkNotZeroAddress(addr);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   checkContract TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_checkContract_success() public view {
    harness.checkContract(address(harness));
    harness.checkContract(address(this));
  }

  function test_checkContract_revertOnEOA() public {
    address eoa = makeAddr("eoa");
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, eoa));
    harness.checkContract(eoa);
  }

  function test_checkContract_revertOnZeroAddress() public {
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0)));
    harness.checkContract(address(0));
  }

  function testFuzz_checkContract_revertOnEOA(address eoa) public {
    vm.assume(eoa.code.length == 0);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, eoa));
    harness.checkContract(eoa);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  checkNotZero(uint256) TESTS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_checkNotZeroAmount_success() public view {
    harness.checkNotZeroAmount(1);
    harness.checkNotZeroAmount(type(uint256).max);
  }

  function test_checkNotZeroAmount_revertOnZero() public {
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    harness.checkNotZeroAmount(0);
  }

  function testFuzz_checkNotZeroAmount_success(uint256 amount) public view {
    vm.assume(amount != 0);
    harness.checkNotZeroAmount(amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   checkValidLltv TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_checkValidLltv_success() public view {
    harness.checkValidLltv(1); // Minimum valid
    harness.checkValidLltv(FixedPointMathLib.WAD / 2); // 50%
    harness.checkValidLltv(FixedPointMathLib.WAD); // Maximum valid (100%)
  }

  function test_checkValidLltv_revertOnZero() public {
    vm.expectRevert(LibCommonErrors.InvalidLltv.selector);
    harness.checkValidLltv(0);
  }

  function test_checkValidLltv_revertOnGreaterThanWad() public {
    vm.expectRevert(LibCommonErrors.InvalidLltv.selector);
    harness.checkValidLltv(FixedPointMathLib.WAD + 1);
  }

  function testFuzz_checkValidLltv_success(uint256 lltv) public view {
    lltv = bound(lltv, 1, FixedPointMathLib.WAD);
    harness.checkValidLltv(lltv);
  }

  function testFuzz_checkValidLltv_revertOnInvalid(uint256 lltv) public {
    vm.assume(lltv == 0 || lltv > FixedPointMathLib.WAD);
    vm.expectRevert(LibCommonErrors.InvalidLltv.selector);
    harness.checkValidLltv(lltv);
  }
}
