// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {MidasFundFactory} from "src/funds/midas/MidasFundFactory.sol";
import {MidasFund} from "src/funds/midas/MidasFund.sol";
import {SettlementMode} from "src/interfaces/funds/midas/IMidasFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Mode} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockMidasDataFeed} from "../../mock/funds/midas/MockMidasDataFeed.sol";
import {MockMidasAccessControl} from "../../mock/funds/midas/MockMidasAccessControl.sol";
import {MockMidasDepositVault} from "../../mock/funds/midas/MockMidasDepositVault.sol";
import {MockMidasRedemptionVault} from "../../mock/funds/midas/MockMidasRedemptionVault.sol";

contract MidasFundFactoryTest is Test {
  event FactoryDeployed();
  event FundCreated(address indexed fund, address indexed depositVault, address indexed redemptionVault);

  uint256 private constant DEPOSITOR_ROLE = 1 << 1;

  MidasFundFactory public factory;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockERC20 public mGlobal;
  MockMidasAccessControl public midasAcl;
  MockMidasDataFeed public depositMTokenFeed;
  MockMidasDataFeed public depositAssetFeed;
  MockMidasDataFeed public redemptionMTokenFeed;
  MockMidasDataFeed public redemptionAssetFeed;
  MockMidasDepositVault public depositVault;
  MockMidasRedemptionVault public redemptionVault;

  address public owner;
  address public depositor;

  function setUp() public {
    owner = makeAddr("owner");
    depositor = address(this);

    usdc = new MockERC20("USD Coin", "USDC", 6);
    mGlobal = new MockERC20("Midas Global", "mGLOBAL", 18);
    midasAcl = new MockMidasAccessControl();
    depositMTokenFeed = new MockMidasDataFeed();
    depositAssetFeed = new MockMidasDataFeed();
    redemptionMTokenFeed = new MockMidasDataFeed();
    redemptionAssetFeed = new MockMidasDataFeed();

    depositVault = new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    redemptionVault = new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    depositVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);
    redemptionVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(mGlobal), "wmGLOBAL", "Wrapped mGLOBAL");

    factory = new MidasFundFactory(owner);
  }

  function test_Factory_Deploy_EmitsFactoryDeployedEvent() public {
    vm.expectEmit(false, false, false, false);
    emit FactoryDeployed();

    new MidasFundFactory(owner);
  }

  function test_Factory_DeploysMidasFund() public {
    uint64 nonce = vm.getNonce(address(factory));
    address expectedFundAddress = vm.computeCreateAddress(address(factory), uint256(nonce));
    vm.expectEmit(true, true, true, false, address(factory));
    emit FundCreated(expectedFundAddress, address(depositVault), address(redemptionVault));

    address fundAddress = _createFund(SettlementMode.INSTANT, SettlementMode.INSTANT);
    assertEq(fundAddress, expectedFundAddress, "fund");
    MidasFund fund = MidasFund(fundAddress);
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.mToken(), address(mGlobal), "mToken");
    assertEq(fund.depositVault(), address(depositVault), "deposit vault");
    assertEq(fund.redemptionVault(), address(redemptionVault), "redemption vault");
    assertEq(fund.owner(), owner, "owner");
  }

  function test_Factory_ConfiguresRoles() public {
    address fundAddress = _createFund(SettlementMode.INSTANT, SettlementMode.INSTANT);
    MidasFund fund = MidasFund(fundAddress);
    assertEq(fund.rolesOf(depositor), DEPOSITOR_ROLE, "depositor");
  }

  function test_Factory_ConfiguresSettlementModes() public {
    MidasFund fund = MidasFund(_createFund(SettlementMode.REQUEST, SettlementMode.INSTANT));
    assertEq(uint256(fund.settlementMode(Mode.DEPOSIT)), uint256(SettlementMode.REQUEST), "deposit mode");
    assertEq(uint256(fund.settlementMode(Mode.REDEEM)), uint256(SettlementMode.INSTANT), "redeem mode");

    MidasFund fund2 = MidasFund(_createFund(SettlementMode.INSTANT, SettlementMode.REQUEST));
    assertEq(uint256(fund2.settlementMode(Mode.DEPOSIT)), uint256(SettlementMode.INSTANT), "deposit mode 2");
    assertEq(uint256(fund2.settlementMode(Mode.REDEEM)), uint256(SettlementMode.REQUEST), "redeem mode 2");
  }

  function test_Factory_MultipleDeployments() public {
    address fundOne = _createFund(SettlementMode.INSTANT, SettlementMode.INSTANT);
    address fundTwo = _createFund(SettlementMode.INSTANT, SettlementMode.INSTANT);

    assertTrue(fundOne != fundTwo, "distinct funds");
  }

  function test_Factory_RevertsInvalidDepositor() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(
      owner,
      address(1),
      address(depositVault),
      address(redemptionVault),
      address(wrappedShare),
      address(usdc),
      SettlementMode.INSTANT,
      SettlementMode.INSTANT
    );
  }

  function test_Factory_RevertsInvalidDepositVault() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(
      owner,
      depositor,
      address(1),
      address(redemptionVault),
      address(wrappedShare),
      address(usdc),
      SettlementMode.INSTANT,
      SettlementMode.INSTANT
    );
  }

  function test_Factory_RevertsInvalidRedemptionVault() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(
      owner,
      depositor,
      address(depositVault),
      address(1),
      address(wrappedShare),
      address(usdc),
      SettlementMode.INSTANT,
      SettlementMode.INSTANT
    );
  }

  function test_Factory_RevertsInvalidWrappedShare() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(
      owner,
      depositor,
      address(depositVault),
      address(redemptionVault),
      address(1),
      address(usdc),
      SettlementMode.INSTANT,
      SettlementMode.INSTANT
    );
  }

  function test_Factory_RevertsInvalidAsset() public {
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(1)));
    factory.createFund(
      owner,
      depositor,
      address(depositVault),
      address(redemptionVault),
      address(wrappedShare),
      address(1),
      SettlementMode.INSTANT,
      SettlementMode.INSTANT
    );
  }

  function test_Factory_RevertsWrappedShareMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    WrappedAsset otherWrappedShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    otherWrappedShare.initialize(owner, owner, address(otherToken), "wOther", "wOTH");

    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    factory.createFund(
      owner,
      depositor,
      address(depositVault),
      address(redemptionVault),
      address(otherWrappedShare),
      address(usdc),
      SettlementMode.INSTANT,
      SettlementMode.INSTANT
    );
  }

  function test_Factory_RevertsRedemptionVaultMTokenMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    MockMidasRedemptionVault otherRedemptionVault =
      new MockMidasRedemptionVault(address(otherToken), address(redemptionMTokenFeed), address(midasAcl));

    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    factory.createFund(
      owner,
      depositor,
      address(depositVault),
      address(otherRedemptionVault),
      address(wrappedShare),
      address(usdc),
      SettlementMode.INSTANT,
      SettlementMode.INSTANT
    );
  }

  function _createFund(SettlementMode depositMode, SettlementMode redeemMode) internal returns (address) {
    return factory.createFund(
      owner,
      depositor,
      address(depositVault),
      address(redemptionVault),
      address(wrappedShare),
      address(usdc),
      depositMode,
      redeemMode
    );
  }
}
