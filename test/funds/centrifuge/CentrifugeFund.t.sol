// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentrifugeFund} from "src/funds/centrifuge/CentrifugeFund.sol";
import {CentrifugeFundFactory} from "src/funds/centrifuge/CentrifugeFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockCentrifugeVault} from "../../mock/funds/centrifuge/MockCentrifugeVault.sol";

contract CentrifugeFundTest is Test {
  using LibOrder for Order;

  error InvalidInitialization();
  error Unauthorized();

  event OrderCreated(
    bytes32 indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);
  event CancelRequestSubmitted(bytes32 indexed orderId);

  uint256 private constant ONE = 1e6;

  // WrappedAsset roles
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           TEST STATE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  CentrifugeFundFactory public factory;
  CentrifugeFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public assetToken;
  MockERC20 public shareToken;
  MockCentrifugeVault public vault;

  address public owner;
  address public operator;
  address public outsider;

  function setUp() public {
    owner = makeAddr("owner");
    operator = makeAddr("operator");
    outsider = makeAddr("outsider");

    assetToken = new MockERC20("USD Coin", "USDC", 6);
    shareToken = new MockERC20("Centrifuge Share", "cfgSHR", 6);
    vault = new MockCentrifugeVault(address(assetToken), address(shareToken));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(shareToken), "wShare", "Wrapped Share");

    factory = new CentrifugeFundFactory(owner);
    address fundAddress = factory.createFund(owner, address(this), address(vault), address(wrappedShare));
    fund = CentrifugeFund(fundAddress);

    vault.setPermissioned(address(fund), true);

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
    assertEq(fund.asset(), address(assetToken), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.vault(), address(vault), "vault");
    assertEq(fund.rolesOf(address(this)), fund.DEPOSITOR_ROLE(), "depositor role");
    assertEq(uint256(fund.state(_depositOrder(ONE, ONE))), uint256(State.EMPTY), "initial state");
  }

  function test_Initialize_RevertsInvalidOwner() public {
    CentrifugeFund impl = new CentrifugeFund();
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.CENTRIFUGE_FUND_BEACON());
    vm.expectRevert(CommonErrors.AddressZero.selector);
    CentrifugeFund(fundProxy).initialize(address(0), address(this), address(vault), address(wrappedShare));
  }

  function test_Initialize_RevertsInvalidDepositor() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.CENTRIFUGE_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    CentrifugeFund(fundProxy).initialize(owner, address(0xBEEF), address(vault), address(wrappedShare));
  }

  function test_Initialize_RevertsInvalidVault() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.CENTRIFUGE_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    CentrifugeFund(fundProxy).initialize(owner, address(this), address(0xBEEF), address(wrappedShare));
  }

  function test_Initialize_RevertsInvalidWrappedShare() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.CENTRIFUGE_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    CentrifugeFund(fundProxy).initialize(owner, address(this), address(vault), address(0xBEEF));
  }

  function test_Initialize_RevertsWrappedShareMismatch() public {
    // Deploy wrappedShare wrapping a different token
    MockERC20 otherToken = new MockERC20("Other", "OTH", 6);
    WrappedAsset impl2 = new WrappedAsset();
    address proxy2 = LibClone.deployERC1967(address(impl2));
    WrappedAsset badWrappedShare = WrappedAsset(proxy2);
    vm.prank(owner);
    badWrappedShare.initialize(owner, owner, address(otherToken), "bad", "Bad");

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.CENTRIFUGE_FUND_BEACON());
    vm.expectRevert(LibFundsErrors.InvalidReceiver.selector);
    CentrifugeFund(fundProxy).initialize(owner, address(this), address(vault), address(badWrappedShare));
  }

  function test_Initialize_OnlyOnce() public {
    vm.expectRevert(InvalidInitialization.selector);
    fund.initialize(owner, address(this), address(vault), address(wrappedShare));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             CREATE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Create_DepositSuccess() public {
    Order memory order = _depositOrder(ONE, ONE);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    State state = fund.create(order);

    assertEq(uint256(state), uint256(State.ACCEPTED), "state");
  }

  function test_Create_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE, ONE);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    fund.create(order);
  }

  function test_Create_RevertsAmountZero() public {
    Order memory order = _depositOrder(0, ONE);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE, ONE);
    order.owner = outsider;
    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidReceiver() public {
    Order memory order = _depositOrder(ONE, ONE);
    order.receiver = outsider;
    vm.expectRevert(LibFundsErrors.InvalidReceiver.selector);
    fund.create(order);
  }

  function test_Create_RevertsPendingOrder() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);

    // Already ACCEPTED
    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(order);

    // Commit to PROCESSING
    _commitDeposit(order);

    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(order);
  }

  function test_Create_RevertsNotPermissioned() public {
    vault.setPermissioned(address(fund), false);
    Order memory order = _depositOrder(ONE, ONE);
    vm.expectRevert(LibFundsErrors.NotAllowedToOperateWithVault.selector);
    fund.create(order);
  }

  function test_Create_AfterEndedOrder() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    vault.fulfillDeposit(address(fund), order.output);
    fund.unlock(order);

    Order memory nextOrder = _depositOrder(ONE * 2, ONE * 2);
    State state = fund.create(nextOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  function test_Create_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE, ONE);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.create(order);
  }

  function test_Create_SucceedsOutputExceedsExpected() public {
    // convertToShares(ONE) = ONE (1:1 rate), output > ONE is allowed
    Order memory order = _depositOrder(ONE, ONE + 1);
    State s = fund.create(order);
    assertEq(uint256(s), uint256(State.ACCEPTED), "accepted");
  }

  function test_Create_RevertsOutputDeviationTooLarge() public {
    // MAX_OUTPUT_DEVIATION = 100 (1%). For input=10000, expected=10000, min allowed = 9900
    uint256 input = 10000;
    uint256 expectedOutput = input; // 1:1 rate
    uint256 tooLowOutput = expectedOutput - (expectedOutput * 101 / 10000) - 1; // just over 1%

    Order memory order = _depositOrder(input, tooLowOutput);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  function test_Create_OutputAtMaxDeviation() public {
    // Exactly 1% deviation should succeed
    uint256 input = 10000;
    uint256 expectedOutput = input; // 1:1 rate
    uint256 maxDeviationOutput = expectedOutput - (expectedOutput * 100 / 10000); // exactly 1% below

    Order memory order = _depositOrder(input, maxDeviationOutput);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted at max deviation");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             CANCEL                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Cancel_Success() public {
    Order memory order = _depositOrder(ONE, ONE);
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
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.cancel(wrongOrder);
  }

  function test_Cancel_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.cancel(order);
  }

  function test_Cancel_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.cancel(order);
  }

  function test_Cancel_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE, ONE);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.cancel(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             COMMIT                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Commit_DepositSuccess() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);

    assetToken.mint(address(this), order.input);
    assetToken.approve(address(fund), order.input);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderCommitted(orderId, order.mode, order.input);
    (State state, uint256 amount) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(amount, order.input, "amount");
    // Asset should be in vault (pulled via requestDeposit)
    assertEq(assetToken.balanceOf(address(vault)), order.input, "vault has asset");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");
  }

  function test_Commit_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE, ONE);
    fund.create(order);

    _mintWrappedShare(address(this), order.input);
    wrappedShare.approve(address(fund), order.input);

    (State state, uint256 amount) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(amount, order.input, "amount");
    // Share tokens should be in vault (pulled via requestRedeem)
    assertEq(shareToken.balanceOf(address(vault)), order.input, "vault has shares");
    assertEq(wrappedShare.balanceOf(address(this)), 0, "burned");
  }

  function test_Commit_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    assetToken.mint(address(this), order.input);
    assetToken.approve(address(fund), order.input);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.commit(wrongOrder);
  }

  function test_Commit_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE, ONE);
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
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE, ONE);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.commit(order);
  }

  function test_Commit_DepositClearsApproval() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    assertEq(assetToken.allowance(address(fund), address(vault)), 0, "approval cleared");
  }

  function test_Commit_RedeemClearsApproval() public {
    Order memory order = _redeemOrder(ONE, ONE);
    fund.create(order);
    _mintWrappedShare(address(this), order.input);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    assertEq(shareToken.allowance(address(fund), address(vault)), 0, "approval cleared");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             UNLOCK                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Unlock_DepositSuccess() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    vault.fulfillDeposit(address(fund), order.output);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, order.output, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.output, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), order.output, "wShare minted");
  }

  function test_Unlock_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE, ONE);
    fund.create(order);
    _mintWrappedShare(address(this), order.input);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);
    vault.fulfillRedeem(address(fund), order.output);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, order.output, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.output, "amount");
    assertEq(assetToken.balanceOf(address(this)), order.output, "asset received");
  }

  function test_Unlock_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    vault.fulfillDeposit(address(fund), order.output);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.unlock(wrongOrder);
  }

  function test_Unlock_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    // ACCEPTED, not UNLOCKING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.unlock(order);

    _commitDeposit(order);
    // PROCESSING, not UNLOCKING (no fulfillment yet)
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);
  }

  function test_Unlock_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    vault.fulfillDeposit(address(fund), order.output);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.unlock(order);
  }

  function test_Unlock_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE, ONE);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.unlock(order);
  }

  function test_Unlock_PartialDeposit() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    // Partial fill: only half the shares are ready, rest still pending
    uint256 halfShares = order.output / 2;
    vault.partialFulfillDeposit(address(fund), halfShares, order.input / 2);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "back to processing");
    assertEq(amount, halfShares, "partial amount");
    assertEq(wrappedShare.balanceOf(address(this)), halfShares, "partial wShare minted");
  }

  function test_Unlock_PartialRedeem() public {
    Order memory order = _redeemOrder(ONE, ONE);
    fund.create(order);
    _mintWrappedShare(address(this), order.input);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    // Partial fill: only half the assets are ready, rest still pending
    uint256 halfAssets = order.output / 2;
    vault.partialFulfillRedeem(address(fund), halfAssets, order.input / 2);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "back to processing");
    assertEq(amount, halfAssets, "partial amount");
    assertEq(assetToken.balanceOf(address(this)), halfAssets, "partial asset received");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             RECOVER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Recover_DepositSuccess() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    vault.fulfillCancelDeposit(address(fund), order.input);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderRecovered(orderId, order.mode, order.input, address(this));
    (State state, uint256 amount) = fund.recover(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.input, "amount");
    assertEq(assetToken.balanceOf(address(this)), order.input, "asset recovered");
  }

  function test_Recover_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE, ONE);
    fund.create(order);
    _mintWrappedShare(address(this), order.input);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    vault.fulfillCancelRedeem(address(fund), order.input);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderRecovered(orderId, order.mode, order.input, address(this));
    (State state, uint256 amount) = fund.recover(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.input, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), order.input, "wShare recovered");
  }

  function test_Recover_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.cancelRequest(order);
    vault.fulfillCancelDeposit(address(fund), order.input);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.recover(wrongOrder);
  }

  function test_Recover_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    // ACCEPTED, not RECOVERING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.recover(order);
  }

  function test_Recover_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    vm.prank(owner);
    fund.cancelRequest(order);
    vault.fulfillCancelDeposit(address(fund), order.input);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.recover(order);
  }

  function test_Recover_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE, ONE);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.recover(order);
  }

  function test_Recover_PartialDeposit() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    // Partial cancel fulfillment: some assets returned, cancel still pending
    uint256 halfAssets = order.input / 2;
    vault.partialFulfillCancelDeposit(address(fund), halfAssets, halfAssets);
    // Keep pendingCancelDeposit = true to indicate more to come
    // (partialFulfillCancelDeposit doesn't clear it, but we also need the flag)
    // The _stateHasPendingRecover checks both pending flag AND claimable

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.RECOVERING), "still recovering");
    assertEq(amount, halfAssets, "partial amount");
  }

  function test_Recover_PartialRedeem() public {
    Order memory order = _redeemOrder(ONE, ONE);
    fund.create(order);
    _mintWrappedShare(address(this), order.input);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    // Partial cancel fulfillment: some shares returned, more claimable remains
    uint256 halfShares = order.input / 2;
    vault.partialFulfillCancelRedeem(address(fund), halfShares, halfShares);

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    (State state, uint256 amount) = fund.recover(order);
    // After claiming, there's still pendingCancelRedeem = true (flag from cancelRequest)
    assertEq(uint256(state), uint256(State.RECOVERING), "still recovering");
    assertEq(amount, halfShares, "partial amount");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CANCEL REQUEST                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_CancelRequest_DepositSuccess() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit CancelRequestSubmitted(orderId);

    vm.prank(owner);
    fund.cancelRequest(order);

    // Internal state is RECOVERING, but state() returns PROCESSING since cancel not yet fulfilled
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing (hidden recovering)");

    // Verify vault received cancel request
    assertTrue(vault._pendingCancelDeposit(address(fund)), "pending cancel on vault");
  }

  function test_CancelRequest_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE, ONE);
    fund.create(order);
    _mintWrappedShare(address(this), order.input);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing (hidden recovering)");
    assertTrue(vault._pendingCancelRedeem(address(fund)), "pending cancel on vault");
  }

  function test_CancelRequest_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);

    // ACCEPTED, not PROCESSING
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.cancelRequest(order);
  }

  function test_CancelRequest_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.cancelRequest(wrongOrder);
  }

  function test_CancelRequest_RevertsUnauthorizedOutsider() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.cancelRequest(order);
  }

  function test_CancelRequest_RevertsUnauthorizedDepositor() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    // address(this) has DEPOSITOR_ROLE but not OPERATOR_ROLE
    vm.expectRevert(Unauthorized.selector);
    fund.cancelRequest(order);
  }

  function test_CancelRequest_SucceedsWithOperator() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    uint256 operatorRole = fund.OPERATOR_ROLE();
    vm.prank(owner);
    fund.grantRoles(operator, operatorRole);
    vm.prank(operator);
    fund.cancelRequest(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                             VIEWS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Vault_ReturnsVault() public view {
    assertEq(fund.vault(), address(vault), "vault");
  }

  function test_Asset_ReturnsAsset() public view {
    assertEq(fund.asset(), address(assetToken), "asset");
  }

  function test_Share_ReturnsWrappedShare() public view {
    assertEq(fund.share(), address(wrappedShare), "share");
  }

  function test_TotalAssets_UsesVaultConversion() public {
    // Mint some wrapped shares
    _mintWrappedShare(address(this), 5 * ONE);
    uint256 totalAssets = fund.totalAssets();
    // 1:1 rate so totalAssets = totalSupply
    assertEq(totalAssets, 5 * ONE, "totalAssets");
  }

  function test_MaxDeposit_ReturnsMinOfBalanceAndVaultMax() public {
    assetToken.mint(address(this), 100 * ONE);

    // Vault max is unlimited, so maxDeposit = balance
    assertEq(fund.maxDeposit(address(this)), 100 * ONE, "balance limited");

    // Set vault max to less than balance
    vault.setMaxDeposit(50 * ONE);
    assertEq(fund.maxDeposit(address(this)), 50 * ONE, "vault limited");
  }

  function test_MaxRedeem_ReturnsMinOfBalanceAndVaultMax() public {
    _mintWrappedShare(address(this), 100 * ONE);

    // Vault max is unlimited, so maxRedeem = balance
    assertEq(fund.maxRedeem(address(this)), 100 * ONE, "balance limited");

    // Set vault max to less than balance
    vault.setMaxRedeem(50 * ONE);
    assertEq(fund.maxRedeem(address(this)), 50 * ONE, "vault limited");
  }

  function test_State_AllStates() public {
    Order memory order = _depositOrder(ONE, ONE);
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "empty");

    fund.create(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "accepted");

    _commitDeposit(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    vault.fulfillDeposit(address(fund), order.output);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
  }

  function test_State_DynamicTransitions() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    vault.fulfillDeposit(address(fund), order.output);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");
  }

  function test_State_RecoveringHidesAsProcessing() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    // Cancel not yet fulfilled — state() returns PROCESSING
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "hidden recovering");
  }

  function test_State_RecoveringShowsWhenClaimable() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    // Fulfill cancel — now state() returns RECOVERING
    vault.fulfillCancelDeposit(address(fund), order.input);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering visible");
  }

  function test_State_NonCurrentOrderReturnsEmpty() public {
    Order memory order1 = _depositOrder(ONE, ONE);
    fund.create(order1);
    _commitDeposit(order1);

    Order memory order2 = _depositOrder(2 * ONE, 2 * ONE);
    assertEq(uint256(fund.state(order2)), uint256(State.EMPTY), "non-current order is EMPTY");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        STATE MACHINE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_StateMachine_FullRedeemLifecycle() public {
    Order memory order = _redeemOrder(ONE, ONE);
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "empty");

    fund.create(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "accepted");

    _mintWrappedShare(address(this), order.input);
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    vault.fulfillRedeem(address(fund), order.output);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
    assertEq(assetToken.balanceOf(address(this)), order.output, "asset received");
  }

  function test_StateMachine_DepositCancelRequest() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(owner);
    fund.cancelRequest(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "hidden recovering");

    vault.fulfillCancelDeposit(address(fund), order.input);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    fund.recover(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
    assertEq(assetToken.balanceOf(address(this)), order.input, "asset recovered");
  }

  function test_StateMachine_MultipleOrders() public {
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    vault.fulfillDeposit(address(fund), order.output);
    fund.unlock(order);

    Order memory nextOrder = _depositOrder(ONE * 2, ONE * 2);
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
    Order memory orderA = _depositOrder(ONE, ONE);
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
    Order memory order = _depositOrder(ONE, ONE);
    fund.create(order);
    _commitDeposit(order);
    vault.fulfillDeposit(address(fund), order.output);
    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");

    // Create new order with different salt to guarantee different orderId
    Order memory nextOrder = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: ONE * 2,
      output: ONE * 2,
      salt: keccak256("second-order")
    });
    fund.create(nextOrder);

    // Old order was archived in endedOrders mapping by create().
    // state() checks endedOrders BEFORE currentOrderId, so archived orders return ENDED.
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "old order ENDED (archived)");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            HELPERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _depositOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({mode: Mode.DEPOSIT, owner: address(this), receiver: address(this), input: input, output: output, salt: keccak256("deposit")});
  }

  function _redeemOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({mode: Mode.REDEEM, owner: address(this), receiver: address(this), input: input, output: output, salt: keccak256("redeem")});
  }

  function _commitDeposit(Order memory order) internal {
    assetToken.mint(address(this), order.input);
    assetToken.approve(address(fund), order.input);
    fund.commit(order);
  }

  function _mintWrappedShare(address to, uint256 amount) internal {
    shareToken.mint(owner, amount);
    vm.prank(owner);
    shareToken.approve(address(wrappedShare), amount);
    vm.prank(owner);
    wrappedShare.mint(to, amount);
  }
}
