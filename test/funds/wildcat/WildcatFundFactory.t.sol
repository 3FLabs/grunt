// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WildcatFund} from "src/funds/wildcat/WildcatFund.sol";
import {WildcatFundFactory} from "src/funds/wildcat/WildcatFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockWildcatMarket} from "../../mock/funds/wildcat/MockWildcatMarket.sol";
import {MockWildcat4626Wrapper} from "../../mock/funds/wildcat/MockWildcat4626Wrapper.sol";

contract WildcatFundFactoryTest is Test {
  error InvalidInitialization();

  event FundCreated(address indexed fund, address indexed wrapper);

  WildcatFundFactory public factory;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockWildcatMarket public market;
  MockWildcat4626Wrapper public wrapper;

  address public owner;

  function setUp() public {
    owner = makeAddr("owner");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    market = new MockWildcatMarket(address(usdc));
    wrapper = new MockWildcat4626Wrapper(address(market));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    wrappedShare.initialize(owner, owner, address(wrapper), "wv-WMT", "Wrapped v-WMT");

    factory = new WildcatFundFactory(owner);
  }

  function test_Constructor_DeploysBeacon() public view {
    UpgradeableBeacon beacon = UpgradeableBeacon(factory.WILDCAT_FUND_BEACON());
    assertEq(beacon.owner(), owner, "beacon owner");
    assertTrue(beacon.implementation() != address(0), "implementation set");
  }

  function test_CreateFund_Success() public {
    vm.expectEmit(false, true, false, false, address(factory));
    emit FundCreated(address(0), address(wrapper));
    address fundAddress = factory.createFund(owner, address(this), address(wrapper), address(wrappedShare));

    WildcatFund fund = WildcatFund(fundAddress);
    assertEq(fund.owner(), owner, "owner");
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.market(), address(market), "market");
    assertEq(fund.wrapper(), address(wrapper), "wrapper");
    assertEq(fund.rolesOf(address(this)), 1 << 1, "depositor role");
  }

  function test_CreateFund_RevertWhen_ReinitializingProxy() public {
    address fundAddress = factory.createFund(owner, address(this), address(wrapper), address(wrappedShare));
    vm.expectRevert(InvalidInitialization.selector);
    WildcatFund(fundAddress).initialize(owner, address(this), address(wrapper), address(wrappedShare));
  }

  function test_CreateFund_MultipleIndependentFunds() public {
    address fundA = factory.createFund(owner, address(this), address(wrapper), address(wrappedShare));
    address fundB = factory.createFund(owner, address(this), address(wrapper), address(wrappedShare));
    assertTrue(fundA != fundB, "distinct proxies");
    assertEq(WildcatFund(fundA).market(), WildcatFund(fundB).market(), "same market");
  }

  function test_ImplementationCannotBeInitialized() public {
    UpgradeableBeacon beacon = UpgradeableBeacon(factory.WILDCAT_FUND_BEACON());
    WildcatFund implementation = WildcatFund(beacon.implementation());
    vm.expectRevert(InvalidInitialization.selector);
    implementation.initialize(owner, address(this), address(wrapper), address(wrappedShare));
  }
}
