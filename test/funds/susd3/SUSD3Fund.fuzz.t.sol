// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SUSD3Fund} from "src/funds/susd3/SUSD3Fund.sol";
import {SUSD3FundFactory} from "src/funds/susd3/SUSD3FundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockUSD3} from "../../mock/funds/susd3/MockUSD3.sol";
import {MockSUSD3} from "../../mock/funds/susd3/MockSUSD3.sol";

contract SUSD3FundFuzzTest is Test {
  uint256 private constant MIN_DEPOSIT = 1000e6;
  uint256 private constant MAX_DEPOSIT = 10_000_000e6;
  uint256 private constant COOLDOWN = 30 days;
  uint256 private constant BPS = 10_000;
  uint256 private constant MAX_OUTPUT_DEVIATION = 500;

  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  SUSD3Fund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockUSD3 public usd3;
  MockSUSD3 public susd3;
  address public owner;

  function setUp() public {
    owner = makeAddr("owner");
    usdc = new MockERC20("USD Coin", "USDC", 6);
    usd3 = new MockUSD3(address(usdc));
    susd3 = new MockSUSD3(address(usd3));
    usd3.setMinDeposit(MIN_DEPOSIT);

    wrappedShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(susd3), "wsUSD3", "Wrapped sUSD3");

    SUSD3FundFactory factory = new SUSD3FundFactory(owner);
    fund = SUSD3Fund(factory.createFund(owner, address(this), address(susd3), address(wrappedShare)));

    vm.startPrank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
    vm.stopPrank();
  }

  function _deposit(uint256 amount) internal returns (uint256 shares) {
    uint256 expected = susd3.convertToShares(usd3.convertToShares(amount));
    Order memory o = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: expected,
      salt: bytes32(uint256(1))
    });
    usdc.mint(address(this), amount);
    usdc.approve(address(fund), amount);
    fund.create(o);
    fund.commit(o);
    (, shares) = fund.unlock(o);
  }

  /// @dev A clean deposit→redeem round trip conserves USDC exactly at a 1:1 rate.
  function testFuzz_RoundTripConserves(uint256 amount) public {
    amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);
    uint256 shares = _deposit(amount);

    Order memory r = Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: shares,
      output: amount,
      salt: bytes32(uint256(2))
    });
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);
    vm.warp(block.timestamp + COOLDOWN + 1);
    (State s, uint256 usdcOut) = fund.unlock(r);

    assertEq(uint256(s), uint256(State.ENDED), "ended");
    assertEq(usdcOut, amount, "round trip conserves");
  }

  /// @dev Yield accrued during cooldown can only increase the redeemed amount.
  function testFuzz_YieldIsMonotonic(uint256 amount, uint256 yield) public {
    amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);
    yield = bound(yield, 0, amount);
    uint256 shares = _deposit(amount);

    Order memory r = Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: shares,
      output: amount,
      salt: bytes32(uint256(2))
    });
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);

    // USD3 accrues yield during the cooldown.
    usdc.mint(address(usd3), yield);

    vm.warp(block.timestamp + COOLDOWN + 1);
    (, uint256 usdcOut) = fund.unlock(r);
    assertGe(usdcOut, amount, "yield never reduces output");
  }

  /// @dev The slippage guard reverts exactly when output is more than 5% below the current rate.
  function testFuzz_SlippageBoundary(uint256 amount, uint256 output) public {
    amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);
    uint256 expected = susd3.convertToShares(usd3.convertToShares(amount));
    output = bound(output, 0, expected);

    Order memory o = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: output,
      salt: bytes32(uint256(1))
    });

    bool shouldRevert = expected - output > expected * MAX_OUTPUT_DEVIATION / BPS;
    if (shouldRevert) {
      vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
      fund.create(o);
    } else {
      assertEq(uint256(fund.create(o)), uint256(State.ACCEPTED), "accepted within tolerance");
    }
  }
}
