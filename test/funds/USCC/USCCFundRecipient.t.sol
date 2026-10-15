// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {USCCFund} from "src/funds/USCC/USCCFund.sol";
import {USCCFundFactory} from "src/funds/USCC/USCCFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockAllowlist} from "test/mock/funds/MockAllowlist.sol";
import {MockChainlinkOracle} from "test/mock/funds/MockChainlinkOracle.sol";
import {MockSuperstateToken} from "test/mock/funds/MockSuperstateToken.sol";

/// @title USCCFundRecipientTest
/// @notice USCCFund recipient: set and announced at initialization, readable through recipient(),
///         and changed by setRecipient across an order's lifecycle. The USDC of a deposit goes to
///         the recipient current at commit, and later changes leave unlock and recover untouched.
contract USCCFundRecipientTest is Test {
  using LibOrder for Order;

  error Unauthorized();

  event RecipientUpdated(address indexed newRecipient);
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  uint256 private constant AMOUNT = 1_000e6;
  uint256 private constant OPERATOR_ROLE = 1 << 0;
  uint256 private constant WUSCC_ISSUER_ROLE = 1 << 0;
  uint256 private constant WUSCC_SENDER_ROLE = 1 << 1;
  // ERC-7201: keccak256(abi.encode(uint256(keccak256("uscc.fund")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant MAIN_STORAGE_SLOT = 0x22af3a319200d6ffd5a884897090be53ffe5ca9dd773cf69926581248771a500;

  USCCFund public fund;
  USCCFundFactory public factory;
  WrappedAsset public wuscc;
  MockERC20 public usdc;
  MockSuperstateToken public uscc;
  MockAllowlist public allowlist;
  MockChainlinkOracle public oracle;

  address public owner;
  address public operator;
  address public recipient;
  address public newRecipient;

  function setUp() public {
    owner = makeAddr("owner");
    operator = makeAddr("operator");
    recipient = makeAddr("recipient");
    newRecipient = makeAddr("newRecipient");

    allowlist = new MockAllowlist();
    usdc = new MockERC20("USD Coin", "USDC", 6);
    uscc = new MockSuperstateToken("USCC", "USCC", address(allowlist), address(usdc));
    oracle = new MockChainlinkOracle(6);
    oracle.setRoundData(1, int256(1e6), block.timestamp, 1);
    oracle.setLatestRound(1);

    wuscc = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    wuscc.initialize(owner, owner, address(uscc), "wUSCC", "Wrapped USCC");

    factory = new USCCFundFactory(owner, address(usdc), address(uscc), address(wuscc));
    fund = USCCFund(factory.createFund(owner, address(this), recipient, address(oracle)));

    allowlist.setAllowed(address(fund), "USCC", true);
    allowlist.setAllowed(address(wuscc), "USCC", true);
    allowlist.setAllowed(address(this), "USCC", true);
    allowlist.setAllowed(owner, "USCC", true);
    vm.startPrank(owner);
    wuscc.grantRoles(address(fund), WUSCC_ISSUER_ROLE);
    wuscc.grantRoles(address(this), WUSCC_SENDER_ROLE);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.stopPrank();
  }

  function test_initialize_storesRecipientAtMainSlot() public view {
    bytes32 slot = keccak256(abi.encode(uint256(keccak256("uscc.fund")) - 1)) & ~bytes32(uint256(0xff));
    assertEq(slot, MAIN_STORAGE_SLOT, "slot formula");
    assertEq(_storedRecipient(), recipient, "initial recipient slot");
  }

  function test_recipient_returnsInitialRecipient() public view {
    assertEq(fund.recipient(), recipient, "initial recipient");
  }

  function test_recipient_followsSetRecipient() public {
    vm.prank(operator);
    fund.setRecipient(newRecipient);
    assertEq(fund.recipient(), newRecipient, "updated recipient");
    assertEq(fund.recipient(), _storedRecipient(), "getter should read the slot");
  }

  function testFuzz_initialize_emitsRecipientUpdated(address initialRecipient) public {
    vm.assume(initialRecipient != address(0));
    address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

    vm.expectEmit(true, true, true, true, predicted);
    emit RecipientUpdated(initialRecipient);
    address created = factory.createFund(owner, address(this), initialRecipient, address(oracle));

    assertEq(created, predicted, "fund address");
    assertEq(USCCFund(created).recipient(), initialRecipient, "initial recipient");
  }

  function test_setRecipient_emitsAndStores() public {
    vm.expectEmit(true, true, true, true, address(fund));
    emit RecipientUpdated(newRecipient);
    vm.prank(operator);
    fund.setRecipient(newRecipient);
    assertEq(_storedRecipient(), newRecipient, "recipient slot");
  }

  function test_setRecipient_betweenCreateAndCommitRoutesToNewRecipient() public {
    Order memory order = _depositOrder(AMOUNT);
    fund.create(order);
    vm.prank(operator);
    fund.setRecipient(newRecipient);

    _fundDepositor(AMOUNT);
    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderCommitted(order.toId(address(fund)), Mode.DEPOSIT, AMOUNT);
    fund.commit(order);

    assertEq(usdc.balanceOf(newRecipient), AMOUNT, "new recipient");
    assertEq(usdc.balanceOf(recipient), 0, "old recipient");
    assertEq(usdc.balanceOf(address(fund)), 0, "fund kept USDC");
    assertEq(usdc.balanceOf(address(this)), 0, "depositor kept USDC");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "state");
  }

  function test_setRecipient_afterCommitLeavesUnlockUnaffected() public {
    Order memory order = _depositOrder(AMOUNT);
    fund.create(order);
    _fundDepositor(AMOUNT);
    fund.commit(order);
    vm.prank(operator);
    fund.setRecipient(newRecipient);
    uscc.mint(address(fund), order.output);

    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderUnlocked(order.toId(address(fund)), Mode.DEPOSIT, order.output, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, order.output, "unlocked");
    assertEq(wuscc.balanceOf(address(this)), order.output, "wUSCC to receiver");
    assertEq(usdc.balanceOf(recipient), AMOUNT, "old recipient keeps the commit");
    assertEq(usdc.balanceOf(newRecipient), 0, "new recipient USDC");
    assertEq(uscc.balanceOf(newRecipient), 0, "new recipient USCC");
  }

  function test_setRecipient_afterCommitLeavesRecoverUnaffected() public {
    Order memory order = _depositOrder(AMOUNT);
    fund.create(order);
    _fundDepositor(AMOUNT);
    fund.commit(order);
    vm.prank(operator);
    fund.setRecipient(newRecipient);
    vm.prank(owner);
    fund.recovering(order.toId(address(fund)));
    vm.prank(recipient);
    usdc.transfer(address(fund), AMOUNT);

    vm.expectEmit(true, true, true, true, address(fund));
    emit OrderRecovered(order.toId(address(fund)), Mode.DEPOSIT, AMOUNT, address(this));
    (State state, uint256 amount) = fund.recover(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, AMOUNT, "recovered");
    assertEq(usdc.balanceOf(address(this)), AMOUNT, "USDC back to receiver");
    assertEq(usdc.balanceOf(newRecipient), 0, "new recipient USDC");
    assertEq(usdc.balanceOf(address(fund)), 0, "fund kept USDC");
  }

  function test_setRecipient_redeemCommitPaysNoRecipient() public {
    _mintWuscc(address(this), AMOUNT);
    Order memory order = _redeemOrder(AMOUNT);
    fund.create(order);
    vm.prank(operator);
    fund.setRecipient(newRecipient);
    wuscc.approve(address(fund), AMOUNT);

    fund.commit(order);

    assertEq(uscc.lastOffchainRedeemAmount(), AMOUNT, "redeemed");
    assertEq(usdc.balanceOf(recipient), 0, "old recipient USDC");
    assertEq(usdc.balanceOf(newRecipient), 0, "new recipient USDC");
    assertEq(uscc.balanceOf(newRecipient), 0, "new recipient USCC");
    assertEq(wuscc.balanceOf(newRecipient), 0, "new recipient wUSCC");
  }

  function test_setRecipient_revertsForDepositor() public {
    vm.expectRevert(Unauthorized.selector);
    fund.setRecipient(newRecipient);
    assertEq(_storedRecipient(), recipient, "recipient changed");
  }

  function testFuzz_setRecipient_commitPaysTheLatestRecipient(uint256 firstSeed, uint256 secondSeed, uint256 input)
    public
  {
    address first = address(uint160(bound(firstSeed, 1, type(uint160).max)));
    address second = address(uint160(bound(secondSeed, 1, type(uint160).max)));
    vm.assume(second != address(this) && second != address(fund));
    input = bound(input, 1, 1e15);

    Order memory order = _depositOrder(input);
    fund.create(order);
    vm.startPrank(operator);
    fund.setRecipient(first);
    fund.setRecipient(second);
    vm.stopPrank();
    uint256 firstBefore = usdc.balanceOf(first);
    uint256 secondBefore = usdc.balanceOf(second);

    _fundDepositor(input);
    fund.commit(order);

    assertEq(_storedRecipient(), second, "recipient slot");
    assertEq(usdc.balanceOf(second) - secondBefore, input, "latest recipient paid");
    if (first != second) assertEq(usdc.balanceOf(first), firstBefore, "replaced recipient paid");
    assertEq(usdc.balanceOf(address(this)), 0, "depositor kept USDC");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The recipient is the first field of the namespaced struct and fills its slot alone.
  function _storedRecipient() internal view returns (address) {
    bytes32 word = vm.load(address(fund), MAIN_STORAGE_SLOT);
    assertEq(uint256(word) >> 160, 0, "recipient slot dirty upper bits");
    return address(uint160(uint256(word)));
  }

  function _depositOrder(uint256 input) internal view returns (Order memory) {
    return Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: input,
      salt: keccak256("deposit")
    });
  }

  function _redeemOrder(uint256 input) internal view returns (Order memory) {
    return Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: input,
      salt: keccak256("redeem")
    });
  }

  function _fundDepositor(uint256 amount) internal {
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
  }

  function _mintWuscc(address to, uint256 amount) internal {
    uscc.mint(owner, amount);
    vm.startPrank(owner);
    uscc.approve(address(wuscc), amount);
    wuscc.mint(to, amount);
    vm.stopPrank();
  }
}
