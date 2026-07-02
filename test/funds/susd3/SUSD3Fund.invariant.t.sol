// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SUSD3Fund} from "src/funds/susd3/SUSD3Fund.sol";
import {SUSD3FundFactory} from "src/funds/susd3/SUSD3FundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockUSD3} from "../../mock/funds/susd3/MockUSD3.sol";
import {MockSUSD3} from "../../mock/funds/susd3/MockSUSD3.sol";
import {SUSD3FundHandler} from "../../mock/funds/susd3/SUSD3FundHandler.sol";

contract SUSD3FundInvariantTest is Test {
  uint256 private constant MIN_DEPOSIT = 1000e6;
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant OPERATOR_ROLE = 1 << 0;

  SUSD3Fund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockUSD3 public usd3;
  MockSUSD3 public susd3;
  SUSD3FundHandler public handler;

  function setUp() public {
    address owner = makeAddr("owner");
    address operator = makeAddr("operator");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    usd3 = new MockUSD3(address(usdc));
    susd3 = new MockSUSD3(address(usd3));
    usd3.setMinDeposit(MIN_DEPOSIT);

    wrappedShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(susd3), "wsUSD3", "Wrapped sUSD3");

    SUSD3FundFactory factory = new SUSD3FundFactory(owner);
    handler = new SUSD3FundHandler();
    fund = SUSD3Fund(factory.createFund(owner, address(handler), address(susd3), address(wrappedShare)));

    vm.startPrank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.stopPrank();

    handler.initialize(fund, usdc, usd3, susd3, wrappedShare, operator);
    targetContract(address(handler));
  }

  /// @dev The wrapper always custodies exactly one sUSD3 per outstanding wsUSD3.
  function invariant_wrapperFullyBacked() public view {
    assertEq(wrappedShare.totalSupply(), susd3.balanceOf(address(wrappedShare)), "wrapper backing");
  }

  /// @dev Between orders the fund is a clean pass-through holding no tokens.
  function invariant_fundIdleHoldsNothing() public view {
    if (!handler.hasOrder()) {
      assertEq(usdc.balanceOf(address(fund)), 0, "no idle usdc");
      assertEq(usd3.balanceOf(address(fund)), 0, "no idle usd3");
      assertEq(susd3.balanceOf(address(fund)), 0, "no idle susd3");
    }
  }
}
