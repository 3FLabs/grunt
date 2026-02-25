// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {IPositionManagerAdmin} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {LibManagerStorageHarness} from "test/mock/libs/LibManagerStorageHarness.sol";
import {MockBorrowPosition} from "test/mock/borrow/MockBorrowPosition.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibStorageTest (Manager)
/// @notice Unit tests for manager LibStorage library
contract LibManagerStorageTest is Test {
  LibManagerStorageHarness harness;
  MockERC20 collateralToken;
  MockERC20 debtToken;

  function setUp() public {
    harness = new LibManagerStorageHarness();
    collateralToken = new MockERC20("Collateral", "COL", 18);
    debtToken = new MockERC20("Debt", "DEBT", 18);

    harness.setMetadata("Test PM", "TPM", address(collateralToken), address(debtToken));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        setLtv TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setLtv_emitsEvent() public {
    uint256 ltv = 0.86e18;

    vm.expectEmit();
    emit IPositionManagerAdmin.LTVSet(ltv);
    harness.setLtv(ltv);
  }

  function testFuzz_setLtv_success(uint256 ltv) public {
    ltv = bound(ltv, 1, FixedPointMathLib.WAD);

    harness.setLtv(ltv);
    assertEq(harness.getLtv(), uint64(ltv));
  }

  function testFuzz_setLtv_revertOnInvalid(uint256 ltv) public {
    vm.assume(ltv == 0 || ltv > FixedPointMathLib.WAD);

    vm.expectRevert(LibCommonErrors.InvalidLtv.selector);
    harness.setLtv(ltv);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   updateSnapshot TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_updateSnapshot_empty() public {
    assertEq(harness.getLastTotalAssets(), 0);
    harness.updateSnapshot();
    assertEq(harness.getLastTotalAssets(), 0);
  }

  function testFuzz_updateSnapshot(uint128 collateral1, uint128 debt1, uint128 collateral2, uint128 debt2) public {
    // Ensure collateral >= debt for each module
    vm.assume(collateral1 >= debt1);
    vm.assume(collateral2 >= debt2);

    MockBorrowPosition module1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition module2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    module1.setTotalCollateralQuoted(collateral1);
    module1.setTotalBorrowed(debt1);
    module2.setTotalCollateralQuoted(collateral2);
    module2.setTotalBorrowed(debt2);

    harness.addBorrowModule(address(module1));
    harness.addBorrowModule(address(module2));

    harness.updateSnapshot();

    uint256 expected = uint256(collateral1) + uint256(collateral2) - uint256(debt1) - uint256(debt2);
    assertEq(harness.getLastTotalAssets(), expected);
  }
}
