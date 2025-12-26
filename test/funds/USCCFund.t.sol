// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {Test} from "forge-std/Test.sol";
import {USCCFund} from "src/funds/USCCFund.sol";
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
  error InvalidRoles(uint256 roles);
  error ChainlinkInvalidAnswer();
  error ChainlinkIncompleteRound();
  error ChainlinkStaleRound();
  error ChainlinkFatFinger();
  error InvalidOracle(address oracle);
  error DecimalsMismatch(uint256 decimalsA, uint256 decimalsB);
  error InvalidBps(uint256 bps);
  error InvalidInitialization();
  error Unauthorized();

  event OrderCreated(
    Id indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(Id indexed orderId, Mode mode, uint256 amount);
  event OrderRecovered(Id indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderUnlocked(Id indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderRecovering(Id indexed orderId);
  event OracleUpdated(address indexed newOracle, address indexed operator);
  event OrderResolved(Id indexed orderId, uint256 newInput, uint256 newOutput, address indexed operator);
  event maxPriceDeviationBpsUpdated(uint256 maxPriceDeviationBps);

  bytes32 private constant _MAIN_STORAGE_SLOT = 0x22af3a319200d6ffd5a884897090be53ffe5ca9dd773cf69926581248771a500;
  uint256 private constant DEFAULT_BPS = 100;
  uint256 private constant ONE_USDC = 1e6;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TEST STATE                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
    wuscc.initialize(owner, owner, "wUSCC", "Wrapped USCC", 6);

    fund = new USCCFund();
    fund.initialize(
      owner, address(this), recipient, address(usdc), address(uscc), address(wuscc), address(oracle), DEFAULT_BPS
    );

    allowlist.setAllowed(address(fund), "USCC", true);
    uint256 issuerRole = wuscc.ISSUER_ROLE();
    vm.prank(owner);
    wuscc.grantRoles(address(fund), issuerRole);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           INITIALIZATION                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_Success() public view {
    assertEq(fund.owner(), owner, "owner");
    assertEq(fund.asset(), address(usdc), "usdc");
    assertEq(fund.share(), address(wuscc), "wuscc");
    assertEq(fund.rolesOf(address(this)), fund.DEPOSITOR_ROLE(), "depositor role");
    assertEq(uint256(fund.state(_depositOrder(ONE_USDC, ONE_USDC))), uint256(State.EMPTY), "initial state");
  }

  function test_Initialize_RevertsInvalidContract() public {
    USCCFund local = new USCCFund();
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(0xBEEF)));
    local.initialize(
      owner, address(0xBEEF), recipient, address(usdc), address(uscc), address(wuscc), address(oracle), DEFAULT_BPS
    );

    local = new USCCFund();
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(1)));
    local.initialize(
      owner, address(this), recipient, address(1), address(uscc), address(wuscc), address(oracle), DEFAULT_BPS
    );

    local = new USCCFund();
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(2)));
    local.initialize(
      owner, address(this), recipient, address(usdc), address(2), address(wuscc), address(oracle), DEFAULT_BPS
    );

    local = new USCCFund();
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(3)));
    local.initialize(
      owner, address(this), recipient, address(usdc), address(uscc), address(3), address(oracle), DEFAULT_BPS
    );

    local = new USCCFund();
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(4)));
    local.initialize(
      owner, address(this), recipient, address(usdc), address(uscc), address(wuscc), address(4), DEFAULT_BPS
    );
  }

  function test_Initialize_RevertsInvalidRecipient() public {
    USCCFund local = new USCCFund();
    vm.expectRevert(AddressZero.selector);
    local.initialize(
      owner, address(this), address(0), address(usdc), address(uscc), address(wuscc), address(oracle), DEFAULT_BPS
    );
  }

  function test_Initialize_RevertsDecimalsMismatch() public {
    USCCFund local = new USCCFund();
    MockERC20 badUsdc = new MockERC20("Bad USDC", "BUSDC", 18);
    vm.expectRevert(abi.encodeWithSelector(DecimalsMismatch.selector, 18, 6));
    local.initialize(
      owner, address(this), recipient, address(badUsdc), address(uscc), address(wuscc), address(oracle), DEFAULT_BPS
    );

    local = new USCCFund();
    MockERC20 badUscc = new MockERC20("Bad USCC", "BUSCC", 18);
    vm.expectRevert(abi.encodeWithSelector(DecimalsMismatch.selector, 18, 6));
    local.initialize(
      owner, address(this), recipient, address(usdc), address(badUscc), address(wuscc), address(oracle), DEFAULT_BPS
    );
  }

  function test_Initialize_RevertsWrappedAssetDecimalsMismatch() public {
    USCCFund local = new USCCFund();
    MockERC20 badWuscc = new MockERC20("Bad WUSCC", "BWUSCC", 18);
    vm.expectRevert(abi.encodeWithSelector(DecimalsMismatch.selector, 18, 6));
    local.initialize(
      owner, address(this), recipient, address(usdc), address(uscc), address(badWuscc), address(oracle), DEFAULT_BPS
    );
  }

  function test_Initialize_RevertsInvalidOracleDecimals() public {
    USCCFund local = new USCCFund();
    MockChainlinkOracle badOracle = new MockChainlinkOracle(8);
    vm.expectRevert(abi.encodeWithSelector(InvalidOracle.selector, address(badOracle)));
    local.initialize(
      owner, address(this), recipient, address(usdc), address(uscc), address(wuscc), address(badOracle), DEFAULT_BPS
    );
  }

  function test_Initialize_RevertsInvalidBps() public {
    USCCFund local = new USCCFund();
    vm.expectRevert(abi.encodeWithSelector(InvalidBps.selector, 10_001));
    local.initialize(
      owner, address(this), recipient, address(usdc), address(uscc), address(wuscc), address(oracle), 10_001
    );
  }

  function test_Initialize_OnlyOnce() public {
    vm.expectRevert(InvalidInitialization.selector);
    fund.initialize(
      owner, address(this), recipient, address(usdc), address(uscc), address(wuscc), address(oracle), DEFAULT_BPS
    );
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
  /*                              COMMIT                        */
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

    vm.prank(owner);
    wuscc.mint(address(this), order.input);

    uint256 balanceBefore = wuscc.balanceOf(address(this));
    (State state,) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(wuscc.balanceOf(address(this)), balanceBefore - order.input, "burned");
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
  /*                              UNLOCK                        */
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
    vm.prank(owner);
    wuscc.mint(address(this), order.input);
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
  /*                              RECOVER                       */
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
    vm.prank(owner);
    wuscc.mint(address(this), order.input);
    fund.commit(order);

    vm.prank(owner);
    fund.recovering();
    uscc.mint(address(fund), order.input);

    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.input, "amount");
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
  /*                              ADMIN                         */
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

  function test_SetMaxPriceDeviationBps_Success() public {
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit maxPriceDeviationBpsUpdated(200);
    fund.setMaxPriceDeviationBps(200);
  }

  function test_SetMaxPriceDeviationBps_RevertsInvalidBps() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(InvalidBps.selector, 10_001));
    fund.setMaxPriceDeviationBps(10_001);
  }

  function test_SetMaxPriceDeviationBps_OnlyOperatorOrOwner() public {
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.setMaxPriceDeviationBps(200);
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                              VIEWS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Asset_ReturnsUsdc() public view {
    assertEq(fund.asset(), address(usdc), "asset");
  }

  function test_Share_ReturnsWuscc() public view {
    assertEq(fund.share(), address(wuscc), "share");
  }

  function test_TotalAssets_ValidPrice() public {
    uscc.mint(address(fund), 5 * ONE_USDC);
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

  function test_TotalAssets_FatFingerProtectionTriggered() public {
    oracle.setRoundData(2, int256(ONE_USDC * 2), block.timestamp, 2);
    oracle.setLatestRound(2);
    vm.expectRevert(ChainlinkFatFinger.selector);
    fund.totalAssets();
  }

  function test_TotalAssets_FatFingerProtectionPasses() public {
    oracle.setRoundData(2, int256(ONE_USDC + 50), block.timestamp, 2);
    oracle.setLatestRound(2);
    fund.totalAssets();
  }

  function test_TotalAssets_FirstRound() public {
    oracle.setLatestRound(1);
    fund.totalAssets();
  }

  function test_TotalAssets_PreviousRoundInvalid() public {
    oracle.setRoundData(2, int256(ONE_USDC), block.timestamp, 2);
    oracle.setRoundData(1, 0, block.timestamp, 1);
    oracle.setLatestRound(2);
    vm.expectRevert(ChainlinkInvalidAnswer.selector);
    fund.totalAssets();
  }

  function test_MaxDeposit_ReturnsMax() public view {
    assertEq(fund.maxDeposit(address(this)), type(uint256).max, "max deposit");
  }

  function test_MaxRedeem_ReturnsBalance() public {
    vm.prank(owner);
    wuscc.mint(address(this), ONE_USDC);
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
    vm.prank(owner);
    wuscc.mint(address(this), order.input);
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
  /*                              ROLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Roles_DepositorImmutable() public {
    uint256 depositorRole = fund.DEPOSITOR_ROLE();
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(InvalidRoles.selector, depositorRole));
    fund.grantRoles(outsider, depositorRole);
  }

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

  function test_Edge_ZeroOutput() public {
    Order memory order = _depositOrder(ONE_USDC, 0);
    fund.create(order);
    _commitDeposit(order);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");
  }

  function test_Edge_LargeAmounts() public {
    uint256 amount = type(uint96).max;
    Order memory order = _depositOrder(amount, amount);
    fund.create(order);
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    fund.commit(order);
  }

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
}
