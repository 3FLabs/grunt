// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Vm} from "forge-std/Vm.sol";
import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {MockMaliciousPositionManager} from "test/mock/manager/MockMaliciousPositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

/// @title FacilityPositionManagerTargetTest
/// @notice Position manager operations on an intent's target PM (useTarget = true)
contract FacilityPositionManagerTargetTest is FacilityBaseTest {
  uint256 constant COLLATERAL = 1000e18;
  uint256 constant BORROW = 500e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Resolving intent depositing the PM's collateral and targeting the PM
  function _createTargetIntent() internal returns (uint256 intentId) {
    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositAsset = Asset({asset: address(collateralToken), isPositionManager: false});
    vm.prank(owner);
    intentId = facility.createIntent(props);

    _mintCollateral(user, COLLATERAL);
    vm.prank(user);
    facility.deposit(intentId, COLLATERAL);
    vm.warp(block.timestamp + 1 days + 1);
  }

  /// @notice Target intent holding COLLATERAL - BORROW PM shares and BORROW debt
  function _createLeveredTargetIntent() internal returns (uint256 intentId) {
    intentId = _createTargetIntent();
    vm.prank(facilitator);
    facility.depositManager(intentId, COLLATERAL, BORROW, true);
  }

  function _tracked(uint256 id, address token) internal view returns (uint256) {
    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(id);
    for (uint256 i; i < tokens.length; ++i) {
      if (tokens[i] == token) return amounts[i];
    }
    return 0;
  }

  /// @notice Recorded Approval logs of `token` owned by the facility
  function _facilityApprovals(MockERC20 token) internal returns (uint256 count) {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    bytes32 facilityTopic = bytes32(uint256(uint160(address(facility))));
    for (uint256 i; i < logs.length; ++i) {
      if (
        logs[i].emitter == address(token) && logs[i].topics[0] == ERC20.Approval.selector
          && logs[i].topics[1] == facilityTopic
      ) ++count;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       DEPOSIT MANAGER                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_depositManager_useTargetAsset() public {
    uint256 intentId = _createTargetIntent();

    vm.expectEmit(true, true, true, true, address(collateralToken));
    emit ERC20.Approval(address(facility), address(positionManager), COLLATERAL);
    vm.expectEmit(true, true, true, true, address(collateralToken));
    emit ERC20.Approval(address(facility), address(positionManager), 0);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(collateralToken), address(positionManager), COLLATERAL);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(debtToken), address(positionManager), BORROW);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(positionManager), address(0), COLLATERAL - BORROW);
    vm.prank(facilitator);
    facility.depositManager(intentId, COLLATERAL, BORROW, true);

    assertEq(_tracked(intentId, address(collateralToken)), 0, "tracked collateral");
    assertEq(_tracked(intentId, address(debtToken)), BORROW, "tracked debt");
    assertEq(_tracked(intentId, address(positionManager)), COLLATERAL - BORROW, "tracked shares");
    assertEq(positionManager.balanceOf(address(facility)), COLLATERAL - BORROW, "shares held");
    assertEq(collateralToken.allowance(address(facility), address(positionManager)), 0, "allowance");
  }

  function test_depositManager_useTargetBorrowOnly() public {
    uint256 intentId = _createLeveredTargetIntent();

    vm.recordLogs();
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(debtToken), address(positionManager), 100e18);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(positionManager), address(0), 100e18);
    vm.prank(facilitator);
    facility.depositManager(intentId, 0, 100e18, true);

    assertEq(_facilityApprovals(collateralToken), 0, "collateral approvals");
    assertEq(_tracked(intentId, address(debtToken)), BORROW + 100e18, "tracked debt");
    assertEq(_tracked(intentId, address(positionManager)), COLLATERAL - BORROW - 100e18, "tracked shares");
  }

  function test_depositManager_revertWhenTargetNotPM() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AssetNotPositionManager.selector, address(debtToken)));
    facility.depositManager(intentId, 0, 1, true);
  }

  function test_depositManager_revertWhenTargetPMIsBothAssets() public {
    address pmAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    MockMaliciousPositionManager maliciousPM = new MockMaliciousPositionManager(pmAddr, pmAddr);
    assertEq(address(maliciousPM), pmAddr);

    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositAsset = Asset({asset: pmAddr, isPositionManager: false});
    props.targetAsset = Asset({asset: pmAddr, isPositionManager: true});
    props.guardKey = pmAddr;
    vm.prank(owner);
    uint256 intentId = facility.createIntent(props);
    vm.warp(block.timestamp + 1 days + 1);

    vm.prank(facilitator);
    vm.expectRevert(LibFacilityErrors.InvalidPositionManagerAssets.selector);
    facility.depositManager(intentId, 0, 0, true);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WITHDRAW MANAGER                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdrawManager_useTargetAsset() public {
    uint256 intentId = _createLeveredTargetIntent();

    vm.expectEmit(true, true, true, true, address(debtToken));
    emit ERC20.Approval(address(facility), address(positionManager), 200e18);
    vm.expectEmit(true, true, true, true, address(debtToken));
    emit ERC20.Approval(address(facility), address(positionManager), 0);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(collateralToken), address(positionManager), 300e18);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(debtToken), address(positionManager), 200e18);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(positionManager), address(0), 100e18);
    vm.prank(facilitator);
    facility.withdrawManager(intentId, 300e18, 200e18, true, WithdrawalStrategy.SEQUENTIAL);

    assertEq(_tracked(intentId, address(collateralToken)), 300e18, "tracked collateral");
    assertEq(_tracked(intentId, address(debtToken)), BORROW - 200e18, "tracked debt");
    assertEq(_tracked(intentId, address(positionManager)), COLLATERAL - BORROW - 100e18, "tracked shares");
    assertEq(debtToken.allowance(address(facility), address(positionManager)), 0, "allowance");
  }

  function test_withdrawManager_useTargetWithdrawOnly() public {
    uint256 intentId = _createLeveredTargetIntent();

    vm.recordLogs();
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(collateralToken), address(positionManager), 100e18);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(positionManager), address(0), 100e18);
    vm.prank(facilitator);
    facility.withdrawManager(intentId, 100e18, 0, true, WithdrawalStrategy.SEQUENTIAL);

    assertEq(_facilityApprovals(debtToken), 0, "debt approvals");
    assertEq(_tracked(intentId, address(collateralToken)), 100e18, "tracked collateral");
    assertEq(_tracked(intentId, address(positionManager)), COLLATERAL - BORROW - 100e18, "tracked shares");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        BURN MANAGER                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_burnManager_useTargetAsset() public {
    uint256 intentId = _createLeveredTargetIntent();
    // shares / (supply + virtual offset 1): collateral 1000e18 * 100e18 / (500e18 + 1) floors, debt ceils to 100e18
    uint256 collateralOut = 199_999_999_999_999_999_999;

    vm.expectEmit(true, true, true, true, address(debtToken));
    emit ERC20.Approval(address(facility), address(positionManager), type(uint256).max);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenReceived(intentId, address(collateralToken), address(positionManager), collateralOut);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(debtToken), address(positionManager), 100e18);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacility.TokenSent(intentId, address(positionManager), address(0), 100e18);
    vm.expectEmit(true, true, true, true, address(debtToken));
    emit ERC20.Approval(address(facility), address(positionManager), 0);
    vm.prank(facilitator);
    facility.burnManager(intentId, 100e18, true, WithdrawalStrategy.PROPORTIONAL);

    assertEq(_tracked(intentId, address(collateralToken)), collateralOut, "tracked collateral");
    assertEq(_tracked(intentId, address(debtToken)), BORROW - 100e18, "tracked debt");
    assertEq(_tracked(intentId, address(positionManager)), COLLATERAL - BORROW - 100e18, "tracked shares");
    assertEq(debtToken.allowance(address(facility), address(positionManager)), 0, "allowance");
  }
}
