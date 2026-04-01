// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ParetoFundFactory} from "src/funds/pareto/ParetoFundFactory.sol";
import {ParetoFund} from "src/funds/pareto/ParetoFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockIdleCDOEpochVariant} from "../../mock/funds/pareto/MockIdleCDOEpochVariant.sol";
import {MockIdleCreditVault} from "../../mock/funds/pareto/MockIdleCreditVault.sol";

contract ParetoFundFactoryTest is Test {
  event FactoryDeployed();
  event FundCreated(address indexed fund, address indexed vault);

  uint256 private constant DEPOSITOR_ROLE = 1 << 1;

  ParetoFundFactory public factory;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockERC20 public aaTranche;
  MockIdleCreditVault public strategy;
  MockIdleCDOEpochVariant public cdo;

  address public owner;
  address public depositor;

  function setUp() public {
    owner = makeAddr("owner");
    depositor = address(this);

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
  }

  function test_Factory_Deploy_EmitsFactoryDeployedEvent() public {
    vm.expectEmit(false, false, false, false);
    emit FactoryDeployed();

    new ParetoFundFactory(owner);
  }

  function test_Factory_DeploysParetoFund() public {
    uint64 nonce = vm.getNonce(address(factory));
    address expectedFundAddress = vm.computeCreateAddress(address(factory), uint256(nonce));
    vm.expectEmit(true, true, false, false, address(factory));
    emit FundCreated(expectedFundAddress, address(cdo));

    address fundAddress = factory.createFund(owner, depositor, address(cdo), address(wrappedShare));
    assertEq(fundAddress, expectedFundAddress, "fund");
    ParetoFund fund = ParetoFund(fundAddress);
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.vault(), address(cdo), "vault");
    assertEq(fund.owner(), owner, "owner");
  }

  function test_Factory_ConfiguresRoles() public {
    address fundAddress = factory.createFund(owner, depositor, address(cdo), address(wrappedShare));
    ParetoFund fund = ParetoFund(fundAddress);
    assertEq(fund.rolesOf(depositor), DEPOSITOR_ROLE, "depositor");
  }

  function test_Factory_MultipleDeployments() public {
    address fundOne = factory.createFund(owner, depositor, address(cdo), address(wrappedShare));
    address fundTwo = factory.createFund(owner, depositor, address(cdo), address(wrappedShare));

    assertTrue(fundOne != fundTwo, "distinct funds");
  }

  function test_Factory_RevertsInvalidDepositor() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, address(1), address(cdo), address(wrappedShare));
  }

  function test_Factory_RevertsInvalidVault() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, depositor, address(1), address(wrappedShare));
  }

  function test_Factory_RevertsInvalidWrappedShare() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, depositor, address(cdo), address(1));
  }

  function test_Factory_RevertsWrappedShareMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    WrappedAsset otherWrappedShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    otherWrappedShare.initialize(owner, owner, address(otherToken), "wOther", "wOTH");

    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    factory.createFund(owner, depositor, address(cdo), address(otherWrappedShare));
  }
}
