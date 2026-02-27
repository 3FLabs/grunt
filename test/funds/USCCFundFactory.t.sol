// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {USCCFundFactory} from "src/funds/USCCFundFactory.sol";
import {USCCFund} from "src/funds/USCCFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";

import {MockERC20} from "../mock/MockERC20.sol";
import {MockAllowlist} from "../mock/funds/MockAllowlist.sol";
import {MockChainlinkOracle} from "../mock/funds/MockChainlinkOracle.sol";
import {MockSuperstateToken} from "../mock/funds/MockSuperstateToken.sol";

contract USCCFundFactoryTest is Test {
  event FactoryDeployed(address indexed usdc, address indexed uscc, address indexed wrappedAsset);
  event FundCreated(address indexed fund, address indexed recipient);

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
    // Initialize oracle with valid data since USCCFund.initialize() now reads from it
    oracle.setRoundData(1, int256(1e6), block.timestamp, 1);
    oracle.setLatestRound(1);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wuscc = WrappedAsset(proxy);
    vm.prank(owner);
    wuscc.initialize(owner, owner, address(uscc), "wUSCC", "Wrapped USCC");

    factory = new USCCFundFactory(owner, address(usdc), address(uscc), address(wuscc));
  }

  function test_Factory_Deploy_EmitsFactoryDeployedEvent() public {
    uint64 nonce = vm.getNonce(address(this));
    address expectedFactory = vm.computeCreateAddress(address(this), uint256(nonce));

    vm.expectEmit(true, true, true, false, expectedFactory);
    emit FactoryDeployed(address(usdc), address(uscc), address(wuscc));

    new USCCFundFactory(owner, address(usdc), address(uscc), address(wuscc));
  }

  function test_Factory_DeploysUSCCFund() public {
    uint64 nonce = vm.getNonce(address(factory));
    address expectedFundAddress = vm.computeCreateAddress(address(factory), uint256(nonce));
    vm.expectEmit(true, true, false, false, address(factory));
    emit FundCreated(expectedFundAddress, recipient);

    address fundAddress = factory.createFund(owner, depositor, recipient, address(oracle));
    assertEq(fundAddress, expectedFundAddress, "fund");
    USCCFund fund = USCCFund(fundAddress);
    assertEq(fund.asset(), address(usdc), "usdc");
    assertEq(fund.share(), address(wuscc), "wuscc");
    assertEq(fund.owner(), owner, "owner");
  }

  function test_Setup_WrappedAssetInitialized() public view {
    assertEq(wuscc.owner(), owner, "owner");
    assertEq(wuscc.symbol(), "wUSCC", "symbol");
  }

  function test_Factory_ConfiguresRoles() public {
    address fundAddress = factory.createFund(owner, depositor, recipient, address(oracle));
    USCCFund fund = USCCFund(fundAddress);
    assertEq(fund.rolesOf(depositor), 1 << 1, "depositor");
  }

  function test_Factory_MultipleDeployments() public {
    address fundOne = factory.createFund(owner, depositor, recipient, address(oracle));
    address fundTwo = factory.createFund(owner, depositor, recipient, address(oracle));

    assertTrue(fundOne != fundTwo, "distinct funds");
  }

  function test_Factory_RevertsInvalidContracts() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, address(1), recipient, address(oracle));
  }

  function test_Factory_RevertsInvalidUsdc() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    new USCCFundFactory(owner, address(1), address(uscc), address(wuscc));
  }

  function test_Factory_RevertsInvalidUscc() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    new USCCFundFactory(owner, address(usdc), address(1), address(wuscc));
  }

  function test_Factory_RevertsInvalidWrappedAsset() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    new USCCFundFactory(owner, address(usdc), address(uscc), address(1));
  }

  function test_Factory_RevertsInvalidOracle() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, depositor, recipient, address(1));
  }
}
