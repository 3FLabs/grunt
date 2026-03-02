// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ParetoFund} from "src/funds/pareto/ParetoFund.sol";
import {ParetoFundFactory} from "src/funds/pareto/ParetoFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockIdleCDOEpochVariant} from "../../mock/funds/pareto/MockIdleCDOEpochVariant.sol";
import {MockIdleCreditVault} from "../../mock/funds/pareto/MockIdleCreditVault.sol";
import {ParetoFundHandler} from "test/mock/funds/pareto/ParetoFundHandler.sol";

contract ParetoFundFuzzTest is Test {
  using LibOrder for Order;

  uint256 private constant ONE_USDC = 1e6;
  uint256 private constant ONE_AA = 1e18;

  // WrappedAsset roles
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  ParetoFundFactory public factory;
  ParetoFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockERC20 public aaTranche;
  MockIdleCreditVault public strategy;
  MockIdleCDOEpochVariant public cdo;

  address public owner;

  function setUp() public {
    owner = makeAddr("owner");

    usdc = new MockERC20("USDC", "USDC", 6);
    aaTranche = new MockERC20("AA Tranche", "AA", 18);
    strategy = new MockIdleCreditVault();
    cdo = new MockIdleCDOEpochVariant(address(usdc), address(aaTranche), address(strategy));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(aaTranche), "wAA", "Wrapped AA");

    factory = new ParetoFundFactory(owner);
    address fundAddr = factory.createFund(owner, address(this), address(cdo), address(wrappedShare));
    fund = ParetoFund(fundAddr);

    cdo.setWalletAllowed(address(fund), true);
    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    vm.prank(owner);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FUZZ: DEPOSIT UNLOCK                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_DepositUnlock_Succeeds(uint96 input) public {
    uint256 inputAmount = bound(uint256(input), 1, type(uint96).max);
    // At virtualPrice=1e18, depositAA mints inputAmount * 1e18 / 1e18 = inputAmount AA tokens
    // But AA is 18 decimals, USDC is 6 decimals, so mint = inputAmount * 1e12
    uint256 expectedAA = inputAmount * 1e12;

    Order memory order = _depositOrder(inputAmount, expectedAA);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    // depositAA already minted AA to fund, state should be UNLOCKING
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    (State newState, uint256 amount) = fund.unlock(order);

    assertEq(amount, expectedAA, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), expectedAA, "wShare minted");
    assertEq(aaTranche.balanceOf(address(wrappedShare)), expectedAA, "aa in wShare");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FUZZ: REDEEM UNLOCK                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_RedeemUnlock_Succeeds(uint96 input) public {
    uint256 inputUsdc = bound(uint256(input), 1, type(uint96).max);
    uint256 aaAmount = inputUsdc * 1e12;

    // First deposit to get wrapped shares
    _depositAndUnlock(inputUsdc);

    // Redeem
    Order memory order = _redeemOrder(aaAmount, inputUsdc);
    fund.create(order);
    wrappedShare.approve(address(fund), aaAmount);
    fund.commit(order);

    // Advance epoch
    uint256 pendingAmount = strategy.withdrawsRequests(address(fund));
    cdo.fundUnderlying(pendingAmount);
    cdo.advanceEpoch();

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    (State newState, uint256 amount) = fund.unlock(order);

    assertEq(amount, inputUsdc, "amount");
    assertEq(usdc.balanceOf(address(this)), inputUsdc, "usdc received");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                FUZZ: DEPOSIT RESOLVE THEN UNLOCK              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_DepositResolveThenUnlock(uint96 input, uint96 resolvedOutput) public {
    uint256 inputAmount = bound(uint256(input), 1, type(uint96).max);
    uint256 expectedAA = inputAmount * 1e12;
    // Make the order expect much more output so it stays PROCESSING
    uint256 highOutput = expectedAA * 2;

    Order memory order = _depositOrder(inputAmount, highOutput);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    // Fund has expectedAA but order expects highOutput → PROCESSING
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing");

    // Resolve to match or lower than actual balance
    uint256 resolvedOut = bound(uint256(resolvedOutput), 1, expectedAA);
    vm.prank(owner);
    fund.resolve(order, inputAmount, resolvedOut);

    // Now balance >= resolvedOutput → UNLOCKING
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    (State newState, uint256 amount) = fund.unlock(order);
    assertEq(amount, expectedAA, "full balance unlocked");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                FUZZ: TOTAL ASSETS VARYING PRICE               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_TotalAssets_VaryingVirtualPrice(uint64 rawPrice) public {
    uint256 price = bound(uint256(rawPrice), 0.5e18, 2e18);

    // Deposit at default 1e18 price
    uint256 inputUsdc = ONE_USDC;
    _depositAndUnlock(inputUsdc);

    uint256 supply = wrappedShare.totalSupply();
    assertEq(supply, ONE_AA, "supply");

    // Change virtualPrice
    cdo.setVirtualPrice(price);
    uint256 expected = supply * price / 1e18;
    assertEq(fund.totalAssets(), expected, "totalAssets");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                FUZZ: ARCHIVED ORDER REMAINS ENDED             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_ArchivedEndedOrderRemainsEnded(uint96 input, uint96 nextInput) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount - 1);
    uint256 nextInputAmount = bound(uint256(nextInput), 1, maxAmount);
    if (nextInputAmount == inputAmount) nextInputAmount = inputAmount + 1;

    uint256 aaAmount = inputAmount * 1e12;
    uint256 nextAaAmount = nextInputAmount * 1e12;

    Order memory order = _depositOrder(inputAmount, aaAmount);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    // depositAA mints exactly aaAmount at 1:1, so state = UNLOCKING
    fund.unlock(order);

    Order memory nextOrder = _depositOrderWithSalt(nextInputAmount, nextAaAmount, keccak256("next"));
    fund.create(nextOrder);

    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "archived order ended");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                             */
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

  function _depositAndUnlock(uint256 usdcAmount) internal {
    uint256 aaAmount = usdcAmount * 1e12;
    Order memory order = _depositOrder(usdcAmount, aaAmount);
    fund.create(order);
    usdc.mint(address(this), usdcAmount);
    usdc.approve(address(fund), usdcAmount);
    fund.commit(order);
    fund.unlock(order);
  }
}

contract ParetoFundInvariantTest is StdInvariant, Test {
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  ParetoFundFactory public factory;
  ParetoFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockERC20 public aaTranche;
  MockIdleCreditVault public strategy;
  MockIdleCDOEpochVariant public cdo;

  ParetoFundHandler public handler;

  address public owner;

  function setUp() public {
    owner = makeAddr("owner");

    usdc = new MockERC20("USDC", "USDC", 6);
    aaTranche = new MockERC20("AA Tranche", "AA", 18);
    strategy = new MockIdleCreditVault();
    cdo = new MockIdleCDOEpochVariant(address(usdc), address(aaTranche), address(strategy));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(aaTranche), "wAA", "Wrapped AA");

    handler = new ParetoFundHandler();

    factory = new ParetoFundFactory(owner);
    address fundAddr = factory.createFund(owner, address(handler), address(cdo), address(wrappedShare));
    fund = ParetoFund(fundAddr);

    cdo.setWalletAllowed(address(fund), true);

    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    vm.prank(owner);
    wrappedShare.grantRoles(address(handler), SENDER_ROLE);

    uint256 operatorRole = fund.OPERATOR_ROLE();
    vm.prank(owner);
    fund.grantRoles(address(handler), operatorRole);

    handler.initialize(fund, usdc, aaTranche, wrappedShare, cdo, strategy);

    bytes4[] memory selectors = new bytes4[](8);
    selectors[0] = handler.act_createDeposit.selector;
    selectors[1] = handler.act_createRedeem.selector;
    selectors[2] = handler.act_cancel.selector;
    selectors[3] = handler.act_commit.selector;
    selectors[4] = handler.act_cdoFulfillDeposit.selector;
    selectors[5] = handler.act_cdoFulfillRedeem.selector;
    selectors[6] = handler.act_resolve.selector;
    selectors[7] = handler.act_unlock.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  function invariant_FundDoesNotHoldWrappedShares() public view {
    assertEq(wrappedShare.balanceOf(address(fund)), 0, "fund holds wrappedShare");
  }

  function invariant_WrappedShareSupplyMatchesUnderlying() public view {
    assertEq(wrappedShare.totalSupply(), aaTranche.balanceOf(address(wrappedShare)), "wShare supply mismatch");
  }

  function invariant_TotalAssetsConsistent() public view {
    uint256 supply = wrappedShare.totalSupply();
    uint256 price = cdo.virtualPrice(address(aaTranche));
    uint256 expected = supply * price / 1e18;
    assertEq(fund.totalAssets(), expected, "totalAssets mismatch");
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
      // State can be PROCESSING or UNLOCKING depending on CDO state
      assertTrue(
        uint256(actual) == uint256(State.PROCESSING) || uint256(actual) == uint256(State.UNLOCKING),
        "processing or unlocking"
      );
      return;
    }
  }
}
