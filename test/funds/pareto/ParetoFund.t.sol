// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ParetoFund} from "src/funds/pareto/ParetoFund.sol";
import {ParetoFundFactory} from "src/funds/pareto/ParetoFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockIdleCDOEpochVariant} from "../../mock/funds/pareto/MockIdleCDOEpochVariant.sol";
import {MockIdleCreditVault} from "../../mock/funds/pareto/MockIdleCreditVault.sol";

contract ParetoFundTest is Test {
  using LibOrder for Order;

  error InvalidInitialization();
  error Unauthorized();

  event OrderCreated(
    bytes32 indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);
  event OrderResolved(
    bytes32 indexed orderId, bytes32 indexed newOrderId, uint256 input, uint256 output, address indexed caller
  );

  uint256 private constant ONE_USDC = 1e6;
  uint256 private constant ONE_AA = 1e18;

  // WrappedAsset roles
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TEST STATE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  ParetoFundFactory public factory;
  ParetoFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockERC20 public aaTranche;
  MockIdleCreditVault public strategy;
  MockIdleCDOEpochVariant public cdo;

  address public owner;
  address public operator;
  address public outsider;

  function setUp() public {
    owner = makeAddr("owner");
    operator = makeAddr("operator");
    outsider = makeAddr("outsider");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    aaTranche = new MockERC20("AA Tranche", "AA", 18);
    strategy = new MockIdleCreditVault();
    cdo = new MockIdleCDOEpochVariant(address(usdc), address(aaTranche), address(strategy));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(aaTranche), "wAA", "Wrapped AA");

    factory = new ParetoFundFactory(owner);
    address fundAddress = factory.createFund(owner, address(this), address(cdo), address(wrappedShare));
    fund = ParetoFund(fundAddress);

    cdo.setWalletAllowed(address(fund), true);

    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);

    vm.prank(owner);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_Success() public view {
    assertEq(fund.owner(), owner, "owner");
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.vault(), address(cdo), "vault");
    assertEq(fund.rolesOf(address(this)), fund.DEPOSITOR_ROLE(), "depositor role");
    assertEq(uint256(fund.state(_depositOrder(ONE_USDC, ONE_AA))), uint256(State.EMPTY), "initial state");
  }

  function test_Initialize_RevertsInvalidOwner() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.PARETO_FUND_BEACON());
    vm.expectRevert(CommonErrors.AddressZero.selector);
    ParetoFund(fundProxy).initialize(address(0), address(this), address(cdo), address(wrappedShare));
  }

  function test_Initialize_RevertsInvalidDepositor() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.PARETO_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    ParetoFund(fundProxy).initialize(owner, address(0xBEEF), address(cdo), address(wrappedShare));
  }

  function test_Initialize_RevertsInvalidVault() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.PARETO_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    ParetoFund(fundProxy).initialize(owner, address(this), address(0xBEEF), address(wrappedShare));
  }

  function test_Initialize_RevertsInvalidWrappedShare() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.PARETO_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    ParetoFund(fundProxy).initialize(owner, address(this), address(cdo), address(0xBEEF));
  }

  function test_Initialize_RevertsWrappedShareMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    WrappedAsset impl2 = new WrappedAsset();
    address proxy2 = LibClone.deployERC1967(address(impl2));
    WrappedAsset badWrappedShare = WrappedAsset(proxy2);
    vm.prank(owner);
    badWrappedShare.initialize(owner, owner, address(otherToken), "bad", "Bad");

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.PARETO_FUND_BEACON());
    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    ParetoFund(fundProxy).initialize(owner, address(this), address(cdo), address(badWrappedShare));
  }

  function test_Initialize_OnlyOnce() public {
    vm.expectRevert(InvalidInitialization.selector);
    fund.initialize(owner, address(this), address(cdo), address(wrappedShare));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             CREATE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Create_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    State state = fund.create(order);

    assertEq(uint256(state), uint256(State.ACCEPTED), "state");
  }

  function test_Create_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE_AA, ONE_USDC);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    fund.create(order);
  }

  function test_Create_RevertsAmountZero() public {
    Order memory order = _depositOrder(0, ONE_AA);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    order.owner = outsider;
    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidReceiver() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    order.receiver = outsider;
    vm.expectRevert(LibFundsErrors.InvalidReceiver.selector);
    fund.create(order);
  }

  function test_Create_RevertsPendingOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);

    // Already ACCEPTED
    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(order);

    // Commit to PROCESSING
    _commitDeposit(order);

    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(order);
  }

  function test_Create_RevertsNotAllowed() public {
    cdo.setWalletAllowed(address(fund), false);
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    vm.expectRevert(LibFundsErrors.NotAllowedByFund.selector);
    fund.create(order);
  }

  function test_Create_AfterEndedOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);
    _fulfillDeposit(order);
    fund.unlock(order);

    Order memory nextOrder = _depositOrder(ONE_USDC * 2, ONE_AA * 2);
    State state = fund.create(nextOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  function test_Create_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.create(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             CANCEL                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Cancel_Success() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    bytes32 orderId = order.toId(address(fund));
    fund.create(order);

    vm.expectEmit(true, true, true, true);
    emit OrderCanceled(orderId, order.mode, order.owner);
    State state = fund.cancel(order);
    assertEq(uint256(state), uint256(State.EMPTY), "state");
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "order state");

    // Can create again after cancel
    State next = fund.create(order);
    assertEq(uint256(next), uint256(State.ACCEPTED), "accepted");
  }

  function test_Cancel_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.cancel(wrongOrder);
  }

  function test_Cancel_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.cancel(order);
  }

  function test_Cancel_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.cancel(order);
  }

  function test_Cancel_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.cancel(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             COMMIT                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Commit_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);

    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderCommitted(orderId, order.mode, order.input);
    (State state, uint256 amount) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(amount, order.input, "amount");
    // USDC should be in CDO (pulled via depositAA)
    assertEq(usdc.balanceOf(address(cdo)), order.input, "cdo has usdc");
    // AA tranche tokens minted to fund: amount * 1e18 / virtualPrice = 1e6 * 1e18 / 1e6 = 1e18
    assertEq(aaTranche.balanceOf(address(fund)), ONE_AA, "fund has AA tranche");
    // State is UNLOCKING because balance (1e18) >= order.output (1e18)
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");
  }

  function test_Commit_RedeemSuccess() public {
    // First deposit to get wrappedShares
    Order memory depositOrder = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(depositOrder);
    _commitDeposit(depositOrder);
    _fulfillDeposit(depositOrder);
    fund.unlock(depositOrder);

    // Now redeem
    Order memory order = _redeemOrder(ONE_AA, ONE_USDC);
    fund.create(order);
    wrappedShare.approve(address(fund), order.input);

    (State state, uint256 amount) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(amount, order.input, "amount");
    // Wrapped shares should be burned
    assertEq(wrappedShare.balanceOf(address(this)), 0, "burned");
  }

  function test_Commit_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.commit(wrongOrder);
  }

  function test_Commit_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    // Not created yet
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, order.toId(address(fund))));
    fund.commit(order);

    fund.create(order);
    _commitDeposit(order);

    // Already PROCESSING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.commit(order);
  }

  function test_Commit_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsNotAllowed() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    cdo.setWalletAllowed(address(fund), false);
    vm.expectRevert(LibFundsErrors.NotAllowedByFund.selector);
    fund.commit(order);
  }

  function test_Commit_DepositClearsApproval() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);

    assertEq(usdc.allowance(address(fund), address(cdo)), 0, "approval cleared");
  }

  function test_Commit_RedeemClearsApproval() public {
    // First deposit to get wrappedShares
    Order memory depositOrder = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(depositOrder);
    _commitDeposit(depositOrder);
    _fulfillDeposit(depositOrder);
    fund.unlock(depositOrder);

    // Now redeem
    Order memory order = _redeemOrder(ONE_AA, ONE_USDC);
    fund.create(order);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    assertEq(aaTranche.allowance(address(fund), address(cdo)), 0, "approval cleared");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             UNLOCK                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Unlock_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);
    // After depositAA, fund has AA tranche tokens. State should be UNLOCKING.
    _fulfillDeposit(order);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, ONE_AA, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, ONE_AA, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), ONE_AA, "wShare minted");
  }

  function test_Unlock_RedeemSuccess() public {
    // First deposit to get wrappedShares
    Order memory depositOrder = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(depositOrder);
    _commitDeposit(depositOrder);
    _fulfillDeposit(depositOrder);
    fund.unlock(depositOrder);

    // Now redeem
    Order memory order = _redeemOrder(ONE_AA, ONE_USDC);
    fund.create(order);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    // Advance epoch to make withdrawal claimable
    _fulfillRedeem();

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, ONE_USDC, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, ONE_USDC, "amount");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "usdc received");
  }

  function test_Unlock_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);
    _fulfillDeposit(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.unlock(wrongOrder);
  }

  function test_Unlock_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    // ACCEPTED, not UNLOCKING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.unlock(order);

    _commitDeposit(order);
    // Clear AA tranche balance to keep PROCESSING (output not met)
    aaTranche.burn(address(fund), aaTranche.balanceOf(address(fund)));
    // PROCESSING, not UNLOCKING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);
  }

  function test_Unlock_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);
    _fulfillDeposit(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.unlock(order);
  }

  function test_Unlock_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.unlock(order);
  }

  function test_Unlock_DepositClearsApproval() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);
    _fulfillDeposit(order);
    fund.unlock(order);

    assertEq(aaTranche.allowance(address(fund), address(wrappedShare)), 0, "approval cleared");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             RECOVER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Recover_AlwaysReverts() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);

    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recover(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             RESOLVE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Resolve_Success() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);

    bytes32 orderId = order.toId(address(fund));
    // Compute the new order ID after resolve modifies input/output in memory
    Order memory resolvedOrder = Order({
      mode: order.mode,
      owner: order.owner,
      receiver: order.receiver,
      input: ONE_USDC / 2,
      output: ONE_AA / 2,
      salt: order.salt
    });
    bytes32 newOrderId = resolvedOrder.toId(address(fund));

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderResolved(orderId, newOrderId, ONE_USDC / 2, ONE_AA / 2, owner);
    fund.resolve(order, ONE_USDC / 2, ONE_AA / 2);
  }

  function test_Resolve_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);

    // ACCEPTED, not PROCESSING
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.resolve(order, ONE_USDC, ONE_AA);
  }

  function test_Resolve_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.resolve(wrongOrder, ONE_USDC, ONE_AA);
  }

  function test_Resolve_OnlyOwnerOrOperator() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);

    // outsider cannot resolve
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.resolve(order, ONE_USDC, ONE_AA);

    // depositor (address(this)) cannot resolve either
    vm.expectRevert(Unauthorized.selector);
    fund.resolve(order, ONE_USDC, ONE_AA);
  }

  function test_Resolve_SucceedsWithOperator() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);

    uint256 operatorRole = fund.OPERATOR_ROLE();
    vm.prank(owner);
    fund.grantRoles(operator, operatorRole);

    vm.prank(operator);
    fund.resolve(order, ONE_USDC, ONE_AA);
  }

  function test_Resolve_SucceedsWithOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.resolve(order, ONE_USDC, ONE_AA);
  }

  function test_Resolve_AffectsDepositStateTransition() public {
    // Create deposit with high expected output
    Order memory order = _depositOrder(ONE_USDC, ONE_AA * 2);
    fund.create(order);
    _commitDeposit(order);

    // Fund has 1e18 AA tranche tokens from depositAA, but order.output = 2e18
    // So state should still be PROCESSING (balance < expected)
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing before resolve");

    // Resolve with lower output threshold
    vm.prank(owner);
    fund.resolve(order, ONE_USDC, ONE_AA);

    // Now balance (1e18) >= resolvedOutput (1e18), state should be UNLOCKING
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after resolve");
  }

  function test_Resolve_AffectsRedeemStateTransition() public {
    // First deposit to get wrappedShares
    Order memory depositOrder = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(depositOrder);
    _commitDeposit(depositOrder);
    _fulfillDeposit(depositOrder);
    fund.unlock(depositOrder);

    // Set epoch as running so withdrawal isn't immediately claimable
    cdo.setEpochEndDate(block.timestamp + 1 days);

    // Create redeem order
    Order memory order = _redeemOrder(ONE_AA, ONE_USDC);
    fund.create(order);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    // Resolve — redeem state is determined by epoch, not resolve
    vm.prank(owner);
    fund.resolve(order, ONE_AA, ONE_USDC / 2);

    // Still PROCESSING since epoch hasn't ended
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "still processing");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             VIEWS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Vault_ReturnsVault() public view {
    assertEq(fund.vault(), address(cdo), "vault");
  }

  function test_Asset_ReturnsAsset() public view {
    assertEq(fund.asset(), address(usdc), "asset");
  }

  function test_Share_ReturnsWrappedShare() public view {
    assertEq(fund.share(), address(wrappedShare), "share");
  }

  function test_TotalAssets_UsesVirtualPrice() public {
    _depositAndUnlock(ONE_USDC);

    uint256 totalAssets = fund.totalAssets();
    // totalSupply (1e18) * virtualPrice (1e6) / 1e18 = 1e6
    // virtualPrice is in underlying decimals (1e6 for USDC means 1:1)
    assertEq(totalAssets, ONE_USDC, "totalAssets at 1:1");

    // Change virtualPrice to 1.5e6 (1 AA = 1.5 USDC)
    cdo.setVirtualPrice(1.5e6);
    totalAssets = fund.totalAssets();
    assertEq(totalAssets, ONE_USDC * 15 / 10, "totalAssets at 1.5x");
  }

  function test_MaxDeposit_ReturnsMax() public view {
    assertEq(fund.maxDeposit(address(this)), type(uint256).max, "max deposit");
    assertEq(fund.maxDeposit(outsider), type(uint256).max, "max deposit outsider");
  }

  function test_MaxRedeem_ReturnsBalance() public {
    assertEq(fund.maxRedeem(address(this)), 0, "no balance");

    _depositAndUnlock(ONE_USDC);

    assertEq(fund.maxRedeem(address(this)), ONE_AA, "has balance");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             STATE                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_State_AllStates() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "empty");

    fund.create(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "accepted");

    _commitDeposit(order);
    // After depositAA, fund has AA tranche, and balance >= output → UNLOCKING
    // (since depositAA mints exactly output amount at 1:1 virtualPrice)
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
  }

  function test_State_DepositProcessingWhenOutputNotMet() public {
    // Create order expecting more output than depositAA will produce
    Order memory order = _depositOrder(ONE_USDC, ONE_AA * 2);
    fund.create(order);
    _commitDeposit(order);

    // depositAA mints 1e18 AA at 1:1, but order expects 2e18
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");
  }

  function test_State_RedeemDynamicTransitions() public {
    // First deposit
    _depositAndUnlock(ONE_USDC);

    // Now redeem
    Order memory order = _redeemOrder(ONE_AA, ONE_USDC);
    fund.create(order);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    // Set epoch as running (epoch not ended yet)
    cdo.setEpochEndDate(block.timestamp + 1 days);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing during epoch");

    // Advance epoch to make withdrawal claimable
    _fulfillRedeem();
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after epoch");
  }

  function test_State_NonCurrentOrderReturnsEmpty() public {
    Order memory order1 = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order1);
    _commitDeposit(order1);

    Order memory order2 = _depositOrder(2 * ONE_USDC, 2 * ONE_AA);
    assertEq(uint256(fund.state(order2)), uint256(State.EMPTY), "non-current order is EMPTY");
  }

  function test_State_ResolvedOutputUsedForTransition() public {
    // Create deposit with very high output expectation
    Order memory order = _depositOrder(ONE_USDC, ONE_AA * 10);
    fund.create(order);
    _commitDeposit(order);

    // Fund has 1e18 AA from depositAA but expects 10e18 → PROCESSING
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    // Resolve to lower the threshold
    vm.prank(owner);
    fund.resolve(order, ONE_USDC, ONE_AA);

    // Now 1e18 >= 1e18 → UNLOCKING
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after resolve");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        STATE MACHINE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_StateMachine_FullRedeemLifecycle() public {
    // Deposit first to get shares
    _depositAndUnlock(ONE_USDC);

    // Set epoch as running so withdrawal isn't immediately claimable
    cdo.setEpochEndDate(block.timestamp + 1 days);

    // Redeem lifecycle
    Order memory order = _redeemOrder(ONE_AA, ONE_USDC);
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "empty");

    fund.create(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "accepted");

    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    _fulfillRedeem();
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "usdc received");
  }

  function test_StateMachine_MultipleOrders() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);
    _fulfillDeposit(order);
    fund.unlock(order);

    Order memory nextOrder = _depositOrder(ONE_USDC * 2, ONE_AA * 2);
    fund.create(nextOrder);
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             ROLES                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Roles_OperatorGrantable() public {
    uint256 operatorRole = fund.OPERATOR_ROLE();
    vm.prank(owner);
    fund.grantRoles(operator, operatorRole);
    assertEq(fund.rolesOf(operator), operatorRole, "operator role");
  }

  function test_Roles_OwnershipTransfer() public {
    vm.prank(owner);
    fund.transferOwnership(operator);
    assertEq(fund.owner(), operator, "new owner");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         EDGE CASES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Edge_OrderIdCollision() public view {
    Order memory orderA = _depositOrder(ONE_USDC, ONE_AA);
    Order memory orderB = Order({
      mode: orderA.mode,
      owner: orderA.owner,
      receiver: orderA.receiver,
      input: orderA.input,
      output: orderA.output,
      salt: keccak256("different")
    });
    assertFalse(orderA.toId(address(fund)) == orderB.toId(address(fund)), "different ids");
  }

  function test_Edge_ArchivedOrderReturnsEnded() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_AA);
    fund.create(order);
    _commitDeposit(order);
    _fulfillDeposit(order);
    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");

    // Create new order with different salt
    Order memory nextOrder = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: ONE_USDC * 2,
      output: ONE_AA * 2,
      salt: keccak256("second-order")
    });
    fund.create(nextOrder);

    // Old order was archived — state() returns ENDED
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "old order ENDED (archived)");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            HELPERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _depositOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      salt: keccak256("deposit")
    });
  }

  function _redeemOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      salt: keccak256("redeem")
    });
  }

  function _commitDeposit(Order memory order) internal {
    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);
    fund.commit(order);
  }

  /// @dev For deposit: after commitDeposit, the fund already has AA tranche tokens
  ///      from depositAA. This is a no-op if the balance already meets output.
  ///      If the order expects more than what was minted, this mints additional AA tokens.
  function _fulfillDeposit(Order memory order) internal {
    uint256 currentBalance = aaTranche.balanceOf(address(fund));
    if (currentBalance < order.output) {
      aaTranche.mint(address(fund), order.output - currentBalance);
    }
  }

  /// @dev For redeem: advances epoch and funds CDO with underlying.
  function _fulfillRedeem() internal {
    // Fund CDO with underlying for claim
    uint256 pendingAmount = strategy.withdrawsRequests(address(fund));
    cdo.fundUnderlying(pendingAmount);
    // Advance epoch to make withdrawal claimable
    cdo.advanceEpoch();
  }

  /// @dev Full deposit + unlock cycle to get wrappedShares
  function _depositAndUnlock(uint256 usdcAmount) internal {
    Order memory order = _depositOrder(usdcAmount, usdcAmount * 1e12); // scale 6 → 18
    fund.create(order);
    _commitDeposit(order);
    _fulfillDeposit(order);
    fund.unlock(order);
  }
}
