// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {IFacilityIntents} from "src/interfaces/facility/base/IFacilityIntents.sol";
import {IFund} from "src/interfaces/funds/IFund.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

/// @title FacilityFundsRedeemTest
/// @notice Intent accounting of fund orders: REDEEM commit, unlock and recover, and both modes fuzzed
contract FacilityFundsRedeemTest is FacilityBaseTest {
  uint256 constant DEPOSITED = 1000e18;
  uint256 constant INPUT = 600e18;
  uint256 constant MIN_OUT = 550e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Resolving target-PM intent holding DEPOSITED of `depositToken`, bound to mockFund
  function _createIntentWithFund(MockERC20 depositToken) internal returns (uint256 intentId) {
    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositAsset = Asset({asset: address(depositToken), isPositionManager: false});
    vm.prank(owner);
    intentId = facility.createIntent(props);

    depositToken.setBalance(user, DEPOSITED);
    vm.prank(user);
    facility.deposit(intentId, DEPOSITED);

    vm.warp(block.timestamp + 1 days + 1);
    vm.prank(facilitator);
    _setFund(intentId, address(mockFund));
  }

  function _createCommittedRedeem() internal returns (uint256 intentId) {
    intentId = _createIntentWithFund(collateralToken);
    vm.startPrank(facilitator);
    facility.create(intentId, INPUT, MIN_OUT, Mode.REDEEM);
    facility.commit(intentId);
    vm.stopPrank();
  }

  function _tracked(uint256 id, address token) internal view returns (uint256) {
    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(id);
    for (uint256 i; i < tokens.length; ++i) {
      if (tokens[i] == token) return amounts[i];
    }
    return 0;
  }

  function _assertOrderEnded(uint256 id) internal view {
    (Order memory order,) = facility.getOrder(id);
    assertEq(order.owner, address(0), "order");
    (, address fund,,) = facility.getIntent(id);
    assertEq(fund, address(0), "fund");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           COMMIT                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_commit_redeemSendsShareToFund() public {
    uint256 intentId = _createIntentWithFund(collateralToken);
    vm.prank(facilitator);
    facility.create(intentId, INPUT, MIN_OUT, Mode.REDEEM);

    vm.expectEmit(true, true, true, true, address(collateralToken));
    emit ERC20.Approval(address(facility), address(mockFund), INPUT);
    vm.expectEmit(true, true, true, true, address(collateralToken));
    emit ERC20.Approval(address(facility), address(mockFund), 0);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(collateralToken), address(mockFund), INPUT);
    vm.prank(facilitator);
    facility.commit(intentId);

    assertEq(_tracked(intentId, address(collateralToken)), DEPOSITED - INPUT, "tracked share");
    assertEq(collateralToken.balanceOf(address(mockFund)), INPUT, "fund share balance");
    assertEq(collateralToken.allowance(address(facility), address(mockFund)), 0, "allowance");
  }

  function test_commit_revertWhenFundOverReports() public {
    uint256 intentId = _createIntentWithFund(collateralToken);
    vm.prank(facilitator);
    Order memory order = facility.create(intentId, INPUT, MIN_OUT, Mode.REDEEM);
    vm.mockCall(address(mockFund), abi.encodeCall(IFund.commit, (order)), abi.encode(State.PROCESSING, INPUT + 1));

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CommitAmountMismatch.selector, intentId, INPUT, INPUT + 1));
    facility.commit(intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      UNLOCK / RECOVER                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_unlock_redeemReceivesAssetAndEndsOrder() public {
    uint256 intentId = _createCommittedRedeem();
    uint256 out = 580e18;
    mockFund.setUnlockAmount(out);
    _mintDebt(address(mockFund), out);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(debtToken), address(mockFund), out);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacilityIntents.FundUpdated(intentId, address(0));
    vm.prank(facilitator);
    facility.unlock(intentId);

    assertEq(_tracked(intentId, address(debtToken)), out, "tracked asset");
    _assertOrderEnded(intentId);
  }

  function test_recover_redeemReturnsShareAndEndsOrder() public {
    uint256 intentId = _createCommittedRedeem();

    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(collateralToken), address(mockFund), INPUT);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacilityIntents.FundUpdated(intentId, address(0));
    vm.prank(facilitator);
    facility.recover(intentId);

    assertEq(_tracked(intentId, address(collateralToken)), DEPOSITED, "tracked share");
    _assertOrderEnded(intentId);
  }

  function test_recover_redeemAfterPartialUnlockTracksBothTokens() public {
    uint256 intentId = _createCommittedRedeem();
    _mintDebt(address(mockFund), 300e18);
    mockFund.setNextUnlockState(State.PROCESSING);
    mockFund.setUnlockAmount(300e18);
    vm.prank(facilitator);
    facility.unlock(intentId);

    (Order memory order,) = facility.getOrder(intentId);
    assertEq(order.input, INPUT, "order kept");
    (, address fund,,) = facility.getIntent(intentId);
    assertEq(fund, address(mockFund), "fund kept");

    mockFund.setRecoverAmount(200e18);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(collateralToken), address(mockFund), 200e18);
    vm.prank(facilitator);
    facility.recover(intentId);

    assertEq(_tracked(intentId, address(debtToken)), 300e18, "tracked asset");
    assertEq(_tracked(intentId, address(collateralToken)), DEPOSITED - INPUT + 200e18, "tracked share");
    _assertOrderEnded(intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            FUZZ                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_orderLifecycle_tracksIntentBalances(
    bool isRedeem,
    bool shouldRecover,
    uint256 input,
    uint256 output
  ) public {
    input = bound(input, 1, DEPOSITED);
    output = bound(output, 1, type(uint128).max);
    MockERC20 tokenIn = isRedeem ? collateralToken : debtToken;
    MockERC20 tokenOut = isRedeem ? debtToken : collateralToken;
    uint256 intentId = _createIntentWithFund(tokenIn);

    vm.startPrank(facilitator);
    facility.create(intentId, input, output, isRedeem ? Mode.REDEEM : Mode.DEPOSIT);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(tokenIn), address(mockFund), input);
    facility.commit(intentId);
    assertEq(_tracked(intentId, address(tokenIn)), DEPOSITED - input, "tracked input after commit");

    if (shouldRecover) {
      vm.expectEmit(true, true, true, true, address(facility));
      emit IFacility.TokenReceived(intentId, address(tokenIn), address(mockFund), input);
      facility.recover(intentId);
      assertEq(_tracked(intentId, address(tokenIn)), DEPOSITED, "tracked input");
    } else {
      tokenOut.mint(address(mockFund), output);
      vm.expectEmit(true, true, true, true, address(facility));
      emit IFacility.TokenReceived(intentId, address(tokenOut), address(mockFund), output);
      facility.unlock(intentId);
      assertEq(_tracked(intentId, address(tokenOut)), output, "tracked output");
    }
    vm.stopPrank();
    _assertOrderEnded(intentId);
  }
}
