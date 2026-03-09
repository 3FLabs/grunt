// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CentrifugeFund} from "src/funds/centrifuge/CentrifugeFund.sol";
import {CentrifugeFundFactory} from "src/funds/centrifuge/CentrifugeFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockCentrifugeVault} from "../../mock/funds/centrifuge/MockCentrifugeVault.sol";
import {CentrifugeFundHandler} from "test/mock/funds/centrifuge/CentrifugeFundHandler.sol";

contract CentrifugeFundFuzzTest is Test {
  using LibOrder for Order;

  uint256 private constant ONE = 1e6;

  // CentrifugeFund roles
  uint256 private constant OPERATOR_ROLE = 1 << 0;

  // WrappedAsset roles
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  CentrifugeFundFactory public factory;
  CentrifugeFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public assetToken;
  MockERC20 public shareToken;
  MockCentrifugeVault public vault;

  address public owner;

  function setUp() public {
    owner = makeAddr("owner");

    assetToken = new MockERC20("USDC", "USDC", 6);
    shareToken = new MockERC20("Share", "SHR", 6);
    vault = new MockCentrifugeVault(address(assetToken), address(shareToken));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(shareToken), "wShare", "wSHR");

    factory = new CentrifugeFundFactory(owner);
    address fundAddr = factory.createFund(owner, address(this), address(vault), address(wrappedShare));
    fund = CentrifugeFund(fundAddr);

    vault.setPermissioned(address(fund), true);
    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    vm.prank(owner);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FUZZ: DEPOSIT UNLOCK                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_DepositUnlock_Succeeds(uint96 input, uint96 fulfilled) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 fulfilledAmount = bound(uint256(fulfilled), 1, maxAmount);

    Order memory order = _depositOrder(inputAmount, inputAmount);
    fund.create(order);

    assetToken.mint(address(this), inputAmount);
    assetToken.approve(address(fund), inputAmount);
    fund.commit(order);

    vault.fulfillDeposit(address(fund), fulfilledAmount);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    (State newState, uint256 amount) = fund.unlock(order);

    assertEq(amount, fulfilledAmount, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), fulfilledAmount, "wShare minted");
    assertEq(shareToken.balanceOf(address(wrappedShare)), fulfilledAmount, "share in wShare");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FUZZ: REDEEM UNLOCK                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_RedeemUnlock_Succeeds(uint96 input, uint96 fulfilled) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 fulfilledAmount = bound(uint256(fulfilled), 1, maxAmount);

    Order memory order = _redeemOrder(inputAmount, inputAmount);
    fund.create(order);

    _mintWrappedShare(address(this), inputAmount);
    wrappedShare.approve(address(fund), inputAmount);
    fund.commit(order);

    vault.fulfillRedeem(address(fund), fulfilledAmount);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    (State newState, uint256 amount) = fund.unlock(order);

    assertEq(amount, fulfilledAmount, "amount");
    assertEq(assetToken.balanceOf(address(this)), fulfilledAmount, "asset received");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     FUZZ: DEPOSIT RECOVER                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_DepositRecover_Succeeds(uint96 input, uint96 recovered) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 recoveredAmount = bound(uint256(recovered), 1, inputAmount);

    Order memory order = _depositOrder(inputAmount, inputAmount);
    fund.create(order);

    assetToken.mint(address(this), inputAmount);
    assetToken.approve(address(fund), inputAmount);
    fund.commit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    vault.fulfillCancelDeposit(address(fund), recoveredAmount);

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    (State newState, uint256 amount) = fund.recover(order);

    assertEq(amount, recoveredAmount, "amount");
    assertEq(assetToken.balanceOf(address(this)), recoveredAmount, "asset recovered");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     FUZZ: REDEEM RECOVER                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_RedeemRecover_Succeeds(uint96 input, uint96 recovered) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount);
    uint256 recoveredAmount = bound(uint256(recovered), 1, inputAmount);

    Order memory order = _redeemOrder(inputAmount, inputAmount);
    fund.create(order);

    _mintWrappedShare(address(this), inputAmount);
    wrappedShare.approve(address(fund), inputAmount);
    fund.commit(order);

    vm.prank(owner);
    fund.cancelRequest(order);

    vault.fulfillCancelRedeem(address(fund), recoveredAmount);

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    (State newState, uint256 amount) = fund.recover(order);

    assertEq(amount, recoveredAmount, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), recoveredAmount, "wShare recovered");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     FUZZ: PARTIAL FILLS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_PartialDepositUnlock(uint96 input, uint96 partialShares, uint96 consumedAssets) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 2, maxAmount);
    uint256 partialAmount = bound(uint256(partialShares), 1, maxAmount);
    uint256 consumed = bound(uint256(consumedAssets), 1, inputAmount - 1);

    Order memory order = _depositOrder(inputAmount, inputAmount);
    fund.create(order);

    assetToken.mint(address(this), inputAmount);
    assetToken.approve(address(fund), inputAmount);
    fund.commit(order);

    vault.partialFulfillDeposit(address(fund), partialAmount, consumed);

    (State newState,) = fund.unlock(order);

    // Partial fill → back to PROCESSING
    assertEq(uint256(newState), uint256(State.PROCESSING), "still processing");
    assertEq(wrappedShare.balanceOf(address(this)), partialAmount, "partial wShare");
  }

  function testFuzz_PartialRedeemUnlock(uint96 input, uint96 partialAssets, uint96 consumedShares) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 2, maxAmount);
    uint256 partialAmount = bound(uint256(partialAssets), 1, maxAmount);
    uint256 consumed = bound(uint256(consumedShares), 1, inputAmount - 1);

    Order memory order = _redeemOrder(inputAmount, inputAmount);
    fund.create(order);

    _mintWrappedShare(address(this), inputAmount);
    wrappedShare.approve(address(fund), inputAmount);
    fund.commit(order);

    vault.partialFulfillRedeem(address(fund), partialAmount, consumed);

    (State newState,) = fund.unlock(order);

    assertEq(uint256(newState), uint256(State.PROCESSING), "still processing");
    assertEq(assetToken.balanceOf(address(this)), partialAmount, "partial asset");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FUZZ: SLIPPAGE GUARD                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_SlippageGuard_OutputBounds(uint96 input, uint96 output) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 100, maxAmount); // min 100 for meaningful deviation
    uint256 outputAmount = bound(uint256(output), 0, maxAmount);

    // With 1:1 rate, expectedOutput == inputAmount
    // Only reverts when output < expectedOutput AND deviation > 5%
    uint256 maxDeviation = inputAmount * 500 / 10000;

    Order memory order = Order({
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: outputAmount,
      mode: Mode.DEPOSIT,
      salt: keccak256("fuzz-slippage")
    });

    if (outputAmount < inputAmount && (inputAmount - outputAmount > maxDeviation)) {
      vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    }

    fund.create(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              FUZZ: SLIPPAGE GUARD (NON-1:1 RATE)                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_SlippageGuard_NonOneToOneRate(uint96 input, uint96 output, uint64 rawRate) public {
    uint256 rate = bound(uint256(rawRate), 0.5e18, 2e18);
    vault.setConversionRate(rate);

    uint256 inputAmount = bound(uint256(input), 100, type(uint96).max);
    uint256 outputAmount = bound(uint256(output), 0, type(uint96).max);

    // For deposit: convertToShares = input * 1e18 / rate
    uint256 expectedOutput = inputAmount * 1e18 / rate;
    uint256 maxDeviation = expectedOutput * 500 / 10000; // 5%

    Order memory order = Order({
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: outputAmount,
      mode: Mode.DEPOSIT,
      salt: keccak256("fuzz-slippage-rate")
    });

    if (outputAmount < expectedOutput && (expectedOutput - outputAmount > maxDeviation)) {
      vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    }

    fund.create(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              FUZZ: TOTAL ASSETS (NON-1:1 RATE)                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_TotalAssets_NonOneToOneRate(uint96 rawShares, uint64 rawRate) public {
    uint256 shares = bound(uint256(rawShares), 1, type(uint96).max);
    uint256 rate = bound(uint256(rawRate), 0.5e18, 2e18);

    // Deposit+fulfill+unlock at 1:1 to mint wrapped shares
    Order memory order = _depositOrder(shares, shares);
    fund.create(order);

    assetToken.mint(address(this), shares);
    assetToken.approve(address(fund), shares);
    fund.commit(order);

    vault.fulfillDeposit(address(fund), shares);
    fund.unlock(order);

    assertEq(wrappedShare.totalSupply(), shares, "wShare supply");

    // Change conversion rate and verify totalAssets reflects it
    vault.setConversionRate(rate);
    uint256 expected = shares * rate / 1e18;
    assertEq(fund.totalAssets(), expected, "totalAssets at non-1:1 rate");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FUZZ: ARCHIVED ORDER                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_ArchivedEndedOrderRemainsEnded(uint96 input, uint96 nextInput) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount - 1);
    uint256 nextInputAmount = bound(uint256(nextInput), 1, maxAmount);
    if (nextInputAmount == inputAmount) nextInputAmount = inputAmount + 1;

    Order memory order = _depositOrder(inputAmount, inputAmount);
    fund.create(order);

    assetToken.mint(address(this), inputAmount);
    assetToken.approve(address(fund), inputAmount);
    fund.commit(order);

    vault.fulfillDeposit(address(fund), inputAmount);
    fund.unlock(order);

    Order memory nextOrder = _depositOrderWithSalt(nextInputAmount, nextInputAmount, keccak256("next"));
    fund.create(nextOrder);

    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "archived order ended");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                               */
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

  function _depositOrderWithSalt(uint256 input, uint256 output, bytes32 salt) internal view returns (Order memory) {
    return Order({
      owner: address(this), receiver: address(this), input: input, output: output, mode: Mode.DEPOSIT, salt: salt
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

  function _mintWrappedShare(address to, uint256 amount) internal {
    shareToken.mint(owner, amount);
    vm.prank(owner);
    shareToken.approve(address(wrappedShare), amount);
    vm.prank(owner);
    wrappedShare.mint(to, amount);
  }
}

contract CentrifugeFundInvariantTest is StdInvariant, Test {
  uint256 private constant OPERATOR_ROLE = 1 << 0;

  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  CentrifugeFundFactory public factory;
  CentrifugeFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public assetToken;
  MockERC20 public shareToken;
  MockCentrifugeVault public vault;

  CentrifugeFundHandler public handler;

  address public owner;

  function setUp() public {
    owner = makeAddr("owner");

    assetToken = new MockERC20("USDC", "USDC", 6);
    shareToken = new MockERC20("Share", "SHR", 6);
    vault = new MockCentrifugeVault(address(assetToken), address(shareToken));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(shareToken), "wShare", "wSHR");

    handler = new CentrifugeFundHandler();

    factory = new CentrifugeFundFactory(owner);
    address fundAddr = factory.createFund(owner, address(handler), address(vault), address(wrappedShare));
    fund = CentrifugeFund(fundAddr);

    vault.setPermissioned(address(fund), true);

    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    vm.prank(owner);
    wrappedShare.grantRoles(address(handler), SENDER_ROLE);

    vm.prank(owner);
    fund.grantRoles(address(handler), OPERATOR_ROLE);

    handler.initialize(fund, assetToken, shareToken, wrappedShare, vault);

    bytes4[] memory selectors = new bytes4[](11);
    selectors[0] = handler.act_createDeposit.selector;
    selectors[1] = handler.act_createRedeem.selector;
    selectors[2] = handler.act_commit.selector;
    selectors[3] = handler.act_cancelRequest.selector;
    selectors[4] = handler.act_vaultFulfillDeposit.selector;
    selectors[5] = handler.act_vaultFulfillRedeem.selector;
    selectors[6] = handler.act_vaultFulfillCancelDeposit.selector;
    selectors[7] = handler.act_vaultFulfillCancelRedeem.selector;
    selectors[8] = handler.act_unlock.selector;
    selectors[9] = handler.act_recover.selector;
    selectors[10] = handler.act_cancel.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  function invariant_FundDoesNotHoldWrappedShares() public view {
    assertEq(wrappedShare.balanceOf(address(fund)), 0, "fund holds wrappedShare");
  }

  function invariant_WrappedShareSupplyMatchesUnderlying() public view {
    assertEq(wrappedShare.totalSupply(), shareToken.balanceOf(address(wrappedShare)), "wShare supply mismatch");
  }

  function invariant_TotalAssetsConsistent() public view {
    assertEq(fund.totalAssets(), vault.convertToAssets(wrappedShare.totalSupply()), "totalAssets mismatch");
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

    if (stage == State.PROCESSING) {
      if (order.mode == Mode.DEPOSIT) {
        uint256 claimable = vault._claimableMint(address(fund));
        State expected = claimable > 0 ? State.UNLOCKING : State.PROCESSING;
        assertEq(uint256(actual), uint256(expected), "processing deposit");
      } else {
        uint256 claimable = vault._claimableWithdraw(address(fund));
        State expected = claimable > 0 ? State.UNLOCKING : State.PROCESSING;
        assertEq(uint256(actual), uint256(expected), "processing redeem");
      }
      return;
    }

    if (stage == State.RECOVERING) {
      if (order.mode == Mode.DEPOSIT) {
        uint256 claimableFulfilled = vault._claimableMint(address(fund));
        if (claimableFulfilled > 0) {
          assertEq(uint256(actual), uint256(State.UNLOCKING), "recovering deposit: fulfilled");
        } else {
          uint256 claimable = vault._claimableCancelDeposit(address(fund));
          State expected = claimable > 0 ? State.RECOVERING : State.PROCESSING;
          assertEq(uint256(actual), uint256(expected), "recovering deposit");
        }
      } else {
        uint256 claimableFulfilled = vault._claimableWithdraw(address(fund));
        if (claimableFulfilled > 0) {
          assertEq(uint256(actual), uint256(State.UNLOCKING), "recovering redeem: fulfilled");
        } else {
          uint256 claimable = vault._claimableCancelRedeem(address(fund));
          State expected = claimable > 0 ? State.RECOVERING : State.PROCESSING;
          assertEq(uint256(actual), uint256(expected), "recovering redeem");
        }
      }
      return;
    }
  }
}
