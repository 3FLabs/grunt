// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {ReentrantCollateral} from "../mock/manager/ReentrantCollateral.sol";
import {ReentrantMinter} from "../mock/manager/ReentrantMinter.sol";
import {MockBorrowPosition} from "../mock/borrow/MockBorrowPosition.sol";

/// @title PositionManagerSharePriceWindowTest
/// @notice Verifies that totalAssets()/totalSupply() cannot be observed mid-operation, even
///         through a debt/collateral token transfer hook fired during deposit() or withdraw().
contract PositionManagerSharePriceWindowTest is Test {
  using LibClone for address;

  uint256 constant POSITION_MANAGER_LTV = 0.7e18;
  uint128 constant BP_SAFE_LTV = 0.8e18;
  uint256 constant _ROLE_MINTER = 1 << 0;
  uint256 constant _ROLE_CURATOR = 1 << 1;

  address owner;
  PositionManager pm;
  MockERC20 collateral;
  ReentrantCollateral debt;
  MockBorrowPosition borrowPosition;
  ReentrantMinter attacker;

  function setUp() public {
    owner = makeAddr("owner");

    collateral = new MockERC20("Collateral", "COLL", 18);
    debt = new ReentrantCollateral();

    pm = PositionManager(address(new PositionManager()).clone());
    pm.initialize(
      owner,
      PositionManagerMetadata({
        name: "PM Window", symbol: "PMW", collateralAsset: address(collateral), debtAsset: address(debt)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );

    borrowPosition = new MockBorrowPosition(address(collateral), address(debt));
    borrowPosition.setSafeLtv(BP_SAFE_LTV);
    borrowPosition.setAvailableLiquidity(1_000_000e18);

    // addBorrowModule requires Ownable(module).owner() == address(pm); fake it for the mock.
    vm.mockCall(address(borrowPosition), abi.encodeWithSignature("owner()"), abi.encode(address(pm)));

    attacker = new ReentrantMinter(pm);

    vm.startPrank(owner);
    pm.addBorrowModule(address(borrowPosition));
    pm.grantRoles(address(attacker), _ROLE_MINTER);
    pm.grantRoles(owner, _ROLE_CURATOR);

    SupplyQueueEntry[] memory sq = new SupplyQueueEntry[](1);
    sq[0] = SupplyQueueEntry({position: address(borrowPosition), maxBorrow: type(uint96).max});
    pm.setSupplyQueue(sq);
    address[] memory wq = new address[](1);
    wq[0] = address(borrowPosition);
    pm.setWithdrawalQueue(wq);
    vm.stopPrank();

    // Pre-fund the borrow position with debt liquidity so it can lend.
    debt.setBalance(address(borrowPosition), 1_000_000e18);
    // Fund the attacker with collateral for deposits.
    collateral.setBalance(address(attacker), 100e18);
    vm.prank(address(attacker));
    collateral.approve(address(pm), type(uint256).max);
    vm.prank(address(attacker));
    debt.approve(address(pm), type(uint256).max);
  }

  /// @notice During deposit, the debt-token transfer to the caller fires a callback that tries
  ///         to read totalSupply()/totalAssets(). The reads must revert with Reentrancy() so an
  ///         external integrator cannot price PM shares against mid-operation state.
  function test_deposit_viewReadDuringDebtTransferReverts() public {
    debt.setCallbackEnabled(true);
    attacker.setAttackType(ReentrantMinter.AttackType.READ_VIEWS);

    vm.prank(address(attacker));
    pm.deposit(50e18, 10e18);

    assertTrue(attacker.totalSupplyReadReverted(), "totalSupply() read should revert during deposit");
    assertTrue(attacker.totalAssetsReadReverted(), "totalAssets() read should revert during deposit");
  }

  /// @notice During withdraw, the collateral-token transfer to the caller fires a callback that
  ///         tries to read totalSupply()/totalAssets(). The reads must revert.
  function test_withdraw_viewReadDuringCollateralTransferReverts() public {
    // Seed a position first (no callback yet).
    debt.setCallbackEnabled(false);
    vm.prank(address(attacker));
    pm.deposit(50e18, 10e18);

    // Deploy a hookable collateral and rewire by re-initializing in a fresh PM.
    // Easier: swap to a hookable collateral via a second PM dedicated to withdraw.
    PositionManager pm2 = PositionManager(address(new PositionManager()).clone());
    ReentrantCollateral hookableCollateral = new ReentrantCollateral();
    pm2.initialize(
      owner,
      PositionManagerMetadata({
        name: "PM Window 2", symbol: "PMW2", collateralAsset: address(hookableCollateral), debtAsset: address(debt)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );
    MockBorrowPosition bp2 = new MockBorrowPosition(address(hookableCollateral), address(debt));
    bp2.setSafeLtv(BP_SAFE_LTV);
    bp2.setAvailableLiquidity(1_000_000e18);
    vm.mockCall(address(bp2), abi.encodeWithSignature("owner()"), abi.encode(address(pm2)));

    ReentrantMinter attacker2 = new ReentrantMinter(pm2);

    vm.startPrank(owner);
    pm2.addBorrowModule(address(bp2));
    pm2.grantRoles(address(attacker2), _ROLE_MINTER);
    pm2.grantRoles(owner, _ROLE_CURATOR);
    SupplyQueueEntry[] memory sq = new SupplyQueueEntry[](1);
    sq[0] = SupplyQueueEntry({position: address(bp2), maxBorrow: type(uint96).max});
    pm2.setSupplyQueue(sq);
    address[] memory wq = new address[](1);
    wq[0] = address(bp2);
    pm2.setWithdrawalQueue(wq);
    vm.stopPrank();

    debt.setBalance(address(bp2), 1_000_000e18);
    hookableCollateral.setBalance(address(attacker2), 100e18);
    vm.prank(address(attacker2));
    hookableCollateral.approve(address(pm2), type(uint256).max);
    vm.prank(address(attacker2));
    debt.approve(address(pm2), type(uint256).max);

    // Seed position on pm2 with callback disabled.
    hookableCollateral.setCallbackEnabled(false);
    vm.prank(address(attacker2));
    pm2.deposit(50e18, 10e18);

    // Now arm the callback and withdraw collateral.
    hookableCollateral.setCallbackEnabled(true);
    attacker2.setAttackType(ReentrantMinter.AttackType.READ_VIEWS);
    vm.prank(address(attacker2));
    pm2.withdraw(5e18, 0, WithdrawalStrategy.SEQUENTIAL);

    assertTrue(attacker2.totalSupplyReadReverted(), "totalSupply() read should revert during withdraw");
    assertTrue(attacker2.totalAssetsReadReverted(), "totalAssets() read should revert during withdraw");
  }

  /// @notice Outside any guarded operation, public views must work normally.
  function test_views_workOutsideOperation() public {
    debt.setCallbackEnabled(false);
    vm.prank(address(attacker));
    pm.deposit(50e18, 10e18);

    // These calls must succeed.
    pm.totalSupply();
    pm.totalAssets();
    pm.collateralAmount();
    pm.collateralAmountQuoted();
    pm.debtAmount();
    pm.pendingFees();
  }
}
