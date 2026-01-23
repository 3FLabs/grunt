// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {USCCFund} from "src/funds/USCCFund.sol";
import {USCCFundFactory} from "src/funds/USCCFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";

import {MockERC20} from "../mock/funds/MockERC20.sol";
import {MockAllowlist} from "../mock/funds/MockAllowlist.sol";
import {MockChainlinkOracle} from "../mock/funds/MockChainlinkOracle.sol";
import {MockSuperstateToken} from "../mock/funds/MockSuperstateToken.sol";
import {USCCFundHandler} from "test/mock/funds/USCCFundHandler.sol";

contract USCCFundFuzzTest is Test {
  uint256 private constant ONE_USDC = 1e6;

  // WrappedAsset roles (matching internal constants)
  uint256 private constant WUSCC_ISSUER_ROLE = 1 << 0;
  uint256 private constant WUSCC_SENDER_ROLE = 1 << 1;

  USCCFundFactory public factory;
  USCCFund public fund;
  WrappedAsset public wuscc;
  MockERC20 public usdc;
  MockSuperstateToken public uscc;
  MockAllowlist public allowlist;
  MockChainlinkOracle public oracle;

  address public owner;
  address public recipient;

  function setUp() public {
    owner = makeAddr("owner");
    recipient = makeAddr("recipient");

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
    vm.prank(owner);
    wuscc.grantRoles(address(fund), WUSCC_ISSUER_ROLE);

    vm.prank(owner);
    wuscc.grantRoles(address(this), WUSCC_SENDER_ROLE);
  }

  function testFuzz_DepositUnlock_SucceedsWhenReceivedGteOutput(
    uint96 input,
    uint96 output,
    uint96 preExistingUscc,
    uint96 receivedUscc
  ) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = bound(uint256(output), 0, maxAmount);
    uint256 preExistingAmount = uint256(preExistingUscc);
    uint256 receivedAmount = bound(uint256(receivedUscc), outputAmount, maxAmount);

    if (preExistingAmount > 0) uscc.mint(address(fund), preExistingAmount);

    Order memory order = _depositOrder(inputAmount, outputAmount);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    if (receivedAmount > 0) uscc.mint(address(fund), receivedAmount);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    fund.unlock(order);

    assertEq(wuscc.balanceOf(address(this)), receivedAmount, "wuscc minted");
    // USCC is now held by wUSCC contract after unlock (not fund)
    assertEq(uscc.balanceOf(address(wuscc)), receivedAmount, "uscc in wuscc");
    assertEq(uscc.balanceOf(address(fund)), preExistingAmount, "fund pre-existing uscc");
    assertEq(usdc.balanceOf(recipient), inputAmount, "usdc recipient");
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
  }

  function testFuzz_DepositUnlock_RevertsWhenReceivedLtOutput(
    uint96 input,
    uint96 output,
    uint96 preExistingUscc,
    uint96 receivedUscc
  ) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = bound(uint256(output), 1, maxAmount);
    uint256 preExistingAmount = uint256(preExistingUscc);
    uint256 receivedAmount = bound(uint256(receivedUscc), 0, outputAmount - 1);

    if (preExistingAmount > 0) uscc.mint(address(fund), preExistingAmount);

    Order memory order = _depositOrder(inputAmount, outputAmount);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    if (receivedAmount > 0) uscc.mint(address(fund), receivedAmount);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);
  }

  function testFuzz_DepositRecover_SucceedsWhenUsdcReturnedGteInput(uint96 input, uint96 output, uint96 returnedUsdc)
    public
  {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = uint256(output);
    uint256 returnedAmount = bound(uint256(returnedUsdc), inputAmount, maxAmount);

    Order memory order = _depositOrder(inputAmount, outputAmount);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    vm.prank(owner);
    fund.recovering();

    usdc.mint(address(fund), returnedAmount);

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    fund.recover(order);

    assertEq(usdc.balanceOf(address(this)), returnedAmount, "usdc recovered");
    assertEq(usdc.balanceOf(address(fund)), 0, "fund usdc cleared");
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
  }

  function testFuzz_DepositRecover_RevertsWhenUsdcReturnedLtInput(uint96 input, uint96 output, uint96 returnedUsdc)
    public
  {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = uint256(output);
    uint256 returnedAmount = bound(uint256(returnedUsdc), 0, inputAmount - 1);

    Order memory order = _depositOrder(inputAmount, outputAmount);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    vm.prank(owner);
    fund.recovering();

    if (returnedAmount > 0) usdc.mint(address(fund), returnedAmount);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.RECOVERING));
    fund.recover(order);
  }

  function testFuzz_ArchivedEndedOrderRemainsEndedAfterNewOrder(uint96 input, uint96 output, uint96 nextInput) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount - 1);
    uint256 outputAmount = bound(uint256(output), 1, maxAmount);
    uint256 nextInputAmount = bound(uint256(nextInput), 1, maxAmount);
    if (nextInputAmount == inputAmount) {
      nextInputAmount = inputAmount + 1;
    }

    Order memory order = _depositOrder(inputAmount, outputAmount);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    uscc.mint(address(fund), outputAmount);
    fund.unlock(order);

    Order memory nextOrder = _depositOrder(nextInputAmount, outputAmount);
    fund.create(nextOrder);

    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "archived order ended");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  function testFuzz_RedeemUnlock_SucceedsWhenUsdcOutGteOutput(uint96 input, uint96 output, uint96 usdcOut) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = bound(uint256(output), 0, maxAmount);
    uint256 usdcOutAmount = bound(uint256(usdcOut), outputAmount, maxAmount);

    Order memory order = _redeemOrder(inputAmount, outputAmount);
    fund.create(order);

    _mintWuscc(address(this), inputAmount);
    wuscc.approve(address(fund), inputAmount);

    fund.commit(order);

    if (usdcOutAmount > 0) usdc.mint(address(fund), usdcOutAmount);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    fund.unlock(order);

    assertEq(usdc.balanceOf(address(this)), usdcOutAmount, "usdc received");
    assertEq(usdc.balanceOf(address(fund)), 0, "fund usdc cleared");
    assertEq(wuscc.balanceOf(address(this)), 0, "wuscc burned");
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
  }

  function testFuzz_RedeemUnlock_RevertsWhenUsdcOutLtOutput(uint96 input, uint96 output, uint96 usdcOut) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = bound(uint256(output), 1, maxAmount);
    uint256 usdcOutAmount = bound(uint256(usdcOut), 0, outputAmount - 1);

    Order memory order = _redeemOrder(inputAmount, outputAmount);
    fund.create(order);

    _mintWuscc(address(this), inputAmount);
    wuscc.approve(address(fund), inputAmount);

    fund.commit(order);

    if (usdcOutAmount > 0) usdc.mint(address(fund), usdcOutAmount);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);
  }

  function testFuzz_RedeemRecover_SucceedsWhenUsccReturnedGteInput(
    uint96 input,
    uint96 output,
    uint96 preExistingUscc,
    uint96 returnedUscc
  ) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = uint256(output);
    uint256 preExistingAmount = uint256(preExistingUscc);
    uint256 returnedAmount = bound(uint256(returnedUscc), inputAmount, maxAmount);

    // Pre-existing USCC goes to wUSCC (simulating prior wraps)
    if (preExistingAmount > 0) {
      uscc.mint(owner, preExistingAmount);
      vm.prank(owner);
      uscc.approve(address(wuscc), preExistingAmount);
      vm.prank(owner);
      wuscc.mint(owner, preExistingAmount);
    }

    Order memory order = _redeemOrder(inputAmount, outputAmount);
    fund.create(order);

    _mintWuscc(address(this), inputAmount);
    wuscc.approve(address(fund), inputAmount);
    fund.commit(order);

    vm.prank(owner);
    fund.recovering();

    // Superstate returns USCC to fund
    uscc.mint(address(fund), returnedAmount);

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    fund.recover(order);

    assertEq(wuscc.balanceOf(address(this)), returnedAmount, "wuscc recovered");
    // USCC is now held by wUSCC contract (inputAmount was burned during offchainRedeem in commit)
    assertEq(uscc.balanceOf(address(wuscc)), preExistingAmount + returnedAmount, "uscc in wuscc");
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
  }

  function testFuzz_RedeemRecover_RevertsWhenUsccReturnedLtInput(
    uint96 input,
    uint96 output,
    uint96 preExistingUscc,
    uint96 returnedUscc
  ) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = uint256(output);
    uint256 preExistingAmount = uint256(preExistingUscc);
    uint256 returnedAmount = bound(uint256(returnedUscc), 0, inputAmount - 1);

    // Pre-existing USCC goes to wUSCC
    if (preExistingAmount > 0) {
      uscc.mint(owner, preExistingAmount);
      vm.prank(owner);
      uscc.approve(address(wuscc), preExistingAmount);
      vm.prank(owner);
      wuscc.mint(owner, preExistingAmount);
    }

    Order memory order = _redeemOrder(inputAmount, outputAmount);
    fund.create(order);

    _mintWuscc(address(this), inputAmount);
    wuscc.approve(address(fund), inputAmount);
    fund.commit(order);

    vm.prank(owner);
    fund.recovering();

    if (returnedAmount > 0) uscc.mint(address(fund), returnedAmount);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.RECOVERING));
    fund.recover(order);
  }

  function testFuzz_DepositResolveThenUnlock_UsesOriginalOrder(
    uint96 input,
    uint96 initialOutput,
    uint96 resolvedInput,
    uint96 resolvedOutput,
    uint96 receivedUscc
  ) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);

    Order memory original = _depositOrder(inputAmount, bound(uint256(initialOutput), 0, maxAmount));
    fund.create(original);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(original);

    uint256 newInput = bound(uint256(resolvedInput), 0, maxAmount);
    uint256 newOutput = bound(uint256(resolvedOutput), 0, maxAmount);
    vm.assume(newInput != original.input || newOutput != original.output);

    vm.prank(owner);
    fund.resolve(original, newInput, newOutput);

    Order memory resolved = Order({
      owner: original.owner,
      receiver: original.receiver,
      input: newInput,
      output: newOutput,
      mode: original.mode,
      salt: original.salt
    });

    State expectedState = newOutput == 0 ? State.UNLOCKING : State.PROCESSING;
    assertEq(uint256(fund.state(original)), uint256(expectedState), "original state");
    assertEq(uint256(fund.state(resolved)), uint256(State.EMPTY), "resolved empty");

    uint256 receivedAmount = bound(uint256(receivedUscc), newOutput, maxAmount);
    if (receivedAmount > 0) uscc.mint(address(fund), receivedAmount);

    assertEq(uint256(fund.state(original)), uint256(State.UNLOCKING), "original unlocking");

    vm.expectRevert();
    fund.unlock(resolved);

    fund.unlock(original);

    assertEq(wuscc.balanceOf(address(this)), receivedAmount, "wuscc minted");
    assertEq(usdc.balanceOf(recipient), inputAmount, "usdc recipient");
    assertEq(uint256(fund.state(original)), uint256(State.ENDED), "ended");
  }

  function testFuzz_DepositResolveInRecoveringThenRecover_UsesOriginalOrder(
    uint96 input,
    uint96 initialOutput,
    uint96 resolvedInput,
    uint96 resolvedOutput,
    uint96 returnedUsdc
  ) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);

    Order memory original = _depositOrder(inputAmount, bound(uint256(initialOutput), 0, maxAmount));
    fund.create(original);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(original);

    vm.prank(owner);
    fund.recovering();

    uint256 newInput = bound(uint256(resolvedInput), 0, maxAmount);
    uint256 newOutput = bound(uint256(resolvedOutput), 0, maxAmount);
    vm.assume(newInput != original.input || newOutput != original.output);

    vm.prank(owner);
    fund.resolve(original, newInput, newOutput);

    Order memory resolved = Order({
      owner: original.owner,
      receiver: original.receiver,
      input: newInput,
      output: newOutput,
      mode: original.mode,
      salt: original.salt
    });

    State expectedState = newInput == 0 ? State.RECOVERING : State.PROCESSING;
    assertEq(uint256(fund.state(original)), uint256(expectedState), "original state");
    assertEq(uint256(fund.state(resolved)), uint256(State.EMPTY), "resolved empty");

    uint256 returnedAmount = bound(uint256(returnedUsdc), newInput, maxAmount);
    if (returnedAmount > 0) usdc.mint(address(fund), returnedAmount);

    assertEq(uint256(fund.state(original)), uint256(State.RECOVERING), "original recovering");

    vm.expectRevert();
    fund.recover(resolved);

    fund.recover(original);

    assertEq(usdc.balanceOf(address(this)), returnedAmount, "usdc recovered");
    assertEq(usdc.balanceOf(address(fund)), 0, "fund usdc cleared");
    assertEq(uint256(fund.state(original)), uint256(State.ENDED), "ended");
  }

  function testFuzz_RedeemResolveThenUnlock_UsesOriginalOrder(
    uint96 input,
    uint96 initialOutput,
    uint96 resolvedInput,
    uint96 resolvedOutput,
    uint96 usdcOut
  ) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);

    Order memory original = _redeemOrder(inputAmount, bound(uint256(initialOutput), 0, maxAmount));
    fund.create(original);

    _mintWuscc(address(this), inputAmount);
    wuscc.approve(address(fund), inputAmount);
    fund.commit(original);

    uint256 newInput = bound(uint256(resolvedInput), 0, maxAmount);
    uint256 newOutput = bound(uint256(resolvedOutput), 0, maxAmount);
    vm.assume(newInput != original.input || newOutput != original.output);

    vm.prank(owner);
    fund.resolve(original, newInput, newOutput);

    Order memory resolved = Order({
      owner: original.owner,
      receiver: original.receiver,
      input: newInput,
      output: newOutput,
      mode: original.mode,
      salt: original.salt
    });

    State expectedState = newOutput == 0 ? State.UNLOCKING : State.PROCESSING;
    assertEq(uint256(fund.state(original)), uint256(expectedState), "original state");
    assertEq(uint256(fund.state(resolved)), uint256(State.EMPTY), "resolved empty");

    uint256 usdcOutAmount = bound(uint256(usdcOut), newOutput, maxAmount);
    if (usdcOutAmount > 0) usdc.mint(address(fund), usdcOutAmount);

    assertEq(uint256(fund.state(original)), uint256(State.UNLOCKING), "original unlocking");

    vm.expectRevert();
    fund.unlock(resolved);

    fund.unlock(original);

    assertEq(usdc.balanceOf(address(this)), usdcOutAmount, "usdc received");
    assertEq(usdc.balanceOf(address(fund)), 0, "fund usdc cleared");
    assertEq(uint256(fund.state(original)), uint256(State.ENDED), "ended");
  }

  function testFuzz_RedeemResolveInRecoveringThenRecover_UsesOriginalOrder(
    uint96 input,
    uint96 initialOutput,
    uint96 resolvedInput,
    uint96 resolvedOutput,
    uint96 returnedUscc
  ) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);

    Order memory original = _redeemOrder(inputAmount, bound(uint256(initialOutput), 0, maxAmount));
    fund.create(original);

    _mintWuscc(address(this), inputAmount);
    wuscc.approve(address(fund), inputAmount);
    fund.commit(original);

    vm.prank(owner);
    fund.recovering();

    uint256 newInput = bound(uint256(resolvedInput), 0, maxAmount);
    uint256 newOutput = bound(uint256(resolvedOutput), 0, maxAmount);
    vm.assume(newInput != original.input || newOutput != original.output);

    vm.prank(owner);
    fund.resolve(original, newInput, newOutput);

    Order memory resolved = Order({
      owner: original.owner,
      receiver: original.receiver,
      input: newInput,
      output: newOutput,
      mode: original.mode,
      salt: original.salt
    });

    State expectedState = newInput == 0 ? State.RECOVERING : State.PROCESSING;
    assertEq(uint256(fund.state(original)), uint256(expectedState), "original state");
    assertEq(uint256(fund.state(resolved)), uint256(State.EMPTY), "resolved empty");

    uint256 returnedAmount = bound(uint256(returnedUscc), newInput, maxAmount);
    if (returnedAmount > 0) uscc.mint(address(fund), returnedAmount);

    assertEq(uint256(fund.state(original)), uint256(State.RECOVERING), "original recovering");

    vm.expectRevert();
    fund.recover(resolved);

    fund.recover(original);

    assertEq(wuscc.balanceOf(address(this)), returnedAmount, "wuscc recovered");
    // USCC is now held by wUSCC contract (inputAmount was burned during offchainRedeem in commit)
    assertEq(uscc.balanceOf(address(wuscc)), returnedAmount, "uscc in wuscc");
    assertEq(uscc.balanceOf(address(fund)), 0, "fund has no uscc");
    assertEq(uint256(fund.state(original)), uint256(State.ENDED), "ended");
  }

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

  /// @dev Helper to mint wUSCC to a recipient. Wraps USCC into wUSCC.
  function _mintWuscc(address to, uint256 amount) internal {
    uscc.mint(owner, amount);
    vm.prank(owner);
    uscc.approve(address(wuscc), amount);
    vm.prank(owner);
    wuscc.mint(to, amount);
  }
}

contract USCCFundInvariantTest is StdInvariant, Test {
  uint256 private constant ONE_USDC = 1e6;

  // WrappedAsset roles (matching internal constants)
  uint256 private constant WUSCC_ISSUER_ROLE = 1 << 0;
  uint256 private constant WUSCC_SENDER_ROLE = 1 << 1;

  USCCFundFactory public factory;
  USCCFund public fund;
  WrappedAsset public wuscc;
  MockERC20 public usdc;
  MockSuperstateToken public uscc;
  MockAllowlist public allowlist;
  MockChainlinkOracle public oracle;

  USCCFundHandler public handler;

  address public owner;
  address public recipient;

  function setUp() public {
    owner = makeAddr("owner");
    recipient = makeAddr("recipient");

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

    handler = new USCCFundHandler();

    factory = new USCCFundFactory(owner, address(usdc), address(uscc), address(wuscc));
    address fundAddress = factory.createFund(owner, address(handler), recipient, address(oracle));
    fund = USCCFund(fundAddress);

    allowlist.setAllowed(address(fund), "USCC", true);

    vm.prank(owner);
    wuscc.grantRoles(address(fund), WUSCC_ISSUER_ROLE);

    vm.prank(owner);
    wuscc.grantRoles(address(handler), WUSCC_SENDER_ROLE);

    uint256 operatorRole = fund.OPERATOR_ROLE();
    vm.prank(owner);
    fund.grantRoles(address(handler), operatorRole);

    handler.initialize(fund, usdc, uscc, wuscc, recipient);

    bytes4[] memory selectors = new bytes4[](10);
    selectors[0] = handler.act_createDeposit.selector;
    selectors[1] = handler.act_createRedeem.selector;
    selectors[2] = handler.act_commit.selector;
    selectors[3] = handler.act_setRecovering.selector;
    selectors[4] = handler.act_resolve.selector;
    selectors[5] = handler.act_superstateMintUscc.selector;
    selectors[6] = handler.act_superstateMintUsdc.selector;
    selectors[7] = handler.act_unlock.selector;
    selectors[8] = handler.act_recover.selector;
    selectors[9] = handler.act_cancel.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  function invariant_FundDoesNotHoldWuscc() public view {
    assertEq(wuscc.balanceOf(address(fund)), 0, "fund holds wUSCC");
  }

  function invariant_RecipientBalanceMatchesDeposits() public view {
    assertEq(usdc.balanceOf(recipient), handler.expectedRecipientUsdc(), "recipient usdc mismatch");
  }

  function invariant_balanceWUSCCMatchesUnderlyingUSCC() public view {
    uint256 wusccBalance = uscc.balanceOf(address(wuscc));
    uint256 totalSupply = wuscc.totalSupply();
    assertEq(totalSupply, wusccBalance, "wUSCC underlying USCC mismatch");
  }

  function invariant_TotalAssetsTracksWusccSupplyWhenPriceIsOne() public view {
    // totalAssets is now based on wUSCC.totalSupply() * oracle price
    // With oracle price = 1, totalAssets should equal wUSCC.totalSupply()
    assertEq(fund.totalAssets(), wuscc.totalSupply(), "totalAssets mismatch");
  }

  function invariant_StateMatchesModel() public view {
    State stage = handler.internalState();
    if (stage == State.EMPTY) return;

    Order memory order = handler.getOrder();
    State actual = fund.state(order);

    if (stage == State.ACCEPTED) {
      assertEq(uint256(actual), uint256(State.ACCEPTED), "accepted");
      return;
    }

    if (stage == State.ENDED) {
      assertEq(uint256(actual), uint256(State.ENDED), "ended");
      return;
    }

    uint256 cachedUsccBalance = handler.cachedUsccBalance();
    uint256 effectiveInput = handler.effectiveInput();
    uint256 effectiveOutput = handler.effectiveOutput();

    if (stage == State.PROCESSING) {
      if (order.mode == Mode.DEPOSIT) {
        uint256 currentUscc = uscc.balanceOf(address(fund));
        uint256 delta = currentUscc >= cachedUsccBalance ? currentUscc - cachedUsccBalance : 0;
        State expected = delta >= effectiveOutput ? State.UNLOCKING : State.PROCESSING;
        assertEq(uint256(actual), uint256(expected), "processing deposit");
      } else {
        uint256 currentUsdc = usdc.balanceOf(address(fund));
        State expected = currentUsdc >= effectiveOutput ? State.UNLOCKING : State.PROCESSING;
        assertEq(uint256(actual), uint256(expected), "processing redeem");
      }
      return;
    }

    if (stage == State.RECOVERING) {
      if (order.mode == Mode.DEPOSIT) {
        uint256 currentUsdc = usdc.balanceOf(address(fund));
        State expected = currentUsdc >= effectiveInput ? State.RECOVERING : State.PROCESSING;
        assertEq(uint256(actual), uint256(expected), "recovering deposit");
      } else {
        uint256 currentUscc = uscc.balanceOf(address(fund));
        uint256 delta = currentUscc >= cachedUsccBalance ? currentUscc - cachedUsccBalance : 0;
        State expected = delta >= effectiveInput ? State.RECOVERING : State.PROCESSING;
        assertEq(uint256(actual), uint256(expected), "recovering redeem");
      }
      return;
    }

    assertTrue(stage != State.PENDING, "stage pending");
  }
}
