// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ParetoFund} from "src/funds/pareto/ParetoFund.sol";
import {ParetoFundFactory} from "src/funds/pareto/ParetoFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";
import {IIdleCDOEpochVariant} from "src/interfaces/integrations/pareto/IIdleCDOEpochVariant.sol";
import {IIdleCreditVault} from "src/interfaces/integrations/pareto/IIdleCreditVault.sol";

/// @dev Extended interface for calling CDO admin functions in fork tests.
interface IIdleCDOFork {
  function stopEpoch(uint256 _newApr, uint256 _interest) external;
  function startEpoch() external;
  function setKeyringParams(address, uint256, bool) external;
  function expectedEpochInterest() external view returns (uint256);
  function pendingWithdrawFees() external view returns (uint256);
  function epochDuration() external view returns (uint256);
  function bufferPeriod() external view returns (uint256);
}

/// @dev Extended interface for reading strategy state in fork tests.
interface IIdleCreditVaultFork {
  function pendingWithdraws() external view returns (uint256);
  function borrower() external view returns (address);
  function manager() external view returns (address);
}

/// @notice Fork tests for ParetoFund against mainnet FalconX Credit Vault (IdleCDOEpochVariant).
/// @dev Epoch simulation uses impersonation of the CDO owner/manager to call startEpoch/stopEpoch,
///      and deals USDC to the borrower to fund interest payments and withdrawal fulfillment.
contract ParetoFundForkTest is Test {
  using LibOrder for Order;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address constant CDO = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d;
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address constant AA_TRANCHE = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C;
  address constant STRATEGY = 0x17E9Ab2992dfecBe779a06A92a6cDB9fE6aEeEf3;
  address constant CDO_OWNER = 0xFb3bD022D5DAcF95eE28a6B07825D4Ff9C5b3814;

  uint256 constant EPOCH_END_DATE = 1772542271;
  uint256 constant BUFFER_PERIOD = 21600;

  uint256 constant ONE = 1e6;
  uint256 constant ISSUER_ROLE = 1 << 0;
  uint256 constant SENDER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           STATE                               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  ParetoFundFactory factory;
  ParetoFund fund;
  WrappedAsset wrappedShare;
  address owner;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC_URL"));

    owner = makeAddr("owner");

    // Deploy WrappedAsset proxy wrapping the real AA tranche token
    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, AA_TRANCHE, "wAA", "Wrapped AA Tranche");

    // Deploy fund via factory
    factory = new ParetoFundFactory(owner);
    address fundAddress = factory.createFund(owner, address(this), CDO, address(wrappedShare));
    fund = ParetoFund(fundAddress);

    // Grant roles on wrappedShare
    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    vm.prank(owner);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);

    // Disable Keyring KYC on CDO
    vm.prank(CDO_OWNER);
    IIdleCDOFork(CDO).setKeyringParams(address(0), 0, true);

    // Stop the currently running epoch to normalize state
    _stopCurrentEpoch();

    // Fund test contract with USDC
    _dealUSDC(address(this), 1_000_000 * ONE);
  }

  /// @dev Stops the epoch that is running at fork time.
  ///      Warps past epoch end + buffer, funds the borrower, and calls stopEpoch.
  function _stopCurrentEpoch() internal {
    // Warp past epoch end + buffer so startEpoch/stopEpoch conditions are satisfied
    vm.warp(EPOCH_END_DATE + BUFFER_PERIOD + 1);

    // Fund borrower with enough USDC for expectedEpochInterest + pendingWithdraws + margin
    address borrower = IIdleCreditVaultFork(STRATEGY).borrower();
    uint256 expectedInterest = IIdleCDOFork(CDO).expectedEpochInterest();
    uint256 pendingWithdraws = IIdleCreditVaultFork(STRATEGY).pendingWithdraws();
    uint256 borrowerNeeds = expectedInterest + pendingWithdraws + 1_000 * ONE;
    _dealUSDC(borrower, borrowerNeeds);

    // Approve CDO to pull from borrower
    vm.prank(borrower);
    IERC20(USDC).approve(CDO, type(uint256).max);

    // Stop epoch via manager (uses stored expectedEpochInterest)
    address manager = IIdleCreditVaultFork(STRATEGY).manager();
    vm.prank(manager);
    IIdleCDOFork(CDO).stopEpoch(0, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST SCENARIOS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Fork_FullDepositLifecycle() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = _computeExpectedShares(depositAmount);

    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);

    // Commit: depositAA is atomic, mints AA tranche tokens immediately
    _commitDeposit(order);

    // After commit, fund holds AA tokens >= expectedShares → state is UNLOCKING
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after commit");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertGe(amount, expectedShares, "shares received");
    assertEq(wrappedShare.balanceOf(address(this)), amount, "wAA balance");
  }

  function test_Fork_FullRedeemLifecycle() public {
    // First deposit to get wrapped shares
    uint256 depositAmount = 1000 * ONE;
    uint256 shares = _computeExpectedShares(depositAmount);
    uint256 actualShares = _doFullDeposit(depositAmount, shares);

    // Compute expected USDC output from redeeming actualShares
    uint256 virtualPrice = IIdleCDOEpochVariant(CDO).virtualPrice(AA_TRANCHE);
    uint256 expectedAssets = actualShares * virtualPrice / 1e18;

    Order memory order = _redeemOrder(actualShares, expectedAssets);
    fund.create(order);

    // Approve wrapped shares and commit (requestWithdraw)
    wrappedShare.approve(address(fund), actualShares);
    fund.commit(order);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing after commit");

    // Advance epoch so withdrawal becomes claimable
    _advanceEpoch();

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after epoch");

    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertGt(amount, 0, "assets received");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, amount, "USDC balance increased");
  }

  function test_Fork_DepositCancelLifecycle() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = _computeExpectedShares(depositAmount);

    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);

    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "accepted");

    // Cancel before commit (ACCEPTED state)
    fund.cancel(order);

    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "empty after cancel");
  }

  function test_Fork_ViewFunctions() public view {
    assertEq(fund.asset(), USDC, "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.vault(), CDO, "vault");

    // totalAssets should be 0 (no shares minted yet)
    assertEq(fund.totalAssets(), 0, "totalAssets zero");

    // maxDeposit returns type(uint256).max
    assertEq(fund.maxDeposit(address(this)), type(uint256).max, "maxDeposit");

    // maxRedeem returns wrappedShare balance (0 initially)
    assertEq(fund.maxRedeem(address(this)), 0, "maxRedeem zero");

    // virtualPrice sanity: ~1.067 in 6-decimal underlying precision (USDC)
    uint256 virtualPrice = IIdleCDOEpochVariant(CDO).virtualPrice(AA_TRANCHE);
    assertGt(virtualPrice, 1e6, "virtualPrice > 1e6");
    assertLt(virtualPrice, 1.2e6, "virtualPrice < 1.2e6");
  }

  function test_Fork_TotalAssetsAfterDeposit() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = _computeExpectedShares(depositAmount);
    uint256 actualShares = _doFullDeposit(depositAmount, expectedShares);

    uint256 virtualPrice = IIdleCDOEpochVariant(CDO).virtualPrice(AA_TRANCHE);
    uint256 expectedTotalAssets = wrappedShare.totalSupply() * virtualPrice / 1e18;

    assertEq(fund.totalAssets(), expectedTotalAssets, "totalAssets matches formula");
    assertGt(fund.totalAssets(), 0, "totalAssets non-zero");
    assertEq(wrappedShare.totalSupply(), actualShares, "wrappedShare supply matches");
  }

  function test_Fork_NotPermissioned() public {
    // Re-enable keyring on CDO (restore KYC check)
    vm.prank(CDO_OWNER);
    IIdleCDOFork(CDO).setKeyringParams(address(1), 18, false);

    // Deploy a second fund (not whitelisted by keyring)
    address fundAddress2 = factory.createFund(owner, address(this), CDO, address(wrappedShare));
    ParetoFund fund2 = ParetoFund(fundAddress2);

    vm.prank(owner);
    wrappedShare.grantRoles(fundAddress2, ISSUER_ROLE);

    Order memory order = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: 1000 * ONE,
      output: _computeExpectedShares(1000 * ONE),
      salt: keccak256("fork-no-perm")
    });

    // The keyring check reverts inside the CDO (not with our custom error),
    // so we just check that create() reverts
    vm.expectRevert();
    fund2.create(order);
  }

  function test_Fork_RecoverAlwaysReverts() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = _computeExpectedShares(depositAmount);

    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);
    _commitDeposit(order);

    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recover(order);
  }

  function test_Fork_ResolveAndUnlock() public {
    uint256 depositAmount = 1000 * ONE;
    // Overestimate output so state stays PROCESSING after commit
    uint256 overestimatedShares = _computeExpectedShares(depositAmount) * 2;

    Order memory order = _depositOrder(depositAmount, overestimatedShares);
    fund.create(order);
    _commitDeposit(order);

    // State should be PROCESSING because balance < overestimatedShares
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing (overestimated)");

    // Owner resolves with actual output (resolve stores resolved amounts but keeps original order ID)
    uint256 actualBalance = IERC20(AA_TRANCHE).balanceOf(address(fund));
    vm.prank(owner);
    fund.resolve(order, depositAmount, actualBalance);

    // After resolve, the original order is still the current order — use it for state/unlock
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after resolve");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, actualBalance, "shares received");
    assertEq(wrappedShare.balanceOf(address(this)), actualBalance, "wAA balance");
  }

  function test_Fork_MultipleSequentialOrders() public {
    // --- First order: full deposit lifecycle ---
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = _computeExpectedShares(depositAmount);
    uint256 actualShares = _doFullDeposit(depositAmount, expectedShares);

    Order memory depositOrder = _depositOrder(depositAmount, expectedShares);
    assertEq(uint256(fund.state(depositOrder)), uint256(State.ENDED), "deposit ended");

    // --- Second order: full redeem lifecycle ---
    uint256 virtualPrice = IIdleCDOEpochVariant(CDO).virtualPrice(AA_TRANCHE);
    uint256 expectedAssets = actualShares * virtualPrice / 1e18;

    Order memory redeemOrder = _redeemOrder(actualShares, expectedAssets);
    fund.create(redeemOrder);

    // Archived deposit order should still return ENDED
    assertEq(uint256(fund.state(depositOrder)), uint256(State.ENDED), "archived deposit still ENDED");

    wrappedShare.approve(address(fund), actualShares);
    fund.commit(redeemOrder);

    _advanceEpoch();

    (State state, uint256 amount) = fund.unlock(redeemOrder);
    assertEq(uint256(state), uint256(State.ENDED), "redeem ended");
    assertGt(amount, 0, "redeem assets received");

    // Both orders should return ENDED
    assertEq(uint256(fund.state(depositOrder)), uint256(State.ENDED), "deposit still ENDED");
    assertEq(uint256(fund.state(redeemOrder)), uint256(State.ENDED), "redeem ENDED");
  }

  function test_Fork_DepositDuringEpoch() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = _computeExpectedShares(depositAmount);

    // Start a new epoch so the CDO is paused (depositAA would revert)
    address manager = IIdleCreditVaultFork(STRATEGY).manager();
    vm.prank(manager);
    IIdleCDOFork(CDO).startEpoch();
    assertTrue(IIdleCDOEpochVariant(CDO).isEpochRunning(), "epoch running");

    // Create and commit deposit — should route to depositDuringEpoch
    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);
    _commitDeposit(order);

    // Fund should have received AA tranche tokens (possibly fewer due to prorated price)
    uint256 fundBalance = IERC20(AA_TRANCHE).balanceOf(address(fund));
    assertGt(fundBalance, 0, "fund received AA tokens");
    // The discounted amount should be less than or equal to the between-epoch amount
    assertLe(fundBalance, expectedShares * 101 / 100, "within expected range");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTERNAL HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Sets USDC balance for `to` by writing to the proxy's balance mapping (slot 9).
  function _dealUSDC(address to, uint256 amount) internal {
    bytes32 slot = keccak256(abi.encode(to, uint256(9)));
    vm.store(USDC, slot, bytes32(amount));
  }

  /// @dev Computes expected AA tranche tokens from a USDC deposit amount.
  function _computeExpectedShares(uint256 usdcAmount) internal view returns (uint256) {
    return usdcAmount * 1e18 / IIdleCDOEpochVariant(CDO).virtualPrice(AA_TRANCHE);
  }

  /// @dev Runs a full epoch cycle (start → warp → fund borrower → stop) to advance the strategy's epochNumber.
  function _advanceEpoch() internal {
    address manager = IIdleCreditVaultFork(STRATEGY).manager();
    address borrower = IIdleCreditVaultFork(STRATEGY).borrower();

    // 1. Start new epoch (pauses CDO, sets new epochEndDate)
    vm.prank(manager);
    IIdleCDOFork(CDO).startEpoch();

    // 2. Warp past the new epoch end date
    uint256 newEpochEndDate = IIdleCDOEpochVariant(CDO).epochEndDate();
    vm.warp(newEpochEndDate + 1);

    // 3. Fund borrower for interest + pending withdrawals
    uint256 expectedInterest = IIdleCDOFork(CDO).expectedEpochInterest();
    uint256 pendingWithdraws = IIdleCreditVaultFork(STRATEGY).pendingWithdraws();
    uint256 borrowerNeeds = expectedInterest + pendingWithdraws + 1_000 * ONE;
    _dealUSDC(borrower, borrowerNeeds);

    // 4. Approve CDO to pull from borrower
    vm.prank(borrower);
    IERC20(USDC).approve(CDO, type(uint256).max);

    // 5. Stop epoch (increments epochNumber, unpauses)
    vm.prank(manager);
    IIdleCDOFork(CDO).stopEpoch(0, 0);
  }

  /// @dev Executes a full deposit cycle (create → commit → unlock) and returns actual shares received.
  function _doFullDeposit(uint256 depositAmount, uint256 expectedShares) internal returns (uint256 actualShares) {
    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);
    _commitDeposit(order);
    (, actualShares) = fund.unlock(order);
  }

  function _commitDeposit(Order memory order) internal {
    IERC20(USDC).approve(address(fund), order.input);
    fund.commit(order);
  }

  function _depositOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      salt: keccak256("fork-deposit")
    });
  }

  function _redeemOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      salt: keccak256("fork-redeem")
    });
  }
}
