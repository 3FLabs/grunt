// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SUSD3FundFactory} from "src/funds/susd3/SUSD3FundFactory.sol";
import {SUSD3Fund} from "src/funds/susd3/SUSD3Fund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockUSD3} from "../../mock/funds/susd3/MockUSD3.sol";
import {MockSUSD3} from "../../mock/funds/susd3/MockSUSD3.sol";

contract SUSD3FundFactoryTest is Test {
  event FactoryDeployed();
  event FundCreated(address indexed fund, address indexed susd3);

  uint256 private constant DEPOSITOR_ROLE = 1 << 1;

  SUSD3FundFactory public factory;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockUSD3 public usd3;
  MockSUSD3 public susd3;

  address public owner;
  address public depositor;

  function setUp() public {
    owner = makeAddr("owner");
    depositor = address(this);

    usdc = new MockERC20("USD Coin", "USDC", 6);
    usd3 = new MockUSD3(address(usdc));
    susd3 = new MockSUSD3(address(usd3));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(susd3), "wsUSD3", "Wrapped sUSD3");

    factory = new SUSD3FundFactory(owner);
  }

  function test_Factory_Deploy_EmitsFactoryDeployedEvent() public {
    vm.expectEmit(false, false, false, false);
    emit FactoryDeployed();

    new SUSD3FundFactory(owner);
  }

  function test_Factory_DeploysSUSD3Fund() public {
    uint64 nonce = vm.getNonce(address(factory));
    address expectedFundAddress = vm.computeCreateAddress(address(factory), uint256(nonce));
    vm.expectEmit(true, true, false, false, address(factory));
    emit FundCreated(expectedFundAddress, address(susd3));

    address fundAddress = factory.createFund(owner, depositor, address(susd3), address(wrappedShare));
    assertEq(fundAddress, expectedFundAddress, "fund");
    SUSD3Fund fund = SUSD3Fund(fundAddress);
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.susd3(), address(susd3), "susd3");
    assertEq(fund.usd3(), address(usd3), "usd3");
    assertEq(fund.vault(), address(susd3), "vault");
    assertEq(fund.owner(), owner, "owner");
  }

  function test_Factory_ConfiguresRoles() public {
    address fundAddress = factory.createFund(owner, depositor, address(susd3), address(wrappedShare));
    SUSD3Fund fund = SUSD3Fund(fundAddress);
    assertEq(fund.rolesOf(depositor), DEPOSITOR_ROLE, "depositor");
  }

  function test_Factory_MultipleDeployments() public {
    address fundOne = factory.createFund(owner, depositor, address(susd3), address(wrappedShare));
    address fundTwo = factory.createFund(owner, depositor, address(susd3), address(wrappedShare));

    assertTrue(fundOne != fundTwo, "distinct funds");
  }

  function test_Factory_RevertsInvalidDepositor() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, address(1), address(susd3), address(wrappedShare));
  }

  function test_Factory_RevertsInvalidSusd3() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, depositor, address(1), address(wrappedShare));
  }

  function test_Factory_RevertsInvalidWrappedShare() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, depositor, address(susd3), address(1));
  }

  function test_Factory_RevertsWrappedShareMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 6);
    WrappedAsset otherWrappedShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    otherWrappedShare.initialize(owner, owner, address(otherToken), "wOther", "wOTH");

    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    factory.createFund(owner, depositor, address(susd3), address(otherWrappedShare));
  }

  function test_Factory_RevertsInvalidOwner() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.SUSD3_FUND_BEACON());
    vm.expectRevert(CommonErrors.AddressZero.selector);
    SUSD3Fund(fundProxy).initialize(address(0), depositor, address(susd3), address(wrappedShare));
  }
}
