// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WildcatFund} from "src/funds/wildcat/WildcatFund.sol";
import {WildcatFundFactory} from "src/funds/wildcat/WildcatFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";
import {RAY} from "src/libs/Constants.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockWildcatMarket} from "../../mock/funds/wildcat/MockWildcatMarket.sol";
import {MockWildcat4626Wrapper} from "../../mock/funds/wildcat/MockWildcat4626Wrapper.sol";

contract WildcatFundTest is Test {
  using LibOrder for Order;

  error InvalidInitialization();
  error Unauthorized();

  event OrderCreated(
    bytes32 indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);
  event OrderResolved(bytes32 indexed orderId, uint256 input, uint256 output, address indexed caller);
  event OrderForceEnded(bytes32 indexed orderId, address indexed caller);
  event TokensRescued(address indexed token, address indexed to, uint256 amount);

  uint256 private constant ONE_USDC = 1e6;

  // WildcatFund roles
  uint256 private constant OPERATOR_ROLE = 1 << 0;
  uint256 private constant DEPOSITOR_ROLE = 1 << 1;

  // WrappedAsset roles
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         TEST STATE                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  WildcatFundFactory public factory;
  WildcatFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockWildcatMarket public market;
  MockWildcat4626Wrapper public wrapper;

  address public owner;
  address public operator;
  address public outsider;

  function setUp() public {
    owner = makeAddr("owner");
    operator = makeAddr("operator");
    outsider = makeAddr("outsider");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    market = new MockWildcatMarket(address(usdc));
    wrapper = new MockWildcat4626Wrapper(address(market));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(wrapper), "wv-WMT", "Wrapped v-WMT");

    factory = new WildcatFundFactory(owner);
    address fundAddress = factory.createFund(owner, address(this), address(wrapper), address(wrappedShare));
    fund = WildcatFund(fundAddress);

    vm.startPrank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.stopPrank();

    usdc.mint(address(this), 1_000_000 * ONE_USDC);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_Success() public view {
    assertEq(fund.owner(), owner, "owner");
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.market(), address(market), "market");
    assertEq(fund.wrapper(), address(wrapper), "wrapper");
    assertEq(fund.currentBatchExpiry(), 0, "batch expiry");
    assertEq(fund.rolesOf(address(this)), DEPOSITOR_ROLE, "depositor role");
    assertEq(uint256(fund.state(_depositOrder(ONE_USDC, ONE_USDC))), uint256(State.EMPTY), "initial state");
  }

  function test_Initialize_RevertWhen_CalledTwice() public {
    vm.expectRevert(InvalidInitialization.selector);
    fund.initialize(owner, address(this), address(wrapper), address(wrappedShare));
  }

  function test_Initialize_RevertWhen_UnderlyingMismatch() public {
    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    WrappedAsset badWrappedShare = WrappedAsset(proxy);
    badWrappedShare.initialize(owner, owner, address(usdc), "wUSDC", "Wrapped USDC");

    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    factory.createFund(owner, address(this), address(wrapper), address(badWrappedShare));
  }

  function test_Initialize_RevertWhen_ZeroOwner() public {
    vm.expectRevert(CommonErrors.AddressZero.selector);
    factory.createFund(address(0), address(this), address(wrapper), address(wrappedShare));
  }

  function test_Initialize_RevertWhen_DepositorNotContract() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, outsider));
    factory.createFund(owner, outsider, address(wrapper), address(wrappedShare));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           CREATE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Create_Deposit_Success() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderCreated(orderId, Mode.DEPOSIT, address(this), address(this), order.input, order.output);
    State newState = fund.create(order);

    assertEq(uint256(newState), uint256(State.ACCEPTED), "returned state");
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "stored state");
  }

  function test_Create_Redeem_Success() public {
    _depositFor(1000 * ONE_USDC);

    Order memory order = _redeemOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    State newState = fund.create(order);
    assertEq(uint256(newState), uint256(State.ACCEPTED), "returned state");
  }

  function test_Create_RevertWhen_NotDepositor() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.owner = outsider;
    order.receiver = outsider;
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.create(order);
  }

  function test_Create_RevertWhen_ZeroInput() public {
    vm.expectRevert(CommonErrors.AmountZero.selector);
    fund.create(_depositOrder(0, 0));
  }

  function test_Create_RevertWhen_OwnerMismatch() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.owner = outsider;
    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.create(order);
  }

  function test_Create_RevertWhen_ReceiverMismatch() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.receiver = outsider;
    vm.expectRevert(LibFundsErrors.InvalidReceiver.selector);
    fund.create(order);
  }

  function test_Create_RevertWhen_PendingOrder() public {
    fund.create(_depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC));
    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(_depositOrder(2000 * ONE_USDC, 2000 * ONE_USDC));
  }

  function test_Create_RevertWhen_MarketClosed() public {
    market.setClosed(true);
    vm.expectRevert(LibFundsErrors.MarketClosed.selector);
    fund.create(_depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC));
  }

  function test_Create_Redeem_AllowedWhen_MarketClosed() public {
    _depositFor(1000 * ONE_USDC);
    market.setClosed(true);
    State newState = fund.create(_redeemOrder(1000 * ONE_USDC, 1000 * ONE_USDC));
    assertEq(uint256(newState), uint256(State.ACCEPTED), "redeem accepted on closed market");
  }

  function test_Create_RevertWhen_DepositCapExceeded() public {
    market.setMaxTotalSupply(500 * ONE_USDC);
    vm.expectRevert(LibFundsErrors.DepositCapExceeded.selector);
    fund.create(_depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC));
  }

  function test_Create_RevertWhen_OutputTooLow() public {
    // Expected output is 1000e6 shares at scaleFactor RAY; > 5% below must revert
    uint256 input = 1000 * ONE_USDC;
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(_depositOrder(input, input * 94 / 100));
  }

  function test_Create_AllowsOutputWithinDeviation() public {
    uint256 input = 1000 * ONE_USDC;
    State newState = fund.create(_depositOrder(input, input * 96 / 100));
    assertEq(uint256(newState), uint256(State.ACCEPTED), "state");
  }

  function test_Create_RevertWhen_OrderAlreadyExists() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    _runDepositLifecycle(order);

    // Same order (same id) can never be recreated
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.OrderAlreadyExists.selector, order.toId(address(fund))));
    fund.create(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           CANCEL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Cancel_Success() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    fund.create(order);

    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderCanceled(order.toId(address(fund)), Mode.DEPOSIT, address(this));
    State newState = fund.cancel(order);

    assertEq(uint256(newState), uint256(State.EMPTY), "returned state");
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "stored state");
  }

  function test_Cancel_RevertWhen_UnknownOrder() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, order.toId(address(fund))));
    fund.cancel(order);
  }

  function test_Cancel_RevertWhen_Committed() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    fund.create(order);
    usdc.approve(address(fund), order.input);
    fund.commit(order);

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.cancel(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       COMMIT / UNLOCK                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Deposit_FullLifecycle() public {
    uint256 input = 1000 * ONE_USDC;
    Order memory order = _depositOrder(input, input);
    bytes32 orderId = order.toId(address(fund));

    fund.create(order);
    usdc.approve(address(fund), input);

    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderCommitted(orderId, Mode.DEPOSIT, input);
    (State committedState, uint256 committed) = fund.commit(order);

    assertEq(uint256(committedState), uint256(State.PROCESSING), "committed state");
    assertEq(committed, input, "committed amount");
    // Deposit is synchronous: shares already received, so the dynamic state is UNLOCKING
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "dynamic state");
    assertEq(usdc.balanceOf(address(market)), input, "market received usdc");
    assertEq(wrapper.balanceOf(address(fund)), input, "fund holds wrapper shares");

    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderUnlocked(orderId, Mode.DEPOSIT, input, address(this));
    (State unlockedState, uint256 unlocked) = fund.unlock(order);

    assertEq(uint256(unlockedState), uint256(State.ENDED), "unlocked state");
    assertEq(unlocked, input, "unlocked amount");
    assertEq(wrappedShare.balanceOf(address(this)), input, "receiver wrapped shares");
    assertEq(wrapper.balanceOf(address(wrappedShare)), input, "wrapped asset holds wrapper shares");
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "final state");
  }

  function test_Deposit_WithAccruedScaleFactor() public {
    // 10% accrued interest: 1 share = 1.1 underlying
    market.setScaleFactor(RAY * 11 / 10);

    uint256 input = 1100 * ONE_USDC;
    uint256 expectedShares = 1000 * ONE_USDC;
    Order memory order = _depositOrder(input, expectedShares);

    fund.create(order);
    usdc.approve(address(fund), input);
    fund.commit(order);
    (, uint256 unlocked) = fund.unlock(order);

    assertEq(unlocked, expectedShares, "shares minted at scaled rate");
    assertEq(wrappedShare.balanceOf(address(this)), expectedShares, "receiver wrapped shares");
  }

  function test_Deposit_StuckBelowOutput_ResolvedByOperator() public {
    uint256 input = 1000 * ONE_USDC;
    Order memory order = _depositOrder(input, input);
    fund.create(order);

    // Interest accrues between create and commit: fewer shares received than order.output
    market.setScaleFactor(RAY * 102 / 100);
    usdc.approve(address(fund), input);
    fund.commit(order);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "stuck in processing");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);

    uint256 received = input * 100 / 102 + 1; // half-up rayDiv
    vm.prank(operator);
    fund.resolve(order, input, received);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after resolve");
    (, uint256 unlocked) = fund.unlock(order);
    assertEq(unlocked, received, "resolved amount unlocked");
  }

  function test_Redeem_FullLifecycle() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    bytes32 orderId = order.toId(address(fund));

    fund.create(order);
    wrappedShare.approve(address(fund), shares);

    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderCommitted(orderId, Mode.REDEEM, shares);
    (State committedState,) = fund.commit(order);

    assertEq(uint256(committedState), uint256(State.PROCESSING), "committed state");
    assertEq(wrappedShare.balanceOf(address(this)), 0, "wrapped shares burned");
    uint32 expiry = fund.currentBatchExpiry();
    assertEq(expiry, uint32(block.timestamp + 1 days), "batch expiry");

    // Not claimable before expiry
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing before expiry");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);

    // Expired but unpaid: still processing
    vm.warp(expiry + 1);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing while unpaid");

    // Borrower pays the full batch
    market.payBatch(expiry, shares);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking once paid");

    uint256 balanceBefore = usdc.balanceOf(address(this));
    (State unlockedState, uint256 unlocked) = fund.unlock(order);

    assertEq(uint256(unlockedState), uint256(State.ENDED), "ended after full payment");
    assertEq(unlocked, shares, "full amount unlocked");
    assertEq(usdc.balanceOf(address(this)) - balanceBefore, shares, "usdc received");
  }

  function test_Redeem_PartialPayments() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    uint32 expiry = fund.currentBatchExpiry();
    vm.warp(expiry + 1);

    // First partial payment: 40%
    market.payBatch(expiry, shares * 40 / 100);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after partial payment");

    (State stateAfterFirst, uint256 firstAmount) = fund.unlock(order);
    assertEq(uint256(stateAfterFirst), uint256(State.PROCESSING), "back to processing");
    assertEq(firstAmount, shares * 40 / 100, "first partial amount");

    // Second payment completes the batch
    market.payBatch(expiry, shares * 60 / 100);
    (State stateAfterSecond, uint256 secondAmount) = fund.unlock(order);
    assertEq(uint256(stateAfterSecond), uint256(State.ENDED), "ended after final payment");
    assertEq(secondAmount, shares * 60 / 100, "second partial amount");
    assertEq(usdc.balanceOf(address(this)), 1_000_000 * ONE_USDC, "full roundtrip");
  }

  function test_Redeem_SweepsThirdPartyExecutedWithdrawals() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    uint32 expiry = fund.currentBatchExpiry();
    vm.warp(expiry + 1);
    market.payBatch(expiry, shares);

    // A third party executes the withdrawal directly: funds are pushed to the fund contract
    vm.prank(outsider);
    market.executeWithdrawal(address(fund), expiry);
    assertEq(usdc.balanceOf(address(fund)), shares, "usdc pushed to fund");

    // The fund still reports UNLOCKING and unlock() sweeps the pushed balance
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking from pushed balance");
    (State newState, uint256 unlocked) = fund.unlock(order);
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
    assertEq(unlocked, shares, "swept amount");
    assertEq(usdc.balanceOf(address(this)), 1_000_000 * ONE_USDC, "receiver got swept funds");
  }

  function test_Commit_RevertWhen_NotAccepted() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, order.toId(address(fund))));
    fund.commit(order);
  }

  function test_Unlock_RevertWhen_NotDepositor() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.unlock(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           RECOVER                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Recover_AlwaysReverts() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recover(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          FORCE END                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_ForceEnd_StuckRedeem() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    uint32 expiry = fund.currentBatchExpiry();
    vm.warp(expiry + 1);

    // Batch unpaid (borrower delinquent): operator force-ends the order
    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderForceEnded(order.toId(address(fund)), operator);
    vm.prank(operator);
    fund.forceEnd(order);

    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");

    // A late payment arrives and is pushed to the fund; the owner can rescue it
    market.payBatch(expiry, shares);
    vm.prank(outsider);
    market.executeWithdrawal(address(fund), expiry);

    vm.expectEmit(true, true, true, true, address(fund));
    emit TokensRescued(address(usdc), owner, shares);
    vm.prank(owner);
    fund.rescueTokens(address(usdc), owner);
    assertEq(usdc.balanceOf(owner), shares, "owner rescued late payment");
  }

  function test_ForceEnd_RevertWhen_Unlocking() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    uint32 expiry = fund.currentBatchExpiry();
    vm.warp(expiry + 1);
    market.payBatch(expiry, shares);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.UNLOCKING));
    fund.forceEnd(order);
  }

  function test_ForceEnd_RevertWhen_DepositOrder() public {
    uint256 input = 1000 * ONE_USDC;
    Order memory order = _depositOrder(input, input);
    fund.create(order);

    // Interest accrual between create and commit leaves the deposit stuck in PROCESSING
    market.setScaleFactor(RAY * 102 / 100);
    usdc.approve(address(fund), input);
    fund.commit(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "stuck deposit");

    // Deposits must be completed via resolve() + unlock(), never abandoned
    vm.prank(operator);
    vm.expectRevert(LibFundsErrors.ForceEndNotSupported.selector);
    fund.forceEnd(order);
  }

  function test_ForceEnd_RevertWhen_BatchNotExpired() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    // Before expiry the batch is on track, not stuck
    vm.prank(operator);
    vm.expectRevert(LibFundsErrors.BatchNotExpired.selector);
    fund.forceEnd(order);
  }

  function test_ForceEnd_StrandedProceedsDoNotContaminateNextOrder() public {
    uint256 shares = 2000 * ONE_USDC;
    _depositFor(shares);

    // Order A: redeem 1000, batch expires unpaid, operator force-ends it
    Order memory orderA = _redeemOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    fund.create(orderA);
    wrappedShare.approve(address(fund), 1000 * ONE_USDC);
    fund.commit(orderA);
    uint32 expiryA = fund.currentBatchExpiry();
    vm.warp(expiryA + 1);
    vm.prank(operator);
    fund.forceEnd(orderA);

    // Order B: a second redeem in a fresh batch
    Order memory orderB = _redeemOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    orderB.salt = bytes32(uint256(2));
    fund.create(orderB);
    wrappedShare.approve(address(fund), 1000 * ONE_USDC);
    fund.commit(orderB);
    uint32 expiryB = fund.currentBatchExpiry();

    // Order A's batch is paid late and pushed into the fund by a third party
    market.payBatch(expiryA, 1000 * ONE_USDC);
    vm.prank(outsider);
    market.executeWithdrawal(address(fund), expiryA);
    assertEq(usdc.balanceOf(address(fund)), 1000 * ONE_USDC, "stranded proceeds in fund");

    // Order B is unaffected: not unlockable before its own batch pays
    assertEq(uint256(fund.state(orderB)), uint256(State.PROCESSING), "B unaffected by stranded funds");

    // Order B unlocks exactly its own batch proceeds, not the stranded ones
    vm.warp(expiryB + 1);
    market.payBatch(expiryB, 1000 * ONE_USDC);
    uint256 balanceBefore = usdc.balanceOf(address(this));
    (State stateB, uint256 amountB) = fund.unlock(orderB);
    assertEq(uint256(stateB), uint256(State.ENDED), "B ended");
    assertEq(amountB, 1000 * ONE_USDC, "B credited only its own proceeds");
    assertEq(usdc.balanceOf(address(this)) - balanceBefore, 1000 * ONE_USDC, "receiver got B only");
    assertEq(usdc.balanceOf(address(fund)), 1000 * ONE_USDC, "A's proceeds still in fund");

    // With no order in flight, the owner can rescue A's stranded proceeds
    vm.prank(owner);
    fund.rescueTokens(address(usdc), owner);
    assertEq(usdc.balanceOf(owner), 1000 * ONE_USDC, "stranded proceeds rescued");
  }

  function test_ForceEnd_RevertWhen_NotOperator() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.forceEnd(order);
  }

  function test_ForceEnd_RevertWhen_UnknownOrder() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, order.toId(address(fund))));
    fund.forceEnd(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        RESCUE TOKENS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_RescueTokens_RevertWhen_NotOwner() public {
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.rescueTokens(address(usdc), outsider);
  }

  function test_RescueTokens_RevertWhen_OrderInFlight() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    fund.create(order);
    usdc.approve(address(fund), order.input);
    fund.commit(order);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.rescueTokens(address(usdc), owner);
  }

  function test_RescueTokens_SweepsDonations() public {
    usdc.mint(address(fund), 42 * ONE_USDC);
    vm.prank(owner);
    fund.rescueTokens(address(usdc), owner);
    assertEq(usdc.balanceOf(owner), 42 * ONE_USDC, "donation rescued");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           RESOLVE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Resolve_RevertWhen_NotOperator() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.resolve(order, 0, 0);
  }

  function test_Resolve_RevertWhen_RedeemOrder() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    vm.prank(operator);
    vm.expectRevert(LibFundsErrors.ResolveNotSupported.selector);
    fund.resolve(order, shares, shares);
  }

  function test_Resolve_RevertWhen_NotProcessing() public {
    Order memory order = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    fund.create(order);
    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.resolve(order, 0, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            VIEWS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_TotalAssets_TracksScaleFactor() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);
    assertEq(fund.totalAssets(), shares, "1:1 at ray scale factor");

    // 10% interest accrues: same share supply, higher AUM
    market.setScaleFactor(RAY * 11 / 10);
    assertEq(fund.totalAssets(), shares * 11 / 10, "AUM tracks scale factor");
  }

  function test_MaxDeposit() public {
    assertEq(fund.maxDeposit(outsider), 0, "outsider");
    assertEq(fund.maxDeposit(address(this)), 1_000_000 * ONE_USDC, "bounded by balance");

    market.setMaxTotalSupply(500 * ONE_USDC);
    assertEq(fund.maxDeposit(address(this)), 500 * ONE_USDC, "bounded by market cap");

    market.setClosed(true);
    assertEq(fund.maxDeposit(address(this)), 0, "closed market");
  }

  function test_MaxRedeem() public {
    assertEq(fund.maxRedeem(outsider), 0, "outsider");
    _depositFor(1000 * ONE_USDC);
    assertEq(fund.maxRedeem(address(this)), 1000 * ONE_USDC, "wrapped share balance");
  }

  function test_PendingDepositShares_LifecycleVisibility() public {
    assertEq(fund.pendingDepositShares(), 0, "empty fund");

    uint256 input = 1000 * ONE_USDC;
    Order memory order = _depositOrder(input, input);
    fund.create(order);
    assertEq(fund.pendingDepositShares(), 0, "accepted, not committed");

    usdc.approve(address(fund), input);
    fund.commit(order);
    assertEq(fund.pendingDepositShares(), input, "in flight between commit and unlock");

    fund.unlock(order);
    assertEq(fund.pendingDepositShares(), 0, "delivered");
  }

  function test_PendingDepositShares_ZeroDuringRedeem() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    assertEq(fund.pendingDepositShares(), 0, "redeem order has no pending deposit");
  }

  function test_PendingRedeemAssets_LifecycleVisibility() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);
    assertEq(fund.pendingRedeemAssets(), 0, "no redeem in flight");

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    // Full amount pending right after commit (unpaid batch valued at current scaleFactor)
    assertEq(fund.pendingRedeemAssets(), shares, "full amount pending after commit");

    uint32 expiry = fund.currentBatchExpiry();
    vm.warp(expiry + 1);

    // 40% paid: pending = paid-but-unforwarded (400) + unpaid remainder (600)
    market.payBatch(expiry, shares * 40 / 100);
    assertEq(fund.pendingRedeemAssets(), shares, "paid leg + unpaid remainder");

    // Forward the paid 40% to the receiver: only the unpaid remainder is left pending
    fund.unlock(order);
    assertEq(fund.pendingRedeemAssets(), shares * 60 / 100, "unpaid remainder after partial unlock");

    // Third-party push does not change the pending total (paid leg counted until forwarded)
    market.payBatch(expiry, shares * 60 / 100);
    vm.prank(outsider);
    market.executeWithdrawal(address(fund), expiry);
    assertEq(fund.pendingRedeemAssets(), shares * 60 / 100, "pushed proceeds still pending until forwarded");

    fund.unlock(order);
    assertEq(fund.pendingRedeemAssets(), 0, "fully settled");
  }

  function test_PendingRedeemAssets_GrowsWithScaleFactor() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    // Interest keeps accruing on the unpaid batch: pending value grows with scaleFactor
    market.setScaleFactor(RAY * 11 / 10);
    assertEq(fund.pendingRedeemAssets(), shares * 11 / 10, "unpaid remainder accrues interest");
  }

  function test_PendingRedeemAssets_ZeroAfterForceEnd() public {
    uint256 shares = 1000 * ONE_USDC;
    _depositFor(shares);

    Order memory order = _redeemOrder(shares, shares);
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    vm.warp(fund.currentBatchExpiry() + 1);
    vm.prank(operator);
    fund.forceEnd(order);

    assertEq(fund.pendingRedeemAssets(), 0, "no active order after forceEnd");
  }

  function test_State_ArchivedOrdersReturnEnded() public {
    Order memory firstOrder = _depositOrder(1000 * ONE_USDC, 1000 * ONE_USDC);
    _runDepositLifecycle(firstOrder);

    // Creating a new order archives the previous ended one
    Order memory secondOrder = _depositOrder(2000 * ONE_USDC, 2000 * ONE_USDC);
    secondOrder.salt = bytes32(uint256(2));
    fund.create(secondOrder);

    assertEq(uint256(fund.state(firstOrder)), uint256(State.ENDED), "archived order");
    assertEq(uint256(fund.state(secondOrder)), uint256(State.ACCEPTED), "new order");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _depositOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      salt: bytes32(uint256(1))
    });
  }

  function _redeemOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      salt: bytes32(uint256(1))
    });
  }

  /// @dev Runs a full deposit lifecycle so the test contract ends up holding wrapped shares.
  function _depositFor(uint256 amount) internal {
    Order memory order = _depositOrder(amount, amount);
    order.salt = keccak256(abi.encode("depositFor", amount, block.timestamp));
    _runDepositLifecycle(order);
  }

  function _runDepositLifecycle(Order memory order) internal {
    fund.create(order);
    usdc.approve(address(fund), order.input);
    fund.commit(order);
    fund.unlock(order);
  }
}
