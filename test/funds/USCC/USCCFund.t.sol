// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {USCCFund} from "src/funds/USCC/USCCFund.sol";
import {USCCFundFactory} from "src/funds/USCC/USCCFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockAllowlist} from "../../mock/funds/MockAllowlist.sol";
import {MockChainlinkOracle} from "../../mock/funds/MockChainlinkOracle.sol";
import {MockSuperstateToken} from "../../mock/funds/MockSuperstateToken.sol";

contract USCCFundTest is Test {
  using LibOrder for Order;
  using LibClone for address;

  error InvalidInitialization();
  error Unauthorized();

  event OrderCreated(
    bytes32 indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);
  event OrderRecovering(bytes32 indexed orderId);
  event OrderProcessing(bytes32 indexed orderId);
  event OracleUpdated(address indexed newOracle, address indexed operator);
  event OrderResolved(bytes32 indexed orderId, uint256 newInput, uint256 newOutput, address indexed operator);

  uint256 private constant ONE_USDC = 1e6;

  // USCCFund roles (matching internal constants)
  uint256 private constant OPERATOR_ROLE = 1 << 0;
  uint256 private constant DEPOSITOR_ROLE = 1 << 1;

  // WrappedAsset roles (matching internal constants)
  uint256 private constant WUSCC_ISSUER_ROLE = 1 << 0;
  uint256 private constant WUSCC_SENDER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TEST STATE                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  USCCFundFactory public factory;
  USCCFund public fund;
  WrappedAsset public wuscc;
  MockERC20 public usdc;
  MockSuperstateToken public uscc;
  MockAllowlist public allowlist;
  MockChainlinkOracle public oracle;

  address public owner;
  address public operator;
  address public recipient;
  address public outsider;

  function setUp() public {
    owner = makeAddr("owner");
    operator = makeAddr("operator");
    recipient = makeAddr("recipient");
    outsider = makeAddr("outsider");

    allowlist = new MockAllowlist();
    usdc = new MockERC20("USD Coin", "USDC", 6);
    uscc = new MockSuperstateToken("USCC", "USCC", address(allowlist), address(usdc));
    oracle = new MockChainlinkOracle(6);
    oracle.setRoundData(1, int256(ONE_USDC), block.timestamp, 1);
    oracle.setLatestRound(1);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wuscc = WrappedAsset(proxy);
    vm.prank(owner);
    wuscc.initialize(owner, owner, address(uscc), "wUSCC", "Wrapped USCC");

    factory = new USCCFundFactory(owner, address(usdc), address(uscc), address(wuscc));
    address fundAddress = factory.createFund(owner, address(this), recipient, address(oracle));
    fund = USCCFund(fundAddress);

    // Allowlist all addresses that send/receive USCC (mirrors production Superstate enforcement)
    allowlist.setAllowed(address(fund), "USCC", true);
    allowlist.setAllowed(address(wuscc), "USCC", true);
    allowlist.setAllowed(address(this), "USCC", true);
    allowlist.setAllowed(owner, "USCC", true);
    allowlist.setAllowed(operator, "USCC", true);
    allowlist.setAllowed(recipient, "USCC", true);
    allowlist.setAllowed(outsider, "USCC", true);
    vm.prank(owner);
    wuscc.grantRoles(address(fund), WUSCC_ISSUER_ROLE);

    vm.prank(owner);
    wuscc.grantRoles(address(this), WUSCC_SENDER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_Success() public view {
    assertEq(fund.owner(), owner, "owner");
    assertEq(fund.asset(), address(usdc), "usdc");
    assertEq(fund.share(), address(wuscc), "wuscc");
    assertEq(fund.rolesOf(address(this)), DEPOSITOR_ROLE, "depositor role");
    assertEq(uint256(fund.state(_depositOrder(ONE_USDC, ONE_USDC))), uint256(State.EMPTY), "initial state");
  }

  function test_Initialize_RevertsInvalidContract() public {
    USCCFund local = USCCFund(address(new USCCFund(address(usdc), address(uscc), address(wuscc))).clone());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    local.initialize(owner, address(0xBEEF), recipient, address(oracle));

    local = USCCFund(address(new USCCFund(address(usdc), address(uscc), address(wuscc))).clone());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    local.initialize(owner, address(this), recipient, address(1));
  }

  function test_Initialize_RevertsInvalidOwner() public {
    USCCFund local = USCCFund(address(new USCCFund(address(usdc), address(uscc), address(wuscc))).clone());
    vm.expectRevert(CommonErrors.AddressZero.selector);
    local.initialize(address(0), address(this), recipient, address(oracle));
  }

  function test_Initialize_RevertsInvalidRecipient() public {
    USCCFund local = USCCFund(address(new USCCFund(address(usdc), address(uscc), address(wuscc))).clone());
    vm.expectRevert(CommonErrors.AddressZero.selector);
    local.initialize(owner, address(this), address(0), address(oracle));
  }

  function test_Constructor_RevertsUsdcDecimalsMismatch() public {
    MockERC20 badUsdc = new MockERC20("Bad USDC", "BUSDC", 18);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.DecimalsMismatch.selector, 18, 6));
    new USCCFund(address(badUsdc), address(uscc), address(wuscc));
  }

  function test_Constructor_RevertsUsccDecimalsMismatch() public {
    MockERC20 badUscc = new MockERC20("Bad USCC", "BUSCC", 18);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.DecimalsMismatch.selector, 18, 6));
    new USCCFund(address(usdc), address(badUscc), address(wuscc));
  }

  function test_Constructor_RevertsWrappedAssetDecimalsMismatch() public {
    MockERC20 badWuscc = new MockERC20("Bad WUSCC", "BWUSCC", 18);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.DecimalsMismatch.selector, 18, 6));
    new USCCFund(address(usdc), address(uscc), address(badWuscc));
  }

  function test_Initialize_RevertsInvalidOracleDecimals() public {
    USCCFund local = USCCFund(address(new USCCFund(address(usdc), address(uscc), address(wuscc))).clone());
    MockChainlinkOracle badOracle = new MockChainlinkOracle(8);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOracle.selector, address(badOracle)));
    local.initialize(owner, address(this), recipient, address(badOracle));
  }

  function test_Initialize_OnlyOnce() public {
    vm.expectRevert(InvalidInitialization.selector);
    fund.initialize(owner, address(this), recipient, address(oracle));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                              CREATE                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Create_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    State state = fund.create(order);

    assertEq(uint256(state), uint256(State.ACCEPTED), "state");
  }

  function test_Create_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    fund.create(order);
  }

  function test_Create_RevertsAmountZero() public {
    Order memory order = _depositOrder(0, ONE_USDC);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.owner = outsider;
    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidReceiver() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.receiver = outsider;
    vm.expectRevert(LibFundsErrors.InvalidReceiver.selector);
    fund.create(order);
  }

  function test_Create_RevertsPendingOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(order);

    _commitDeposit(order);

    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(order);
  }

  function test_Create_RevertsOrderAlreadyExists() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    _unlockDeposit(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");

    // Create a different order to trigger archiving of the ended order
    Order memory nextOrder = _depositOrder(ONE_USDC * 2, ONE_USDC * 2);
    fund.create(nextOrder);
    _commitDeposit(nextOrder);
    _unlockDeposit(nextOrder);

    // Now try to create a new order with the same params as the first (already archived) order
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.OrderAlreadyExists.selector, order.toId(address(fund))));
    fund.create(order);
  }

  function test_Create_RevertsNotAllowedSuperstate() public {
    allowlist.setAllowed(address(fund), "USCC", false);
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    vm.expectRevert(LibFundsErrors.NotAllowedSuperstate.selector);
    fund.create(order);
  }

  function test_Create_RevertsNotAllowedSuperstate_Receiver() public {
    allowlist.setAllowed(address(this), "USCC", false);
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    vm.expectRevert(LibFundsErrors.NotAllowedSuperstate.selector);
    fund.create(order);
  }

  function test_Create_RevertsRedeem_WhenAccountingPaused() public {
    uscc.setAccountingPaused(true);
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    vm.expectRevert(LibFundsErrors.SuperstateAccountingPaused.selector);
    fund.create(order);
  }

  function test_Create_AllowsDeposit_WhenAccountingPaused() public {
    uscc.setAccountingPaused(true);
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "deposit accepted while paused");
  }

  function test_Create_RevertsInvalidOutput_Deposit() public {
    // With oracle price = 1:1, expected output = input = 100 USDC
    // MAX_OUTPUT_DEVIATION = 500 bps (5%), so min valid output = 100 - 5 = 95
    // Output of 94 should revert
    Order memory order = _depositOrder(100 * ONE_USDC, 94 * ONE_USDC);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidOutput_Redeem() public {
    Order memory order = _redeemOrder(100 * ONE_USDC, 94 * ONE_USDC);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  function test_Create_SucceedsAtMinOutputBoundary_Deposit() public {
    // With oracle price = 1:1, expected output = 100 USDC
    // maxDeviation = 100e6 * 500 / 10000 = 5e6
    // minOutput = 100e6 - 5e6 = 95e6
    Order memory order = _depositOrder(100 * ONE_USDC, 95 * ONE_USDC);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted at boundary");
  }

  function test_Create_SucceedsAtMinOutputBoundary_Redeem() public {
    Order memory order = _redeemOrder(100 * ONE_USDC, 95 * ONE_USDC);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted at boundary");
  }

  function test_Create_SucceedsWithOutputAboveExpected() public {
    // Output above oracle-derived expected should pass (no downside check triggered)
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC * 2);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted above expected");
  }

  function test_Create_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.create(order);
  }

  function test_Create_AfterEndedOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    _unlockDeposit(order);

    Order memory nextOrder = _depositOrder(ONE_USDC * 2, ONE_USDC * 2);
    State state = fund.create(nextOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             CANCEL                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Cancel_Success() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    bytes32 orderId = order.toId(address(fund));
    fund.create(order);

    vm.expectEmit(true, true, true, true);
    emit OrderCanceled(orderId, order.mode, order.owner);
    State state = fund.cancel(order);
    assertEq(uint256(state), uint256(State.EMPTY), "state");
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "order state");

    State next = fund.create(order);
    assertEq(uint256(next), uint256(State.ACCEPTED), "accepted");
  }

  function test_Cancel_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.cancel(wrongOrder);
  }

  function test_Cancel_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.cancel(order);
  }

  function test_Cancel_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.cancel(order);
  }

  function test_Cancel_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.cancel(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          COMMIT                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Commit_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderCommitted(orderId, order.mode, order.input);
    (State state, uint256 amount) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(amount, order.input, "amount");
    assertEq(usdc.balanceOf(recipient), order.input, "recipient");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");
  }

  function test_Commit_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    // Mint wUSCC to this test contract (wraps USCC into wUSCC contract)
    _mintWuscc(address(this), order.input);

    // Approve fund to burn wUSCC from this contract
    wuscc.approve(address(fund), order.input);

    uint256 balanceBefore = wuscc.balanceOf(address(this));
    (State state,) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(wuscc.balanceOf(address(this)), balanceBefore - order.input, "burned");

    // Verify offchainRedeem was called on USCC (not USDC)
    assertEq(uscc.lastOffchainRedeemer(), address(fund), "offchainRedeem caller should be fund");
    assertEq(uscc.lastOffchainRedeemAmount(), order.input, "offchainRedeem amount should match order input");
  }

  function test_Commit_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.commit(wrongOrder);
  }

  function test_Commit_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, order.toId(address(fund))));
    fund.commit(order);

    fund.create(order);
    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);
    fund.commit(order);

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.commit(order);
  }

  function test_Commit_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsNotAllowedSuperstate() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    allowlist.setAllowed(address(fund), "USCC", false);

    vm.expectRevert(LibFundsErrors.NotAllowedSuperstate.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsNotAllowedSuperstate_Receiver() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    allowlist.setAllowed(address(this), "USCC", false);

    vm.expectRevert(LibFundsErrors.NotAllowedSuperstate.selector);
    fund.commit(order);
  }

  function test_Commit_AllowsAfterReceiverReinstated() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    allowlist.setAllowed(address(this), "USCC", false);
    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);
    vm.expectRevert(LibFundsErrors.NotAllowedSuperstate.selector);
    fund.commit(order);

    allowlist.setAllowed(address(this), "USCC", true);
    (State state,) = fund.commit(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "processing");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UNLOCK                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Unlock_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    uscc.mint(address(fund), order.output);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, order.output, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.output, "amount");
    assertEq(wuscc.balanceOf(address(this)), order.output, "minted");
  }

  function test_Unlock_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    uscc.mint(address(fund), order.output);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.unlock(wrongOrder);
  }

  function test_Unlock_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.unlock(order);

    _commitDeposit(order);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);
  }

  function test_Unlock_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    uscc.mint(address(fund), order.output);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.unlock(order);
  }

  function test_Unlock_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.unlock(order);
  }

  function test_Unlock_PartialReceived() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    uscc.mint(address(fund), order.output - 1);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          RECOVER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Recover_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));
    usdc.mint(address(fund), order.input);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderRecovered(orderId, order.mode, order.input, address(this));
    (State state, uint256 amount) = fund.recover(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.input, "amount");
    assertEq(usdc.balanceOf(address(this)), order.input, "received");
  }

  function test_Recover_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));
    usdc.mint(address(fund), order.input);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.recover(wrongOrder);
  }

  function test_Recover_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.recover(order);
  }

  function test_Recover_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));
    usdc.mint(address(fund), order.input);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.recover(order);
  }

  function test_Recover_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.recover(order);
  }

  function test_Recover_NoFundsReturned() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            ADMIN                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Recovering_Success() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderRecovering(order.toId(address(fund)));
    fund.recovering(order.toId(address(fund)));
  }

  function test_Recovering_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    bytes32 staleOrderId = keccak256("stale");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, staleOrderId));
    fund.recovering(staleOrderId);
  }

  function test_Recovering_RevertsStaleOrderId() public {
    // First order: create, commit, unlock
    Order memory order1 = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order1);
    _commitDeposit(order1);
    uscc.mint(address(fund), order1.output);
    fund.unlock(order1);

    // Second order: create, commit → now in PROCESSING
    Order memory order2 = _depositOrder(ONE_USDC * 2, ONE_USDC * 2);
    fund.create(order2);
    _commitDeposit(order2);

    // A stale recovering() call targeting the old order must revert
    bytes32 staleOrderId = order1.toId(address(fund));
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, staleOrderId));
    fund.recovering(staleOrderId);
  }

  function test_CancelRecovering_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    bytes32 staleOrderId = keccak256("stale");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, staleOrderId));
    fund.cancelRecovering(staleOrderId);
  }

  function test_Recovering_RevertsInvalidState() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.EMPTY));
    fund.recovering(bytes32(0));
  }

  function test_Recovering_OnlyOperatorOrOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.recovering(order.toId(address(fund)));
  }

  function test_CancelRecovering_Success() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderProcessing(order.toId(address(fund)));
    fund.cancelRecovering(order.toId(address(fund)));

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "back to processing");
  }

  function test_CancelRecovering_RevertsInvalidState() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.EMPTY));
    fund.cancelRecovering(bytes32(0));
  }

  function test_CancelRecovering_OnlyOperatorOrOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.cancelRecovering(order.toId(address(fund)));
  }

  function test_CancelRecovering_ThenUnlock_Deposit() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    // Operator mistakenly calls recovering
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    // Superstate delivers output USCC despite recovering state
    uscc.mint(address(fund), order.output);

    // State is stuck — RECOVERING branch only checks USDC input, not USCC output
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "stuck in processing");

    // Operator cancels recovering
    vm.prank(owner);
    fund.cancelRecovering(order.toId(address(fund)));

    // Now _state() uses PROCESSING branch which checks USCC output
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after cancel");

    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
    assertEq(wuscc.balanceOf(address(this)), order.output, "wuscc received");
  }

  function test_CancelRecovering_ThenUnlock_Redeem() public {
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _mintWuscc(address(this), order.input);
    wuscc.approve(address(fund), order.input);
    fund.commit(order);

    // Operator mistakenly calls recovering
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    // Superstate delivers output USDC despite recovering state
    usdc.mint(address(fund), order.output);

    // State is stuck — RECOVERING branch only checks USCC input, not USDC output
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "stuck in processing");

    // Operator cancels recovering
    vm.prank(owner);
    fund.cancelRecovering(order.toId(address(fund)));

    // Now _state() uses PROCESSING branch which checks USDC output
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after cancel");

    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
    assertEq(usdc.balanceOf(address(this)), order.output, "usdc received");
  }

  function test_SetOracle_Success() public {
    MockChainlinkOracle newOracle = new MockChainlinkOracle(6);
    // Set valid data in the new oracle since setOracle() now reads from it
    newOracle.setRoundData(1, int256(ONE_USDC), block.timestamp, 1);
    newOracle.setLatestRound(1);

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OracleUpdated(address(newOracle), owner);
    fund.setOracle(address(newOracle));
  }

  function test_SetOracle_RevertsInvalidContract() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    fund.setOracle(address(1));
  }

  function test_SetOracle_RevertsInvalidDecimals() public {
    MockChainlinkOracle newOracle = new MockChainlinkOracle(8);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOracle.selector, address(newOracle)));
    fund.setOracle(address(newOracle));
  }

  function test_SetOracle_OnlyOperatorOrOwner() public {
    MockChainlinkOracle newOracle = new MockChainlinkOracle(6);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.setOracle(address(newOracle));
  }

  function test_Resolve_Success() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    bytes32 orderId = order.toId(address(fund));
    uint256 newInput = order.input;
    uint256 newOutput = ONE_USDC / 2;

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderResolved(orderId, newInput, newOutput, owner);
    fund.resolve(order, newInput, newOutput);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "original processing");

    uscc.mint(address(fund), newOutput);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "uses resolved output");
  }

  function test_Resolve_InRecoveringState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    vm.prank(owner);
    fund.resolve(order, ONE_USDC * 2, ONE_USDC * 2);
  }

  function test_Resolve_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.resolve(order, ONE_USDC, ONE_USDC);
  }

  function test_Resolve_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.resolve(wrongOrder, ONE_USDC, ONE_USDC);
  }

  function test_Resolve_RevertsInputZero() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    fund.resolve(order, 0, ONE_USDC);
  }

  function test_Resolve_OnlyOperatorOrOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.resolve(order, ONE_USDC, ONE_USDC);
  }

  function test_Resolve_DoesNotChangeCurrentOrderId() public {
    // resolve() keeps the original order id; resolved amounts are internal overrides.
    Order memory originalOrder = _depositOrder(ONE_USDC, ONE_USDC);
    bytes32 originalId = originalOrder.toId(address(fund));
    fund.create(originalOrder);
    _commitDeposit(originalOrder);

    // Operator resolves with different amounts (e.g., Superstate sent less than expected)
    uint256 newInput = ONE_USDC;
    uint256 newOutput = (ONE_USDC * 95) / 100; // Only 95% received

    // A resolved Order struct hashes to a different id and becomes the current order.
    Order memory resolvedOrder = Order({
      mode: originalOrder.mode,
      owner: originalOrder.owner,
      receiver: originalOrder.receiver,
      input: newInput,
      output: newOutput,
      salt: originalOrder.salt
    });
    bytes32 resolvedId = resolvedOrder.toId(address(fund));
    assertFalse(originalId == resolvedId, "resolved order id differs");

    vm.prank(owner);
    fund.resolve(originalOrder, newInput, newOutput);

    // Original order id remains valid; resolved order is not recognized.
    assertEq(uint256(fund.state(originalOrder)), uint256(State.PROCESSING), "original order valid");
    assertEq(uint256(fund.state(resolvedOrder)), uint256(State.EMPTY), "resolved order empty");

    // Minting less than the resolved output keeps the order in PROCESSING.
    uscc.mint(address(fund), newOutput - 1);
    assertEq(uint256(fund.state(originalOrder)), uint256(State.PROCESSING), "original order processing");

    // Mint remaining amount to reach the resolved output threshold.
    uscc.mint(address(fund), 1);
    assertEq(uint256(fund.state(originalOrder)), uint256(State.UNLOCKING), "original order unlocking");

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, resolvedId));
    fund.unlock(resolvedOrder);

    fund.unlock(originalOrder);

    // User receives the full amount minted.
    assertEq(wuscc.balanceOf(address(this)), newOutput, "user receives output");
    assertEq(uint256(fund.state(originalOrder)), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            VIEWS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Asset_ReturnsUsdc() public view {
    assertEq(fund.asset(), address(usdc), "asset");
  }

  function test_Share_ReturnsWuscc() public view {
    assertEq(fund.share(), address(wuscc), "share");
  }

  function test_TotalAssets_ValidPrice() public {
    // totalAssets is now based on wUSCC.totalSupply() * oracle price
    _mintWuscc(address(this), 5 * ONE_USDC);
    uint256 totalAssets = fund.totalAssets();
    assertEq(totalAssets, 5 * ONE_USDC, "totalAssets");
  }

  function test_TotalAssets_ChainlinkInvalidAnswer() public {
    oracle.setRoundData(2, 0, block.timestamp, 2);
    oracle.setLatestRound(2);
    vm.expectRevert(LibFundsErrors.ChainlinkInvalidAnswer.selector);
    fund.totalAssets();
  }

  function test_TotalAssets_ChainlinkIncompleteRound() public {
    oracle.setRoundData(2, int256(ONE_USDC), 0, 2);
    oracle.setLatestRound(2);
    vm.expectRevert(LibFundsErrors.ChainlinkIncompleteRound.selector);
    fund.totalAssets();
  }

  function test_TotalAssets_ChainlinkStaleRound() public {
    oracle.setRoundData(2, int256(ONE_USDC), block.timestamp, 1);
    oracle.setLatestRound(2);
    vm.expectRevert(LibFundsErrors.ChainlinkStaleRound.selector);
    fund.totalAssets();
  }

  function test_TotalAssets_FirstRound() public {
    oracle.setLatestRound(1);
    fund.totalAssets();
  }

  function test_TotalAssets_RoundIdGap() public {
    // Simulate a gap in round IDs (e.g., jump from round 1 to round 5)
    // Round 2, 3, 4 don't exist
    oracle.setRoundData(5, int256(ONE_USDC), block.timestamp, 5);
    oracle.setLatestRound(5);

    // This succeeds because we check absolute bounds, not previous rounds
    uscc.mint(address(fund), 5 * ONE_USDC);
    fund.totalAssets();
  }

  function test_TotalAssets_RoundIdGap_LargeJump() public {
    // Simulate a large gap in round IDs
    oracle.setRoundData(100, int256(ONE_USDC), block.timestamp, 100);
    oracle.setLatestRound(100);

    // Round 99 doesn't exist - handled gracefully with bounds-based approach
    uscc.mint(address(fund), 5 * ONE_USDC);
    fund.totalAssets();
  }

  function test_TotalAssets_SuccessWithNonSequentialRounds() public {
    // Bounds-based approach doesn't depend on previous rounds
    // This test verifies that even if previous round data is invalid, we can still read totalAssets
    oracle.setRoundData(2, int256(ONE_USDC), block.timestamp, 2);
    oracle.setRoundData(1, 0, block.timestamp, 1); // Invalid previous round
    oracle.setLatestRound(2);

    // Should succeed because we validate against absolute bounds, not previous rounds
    fund.totalAssets();
  }

  function test_MaxDeposit_ReturnsBalance() public {
    usdc.mint(address(this), ONE_USDC);
    assertEq(fund.maxDeposit(address(this)), ONE_USDC, "max deposit");
  }

  function test_MaxDeposit_ReturnsZero_WhenNotDepositor() public view {
    assertEq(fund.maxDeposit(outsider), 0, "max deposit outsider");
  }

  function test_MaxRedeem_ReturnsBalance() public {
    _mintWuscc(address(this), ONE_USDC);
    assertEq(fund.maxRedeem(address(this)), ONE_USDC, "max redeem");
  }

  function test_MaxRedeem_ReturnsZero_WhenNotDepositor() public view {
    assertEq(fund.maxRedeem(outsider), 0, "max redeem outsider");
  }

  function test_State_AllStates() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "empty");
    fund.create(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "accepted");
    _commitDeposit(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");
    uscc.mint(address(fund), order.output);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");
    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
  }

  function test_State_DynamicTransitions() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");
    uscc.mint(address(fund), order.output);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");
  }

  function test_State_NonCurrentOrderReturnsEmpty() public {
    // Create and process first order
    Order memory order1 = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order1);
    _commitDeposit(order1);

    // Query with a different order that was never created
    Order memory order2 = _depositOrder(2 * ONE_USDC, 2 * ONE_USDC);
    assertEq(uint256(fund.state(order2)), uint256(State.EMPTY), "non-current order should be EMPTY");

    // Even in UNLOCKING state, non-current order should return EMPTY
    uscc.mint(address(fund), order1.output);
    assertEq(uint256(fund.state(order1)), uint256(State.UNLOCKING), "current order is UNLOCKING");
    assertEq(uint256(fund.state(order2)), uint256(State.EMPTY), "non-current order still EMPTY");

    // Complete first order
    fund.unlock(order1);

    // After completion, both should return ENDED/EMPTY appropriately
    assertEq(uint256(fund.state(order1)), uint256(State.ENDED), "completed order is ENDED");
    assertEq(uint256(fund.state(order2)), uint256(State.EMPTY), "non-current order still EMPTY");
  }

  function test_State_ArchivedEndedOrderRemainsEndedAfterNewOrder_RecoveryFlow() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));
    usdc.mint(address(fund), order.input);
    fund.recover(order);

    Order memory nextOrder = _depositOrder(ONE_USDC * 3, ONE_USDC * 3);
    fund.create(nextOrder);

    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "archived order is ENDED");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         STATE MACHINE                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_StateMachine_MultipleOrders() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    uscc.mint(address(fund), order.output);
    fund.unlock(order);

    Order memory nextOrder = _depositOrder(ONE_USDC * 2, ONE_USDC * 2);
    fund.create(nextOrder);
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            ROLES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Roles_OperatorGrantable() public {
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    assertEq(fund.rolesOf(operator), OPERATOR_ROLE, "operator role");
  }

  function test_Roles_OwnershipTransfer() public {
    vm.prank(owner);
    fund.transferOwnership(operator);
    assertEq(fund.owner(), operator, "new owner");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         EDGE CASES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Edge_OrderIdCollision() public view {
    Order memory orderA = _depositOrder(ONE_USDC, ONE_USDC);
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

  function test_Edge_ExcessFunds_DepositUnlock() public {
    // Test that excess USCC received on deposit is transferred to user
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    // Superstate sends 10% more than expected
    uint256 excessAmount = order.output + (order.output / 10);
    uscc.mint(address(fund), excessAmount);

    // State should be UNLOCKING
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    // Unlock should transfer the full excess amount
    fund.unlock(order);

    // User receives all the excess as wUSCC
    assertEq(wuscc.balanceOf(address(this)), excessAmount, "user receives excess wUSCC");
    // USCC is now held by wUSCC contract (not the fund)
    assertEq(uscc.balanceOf(address(wuscc)), excessAmount, "wUSCC holds USCC");
    assertEq(uscc.balanceOf(address(fund)), 0, "fund has no USCC");
  }

  function test_Edge_ExcessFunds_RedeemUnlock() public {
    // Test that excess USDC received on redeem is transferred to user
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _mintWuscc(address(this), order.input);
    wuscc.approve(address(fund), order.input);
    fund.commit(order);

    // Superstate sends 10% more USDC than expected
    uint256 excessAmount = order.output + (order.output / 10);
    usdc.mint(address(fund), excessAmount);

    // State should be UNLOCKING
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    // Unlock should transfer the full excess amount
    fund.unlock(order);

    // User receives all the excess
    assertEq(usdc.balanceOf(address(this)), excessAmount, "user receives excess USDC");
  }

  function test_Edge_ExcessFunds_DepositRecovery() public {
    // Test that excess USDC returned during recovery is transferred to user
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    // Set to recovering state (owner can call this)
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    // Superstate returns 10% more USDC than was sent
    uint256 excessAmount = order.input + (order.input / 10);
    usdc.mint(address(fund), excessAmount);

    // State should be RECOVERING
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    // Recover should transfer the full excess amount
    fund.recover(order);

    // User receives all the excess
    assertEq(usdc.balanceOf(address(this)), excessAmount, "user receives excess USDC in recovery");
  }

  function test_Edge_ExcessFunds_RedeemRecovery() public {
    // Test that excess USCC returned during recovery is transferred to user
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _mintWuscc(address(this), order.input);
    wuscc.approve(address(fund), order.input);
    fund.commit(order);

    // Set to recovering state (owner can call this)
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));

    // Superstate returns 10% more USCC than was burned
    uint256 excessAmount = order.input + (order.input / 10);
    uscc.mint(address(fund), excessAmount);

    // State should be RECOVERING
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    // Recover should transfer the full excess amount as wUSCC
    fund.recover(order);

    // User receives all the excess as wUSCC
    assertEq(wuscc.balanceOf(address(this)), excessAmount, "user receives excess wUSCC in recovery");
  }

  function testFuzz_Create_Deposit(uint96 amount) public {
    amount = uint96(bound(amount, 1, type(uint96).max));
    Order memory order = _depositOrder(amount, amount);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            HELPERS                         */
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

  function _unlockDeposit(Order memory order) internal {
    uscc.mint(address(fund), order.output);
    fund.unlock(order);
  }

  /// @dev Helper to mint wUSCC to a recipient. Wraps USCC into wUSCC.
  function _mintWuscc(address to, uint256 amount) internal {
    uscc.mint(owner, amount);
    vm.prank(owner);
    uscc.approve(address(wuscc), amount);
    vm.prank(owner);
    wuscc.mint(to, amount);
  }
}
