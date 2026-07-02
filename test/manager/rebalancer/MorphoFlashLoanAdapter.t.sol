// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {MorphoFlashLoanAdapter} from "src/manager/rebalancer/MorphoFlashLoanAdapter.sol";
import {IFlashLoanReceiver} from "src/interfaces/manager/rebalancer/IFlashLoanModule.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @notice Configurable {IFlashLoanReceiver} used as the flash-loan initiator. It records what
///         the adapter delivers during the callback and can misbehave on demand: skip the
///         repayment approval, reenter the adapter, or call the provider callback directly.
contract FlashLoanReceiverMock is IFlashLoanReceiver {
  MorphoFlashLoanAdapter public immutable ADAPTER;
  MockERC20 public immutable TOKEN;

  // Behavior switches
  bool public approveRepayment = true;
  bool public reenterFlashLoan;
  bool public callProviderCallbackDirectly;

  // Callback recordings
  uint256 public recordedAmount;
  bytes public recordedData;
  address public recordedSender;
  uint256 public recordedBalance;
  uint256 public callbackCount;

  constructor(address adapter_, address token_) {
    ADAPTER = MorphoFlashLoanAdapter(adapter_);
    TOKEN = MockERC20(token_);
  }

  function setApproveRepayment(bool value) external {
    approveRepayment = value;
  }

  function setReenterFlashLoan(bool value) external {
    reenterFlashLoan = value;
  }

  function setCallProviderCallbackDirectly(bool value) external {
    callProviderCallbackDirectly = value;
  }

  /// @notice Starts a flash loan with this contract as the initiator.
  function initiate(uint256 amount, bytes calldata data) external {
    ADAPTER.flashLoan(address(TOKEN), amount, data);
  }

  /// @inheritdoc IFlashLoanReceiver
  function onFlashLoan(uint256 amount, bytes calldata data) external {
    recordedAmount = amount;
    recordedData = data;
    recordedSender = msg.sender;
    recordedBalance = TOKEN.balanceOf(address(this));
    callbackCount++;
    // Reverts from the misbehaving calls below bubble up through the whole loan chain.
    if (reenterFlashLoan) ADAPTER.flashLoan(address(TOKEN), amount, data);
    if (callProviderCallbackDirectly) ADAPTER.onMorphoFlashLoan(amount, data);
    if (approveRepayment) TOKEN.approve(address(ADAPTER), amount);
  }
}

/// @notice Unit tests for {MorphoFlashLoanAdapter} (spec Section 7.3 and Section 14 item 5).
contract MorphoFlashLoanAdapterTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST CONTRACTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  Morpho public morpho;
  MockERC20 public token;
  MorphoFlashLoanAdapter public adapter;
  FlashLoanReceiverMock public receiver;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner = makeAddr("owner");
  uint256 public constant LIQUIDITY = 1_000_000e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    morpho = new Morpho(owner);
    token = new MockERC20("Flash Token", "FLASH", 18);
    // Morpho flash-lends its raw token balance; a plain transfer of minted tokens is enough.
    token.mint(address(morpho), LIQUIDITY);
    adapter = new MorphoFlashLoanAdapter(address(morpho));
    receiver = new FlashLoanReceiverMock(address(adapter), address(token));

    vm.label(address(morpho), "Morpho");
    vm.label(address(token), "FlashToken");
    vm.label(address(adapter), "MorphoFlashLoanAdapter");
    vm.label(address(receiver), "FlashLoanReceiverMock");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_constructor_setsMorpho() public {
    MorphoFlashLoanAdapter freshAdapter = new MorphoFlashLoanAdapter(address(morpho));
    assertEq(address(freshAdapter.MORPHO()), address(morpho), "MORPHO immutable");
  }

  function test_constructor_revertsOnNonContractMorpho() public {
    address eoa = makeAddr("eoa");
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, eoa));
    new MorphoFlashLoanAdapter(eoa);

    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0)));
    new MorphoFlashLoanAdapter(address(0));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     FLASH LOAN SUCCESS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_flashLoan_deliversFundsAndPayloadToInitiator() public {
    uint256 amount = 123_456e15;
    bytes memory payload = abi.encode(uint256(42), address(this), "opaque payload travels verbatim");

    receiver.initiate(amount, payload);

    assertEq(receiver.callbackCount(), 1, "single callback");
    assertEq(receiver.recordedAmount(), amount, "callback amount");
    assertEq(receiver.recordedData(), payload, "payload verbatim");
    assertEq(receiver.recordedSender(), address(adapter), "callback caller is the adapter");
    // Funds were already on the initiator during the callback.
    assertEq(receiver.recordedBalance(), amount, "funds delivered before callback");
  }

  function test_flashLoan_repaysMorphoAndLeavesNoResidual() public {
    uint256 amount = 5_000e18;

    receiver.initiate(amount, "");

    assertEq(token.balanceOf(address(morpho)), LIQUIDITY, "morpho balance restored");
    assertEq(token.balanceOf(address(adapter)), 0, "adapter holds nothing");
    assertEq(token.balanceOf(address(receiver)), 0, "zero-fee loan fully repaid");
    assertEq(token.allowance(address(receiver), address(adapter)), 0, "repayment allowance consumed");
  }

  function test_flashLoan_fundsForwardedBeforeCallbackAndPulledAfter() public {
    // Pre-fund the receiver so the before/after balances are distinguishable from the loan.
    uint256 preFund = 3e18;
    uint256 amount = 10e18;
    token.mint(address(receiver), preFund);

    receiver.initiate(amount, "ordering");

    // During the callback the receiver held pre-fund + loan: funds arrived BEFORE the callback.
    assertEq(receiver.recordedBalance(), preFund + amount, "loan on receiver during callback");
    // After the loan only the pre-fund remains: repayment was pulled AFTER the callback.
    assertEq(token.balanceOf(address(receiver)), preFund, "exactly the loan pulled back");
    assertEq(token.balanceOf(address(morpho)), LIQUIDITY, "morpho made whole");
    assertEq(token.balanceOf(address(adapter)), 0, "adapter empty");
  }

  function test_flashLoan_clearsTransientStateBetweenLoans() public {
    // Both loans run inside the same test transaction, so transient storage survives between
    // the two calls unless the adapter explicitly clears it on exit.
    receiver.initiate(1_000e18, "first");
    receiver.initiate(2_000e18, "second");

    assertEq(receiver.callbackCount(), 2, "both loans executed");
    assertEq(receiver.recordedAmount(), 2_000e18, "second loan amount");
    assertEq(receiver.recordedData(), bytes("second"), "second loan payload");
    assertEq(token.balanceOf(address(morpho)), LIQUIDITY, "morpho balance restored twice");
    assertEq(token.balanceOf(address(adapter)), 0, "adapter empty");
  }

  function testFuzz_flashLoan_deliversAndRepays(uint256 amount) public {
    amount = bound(amount, 1, LIQUIDITY);

    receiver.initiate(amount, "fuzz");

    assertEq(receiver.recordedAmount(), amount, "callback amount");
    assertEq(receiver.recordedBalance(), amount, "funds delivered before callback");
    assertEq(token.balanceOf(address(morpho)), LIQUIDITY, "morpho balance restored");
    assertEq(token.balanceOf(address(adapter)), 0, "adapter empty");
    assertEq(token.balanceOf(address(receiver)), 0, "receiver repaid everything");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     FLASH LOAN REVERTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_flashLoan_revertsOnNestedFlashLoan() public {
    receiver.setReenterFlashLoan(true);

    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    receiver.initiate(1_000e18, "");
  }

  function test_flashLoan_revertsWhenInitiatorDoesNotApprove() public {
    receiver.setApproveRepayment(false);

    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    receiver.initiate(1_000e18, "");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   PROVIDER CALLBACK AUTH                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_onMorphoFlashLoan_revertsForNonMorphoCaller() public {
    vm.expectRevert(LibRetargetterErrors.UnauthorizedCaller.selector);
    adapter.onMorphoFlashLoan(1_000e18, "");
  }

  function test_onMorphoFlashLoan_revertsFromMorphoWithNoLiveInitiator() public {
    // The caller is Morpho itself but no loan is in flight (empty transient initiator).
    vm.prank(address(morpho));
    vm.expectRevert(LibRetargetterErrors.UnauthorizedCaller.selector);
    adapter.onMorphoFlashLoan(1_000e18, "");
  }

  function test_onMorphoFlashLoan_revertsForNonMorphoCallerDuringLiveLoan() public {
    // The receiver calls the provider callback directly inside its own callback: the initiator
    // is live but msg.sender is not Morpho, so the whole loan reverts.
    receiver.setCallProviderCallbackDirectly(true);

    vm.expectRevert(LibRetargetterErrors.UnauthorizedCaller.selector);
    receiver.initiate(1_000e18, "");
  }
}
