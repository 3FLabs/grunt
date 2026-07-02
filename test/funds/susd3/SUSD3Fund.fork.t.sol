// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SUSD3Fund} from "src/funds/susd3/SUSD3Fund.sol";
import {SUSD3FundFactory} from "src/funds/susd3/SUSD3FundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {ISUSD3} from "src/interfaces/integrations/susd3/ISUSD3.sol";
import {IUSD3} from "src/interfaces/integrations/susd3/IUSD3.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";

interface IUSD3Whitelist {
  function whitelistEnabled() external view returns (bool);
  function management() external view returns (address);
  function setWhitelist(address, bool) external;
}

/// @notice Mainnet-fork tests against the real sUSD3/USD3 contracts.
/// @dev Pinned to a block where sUSD3.cooldownDuration() == 30 days and deposits are open. Run with
///      `FOUNDRY_PROFILE=ci forge test --match-path test/funds/susd3/SUSD3Fund.fork.t.sol` (needs ETH_RPC_URL).
contract SUSD3FundForkTest is Test {
  address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
  address private constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

  uint256 private constant FORK_BLOCK = 25_440_000;
  uint256 private constant COOLDOWN = 30 days;
  uint256 private constant DEPOSIT = 2000e6;

  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant OPERATOR_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  SUSD3Fund public fund;
  WrappedAsset public wrappedShare;
  address public owner;
  address public operator;

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

    // Sanity-check the parameters the design depends on.
    assertEq(ISUSD3(SUSD3).lockDuration(), 0, "lock duration");
    assertEq(ISUSD3(SUSD3).cooldownDuration(), COOLDOWN, "cooldown duration");
    assertEq(IUSD3(USD3).minCommitmentTime(), 0, "commitment time");

    owner = makeAddr("owner");
    operator = makeAddr("operator");

    wrappedShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, SUSD3, "wsUSD3", "Wrapped sUSD3");

    SUSD3FundFactory factory = new SUSD3FundFactory(owner);
    fund = SUSD3Fund(factory.createFund(owner, address(this), SUSD3, address(wrappedShare)));

    vm.startPrank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.stopPrank();

    // If USD3 gates deposits behind a whitelist, allow the fund (management-controlled).
    if (IUSD3Whitelist(USD3).whitelistEnabled()) {
      vm.prank(IUSD3Whitelist(USD3).management());
      IUSD3Whitelist(USD3).setWhitelist(address(fund), true);
    }
  }

  function _depositOrder(uint256 amount, bytes32 salt) internal view returns (Order memory) {
    uint256 expected = ISUSD3(SUSD3).convertToShares(IUSD3(USD3).convertToShares(amount));
    return Order({
      mode: Mode.DEPOSIT, owner: address(this), receiver: address(this), input: amount, output: expected, salt: salt
    });
  }

  function _fundDeposit(bytes32 salt) internal returns (uint256 shares) {
    Order memory o = _depositOrder(DEPOSIT, salt);
    deal(USDC, address(this), DEPOSIT);
    IERC20(USDC).approve(address(fund), DEPOSIT);
    fund.create(o);
    fund.commit(o);
    (, shares) = fund.unlock(o);
  }

  function test_Fork_DepositLifecycle() public {
    uint256 shares = _fundDeposit("d1");

    assertGt(shares, 0, "shares minted");
    assertEq(wrappedShare.balanceOf(address(this)), shares, "wsUSD3 to receiver");
    assertEq(IERC20(SUSD3).balanceOf(address(wrappedShare)), shares, "wrapper backing");
    assertEq(IERC20(USDC).balanceOf(address(fund)), 0, "no usdc dust");
    assertEq(IERC20(USD3).balanceOf(address(fund)), 0, "no usd3 dust");
    assertEq(IERC20(SUSD3).balanceOf(address(fund)), 0, "no susd3 dust");

    // totalAssets reports the position back in USDC, within ~1% of the deposit.
    uint256 ta = fund.totalAssets();
    assertApproxEqRel(ta, DEPOSIT, 0.01e18, "totalAssets ~ deposit");
  }

  function test_Fork_RedeemLifecycle() public {
    uint256 shares = _fundDeposit("d1");

    Order memory r = Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: shares,
      output: IUSD3(USD3).convertToAssets(ISUSD3(SUSD3).convertToAssets(shares)),
      salt: "r1"
    });
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);

    // Cooldown not yet matured.
    assertEq(uint256(fund.state(r)), uint256(State.PROCESSING), "cooling down");

    vm.warp(block.timestamp + COOLDOWN + 1);
    assertEq(uint256(fund.state(r)), uint256(State.UNLOCKING), "unlocking");

    uint256 balBefore = IERC20(USDC).balanceOf(address(this));

    // Drain everything the protocol will release (real sUSD3 floor rounding can force partials).
    State s = fund.state(r);
    for (uint256 i; i < 5 && s == State.UNLOCKING; ++i) {
      (s,) = fund.unlock(r);
    }
    uint256 usdcGained = IERC20(USDC).balanceOf(address(this)) - balBefore;
    assertGt(usdcGained, 0, "usdc received");

    // A sub-wei floor-rounding remainder can be stranded (sUSD3.maxRedeem rounds it to 0);
    // the operator recovery path returns it to the receiver as wsUSD3.
    if (s != State.ENDED) {
      vm.prank(operator);
      fund.cancelRedeem(r);
      (State sr, uint256 sharesBack) = fund.recover(r);
      assertEq(uint256(sr), uint256(State.ENDED), "recovered");
      assertGt(wrappedShare.balanceOf(address(this)), 0, "residual returned");
      assertLt(sharesBack, shares / 1000, "residual is dust");
    }

    // The receiver recovers close to the deposit in USDC (any residual is negligible dust).
    assertApproxEqRel(usdcGained, DEPOSIT, 0.02e18, "usdc ~ deposit");
  }

  function test_Fork_CancelRecover() public {
    uint256 shares = _fundDeposit("d1");

    Order memory r = Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: shares,
      output: IUSD3(USD3).convertToAssets(ISUSD3(SUSD3).convertToAssets(shares)),
      salt: "r1"
    });
    wrappedShare.approve(address(fund), shares);
    fund.create(r);
    fund.commit(r);

    vm.prank(operator);
    fund.cancelRedeem(r);
    assertEq(uint256(fund.state(r)), uint256(State.RECOVERING), "recovering");

    (State s, uint256 sharesBack) = fund.recover(r);
    assertEq(uint256(s), uint256(State.ENDED), "ended");
    assertEq(sharesBack, shares, "shares back");
    assertEq(wrappedShare.balanceOf(address(this)), shares, "wsUSD3 restored");
  }

  function test_Fork_MaxDepositReflectsCaps() public {
    // Fund the account generously so the cap (not the balance) binds.
    deal(USDC, address(this), 1_000_000_000e6);

    uint256 max = fund.maxDeposit(address(this));
    uint256 usd3Cap = IUSD3(USD3).maxDeposit(address(fund));
    uint256 susd3CapUsdc = IUSD3(USD3).convertToAssets(ISUSD3(SUSD3).maxDeposit(address(fund)));

    assertGt(max, 0, "deposits are open");
    assertLe(max, usd3Cap, "bounded by usd3 supply cap");
    assertLe(max, susd3CapUsdc, "bounded by susd3 subordination cap");
  }
}
