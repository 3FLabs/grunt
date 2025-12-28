// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {Test} from "forge-std/Test.sol";
import {USCCFundFactory} from "src/funds/USCCFundFactory.sol";
import {USCCFund} from "src/funds/USCCFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAllowlist} from "./mocks/MockAllowlist.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockSuperstateToken} from "./mocks/MockSuperstateToken.sol";

contract USCCFundFactoryTest is Test {
  error InvalidContract(address addr);

  USCCFundFactory public factory;
  WrappedAsset public wuscc;
  MockERC20 public usdc;
  MockSuperstateToken public uscc;
  MockAllowlist public allowlist;
  MockChainlinkOracle public oracle;

  address public owner;
  address public depositor;
  address public recipient;

  function setUp() public {
    owner = makeAddr("owner");
    depositor = address(this);
    recipient = makeAddr("recipient");

    allowlist = new MockAllowlist();
    usdc = new MockERC20("USD Coin", "USDC", 6);
    uscc = new MockSuperstateToken("USCC", "USCC", address(allowlist), address(usdc));
    oracle = new MockChainlinkOracle(6);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wuscc = WrappedAsset(proxy);
    vm.prank(owner);
    wuscc.initialize(owner, owner, "wUSCC", "Wrapped USCC", 6);

    factory = new USCCFundFactory(owner);
  }

  function test_Factory_DeploysUSCCFund() public {
    address fundAddress = factory.createFund(
      owner, depositor, recipient, address(usdc), address(uscc), address(wuscc), address(oracle), 100
    );
    USCCFund fund = USCCFund(fundAddress);
    assertEq(fund.asset(), address(usdc), "usdc");
    assertEq(fund.share(), address(wuscc), "wuscc");
    assertEq(fund.owner(), owner, "owner");
  }

  function test_Factory_DeploysWrappedAsset() public view {
    assertEq(wuscc.owner(), owner, "owner");
    assertEq(wuscc.symbol(), "wUSCC", "symbol");
  }

  function test_Factory_ConfiguresRoles() public {
    address fundAddress = factory.createFund(
      owner, depositor, recipient, address(usdc), address(uscc), address(wuscc), address(oracle), 100
    );
    USCCFund fund = USCCFund(fundAddress);
    assertEq(fund.rolesOf(depositor), fund.DEPOSITOR_ROLE(), "depositor");
  }

  function test_Factory_MultipleDeployments() public {
    address fundOne = factory.createFund(
      owner, depositor, recipient, address(usdc), address(uscc), address(wuscc), address(oracle), 100
    );
    address fundTwo = factory.createFund(
      owner, depositor, recipient, address(usdc), address(uscc), address(wuscc), address(oracle), 100
    );

    assertTrue(fundOne != fundTwo, "distinct funds");
  }

  function test_Factory_RevertsInvalidContracts() public {
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(1)));
    factory.createFund(owner, address(1), recipient, address(usdc), address(uscc), address(wuscc), address(oracle), 100);
  }

  function test_Factory_RevertsInvalidUsdc() public {
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(1)));
    factory.createFund(
      owner, depositor, recipient, address(1), address(uscc), address(wuscc), address(oracle), 100
    );
  }

  function test_Factory_RevertsInvalidUscc() public {
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(1)));
    factory.createFund(
      owner, depositor, recipient, address(usdc), address(1), address(wuscc), address(oracle), 100
    );
  }

  function test_Factory_RevertsInvalidWrappedAsset() public {
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(1)));
    factory.createFund(
      owner, depositor, recipient, address(usdc), address(uscc), address(1), address(oracle), 100
    );
  }

  function test_Factory_RevertsInvalidOracle() public {
    vm.expectRevert(abi.encodeWithSelector(InvalidContract.selector, address(1)));
    factory.createFund(
      owner, depositor, recipient, address(usdc), address(uscc), address(wuscc), address(1), 100
    );
  }
}
