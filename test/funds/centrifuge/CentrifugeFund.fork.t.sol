// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentrifugeFund} from "src/funds/centrifuge/CentrifugeFund.sol";
import {CentrifugeFundFactory} from "src/funds/centrifuge/CentrifugeFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";
import {ICentrifugeVault} from "src/interfaces/integrations/centrifuge/ICentrifugeVault.sol";

/// @notice Fork tests for CentrifugeFund against mainnet Centrifuge JTRSY/USDC vault.
/// @dev Epoch simulation uses the Spoke's gateway adapter to call executeTransferShares
///      (minting shares to the pool escrow) and BalanceSheet.deposit (setting up escrow accounting),
///      then sets ARM investment state via vm.store to make shares claimable.
contract CentrifugeFundForkTest is Test {
  using LibOrder for Order;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address constant VAULT = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address constant SHARE_TOKEN = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
  address constant HOOK = 0x8E680873b4C77e6088b4Ba0aBD59d100c3D224a4;
  address constant ARM = 0xF48256AbDDf96EcDDc4B3DbD23E8C1921f9761Ae;
  address constant SPOKE = 0xEC3582fcDc34078a4B7a8c75a5a3AE46f48525aB;
  address constant BALANCE_SHEET = 0x12a110cE5f0FC871cC72Bc7ECaF35cf39DD0f43e;
  /// @dev The pool-specific escrow (balanceSheet.escrow(poolId)) where tokens are actually held.
  address constant POOL_ESCROW = 0x0665FDe254598e307b63f3aAe3cCd881a62d4bE3;
  uint64 constant POOL_ID = 281474976710662;
  bytes16 constant SC_ID = 0x00010000000000060000000000000001;

  uint256 constant ARM_INVESTMENTS_SLOT = 5;
  uint256 constant ONE = 1e6;
  uint256 constant ISSUER_ROLE = 1 << 0;
  uint256 constant SENDER_ROLE = 1 << 1;

  /// @dev ARM reason constant for deposit reserves.
  uint32 constant REASON_DEPOSIT = 1;
  /// @dev ARM reason constant for redeem reserves.
  uint32 constant REASON_REDEEM = 2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           STATE                               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  CentrifugeFundFactory factory;
  CentrifugeFund fund;
  WrappedAsset wrappedShare;
  address owner;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC_URL"));

    owner = makeAddr("owner");

    // Deploy WrappedAsset proxy wrapping the real share token
    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, SHARE_TOKEN, "wJTRSY", "Wrapped JTRSY");

    // Deploy fund via factory
    factory = new CentrifugeFundFactory(owner);
    address fundAddress = factory.createFund(owner, address(this), VAULT, address(wrappedShare));
    fund = CentrifugeFund(fundAddress);

    // Grant roles
    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    vm.prank(owner);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);

    // Permissioning: add fund and wrappedShare as pool members via Hook
    _addMember(address(fund));
    _addMember(address(wrappedShare));

    // Fund test contract with USDC (deal doesn't work with USDC proxy, so use vm.store)
    _dealUSDC(address(this), 1_000_000 * ONE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST SCENARIOS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Fork_FullDepositLifecycle() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = ICentrifugeVault(VAULT).convertToShares(depositAmount);

    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);
    _commitDeposit(order);

    // Simulate epoch: fulfill deposit
    _fulfillDeposit(uint128(expectedShares));

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after epoch");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, expectedShares, "shares received");
    assertEq(wrappedShare.balanceOf(address(this)), expectedShares, "wShare balance");
  }

  function test_Fork_FullRedeemLifecycle() public {
    // First deposit to get wrapped shares
    uint256 depositAmount = 1000 * ONE;
    uint256 shares = ICentrifugeVault(VAULT).convertToShares(depositAmount);
    _doFullDeposit(depositAmount, shares);

    uint256 expectedAssets = ICentrifugeVault(VAULT).convertToAssets(shares);
    Order memory order = _redeemOrder(shares, expectedAssets);
    fund.create(order);

    // Approve and commit
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    // Simulate epoch: fulfill redeem
    _fulfillRedeem(uint128(expectedAssets));

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, expectedAssets, "assets received");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, expectedAssets, "USDC balance increased");
  }

  function test_Fork_DepositCancelLifecycle() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = ICentrifugeVault(VAULT).convertToShares(depositAmount);

    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);
    _commitDeposit(order);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    // Cancel request (owner only)
    vm.prank(owner);
    fund.cancelRequest(order);

    // Simulate cancel fulfillment
    _fulfillCancelDeposit(uint128(depositAmount));

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, depositAmount, "assets recovered");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, depositAmount, "USDC returned");
  }

  function test_Fork_PartialDepositFill() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = ICentrifugeVault(VAULT).convertToShares(depositAmount);

    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);
    _commitDeposit(order);

    // Partial epoch: only half filled
    uint128 halfShares = uint128(expectedShares / 2);
    uint128 halfAssets = uint128(depositAmount / 2);
    _fulfillPartialDeposit(halfShares, halfAssets);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking (partial)");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "back to processing");
    assertEq(amount, halfShares, "partial shares");
    assertEq(wrappedShare.balanceOf(address(this)), halfShares, "partial wShare balance");

    // Second epoch: remaining fills (may differ by 1 due to rounding)
    uint128 remainingShares = uint128(expectedShares) - halfShares;
    _fulfillDeposit(remainingShares);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking again");

    (State state2, uint256 amount2) = fund.unlock(order);
    assertEq(uint256(state2), uint256(State.ENDED), "ended");
    assertEq(amount2, remainingShares, "remaining shares");
    assertEq(wrappedShare.balanceOf(address(this)), halfShares + remainingShares, "full wShare balance");
  }

  function test_Fork_ViewFunctions() public view {
    assertEq(fund.asset(), USDC, "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.vault(), VAULT, "vault");

    // totalAssets should be 0 (no shares minted yet)
    assertEq(fund.totalAssets(), 0, "totalAssets zero");

    // Conversion rates should be non-zero and reflect real on-chain rates
    uint256 sharePer1000 = ICentrifugeVault(VAULT).convertToShares(1000 * ONE);
    uint256 assetPer1000 = ICentrifugeVault(VAULT).convertToAssets(1000 * ONE);
    assertGt(sharePer1000, 0, "convertToShares non-zero");
    assertGt(assetPer1000, 0, "convertToAssets non-zero");

    // Rate sanity: ~0.91 shares/USDC → 1000 USDC ≈ 910 shares
    assertGt(sharePer1000, 800 * ONE, "shares lower bound");
    assertLt(sharePer1000, 1000 * ONE, "shares upper bound");

    // maxDeposit returns min(balance, vault.maxDeposit) — vault may return 0 if no active epoch
    uint256 maxDep = fund.maxDeposit(address(this));
    assertLe(maxDep, IERC20(USDC).balanceOf(address(this)), "maxDeposit capped by balance");
  }

  function test_Fork_NotPermissioned() public {
    // Deploy second fund WITHOUT adding it as member
    address fundAddress2 = factory.createFund(owner, address(this), VAULT, address(wrappedShare));
    CentrifugeFund fund2 = CentrifugeFund(fundAddress2);

    vm.prank(owner);
    wrappedShare.grantRoles(fundAddress2, ISSUER_ROLE);

    Order memory order = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: 1000 * ONE,
      output: ICentrifugeVault(VAULT).convertToShares(1000 * ONE),
      salt: keccak256("fork-no-perm")
    });

    vm.expectRevert(LibFundsErrors.NotAllowedByFund.selector);
    fund2.create(order);
  }

  function test_Fork_RedeemCancelLifecycle() public {
    // First deposit to get wrapped shares
    uint256 depositAmount = 1000 * ONE;
    uint256 shares = ICentrifugeVault(VAULT).convertToShares(depositAmount);
    _doFullDeposit(depositAmount, shares);

    uint256 expectedAssets = ICentrifugeVault(VAULT).convertToAssets(shares);
    Order memory order = _redeemOrder(shares, expectedAssets);
    fund.create(order);

    // Approve and commit
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    // Cancel request (owner only)
    vm.prank(owner);
    fund.cancelRequest(order);

    // Simulate cancel fulfillment — shares returned to escrow
    _fulfillCancelRedeem(uint128(shares));

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, shares, "shares recovered");
    assertEq(wrappedShare.balanceOf(address(this)), shares, "wShare returned");
  }

  function test_Fork_PartialRedeemFill() public {
    // First deposit to get wrapped shares
    uint256 depositAmount = 1000 * ONE;
    uint256 shares = ICentrifugeVault(VAULT).convertToShares(depositAmount);
    _doFullDeposit(depositAmount, shares);

    uint256 expectedAssets = ICentrifugeVault(VAULT).convertToAssets(shares);
    Order memory order = _redeemOrder(shares, expectedAssets);
    fund.create(order);

    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    // Partial epoch: only half filled
    uint128 halfAssets = uint128(expectedAssets / 2);
    uint128 remainingShares = uint128(shares / 2);
    _fulfillPartialRedeem(halfAssets, remainingShares);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking (partial)");

    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state1, uint256 amount1) = fund.unlock(order);
    assertEq(uint256(state1), uint256(State.PROCESSING), "back to processing");
    assertEq(amount1, halfAssets, "partial assets");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, halfAssets, "partial USDC");

    // Second epoch: remaining fills
    uint128 remainingAssets = uint128(expectedAssets) - halfAssets;
    _fulfillRedeem(remainingAssets);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking again");

    uint256 usdcBefore2 = IERC20(USDC).balanceOf(address(this));
    (State state2, uint256 amount2) = fund.unlock(order);
    assertEq(uint256(state2), uint256(State.ENDED), "ended");
    assertEq(amount2, remainingAssets, "remaining assets");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore2, remainingAssets, "remaining USDC");
  }

  function test_Fork_SlippageGuard() public {
    uint256 inputAmount = 1000 * ONE;

    // Real on-chain rate: ~0.91 shares/USDC (rate > 1e18 means 1 share > 1 USDC)
    uint256 expectedShares = ICentrifugeVault(VAULT).convertToShares(inputAmount);
    assertLt(expectedShares, inputAmount, "rate sanity: shares < input");

    // 1) Exact match — should succeed
    Order memory exact = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: expectedShares,
      salt: keccak256("slippage-exact")
    });
    fund.create(exact);

    // Archive so we can create next order
    _commitDeposit(exact);
    _fulfillDeposit(uint128(expectedShares));
    fund.unlock(exact);

    // 2) Just over 5% deviation — should revert
    uint256 badOutput = expectedShares - (expectedShares * 501 / 10000) - 1;
    Order memory tooLow = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: badOutput,
      salt: keccak256("slippage-toolow")
    });
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(tooLow);

    // 3) Exactly at 5% boundary — should succeed
    uint256 boundaryOutput = expectedShares - (expectedShares * 500 / 10000);
    Order memory boundary = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: boundaryOutput,
      salt: keccak256("slippage-boundary")
    });
    fund.create(boundary);
  }

  function test_Fork_RequestDepositActuallyEscrows() public {
    uint256 depositAmount = 1000 * ONE;
    uint256 expectedShares = ICentrifugeVault(VAULT).convertToShares(depositAmount);

    Order memory order = _depositOrder(depositAmount, expectedShares);
    fund.create(order);

    uint256 escrowBefore = IERC20(USDC).balanceOf(POOL_ESCROW);
    _commitDeposit(order);
    uint256 escrowAfter = IERC20(USDC).balanceOf(POOL_ESCROW);

    // USDC should have moved to the pool escrow
    assertEq(escrowAfter - escrowBefore, depositAmount, "USDC escrowed in pool escrow");
    // Fund should not hold USDC
    assertEq(IERC20(USDC).balanceOf(address(fund)), 0, "fund has no USDC");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTERNAL HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Sets USDC balance for `to` by writing to the proxy's balance mapping (slot 9).
  function _dealUSDC(address to, uint256 amount) internal {
    bytes32 slot = keccak256(abi.encode(to, uint256(9)));
    vm.store(USDC, slot, bytes32(amount));
  }

  /// @dev Mints share tokens to `to` by impersonating the Spoke (a ward on the ShareToken).
  ///      This avoids fighting with the ShareToken's custom Balance struct storage layout.
  ///      The recipient must already be a pool member (POOL_ESCROW is by default).
  function _mintShares(address to, uint128 amount) internal {
    vm.prank(SPOKE);
    (bool ok,) = SHARE_TOKEN.call(abi.encodeWithSignature("mint(address,uint256)", to, uint256(amount)));
    require(ok, "mintShares failed");
  }

  /// @dev Adds `member` to the Centrifuge pool via the Hook's updateMember.
  function _addMember(address member) internal {
    vm.prank(SPOKE);
    (bool ok,) =
      HOOK.call(abi.encodeWithSignature("updateMember(address,address,uint64)", SHARE_TOKEN, member, type(uint64).max));
    require(ok, "addMember failed");
  }

  /// @dev Computes the ARM storage struct base slot for investments[vault][controller].
  function _armStructBase(address controller) internal pure returns (bytes32) {
    bytes32 innerSlot = keccak256(abi.encode(VAULT, ARM_INVESTMENTS_SLOT));
    return keccak256(abi.encode(controller, innerSlot));
  }

  /// @dev Simulates a full deposit epoch fulfillment:
  ///      1. Sets ARM investment state (maxMint + depositPrice)
  ///      2. Deals share tokens to the pool escrow
  ///      3. Sets up PoolEscrow holding and reserve accounting
  function _fulfillDeposit(uint128 shares) internal {
    _setArmMaxMint(shares);
    _setArmDepositPrice();
    _clearArmPendingDeposit();
    _mintShares(POOL_ESCROW, shares);
    _reserveViaBalanceSheet(SHARE_TOKEN, uint256(shares), REASON_DEPOSIT);
    // Clear the deposit's USDC reserve from the escrow. In reality, the Hub processes the epoch
    // and the pool consumes the USDC (unreserve + withdraw). Without this cleanup, the USDC
    // reserve blocks future scId-based withdrawals (e.g., redeem claims).
    _clearEscrowUsdcReserved();
  }

  /// @dev Clears pendingDepositRequest at ARM struct offset +2 (low 128 bits).
  ///      Empirically verified: struct layout is maxMint|maxWithdraw(+0), depositPrice(+1),
  ///      pendingDepositRequest|pendingRedeemRequest(+2), redeemPrice(+3),
  ///      claimableCancelDeposit|claimableCancelRedeem(+4), pendingCancelDeposit|pendingCancelRedeem(+5).
  function _clearArmPendingDeposit() internal {
    bytes32 structBase = _armStructBase(address(fund));
    bytes32 slot = bytes32(uint256(structBase) + 2);
    uint256 cur = uint256(vm.load(ARM, slot));
    vm.store(ARM, slot, bytes32(cur & (type(uint256).max << 128)));
  }

  /// @dev Simulates a partial deposit fill: sets maxMint and keeps pendingDepositRequest.
  function _fulfillPartialDeposit(uint128 shares, uint128 remainingAssets) internal {
    _fulfillDeposit(shares);
    _setArmPendingDeposit(remainingAssets);
  }

  /// @dev Simulates a full redeem epoch fulfillment.
  function _fulfillRedeem(uint128 assets) internal {
    _setArmMaxWithdraw(assets);
    _setArmRedeemPrice();
    _clearArmPendingRedeem();
    _dealUSDC(POOL_ESCROW, IERC20(USDC).balanceOf(POOL_ESCROW) + assets);
    // Increase escrow USDC holding total (low 128 bits) so the scId-based withdraw succeeds.
    _increaseEscrowUsdcHolding(assets);
    _reserveViaBalanceSheet(USDC, uint256(assets), REASON_REDEEM);
  }

  /// @dev Clears pendingRedeemRequest at ARM struct offset +2 (high 128 bits).
  function _clearArmPendingRedeem() internal {
    bytes32 structBase = _armStructBase(address(fund));
    bytes32 slot = bytes32(uint256(structBase) + 2);
    uint256 cur = uint256(vm.load(ARM, slot));
    vm.store(ARM, slot, bytes32(cur & type(uint128).max));
  }

  /// @dev Simulates a cancel-deposit fulfillment.
  ///      Cancel returns USDC to the escrow unreserved (the ARM's claimableCancelDeposit tracks the claim).
  function _fulfillCancelDeposit(uint128 assets) internal {
    _setArmClaimableCancelDeposit(assets);
    _clearArmPendingCancel();
    // Deal USDC to escrow — the cancel deposit flow doesn't go through BalanceSheet.reserve,
    // it's handled by the ARM directly reading claimableCancelDepositRequest.
    _dealUSDC(POOL_ESCROW, IERC20(USDC).balanceOf(POOL_ESCROW) + assets);
  }

  // ── ARM storage helpers ──

  function _setArmMaxMint(uint128 shares) internal {
    bytes32 structBase = _armStructBase(address(fund));
    uint256 cur = uint256(vm.load(ARM, structBase));
    vm.store(ARM, structBase, bytes32(uint256(shares) | (cur & (type(uint256).max << 128))));
  }

  function _setArmMaxWithdraw(uint128 assets) internal {
    bytes32 structBase = _armStructBase(address(fund));
    uint256 cur = uint256(vm.load(ARM, structBase));
    vm.store(ARM, structBase, bytes32((cur & type(uint128).max) | (uint256(assets) << 128)));
  }

  /// @dev Deposit price in low 128, redeem price in high 128 (slot +1).
  function _setArmDepositPrice() internal {
    bytes32 structBase = _armStructBase(address(fund));
    bytes32 slot = bytes32(uint256(structBase) + 1);
    uint256 cur = uint256(vm.load(ARM, slot));
    uint128 price = uint128(ICentrifugeVault(VAULT).convertToShares(1e18));
    vm.store(ARM, slot, bytes32(uint256(price) | (cur & (type(uint256).max << 128))));
  }

  /// @dev Redeem price in high 128 bits of slot +1.
  function _setArmRedeemPrice() internal {
    bytes32 structBase = _armStructBase(address(fund));
    bytes32 slot = bytes32(uint256(structBase) + 1);
    uint256 cur = uint256(vm.load(ARM, slot));
    uint128 price = uint128(ICentrifugeVault(VAULT).convertToAssets(1e18));
    vm.store(ARM, slot, bytes32((cur & type(uint128).max) | (uint256(price) << 128)));
  }

  /// @dev claimableCancelDepositRequest in low 128 bits of slot +3.
  function _setArmClaimableCancelDeposit(uint128 assets) internal {
    bytes32 structBase = _armStructBase(address(fund));
    bytes32 slot = bytes32(uint256(structBase) + 3);
    uint256 cur = uint256(vm.load(ARM, slot));
    vm.store(ARM, slot, bytes32(uint256(assets) | (cur & (type(uint256).max << 128))));
  }

  function _clearArmPendingCancel() internal {
    bytes32 structBase = _armStructBase(address(fund));
    // Clear pendingCancelDepositRequest flag (slot +4)
    vm.store(ARM, bytes32(uint256(structBase) + 4), bytes32(0));
    // Clear pendingDepositRequest (slot +2, low 128)
    _clearArmPendingDeposit();
  }

  function _setArmPendingDeposit(uint128 remaining) internal {
    bytes32 structBase = _armStructBase(address(fund));
    bytes32 slot = bytes32(uint256(structBase) + 2);
    uint256 cur = uint256(vm.load(ARM, slot));
    vm.store(ARM, slot, bytes32(uint256(remaining) | (cur & (type(uint256).max << 128))));
  }

  /// @dev Sets pendingRedeemRequest at ARM struct offset +2 (high 128 bits).
  function _setArmPendingRedeem(uint128 shares) internal {
    bytes32 structBase = _armStructBase(address(fund));
    bytes32 slot = bytes32(uint256(structBase) + 2);
    uint256 cur = uint256(vm.load(ARM, slot));
    vm.store(ARM, slot, bytes32((cur & type(uint128).max) | (uint256(shares) << 128)));
  }

  /// @dev claimableCancelRedeemRequest in high 128 bits of slot +3.
  function _setArmClaimableCancelRedeem(uint128 shares) internal {
    bytes32 structBase = _armStructBase(address(fund));
    bytes32 slot = bytes32(uint256(structBase) + 3);
    uint256 cur = uint256(vm.load(ARM, slot));
    vm.store(ARM, slot, bytes32((cur & type(uint128).max) | (uint256(shares) << 128)));
  }

  /// @dev Simulates a cancel-redeem fulfillment.
  ///      Sets the ARM's claimableCancelRedeemRequest, clears cancel flags and pending redeem,
  ///      mints shares back to the pool escrow, and reserves them for claiming.
  function _fulfillCancelRedeem(uint128 shares) internal {
    _setArmClaimableCancelRedeem(shares);
    _clearArmPendingCancelRedeem();
    _clearArmPendingRedeem();
    _mintShares(POOL_ESCROW, shares);
    _reserveViaBalanceSheet(SHARE_TOKEN, uint256(shares), REASON_REDEEM);
  }

  /// @dev Simulates a partial redeem fill: fulfills with `halfAssets`, then writes back remaining shares.
  function _fulfillPartialRedeem(uint128 halfAssets, uint128 remainingShares) internal {
    _fulfillRedeem(halfAssets);
    _setArmPendingRedeem(remainingShares);
  }

  /// @dev Clears pendingCancelRedeemRequest flag (slot +4) without touching pendingDeposit.
  function _clearArmPendingCancelRedeem() internal {
    bytes32 structBase = _armStructBase(address(fund));
    vm.store(ARM, bytes32(uint256(structBase) + 4), bytes32(0));
  }

  // ── PoolEscrow/BalanceSheet helpers ──

  /// @dev Calls BalanceSheet.reserve (selector d694356a) by impersonating the ARM.
  ///      This properly updates the PoolEscrow's namespaced holding + reservedBy storage.
  function _reserveViaBalanceSheet(address asset, uint256 amount, uint32 reason) internal {
    vm.prank(ARM);
    (bool ok,) = BALANCE_SHEET.call(
      abi.encodeWithSelector(bytes4(0xd694356a), POOL_ID, SC_ID, asset, uint256(0), amount, ARM, uint256(reason))
    );
    require(ok, "reserveViaBalanceSheet failed");
  }

  /// @dev PoolEscrow holding slot for USDC in this pool (scId/asset/tokenId combo).
  ///      Extracted from on-chain storage trace — the PoolEscrow uses ERC-7201 namespaced storage.
  bytes32 constant ESCROW_USDC_HOLDING_SLOT = 0xf8cec4d932282c3f2949e534c1c5456488b2a3cd3c784a90ff3417f0ca17a47c;

  /// @dev Increases the PoolEscrow's USDC holding total (low 128 bits of the holding slot).
  ///      The 5-param withdraw (966bb766) checks `total - reserved >= amount` before transferring.
  function _increaseEscrowUsdcHolding(uint128 amount) internal {
    uint256 cur = uint256(vm.load(POOL_ESCROW, ESCROW_USDC_HOLDING_SLOT));
    uint128 total = uint128(cur) + amount;
    uint128 reserved = uint128(cur >> 128);
    vm.store(POOL_ESCROW, ESCROW_USDC_HOLDING_SLOT, bytes32(uint256(total) | (uint256(reserved) << 128)));
  }

  /// @dev Zeros out the reserved portion (high 128 bits) of the PoolEscrow USDC holding slot.
  ///      Used after deposit fulfillment to simulate the pool consuming the deposited USDC.
  function _clearEscrowUsdcReserved() internal {
    uint256 cur = uint256(vm.load(POOL_ESCROW, ESCROW_USDC_HOLDING_SLOT));
    uint128 total = uint128(cur);
    vm.store(POOL_ESCROW, ESCROW_USDC_HOLDING_SLOT, bytes32(uint256(total)));
  }

  // ── High-level helpers ──

  /// @dev Executes a full deposit cycle (create → commit → epoch → unlock).
  function _doFullDeposit(uint256 depositAmount, uint256 shares) internal {
    Order memory order = _depositOrder(depositAmount, shares);
    fund.create(order);
    _commitDeposit(order);
    _fulfillDeposit(uint128(shares));
    fund.unlock(order);
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
