// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {IPositionManager, SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {LibManagerErrors} from "../../src/libs/manager/LibManagerErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../src/libs/common/LibCommonErrors.sol";
import {TransferGuard, AddressStatus} from "src/guard/TransferGuard.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";

import {MaliciousBorrowModule} from "test/mock/guard/MaliciousBorrowModule.sol";
import {ReentrantBorrowModule} from "test/mock/guard/ReentrantBorrowModule.sol";

/// @title TransferGuardReentrancyTest
/// @notice PoC demonstrating that guard state changes mid-rebalance are not re-checked
/// @dev This test shows that:
///      1. The pause check in rebalance() happens only at the start
///      2. If a malicious borrow module pauses the guard during its callback,
///         the rebalance continues to completion
///      3. This is documented behavior since only trusted modules should be added,
///         but demonstrates the importance of this trust assumption
contract TransferGuardReentrancyTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  PositionManager public positionManager;
  TransferGuard public guard;
  MaliciousBorrowModule public maliciousModule;
  MockERC20 public debtToken;
  MockERC20 public collateralToken;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public guardOwner;
  address public minter;
  address public rebalancer;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant _ROLE_MINTER = 1 << 0;
  uint256 constant _ROLE_REBALANCER = 1 << 2;
  uint256 constant PAUSER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    owner = makeAddr("owner");
    guardOwner = makeAddr("guardOwner");
    minter = makeAddr("minter");
    rebalancer = makeAddr("rebalancer");

    // Deploy tokens
    debtToken = new MockERC20("Debt Token", "DEBT", 18);
    collateralToken = new MockERC20("Collateral Token", "COLL", 18);

    // Deploy guard
    guard = new TransferGuard();
    guard.initialize(guardOwner);

    // Deploy position manager
    positionManager = new PositionManager();
    positionManager.initialize(
      owner,
      PositionManagerMetadata({
        name: "Test PM",
        symbol: "TPM",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      0.8e18, // 80% LTV
      address(0),
      0,
      0
    );

    // Deploy malicious module
    maliciousModule = new MaliciousBorrowModule(address(guard), address(positionManager));

    // Grant PAUSER_ROLE to malicious module (simulating compromised trusted module)
    vm.prank(guardOwner);
    guard.grantRoles(address(maliciousModule), PAUSER_ROLE);

    // Setup roles
    vm.startPrank(owner);
    positionManager.grantRoles(minter, _ROLE_MINTER);
    positionManager.grantRoles(rebalancer, _ROLE_REBALANCER);
    positionManager.addBorrowModule(address(maliciousModule));
    positionManager.setTransferGuard(address(guard));
    vm.stopPrank();

    // Configure guard (blocklist mode - minter can deposit/withdraw)
    vm.startPrank(guardOwner);
    guard.setTokenConfig(address(positionManager), false, false);
    vm.stopPrank();

    // Setup approvals
    vm.startPrank(minter);
    debtToken.approve(address(positionManager), type(uint256).max);
    collateralToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();

    // Label contracts
    vm.label(address(positionManager), "PositionManager");
    vm.label(address(guard), "TransferGuard");
    vm.label(address(maliciousModule), "MaliciousBorrowModule");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REENTRANCY POC TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice PoC: Demonstrates that rebalance completes even if guard is paused mid-transaction
  /// @dev This test shows the edge case where:
  ///      1. Rebalance starts with guard NOT paused (passes initial check)
  ///      2. Malicious module pauses guard during withdrawCollateral callback
  ///      3. Rebalance completes successfully despite guard now being paused
  ///      4. The guard remains paused after the transaction
  ///
  ///      Security implications:
  ///      - This is NOT a vulnerability if only trusted modules are added (as intended)
  ///      - However, it highlights that the pause check is point-in-time, not continuous
  ///      - A compromised/malicious module could exploit this to complete rebalances
  ///        that should have been blocked
  function test_poc_rebalanceContinuesDespiteMidTransactionPause() public {
    // Verify guard is not paused initially
    assertFalse(guard.paused(address(positionManager)), "Guard should not be paused initially");

    // Enable malicious behavior
    maliciousModule.setShouldPause(true);

    // Create rebalance operation that triggers the malicious callback
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(maliciousModule), amount: 0, operationType: RebalancingOperationType.WITHDRAW
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    // Execute rebalance - this should succeed even though guard gets paused mid-tx
    vm.prank(rebalancer);
    positionManager.rebalance(data, rebalancer);

    // Verify guard is now paused (was paused during the rebalance)
    assertTrue(guard.paused(address(positionManager)), "Guard should be paused after rebalance");

    // Verify that a NEW rebalance would now be blocked
    vm.prank(rebalancer);
    vm.expectRevert(CommonErrors.Paused.selector);
    positionManager.rebalance(data, rebalancer);
  }

  /// @notice Demonstrates normal behavior: rebalance blocked when guard is paused BEFORE start
  function test_rebalanceBlockedWhenPausedBeforeStart() public {
    // Pause guard before rebalance
    vm.prank(guardOwner);
    guard.pause(address(positionManager));

    assertTrue(guard.paused(address(positionManager)), "Guard should be paused");

    // Create empty rebalance operation
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: new RebalancingOperation[](0)});

    // Rebalance should fail because guard is paused at the start
    vm.prank(rebalancer);
    vm.expectRevert(CommonErrors.Paused.selector);
    positionManager.rebalance(data, rebalancer);
  }

  /// @notice PoC: Demonstrates guard can be DISABLED mid-rebalance, allowing subsequent operations
  /// @dev Shows that if guard is changed to address(0) mid-tx, subsequent transfer checks
  ///      in the same transaction would pass (if any were performed)
  function test_poc_guardCanBeDisabledMidTransaction() public {
    // This test demonstrates the concept - in practice, changing the guard requires owner access
    // which should be tightly controlled

    // Verify guard is set
    (,, address currentGuard,,) = positionManager.config();
    assertEq(currentGuard, address(guard), "Guard should be set");

    // In a hypothetical attack scenario:
    // 1. A callback during rebalance could call positionManager.setTransferGuard(address(0))
    //    if the callback has owner privileges (e.g., through a compromised multisig)
    // 2. This would disable all transfer restrictions for the remainder of the transaction
    // 3. Any shares minted/transferred after this point would bypass the guard

    // The mitigation is:
    // - Only add trusted borrow modules
    // - Use timelocks for setTransferGuard changes
    // - The nonReentrant modifier on rebalance prevents re-entry attacks
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                REENTRANCY GUARD PROTECTION                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Demonstrates that the reentrancy guard prevents re-entry during rebalance
  /// @dev A malicious module that tries to re-enter rebalance will fail due to nonReentrant
  function test_reentrancyGuardPreventsReentry() public {
    // Deploy reentrant module
    ReentrantBorrowModule reentrantModule = new ReentrantBorrowModule(address(positionManager), rebalancer);

    // Add reentrant module and grant it rebalancer role (to attempt re-entry)
    vm.startPrank(owner);
    positionManager.addBorrowModule(address(reentrantModule));
    positionManager.grantRoles(address(reentrantModule), _ROLE_REBALANCER);
    vm.stopPrank();

    // Enable reentry attempt
    reentrantModule.setShouldReenter(true);

    // Create rebalance operation that triggers the reentrant callback
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(reentrantModule), amount: 0, operationType: RebalancingOperationType.WITHDRAW
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    // Execute rebalance - the module will try to re-enter but fail
    vm.prank(rebalancer);
    positionManager.rebalance(data, rebalancer);

    // Verify re-entry was attempted but failed
    assertTrue(reentrantModule.reentryAttempted(), "Reentry should have been attempted");
    assertFalse(reentrantModule.reentrySucceeded(), "Reentry should have failed due to reentrancy guard");
  }
}
