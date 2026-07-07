// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SUSD3Fund} from "src/funds/susd3/SUSD3Fund.sol";
import {SUSD3FundFactory} from "src/funds/susd3/SUSD3FundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockUSD3} from "../../mock/funds/susd3/MockUSD3.sol";
import {MockSUSD3} from "../../mock/funds/susd3/MockSUSD3.sol";

contract SUSD3FundTest is Test {
  using LibOrder for Order;

  error Unauthorized();

  event OrderCreated(
    bytes32 indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event RedeemCanceled(bytes32 indexed orderId);
  event OrderResolved(bytes32 indexed orderId, uint256 input, uint256 output, address indexed caller);

  uint256 private constant ONE_USDC = 1e6;
  uint256 private constant MIN_DEPOSIT = 1000e6;
  uint256 private constant COOLDOWN = 30 days;
  uint256 private constant SUSD3_MAIN_STORAGE_SLOT = 0xd63cc11a02da632fb5b68467564e500e196a1d31a6574f58f51073894e8f0b00;

  // SUSD3Fund roles
  uint256 private constant OPERATOR_ROLE = 1 << 0;
  uint256 private constant DEPOSITOR_ROLE = 1 << 1;

  // WrappedAsset roles
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  SUSD3FundFactory public factory;
  SUSD3Fund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockUSD3 public usd3;
  MockSUSD3 public susd3;

  address public owner;
  address public operator;
  address public outsider;

  function setUp() public {
    owner = makeAddr("owner");
    operator = makeAddr("operator");
    outsider = makeAddr("outsider");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    usd3 = new MockUSD3(address(usdc));
    susd3 = new MockSUSD3(address(usd3));
    usd3.setMinDeposit(MIN_DEPOSIT);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(susd3), "wsUSD3", "Wrapped sUSD3");

    factory = new SUSD3FundFactory(owner);
    fund = SUSD3Fund(factory.createFund(owner, address(this), address(susd3), address(wrappedShare)));

    vm.startPrank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.stopPrank();
  }

  /*//////////////////////////////////////////////////////////////
                            HELPERS
  //////////////////////////////////////////////////////////////*/

  function _depositOrder(uint256 input, uint256 output, bytes32 salt) internal view returns (Order memory) {
    return Order({
      mode: Mode.DEPOSIT, owner: address(this), receiver: address(this), input: input, output: output, salt: salt
    });
  }

  function _redeemOrder(uint256 input, uint256 output, bytes32 salt) internal view returns (Order memory) {
    return
      Order({
        mode: Mode.REDEEM, owner: address(this), receiver: address(this), input: input, output: output, salt: salt
      });
  }

  /// @dev Runs a full deposit lifecycle and returns the wsUSD3 shares minted to this contract.
  function _doDeposit(uint256 amount, bytes32 salt) internal returns (uint256 shares) {
    uint256 expected = susd3.convertToShares(usd3.convertToShares(amount));
    Order memory o = _depositOrder(amount, expected, salt);
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    fund.create(o);
    fund.commit(o);
    (, shares) = fund.unlock(o);
  }

  function _packedPendingAmounts() internal view returns (uint128 depositReceived, uint128 pendingRedeemShares) {
    uint256 raw = uint256(vm.load(address(fund), bytes32(SUSD3_MAIN_STORAGE_SLOT + 5)));
    depositReceived = uint128(raw);
    pendingRedeemShares = uint128(raw >> 128);
  }

  /*//////////////////////////////////////////////////////////////
                          INITIALIZATION
  //////////////////////////////////////////////////////////////*/

  function test_Initialize_Success() public view {
    assertEq(fund.owner(), owner, "owner");
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.susd3(), address(susd3), "susd3");
    assertEq(fund.usd3(), address(usd3), "usd3");
    assertEq(fund.vault(), address(susd3), "vault");
    assertEq(fund.rolesOf(address(this)), DEPOSITOR_ROLE, "depositor role");
    assertEq(uint256(fund.state(_depositOrder(2000e6, 2000e6, "x"))), uint256(State.EMPTY), "initial state");
  }

  function test_Initialize_RevertsDecimalsMismatch() public {
    // usd3 wraps an 18-decimal USDC → mismatch vs 6-decimal sUSD3 stack.
    MockERC20 usdc18 = new MockERC20("USDC18", "USDC18", 18);
    MockUSD3 badUsd3 = new MockUSD3(address(usdc18));
    MockSUSD3 badSusd3 = new MockSUSD3(address(badUsd3));

    WrappedAsset wShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    wShare.initialize(owner, owner, address(badSusd3), "wsUSD3", "Wrapped sUSD3");

    // badUsd3 (6) vs usdc18 (18) mismatch.
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.DecimalsMismatch.selector, 18, 6));
    factory.createFund(owner, address(this), address(badSusd3), address(wShare));
  }

  /*//////////////////////////////////////////////////////////////
                          DEPOSIT LIFECYCLE
  //////////////////////////////////////////////////////////////*/

  function test_Deposit_FullLifecycle() public {
    uint256 amount = 2000e6;
    Order memory o = _depositOrder(amount, amount, "d1");

    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);

    assertEq(uint256(fund.create(o)), uint256(State.ACCEPTED), "created");

    (State s, uint256 committed) = fund.commit(o);
    assertEq(uint256(s), uint256(State.PROCESSING), "processing");
    assertEq(committed, amount, "committed input");

    // Synchronous: immediately unlockable.
    assertEq(uint256(fund.state(o)), uint256(State.UNLOCKING), "unlocking");

    (State s2, uint256 out) = fund.unlock(o);
    assertEq(uint256(s2), uint256(State.ENDED), "ended");
    assertEq(out, amount, "shares out (1:1)");
    assertEq(wrappedShare.balanceOf(address(this)), amount, "wsUSD3 to receiver");

    // Fund is a clean pass-through.
    assertEq(usdc.balanceOf(address(fund)), 0, "no usdc dust");
    assertEq(usd3.balanceOf(address(fund)), 0, "no usd3 dust");
    assertEq(susd3.balanceOf(address(fund)), 0, "no susd3 dust");
    // Wrapper custodies the sUSD3 1:1.
    assertEq(susd3.balanceOf(address(wrappedShare)), amount, "wrapper backing");
  }

  function test_Storage_DepositReceivedAndPendingRedeemSharesArePacked() public {
    uint256 amount = 2000e6;
    Order memory o = _depositOrder(amount, amount, "d1");

    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);

    fund.create(o);
    fund.commit(o);

    (uint128 depositReceived, uint128 pendingRedeemShares) = _packedPendingAmounts();
    assertEq(uint256(depositReceived), amount, "depositReceived lower 128");
    assertEq(uint256(pendingRedeemShares), 0, "pendingRedeemShares upper 128");

    fund.unlock(o);

    Order memory r = _redeemOrder(amount, amount, "r1");
    wrappedShare.approve(address(fund), amount);
    fund.create(r);
    fund.commit(r);

    (depositReceived, pendingRedeemShares) = _packedPendingAmounts();
    assertEq(uint256(depositReceived), 0, "depositReceived reset lower 128");
    assertEq(uint256(pendingRedeemShares), amount, "pendingRedeemShares upper 128");
  }

  function test_Deposit_PricePerShareNotOne() public {
    // Seed usd3 to pps = 1.1 (1000 USDC deposited, 100 USDC donated).
    usdc.mint(address(this), MIN_DEPOSIT);
    usdc.approve(address(usd3), MIN_DEPOSIT);
    usd3.deposit(MIN_DEPOSIT, address(this));
    usdc.mint(address(usd3), 100e6);

    uint256 amount = 2000e6;
    uint256 expectedShares = susd3.convertToShares(usd3.convertToShares(amount));
    assertLt(expectedShares, amount, "fewer shares at pps>1");

    Order memory o = _depositOrder(amount, expectedShares, "d2");
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    fund.create(o);
    fund.commit(o);
    (, uint256 out) = fund.unlock(o);
    assertEq(out, expectedShares, "shares out matches expected");
    assertEq(wrappedShare.balanceOf(address(this)), expectedShares, "wsUSD3 minted");
  }

  /*//////////////////////////////////////////////////////////////
                          REDEEM LIFECYCLE
  //////////////////////////////////////////////////////////////*/

  function test_Redeem_FullLifecycle() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");
    assertEq(shares, amount, "deposit shares");

    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);

    fund.create(r);
    (State s, uint256 committed) = fund.commit(r);
    assertEq(uint256(s), uint256(State.PROCESSING), "processing after commit");
    assertEq(committed, shares, "committed shares");

    // Still in cooldown → not unlockable.
    assertEq(uint256(fund.state(r)), uint256(State.PROCESSING), "still cooling down");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(r);

    vm.warp(block.timestamp + COOLDOWN + 1);
    assertEq(uint256(fund.state(r)), uint256(State.UNLOCKING), "unlocking after cooldown");

    uint256 balBefore = usdc.balanceOf(address(this));
    (State s2, uint256 usdcOut) = fund.unlock(r);
    assertEq(uint256(s2), uint256(State.ENDED), "ended");
    assertEq(usdcOut, amount, "usdc out (1:1)");
    assertEq(usdc.balanceOf(address(this)) - balBefore, amount, "receiver got usdc");
    assertEq(wrappedShare.balanceOf(address(this)), 0, "wsUSD3 burned");
    assertEq(susd3.balanceOf(address(fund)), 0, "no susd3 dust");
  }

  function test_Redeem_RoundTripConservesWithYield() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");

    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);

    // USD3 appreciates 5% while the position sits in cooldown.
    usdc.mint(address(usd3), 100e6);

    vm.warp(block.timestamp + COOLDOWN + 1);
    (, uint256 usdcOut) = fund.unlock(r);
    assertEq(usdcOut, 2100e6, "receiver gets appreciated usdc");
  }

  /*//////////////////////////////////////////////////////////////
                          PARTIAL REDEEM
  //////////////////////////////////////////////////////////////*/

  function test_Redeem_Partial() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");

    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);
    vm.warp(block.timestamp + COOLDOWN + 1);

    // sUSD3 can only release half right now (backing-limited).
    susd3.setMaxRedeemCap(shares / 2);

    (State s1, uint256 out1) = fund.unlock(r);
    assertEq(uint256(s1), uint256(State.PROCESSING), "partial -> processing");
    assertEq(out1, amount / 2, "half usdc");

    // Backing recovers; redeem the rest.
    susd3.setMaxRedeemCap(type(uint256).max);
    (State s2, uint256 out2) = fund.unlock(r);
    assertEq(uint256(s2), uint256(State.ENDED), "ended");
    assertEq(out2, amount / 2, "remaining half usdc");
    assertEq(usdc.balanceOf(address(this)), amount, "full usdc delivered");
  }

  function test_Redeem_BlockedWithdrawal() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");

    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);
    vm.warp(block.timestamp + COOLDOWN + 1);

    // Cooldown matured but withdrawals blocked (e.g. unrealized losses).
    susd3.setBlocked(true);
    assertEq(uint256(fund.state(r)), uint256(State.PROCESSING), "blocked -> processing");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(r);

    susd3.setBlocked(false);
    assertEq(uint256(fund.state(r)), uint256(State.UNLOCKING), "unblocked -> unlocking");
    (State s,) = fund.unlock(r);
    assertEq(uint256(s), uint256(State.ENDED), "ended");
  }

  function test_Redeem_Usd3Illiquidity() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");

    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);
    vm.warp(block.timestamp + COOLDOWN + 1);

    // USD3 leg cannot satisfy the full redemption → whole unlock reverts atomically.
    usd3.setMaxRedeemShares(amount / 2);
    vm.expectRevert(bytes("USD3: exceeds maxRedeem"));
    fund.unlock(r);

    // Liquidity returns; unlock completes.
    usd3.setMaxRedeemShares(type(uint256).max);
    (State s, uint256 usdcOut) = fund.unlock(r);
    assertEq(uint256(s), uint256(State.ENDED), "ended");
    assertEq(usdcOut, amount, "full usdc");
  }

  /*//////////////////////////////////////////////////////////////
                          RECOVERY
  //////////////////////////////////////////////////////////////*/

  function test_Recover_CancelRedeem() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");

    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);

    // Operator aborts the pending redeem (no need to wait for cooldown).
    vm.prank(operator);
    fund.cancelRedeem(r);
    assertEq(uint256(fund.state(r)), uint256(State.RECOVERING), "recovering");

    (State s, uint256 sharesBack) = fund.recover(r);
    assertEq(uint256(s), uint256(State.ENDED), "ended");
    assertEq(sharesBack, shares, "shares returned");
    assertEq(wrappedShare.balanceOf(address(this)), shares, "wsUSD3 back to receiver");
    assertEq(susd3.balanceOf(address(fund)), 0, "no susd3 left in fund");
  }

  function test_Recover_AfterPartialUnlock() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");

    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);
    vm.warp(block.timestamp + COOLDOWN + 1);

    // Redeem half, then abort the rest.
    susd3.setMaxRedeemCap(shares / 2);
    (State s1,) = fund.unlock(r);
    assertEq(uint256(s1), uint256(State.PROCESSING), "partial");

    vm.prank(operator);
    fund.cancelRedeem(r);
    (State s2, uint256 sharesBack) = fund.recover(r);
    assertEq(uint256(s2), uint256(State.ENDED), "ended");
    assertEq(sharesBack, shares / 2, "remainder returned as shares");

    // Receiver ends with half USDC + half wsUSD3 == original value.
    assertEq(usdc.balanceOf(address(this)), amount / 2, "half usdc");
    assertEq(wrappedShare.balanceOf(address(this)), shares / 2, "half wsUSD3");
  }

  function test_Recover_RevertsWhenNotRecovering() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");
    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.recover(r);
  }

  function test_CancelRedeem_RevertsForDeposit() public {
    uint256 amount = 2000e6;
    Order memory o = _depositOrder(amount, amount, "d1");
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    fund.create(o);
    fund.commit(o);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidMode.selector, Mode.DEPOSIT));
    fund.cancelRedeem(o);
  }

  /*//////////////////////////////////////////////////////////////
                            RESOLVE
  //////////////////////////////////////////////////////////////*/

  function test_Resolve_StuckDeposit() public {
    uint256 amount = 2000e6;
    uint256 received = susd3.convertToShares(usd3.convertToShares(amount)); // 2000e6 at 1:1

    // Optimistically high output → the deposit yields fewer shares than requested → order sticks.
    Order memory o = _depositOrder(amount, received + 500e6, "d1");
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    fund.create(o);
    fund.commit(o);

    assertEq(uint256(fund.state(o)), uint256(State.PROCESSING), "shortfall -> processing");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(o);

    // Operator lowers the threshold to the actual received amount → unstuck.
    bytes32 id = o.toId(address(fund));
    vm.expectEmit(true, false, false, true, address(fund));
    emit OrderResolved(id, amount, received, operator);
    vm.prank(operator);
    fund.resolve(o, amount, received);

    assertEq(uint256(fund.state(o)), uint256(State.UNLOCKING), "resolved -> unlocking");
    (State s, uint256 out) = fund.unlock(o);
    assertEq(uint256(s), uint256(State.ENDED), "ended");
    assertEq(out, received, "delivered actual shares");
    assertEq(wrappedShare.balanceOf(address(this)), received, "wsUSD3 to receiver");
  }

  function test_Resolve_RevertsWhenNotProcessing() public {
    Order memory o = _depositOrder(2000e6, 2000e6, "d1");
    fund.create(o); // ACCEPTED, not PROCESSING
    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.resolve(o, 2000e6, 1000e6);
  }

  function test_Resolve_RevertsForRedeem() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");
    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidMode.selector, Mode.REDEEM));
    fund.resolve(r, shares, amount);
  }

  function test_Resolve_OnlyOperatorOrOwner() public {
    uint256 amount = 2000e6;
    Order memory o = _depositOrder(amount, amount, "d1");
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    fund.create(o);
    fund.commit(o);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.resolve(o, amount, amount);

    // Owner can also call it.
    vm.prank(owner);
    fund.resolve(o, amount, amount);
  }

  /*//////////////////////////////////////////////////////////////
                          CANCEL / GUARDS
  //////////////////////////////////////////////////////////////*/

  function test_Cancel_AcceptedOrder() public {
    Order memory o = _depositOrder(2000e6, 2000e6, "d1");
    fund.create(o);
    assertEq(uint256(fund.cancel(o)), uint256(State.EMPTY), "empty");
    assertEq(uint256(fund.state(o)), uint256(State.EMPTY), "state empty");
  }

  function test_Create_RevertsBelowMinDeposit() public {
    Order memory o = _depositOrder(MIN_DEPOSIT - 1, MIN_DEPOSIT - 1, "d1");
    vm.expectRevert(LibFundsErrors.BelowMinDeposit.selector);
    fund.create(o);
  }

  function test_Create_RevertsSlippageDeposit() public {
    uint256 amount = 2000e6;
    // expected ~ 2000e6; output 6% below → InvalidOutput.
    Order memory o = _depositOrder(amount, amount * 94 / 100, "d1");
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(o);
  }

  function test_Create_RevertsSlippageRedeem() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");
    Order memory r = _redeemOrder(shares, amount * 94 / 100, "r1");
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(r);
  }

  function test_Deposit_AsyncWhenLocked() public {
    // sUSD3 applies a deposit lock: staking still succeeds, but delivery of the wrapped shares is
    // deferred until the lock elapses (the fund holds the locked sUSD3 meanwhile).
    susd3.setLockDuration(30 days);
    uint256 amount = 2000e6;
    Order memory o = _depositOrder(amount, amount, "d1");
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);

    fund.create(o);
    (State s,) = fund.commit(o);
    assertEq(uint256(s), uint256(State.PROCESSING), "processing");

    // Staked but locked → not yet deliverable.
    assertEq(uint256(fund.state(o)), uint256(State.PROCESSING), "locked -> processing");
    assertEq(susd3.balanceOf(address(fund)), amount, "fund holds locked susd3");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(o);

    // Lock elapses → deliverable.
    vm.warp(block.timestamp + 30 days + 1);
    assertEq(uint256(fund.state(o)), uint256(State.UNLOCKING), "lock elapsed -> unlocking");
    (State s2, uint256 out) = fund.unlock(o);
    assertEq(uint256(s2), uint256(State.ENDED), "ended");
    assertEq(out, amount, "shares delivered");
    assertEq(wrappedShare.balanceOf(address(this)), amount, "wsUSD3 to receiver");
    assertEq(susd3.balanceOf(address(fund)), 0, "no susd3 dust");
  }

  function test_Commit_RevertsSubordinationCap_StaysAccepted() public {
    susd3.setDepositCap(100e6); // far below the order
    uint256 amount = 2000e6;
    Order memory o = _depositOrder(amount, amount, "d1");
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    fund.create(o);

    vm.expectRevert(bytes("sUSD3: deposit cap"));
    fund.commit(o);

    // Order remains ACCEPTED and cancelable.
    assertEq(uint256(fund.state(o)), uint256(State.ACCEPTED), "still accepted");
    assertEq(uint256(fund.cancel(o)), uint256(State.EMPTY), "cancelable");
  }

  function test_Create_RevertsPendingOrder() public {
    Order memory o = _depositOrder(2000e6, 2000e6, "d1");
    fund.create(o);
    Order memory o2 = _depositOrder(2000e6, 2000e6, "d2");
    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(o2);
  }

  function test_Create_RevertsOrderAlreadyExists() public {
    uint256 amount = 2000e6;
    _doDeposit(amount, "d1"); // ends at ENDED

    // Re-creating the exact same (now archived) order id reverts.
    Order memory o = _depositOrder(amount, susd3.convertToShares(usd3.convertToShares(amount)), "d1");
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    bytes32 id = o.toId(address(fund));
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.OrderAlreadyExists.selector, id));
    fund.create(o);
  }

  /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL
  //////////////////////////////////////////////////////////////*/

  function test_Access_OnlyDepositor() public {
    Order memory o = _depositOrder(2000e6, 2000e6, "d1");
    vm.startPrank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.create(o);
    vm.expectRevert(Unauthorized.selector);
    fund.commit(o);
    vm.expectRevert(Unauthorized.selector);
    fund.unlock(o);
    vm.expectRevert(Unauthorized.selector);
    fund.recover(o);
    vm.expectRevert(Unauthorized.selector);
    fund.cancel(o);
    vm.stopPrank();
  }

  function test_Access_CancelRedeemOnlyOperatorOrOwner() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");
    Order memory r = _redeemOrder(shares, amount, "r1");
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.cancelRedeem(r);

    // Owner can also call it.
    vm.prank(owner);
    fund.cancelRedeem(r);
    assertEq(uint256(fund.state(r)), uint256(State.RECOVERING), "recovering");
  }

  /*//////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  function test_View_TotalAssets() public {
    uint256 amount = 2000e6;
    _doDeposit(amount, "d1");
    assertEq(fund.totalAssets(), amount, "totalAssets in usdc (1:1)");
  }

  function test_View_MaxDeposit() public {
    // Fresh state: both vaults empty → 1:1 conversions.
    usdc.mint(address(this), 5000e6);
    assertEq(fund.maxDeposit(address(this)), 5000e6, "bounded by balance");

    usd3.setDepositCap(3000e6);
    assertEq(fund.maxDeposit(address(this)), 3000e6, "bounded by usd3 cap");

    susd3.setDepositCap(1000e6);
    assertEq(fund.maxDeposit(address(this)), 1000e6, "bounded by susd3 cap (usdc)");

    assertEq(fund.maxDeposit(outsider), 0, "non-depositor gets 0");
  }

  function test_View_MaxDeposit_ClampsBelowMinDeposit() public {
    usdc.mint(address(this), MIN_DEPOSIT - 1);
    assertEq(fund.maxDeposit(address(this)), 0, "balance below min");

    usdc.mint(address(this), 1);
    assertEq(fund.maxDeposit(address(this)), MIN_DEPOSIT, "exact min");

    usd3.setDepositCap(MIN_DEPOSIT - 1);
    assertEq(fund.maxDeposit(address(this)), 0, "usd3 cap below min");

    usd3.setDepositCap(type(uint256).max);
    susd3.setDepositCap(MIN_DEPOSIT - 1);
    assertEq(fund.maxDeposit(address(this)), 0, "susd3 cap below min");
  }

  function test_View_MaxRedeem() public {
    uint256 amount = 2000e6;
    uint256 shares = _doDeposit(amount, "d1");
    assertEq(fund.maxRedeem(address(this)), shares, "wrapped balance");
    assertEq(fund.maxRedeem(outsider), 0, "non-depositor gets 0");
  }

  /*//////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  function test_Events_DepositLifecycle() public {
    uint256 amount = 2000e6;
    Order memory o = _depositOrder(amount, amount, "d1");
    bytes32 id = o.toId(address(fund));
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);

    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderCreated(id, Mode.DEPOSIT, address(this), address(this), amount, amount);
    fund.create(o);

    vm.expectEmit(true, false, false, true, address(fund));
    emit OrderCommitted(id, Mode.DEPOSIT, amount);
    fund.commit(o);

    vm.expectEmit(true, true, false, true, address(fund));
    emit OrderUnlocked(id, Mode.DEPOSIT, amount, address(this));
    fund.unlock(o);
  }
}
