// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentrifugeFundFactory} from "src/funds/centrifuge/CentrifugeFundFactory.sol";
import {CentrifugeFund} from "src/funds/centrifuge/CentrifugeFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockCentrifugeVault} from "../../mock/funds/centrifuge/MockCentrifugeVault.sol";

contract CentrifugeFundFactoryTest is Test {
  event FactoryDeployed();
  event FundCreated(address indexed fund, address indexed vault);

  CentrifugeFundFactory public factory;
  WrappedAsset public wrappedShare;
  MockERC20 public assetToken;
  MockERC20 public shareToken;
  MockCentrifugeVault public vault;

  address public owner;
  address public depositor;

  function setUp() public {
    owner = makeAddr("owner");
    depositor = address(this);

    assetToken = new MockERC20("USDC", "USDC", 6);
    shareToken = new MockERC20("Share", "SHR", 6);
    vault = new MockCentrifugeVault(address(assetToken), address(shareToken));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(shareToken), "wShare", "wSHR");

    factory = new CentrifugeFundFactory(owner);
  }

  function test_Factory_Deploy_EmitsFactoryDeployedEvent() public {
    vm.expectEmit(false, false, false, false);
    emit FactoryDeployed();

    new CentrifugeFundFactory(owner);
  }

  function test_Factory_DeploysCentrifugeFund() public {
    uint64 nonce = vm.getNonce(address(factory));
    address expectedFundAddress = vm.computeCreateAddress(address(factory), uint256(nonce));
    vm.expectEmit(true, true, false, false, address(factory));
    emit FundCreated(expectedFundAddress, address(vault));

    address fundAddress = factory.createFund(owner, depositor, address(vault), address(wrappedShare));
    assertEq(fundAddress, expectedFundAddress, "fund");
    CentrifugeFund fund = CentrifugeFund(fundAddress);
    assertEq(fund.asset(), address(assetToken), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.vault(), address(vault), "vault");
    assertEq(fund.owner(), owner, "owner");
  }

  function test_Factory_ConfiguresRoles() public {
    address fundAddress = factory.createFund(owner, depositor, address(vault), address(wrappedShare));
    CentrifugeFund fund = CentrifugeFund(fundAddress);
    assertEq(fund.rolesOf(depositor), fund.DEPOSITOR_ROLE(), "depositor");
  }

  function test_Factory_MultipleDeployments() public {
    address fundOne = factory.createFund(owner, depositor, address(vault), address(wrappedShare));
    address fundTwo = factory.createFund(owner, depositor, address(vault), address(wrappedShare));

    assertTrue(fundOne != fundTwo, "distinct funds");
  }

  function test_Factory_RevertsInvalidDepositor() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, address(1), address(vault), address(wrappedShare));
  }

  function test_Factory_RevertsInvalidVault() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, depositor, address(1), address(wrappedShare));
  }

  function test_Factory_RevertsInvalidWrappedShare() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(owner, depositor, address(vault), address(1));
  }

  function test_Factory_RevertsWrappedShareMismatch() public {
    MockERC20 otherShareToken = new MockERC20("Other", "OTH", 6);
    WrappedAsset otherWrappedShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    otherWrappedShare.initialize(owner, owner, address(otherShareToken), "wOther", "wOTH");

    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    factory.createFund(owner, depositor, address(vault), address(otherWrappedShare));
  }
}
