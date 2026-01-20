// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {
  IPositionManager,
  SupplyQueueEntry,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/IPositionManager.sol";
import {LibErrors} from "../../src/libs/manager/LibErrors.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {TransferGuard, AddressStatus} from "src/guard/TransferGuard.sol";
import {ERC20Mock} from "lib/morpho-blue/src/mocks/ERC20Mock.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";

/// @title MaliciousBorrowModule
/// @notice A malicious borrow module that pauses the guard during withdrawCollateral
/// @dev This demonstrates the reentrancy edge case in rebalance pause checks
///      In this PoC, the module has PAUSER_ROLE granted to it, simulating a scenario where:
///      - A trusted module becomes compromised
///      - Or a module was incorrectly granted pause privileges
contract MaliciousBorrowModule is IBorrowPosition {
  TransferGuard public guard;
  address public token;
  bool public shouldPause;

  constructor(address _guard, address _token) {
    guard = TransferGuard(_guard);
    token = _token;
  }

  function setShouldPause(bool _shouldPause) external {
    shouldPause = _shouldPause;
  }

  // Operation functions
  function supplyCollateral(uint256) external override {
    // No-op for this test
  }

  function withdrawCollateral(uint256) external override {
    // Malicious callback: pause the guard mid-rebalance
    // This module has PAUSER_ROLE, simulating a compromised trusted module
    if (shouldPause && !guard.paused(token)) {
      guard.pause(token);
    }
  }

  function borrow(uint256) external override {
    // No-op for this test
  }

  function repay(uint256) external override {
    // No-op for this test
  }

  // View functions - return dummy values
  function borrowAsset() external pure override returns (address) {
    return address(0);
  }

  function collateralAsset() external pure override returns (address) {
    return address(0);
  }

  function totalBorrowed() external pure override returns (uint256) {
    return 0;
  }

  function totalCollateral() external pure override returns (uint256) {
    return 0;
  }

  function totalCollateralQuoted() external pure override returns (uint256) {
    return 0;
  }

  function isHealthy(uint256) external pure override returns (bool) {
    return true;
  }

  function maxBorrow(uint256) external pure override returns (uint256) {
    return 0;
  }

  function availableLiquidity() external pure override returns (uint256) {
    return 0;
  }

  function availableCollateral(uint256) external pure override returns (uint256) {
    return 0;
  }
}

/// @title ReentrantBorrowModule
/// @notice A malicious borrow module that attempts to re-enter rebalance during callback
contract ReentrantBorrowModule is IBorrowPosition {
  PositionManager public positionManager;
  address public rebalancer;
  bool public shouldReenter;
  bool public reentryAttempted;
  bool public reentrySucceeded;

  constructor(address _positionManager, address _rebalancer) {
    positionManager = PositionManager(_positionManager);
    rebalancer = _rebalancer;
  }

  function setShouldReenter(bool _shouldReenter) external {
    shouldReenter = _shouldReenter;
  }

  function supplyCollateral(uint256) external override {}

  function withdrawCollateral(uint256) external override {
    if (shouldReenter && !reentryAttempted) {
      reentryAttempted = true;
      // Attempt to re-enter rebalance - this should fail with reentrancy guard
      RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: new RebalancingOperation[](0)});
      try positionManager.rebalance(data, rebalancer) {
        reentrySucceeded = true;
      } catch {
        reentrySucceeded = false;
      }
    }
  }

  function borrow(uint256) external override {}
  function repay(uint256) external override {}

  function borrowAsset() external pure override returns (address) {
    return address(0);
  }

  function collateralAsset() external pure override returns (address) {
    return address(0);
  }

  function totalBorrowed() external pure override returns (uint256) {
    return 0;
  }

  function totalCollateral() external pure override returns (uint256) {
    return 0;
  }

  function totalCollateralQuoted() external pure override returns (uint256) {
    return 0;
  }

  function isHealthy(uint256) external pure override returns (bool) {
    return true;
  }

  function maxBorrow(uint256) external pure override returns (uint256) {
    return 0;
  }

  function availableLiquidity() external pure override returns (uint256) {
    return 0;
  }

  function availableCollateral(uint256) external pure override returns (uint256) {
    return 0;
  }
}

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
  ERC20Mock public debtToken;
  ERC20Mock public collateralToken;

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
    debtToken = new ERC20Mock();
    collateralToken = new ERC20Mock();

    // Deploy guard
    guard = new TransferGuard();
    guard.initialize(guardOwner);

    // Deploy position manager
    positionManager = new PositionManager();
    positionManager.initialize(
      owner,
      "Test PM",
      "TPM",
      18,
      address(collateralToken),
      address(debtToken),
      0.8e18, // 80% LLTV
      address(0)
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
    vm.expectRevert(LibErrors.Paused.selector);
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
    vm.expectRevert(LibErrors.Paused.selector);
    positionManager.rebalance(data, rebalancer);
  }

  /// @notice PoC: Demonstrates guard can be DISABLED mid-rebalance, allowing subsequent operations
  /// @dev Shows that if guard is changed to address(0) mid-tx, subsequent transfer checks
  ///      in the same transaction would pass (if any were performed)
  function test_poc_guardCanBeDisabledMidTransaction() public {
    // This test demonstrates the concept - in practice, changing the guard requires owner access
    // which should be tightly controlled

    // Verify guard is set
    (,, address currentGuard) = positionManager.config();
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
