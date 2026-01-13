// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {USCCFund} from "src/funds/USCCFund.sol";
import {USCCFundFactory} from "src/funds/USCCFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, Id} from "src/libs/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAllowlist} from "./mocks/MockAllowlist.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockSuperstateToken} from "./mocks/MockSuperstateToken.sol";

contract USCCFundTest is Test {
  error AddressZero();
  error AmountZero();
  error InvalidContract(address addr);
  error InvalidOwner();
  error InvalidReceiver();
  error PendingOrder();
  error InvalidState(State actual);
  error InvalidOrder(Id orderId);
  error NotAllowedSuperstate();
  error ChainlinkInvalidAnswer();
  error ChainlinkIncompleteRound();
  error ChainlinkStaleRound();
  error InvalidOracle(address oracle);
  error DecimalsMismatch(uint256 decimalsA, uint256 decimalsB);
  error InvalidInitialization();
  error Unauthorized();

  event OrderCreated(
    Id indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(Id indexed orderId, Mode mode, uint256 amount);
  event OrderRecovered(Id indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderUnlocked(Id indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderCanceled(Id indexed orderId, Mode mode, address indexed owner);
  event OrderRecovering(Id indexed orderId);
  event OracleUpdated(address indexed newOracle, address indexed operator);
  event OrderResolved(Id indexed orderId, uint256 newInput, uint256 newOutput, address indexed operator);

  bytes32 private constant _MAIN_STORAGE_SLOT = 0x22af3a319200d6ffd5a884897090be53ffe5ca9dd773cf69926581248771a500;
  uint256 private constant ONE_USDC = 1e6;

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
    wuscc.initialize(owner, owner, address(uscc), "wUSCC", "Wrapped USCC", 6);

    factory = new USCCFundFactory(owner, address(usdc), address(uscc), address(wuscc));
    address fundAddress = factory.createFund(owner, address(this), recipient, address(oracle));
    fund = USCCFund(fundAddress);

    allowlist.setAllowed(address(fund), "USCC", true);
    uint256 issuerRole = wuscc.ISSUER_ROLE();
    vm.prank(owner);
    wuscc.grantRoles(address(fund), issuerRole);

    uint256 senderRole = wuscc.SENDER_ROLE();
    vm.prank(owner);
    wuscc.grantRoles(address(this), senderRole);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_Success() public view {
    assertEq(fund.owner(), owner, "owner");
    assertEq(fund.asset(), address(usdc), "usdc");
    assertEq(fund.share(), address(wuscc), "wuscc");
    assertEq(fund.rolesOf(address(this)), fund.DEPOSITOR_ROLE(), "depositor role");
    assertEq(uint256(fund.state(_depositOrder(ONE_USDC, ONE_USDC))), uint256(State.EMPTY), "initial state");
  }

  function test_Initialize_RevertsInvalidContract() public {
    USCCFund local = new USCCFund(address(usdc), address(uscc), address(wuscc));
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(0xBEEF)));
    local.initialize(owner, address(0xBEEF), recipient, address(oracle));

    local = new USCCFund(address(usdc), address(uscc), address(wuscc));
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(1)));
    local.initialize(owner, address(this), recipient, address(1));
  }

  function test_Initialize_RevertsInvalidOwner() public {
    USCCFund local = new USCCFund(address(usdc), address(uscc), address(wuscc));
    vm.expectRevert(AddressZero.selector);
    local.initialize(address(0), address(this), recipient, address(oracle));
  }

  function test_Initialize_RevertsInvalidRecipient() public {
    USCCFund local = new USCCFund(address(usdc), address(uscc), address(wuscc));
    vm.expectRevert(AddressZero.selector);
    local.initialize(owner, address(this), address(0), address(oracle));
  }

  function test_Constructor_RevertsUsdcDecimalsMismatch() public {
    MockERC20 badUsdc = new MockERC20("Bad USDC", "BUSDC", 18);
    vm.expectRevert(abi.encodeWithSelector(DecimalsMismatch.selector, 18, 6));
    new USCCFund(address(badUsdc), address(uscc), address(wuscc));
  }

  function test_Constructor_RevertsUsccDecimalsMismatch() public {
    MockERC20 badUscc = new MockERC20("Bad USCC", "BUSCC", 18);
    vm.expectRevert(abi.encodeWithSelector(DecimalsMismatch.selector, 18, 6));
    new USCCFund(address(usdc), address(badUscc), address(wuscc));
  }

  function test_Constructor_RevertsWrappedAssetDecimalsMismatch() public {
    MockERC20 badWuscc = new MockERC20("Bad WUSCC", "BWUSCC", 18);
    vm.expectRevert(abi.encodeWithSelector(DecimalsMismatch.selector, 18, 6));
    new USCCFund(address(usdc), address(uscc), address(badWuscc));
  }

  function test_Initialize_RevertsInvalidOracleDecimals() public {
    USCCFund local = new USCCFund(address(usdc), address(uscc), address(wuscc));
    MockChainlinkOracle badOracle = new MockChainlinkOracle(8);
    vm.expectRevert(abi.encodeWithSelector(InvalidOracle.selector, address(badOracle)));
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
    Id orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    State state = fund.create(order);

    assertEq(uint256(state), uint256(State.ACCEPTED), "state");
  }

  function test_Create_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    Id orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    fund.create(order);
  }

  function test_Create_RevertsAmountZero() public {
    Order memory order = _depositOrder(0, ONE_USDC);
    vm.expectRevert(AmountZero.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.owner = outsider;
    vm.expectRevert(InvalidOwner.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidReceiver() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    order.receiver = outsider;
    vm.expectRevert(InvalidReceiver.selector);
    fund.create(order);
  }

  function test_Create_RevertsPendingOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    vm.expectRevert(PendingOrder.selector);
    fund.create(order);

    _commitDeposit(order);

    vm.expectRevert(PendingOrder.selector);
    fund.create(order);
  }

  function test_Create_RevertsNotAllowedSuperstate() public {
    allowlist.setAllowed(address(fund), "USCC", false);
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    vm.expectRevert(NotAllowedSuperstate.selector);
    fund.create(order);
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
    Id orderId = order.toId(address(fund));
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
    vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.cancel(wrongOrder);
  }

  function test_Cancel_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.expectRevert(abi.encodeWithSelector(InvalidState.selector, State.PROCESSING));
    fund.cancel(order);
  }

  function test_Cancel_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
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

    Id orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderCommitted(orderId, order.mode, order.input);
    (State state, uint256 amount) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(amount, order.input, "amount");
    assertEq(usdc.balanceOf(recipient), order.input, "recipient");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");
    assertEq(_cachedBalance(), 0, "cached balance");
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
    vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.commit(wrongOrder);
  }

  function test_Commit_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, order.toId(address(fund))));
    fund.commit(order);

    fund.create(order);
    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);
    fund.commit(order);

    vm.expectRevert(abi.encodeWithSelector(InvalidState.selector, State.PROCESSING));
    fund.commit(order);
  }

  function test_Commit_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.commit(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UNLOCK                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Unlock_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    uscc.mint(address(fund), order.output);

    Id orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, order.output, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.output, "amount");
    assertEq(wuscc.balanceOf(address(this)), order.output, "minted");
  }

  function test_Unlock_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _mintWuscc(address(this), order.input);
    wuscc.approve(address(fund), order.input);
    fund.commit(order);
    usdc.mint(address(fund), order.output);

    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.output, "amount");
    assertEq(usdc.balanceOf(address(this)), order.output, "received");
  }

  function test_Unlock_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    uscc.mint(address(fund), order.output);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.unlock(wrongOrder);
  }

  function test_Unlock_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    vm.expectRevert(abi.encodeWithSelector(InvalidState.selector, State.ACCEPTED));
    fund.unlock(order);

    _commitDeposit(order);
    vm.expectRevert(abi.encodeWithSelector(InvalidState.selector, State.PROCESSING));
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
    fund.recovering();
    usdc.mint(address(fund), order.input);

    Id orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderRecovered(orderId, order.mode, order.input, address(this));
    (State state, uint256 amount) = fund.recover(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.input, "amount");
    assertEq(usdc.balanceOf(address(this)), order.input, "received");
  }

  function test_Recover_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _mintWuscc(address(this), order.input);
    wuscc.approve(address(fund), order.input);
    fund.commit(order);

    vm.prank(owner);
    fund.recovering();
    // Superstate returns USCC to fund
    uscc.mint(address(fund), order.input);

    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.input, "amount");
    // User receives wUSCC back (their original input is re-wrapped)
    assertEq(wuscc.balanceOf(address(this)), order.input, "minted");
  }

  function test_Recover_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering();
    usdc.mint(address(fund), order.input);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.recover(wrongOrder);
  }

  function test_Recover_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    vm.expectRevert(abi.encodeWithSelector(InvalidState.selector, State.ACCEPTED));
    fund.recover(order);
  }

  function test_Recover_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering();
    usdc.mint(address(fund), order.input);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.recover(order);
  }

  function test_Recover_NoFundsReturned() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering();

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
    fund.recovering();
  }

  function test_Recovering_RevertsInvalidState() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(InvalidState.selector, State.EMPTY));
    fund.recovering();
  }

  function test_Recovering_OnlyOperatorOrOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.recovering();
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
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(1)));
    fund.setOracle(address(1));
  }

  function test_SetOracle_RevertsInvalidDecimals() public {
    MockChainlinkOracle newOracle = new MockChainlinkOracle(8);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(InvalidOracle.selector, address(newOracle)));
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

    Order memory resolved = Order({
      owner: order.owner,
      receiver: order.receiver,
      input: ONE_USDC * 2,
      output: ONE_USDC * 3,
      mode: order.mode,
      salt: order.salt
    });
    Id resolvedId = resolved.toId(address(fund));

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderResolved(resolvedId, resolved.input, resolved.output, owner);
    fund.resolve(order, ONE_USDC * 2, ONE_USDC * 3);
  }

  function test_Resolve_InRecoveringState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering();

    vm.prank(owner);
    fund.resolve(order, ONE_USDC * 2, ONE_USDC * 2);
  }

  function test_Resolve_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(InvalidState.selector, State.ACCEPTED));
    fund.resolve(order, ONE_USDC, ONE_USDC);
  }

  function test_Resolve_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.resolve(wrongOrder, ONE_USDC, ONE_USDC);
  }

  function test_Resolve_OnlyOperatorOrOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.resolve(order, ONE_USDC, ONE_USDC);
  }

  function test_Resolve_OrderIdChange() public {
    // Demonstrates that resolve() changes the order ID, requiring use of resolved order for unlock
    Order memory originalOrder = _depositOrder(ONE_USDC, ONE_USDC);
    Id originalId = originalOrder.toId(address(fund));
    fund.create(originalOrder);
    _commitDeposit(originalOrder);

    // Operator resolves with different amounts (e.g., Superstate sent less than expected)
    uint256 newInput = ONE_USDC;
    uint256 newOutput = (ONE_USDC * 95) / 100; // Only 95% received

    vm.prank(owner);
    fund.resolve(originalOrder, newInput, newOutput);

    // Create resolved order with updated amounts
    Order memory resolvedOrder = Order({
      owner: originalOrder.owner,
      receiver: originalOrder.receiver,
      input: newInput,
      output: newOutput,
      mode: originalOrder.mode,
      salt: originalOrder.salt
    });
    Id resolvedId = resolvedOrder.toId(address(fund));

    // Verify the order ID changed
    assertFalse(originalId.eq(resolvedId), "order ID should change after resolve");

    // Original order is now invalid - state() returns EMPTY
    assertEq(uint256(fund.state(originalOrder)), uint256(State.EMPTY), "original order is invalid");

    // Resolved order is valid - state() returns current state
    assertEq(uint256(fund.state(resolvedOrder)), uint256(State.PROCESSING), "resolved order is valid");

    // Mint the resolved output amount to trigger UNLOCKING
    uscc.mint(address(fund), newOutput);
    assertEq(uint256(fund.state(resolvedOrder)), uint256(State.UNLOCKING), "resolved order unlocking");

    // Unlock must use the resolved order, not the original
    fund.unlock(resolvedOrder);

    // User receives the resolved output amount
    assertEq(wuscc.balanceOf(address(this)), newOutput, "user receives resolved output");
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
    vm.expectRevert(ChainlinkInvalidAnswer.selector);
    fund.totalAssets();
  }

  function test_TotalAssets_ChainlinkIncompleteRound() public {
    oracle.setRoundData(2, int256(ONE_USDC), 0, 2);
    oracle.setLatestRound(2);
    vm.expectRevert(ChainlinkIncompleteRound.selector);
    fund.totalAssets();
  }

  function test_TotalAssets_ChainlinkStaleRound() public {
    oracle.setRoundData(2, int256(ONE_USDC), block.timestamp, 1);
    oracle.setLatestRound(2);
    vm.expectRevert(ChainlinkStaleRound.selector);
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

  function test_MaxDeposit_ReturnsMax() public view {
    assertEq(fund.maxDeposit(address(this)), type(uint256).max, "max deposit");
  }

  function test_MaxRedeem_ReturnsBalance() public {
    _mintWuscc(address(this), ONE_USDC);
    assertEq(fund.maxRedeem(address(this)), ONE_USDC, "max redeem");
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

  function test_State_ArchivedEndedOrderRemainsEndedAfterNewOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    _unlockDeposit(order);

    Order memory nextOrder = _depositOrder(ONE_USDC * 2, ONE_USDC * 2);
    fund.create(nextOrder);

    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "archived order is ENDED");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  function test_State_ArchivedEndedOrderRemainsEndedAfterNewOrder_RecoveryFlow() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.recovering();
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

  function test_StateMachine_FullDepositFlow() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    uscc.mint(address(fund), order.output);
    fund.unlock(order);
    assertEq(wuscc.balanceOf(address(this)), order.output, "wuscc balance");
  }

  function test_StateMachine_FullRedeemFlow() public {
    Order memory order = _redeemOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _mintWuscc(address(this), order.input);
    wuscc.approve(address(fund), order.input);
    fund.commit(order);
    usdc.mint(address(fund), order.output);
    fund.unlock(order);
    assertEq(usdc.balanceOf(address(this)), order.output, "usdc balance");
  }

  function test_StateMachine_RecoveryFlow() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.recovering();
    usdc.mint(address(fund), order.input);
    fund.recover(order);
    assertEq(usdc.balanceOf(address(this)), order.input, "recovered");
  }

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
  /*                         EDGE CASES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Edge_CachedBalanceAccuracy() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_USDC);
    fund.create(order);
    _commitDeposit(order);
    assertEq(_cachedBalance(), 0, "cached");
  }

  function test_Edge_OrderIdCollision() public view {
    Order memory orderA = _depositOrder(ONE_USDC, ONE_USDC);
    Order memory orderB = Order({
      owner: orderA.owner,
      receiver: orderA.receiver,
      input: orderA.input,
      output: orderA.output,
      mode: orderA.mode,
      salt: keccak256("different")
    });
    assertFalse(orderA.toId(address(fund)).eq(orderB.toId(address(fund))), "different ids");
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
    fund.recovering();

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
    fund.recovering();

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
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      mode: Mode.DEPOSIT,
      salt: keccak256("deposit")
    });
  }

  function _redeemOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      mode: Mode.REDEEM,
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

  function _cachedBalance() internal view returns (uint256) {
    return uint256(vm.load(address(fund), bytes32(uint256(_MAIN_STORAGE_SLOT) + 6)));
  }

  /// @dev Helper to mint wUSCC to a recipient. Wraps USCC into wUSCC.
  function _mintWuscc(address to, uint256 amount) internal {
    uscc.mint(owner, amount);
    vm.prank(owner);
    uscc.approve(address(wuscc), amount);
    vm.prank(owner);
    wuscc.mint(owner, to, amount);
  }
}
