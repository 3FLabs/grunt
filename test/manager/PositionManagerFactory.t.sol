// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManagerFactory} from "src/manager/PositionManagerFactory.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {ERC20Mock} from "lib/morpho-blue/src/mocks/ERC20Mock.sol";

/// @title PositionManagerFactoryTest
/// @notice Test suite for PositionManagerFactory contract
contract PositionManagerFactoryTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  PositionManagerFactory public factory;
  ERC20Mock public collateralToken;
  ERC20Mock public debtToken;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public beaconOwner;
  address public positionManagerOwner;
  address public user;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant DEFAULT_LLTV = 0.7e18; // 70% LLTV

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  event PositionManagerCreated(
    address indexed positionManager,
    address indexed owner,
    address indexed collateralAsset,
    address debtAsset,
    uint256 lltv
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    // Create test addresses
    beaconOwner = makeAddr("beaconOwner");
    positionManagerOwner = makeAddr("positionManagerOwner");
    user = makeAddr("user");

    // Deploy mock tokens
    collateralToken = new ERC20Mock();
    vm.label(address(collateralToken), "CollateralToken");

    debtToken = new ERC20Mock();
    vm.label(address(debtToken), "DebtToken");

    // Deploy factory
    factory = new PositionManagerFactory(beaconOwner);
    vm.label(address(factory), "PositionManagerFactory");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONSTRUCTOR TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_constructor_deploysBeacon() public view {
    address beacon = factory.POSITION_MANAGER_BEACON();
    assertTrue(beacon != address(0), "Beacon should be deployed");
  }

  function test_constructor_beaconHasCorrectOwner() public view {
    address beacon = factory.POSITION_MANAGER_BEACON();
    assertEq(UpgradeableBeacon(beacon).owner(), beaconOwner, "Beacon owner should be set correctly");
  }

  function test_constructor_beaconHasImplementation() public view {
    address beacon = factory.POSITION_MANAGER_BEACON();
    address implementation = UpgradeableBeacon(beacon).implementation();
    assertTrue(implementation != address(0), "Beacon should have implementation");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                CREATE POSITION MANAGER TESTS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_createPositionManager_deploysProxy() public {
    address positionManager = factory.createPositionManager(
      positionManagerOwner,
      "Test Position Manager",
      "TPM",
      18,
      address(collateralToken),
      address(debtToken),
      DEFAULT_LLTV
    );

    assertTrue(positionManager != address(0), "Position manager should be deployed");
  }

  function test_createPositionManager_initializesCorrectly() public {
    address positionManager = factory.createPositionManager(
      positionManagerOwner,
      "Test Position Manager",
      "TPM",
      18,
      address(collateralToken),
      address(debtToken),
      DEFAULT_LLTV
    );

    PositionManager pm = PositionManager(positionManager);

    assertEq(pm.owner(), positionManagerOwner, "Owner should be set");
    assertEq(pm.name(), "Test Position Manager", "Name should be set");
    assertEq(pm.symbol(), "TPM", "Symbol should be set");
    assertEq(pm.decimals(), 18, "Decimals should be set");
    assertEq(pm.collateralAsset(), address(collateralToken), "Collateral asset should be set");
    assertEq(pm.debtAsset(), address(debtToken), "Debt asset should be set");
    assertEq(pm.lltv(), DEFAULT_LLTV, "LLTV should be set");
  }

  function test_createPositionManager_emitsEvent() public {
    // Skip checking first indexed param (positionManager address) since we can't predict it
    vm.expectEmit(false, true, true, true);
    emit PositionManagerCreated(
      address(0), // Ignored due to first expectEmit param being false
      positionManagerOwner,
      address(collateralToken),
      address(debtToken),
      DEFAULT_LLTV
    );

    factory.createPositionManager(
      positionManagerOwner,
      "Test Position Manager",
      "TPM",
      18,
      address(collateralToken),
      address(debtToken),
      DEFAULT_LLTV
    );
  }

  function test_createPositionManager_multipleDeployments() public {
    address pm1 = factory.createPositionManager(
      positionManagerOwner, "Position Manager 1", "PM1", 18, address(collateralToken), address(debtToken), DEFAULT_LLTV
    );

    address pm2 = factory.createPositionManager(
      user, "Position Manager 2", "PM2", 18, address(collateralToken), address(debtToken), 0.6e18
    );

    assertTrue(pm1 != pm2, "Each deployment should create a unique address");
    assertEq(PositionManager(pm1).owner(), positionManagerOwner, "PM1 owner correct");
    assertEq(PositionManager(pm2).owner(), user, "PM2 owner correct");
    assertEq(PositionManager(pm1).name(), "Position Manager 1", "PM1 name correct");
    assertEq(PositionManager(pm2).name(), "Position Manager 2", "PM2 name correct");
  }

  function test_createPositionManager_anyoneCanCall() public {
    vm.prank(user);
    address positionManager = factory.createPositionManager(
      positionManagerOwner,
      "Test Position Manager",
      "TPM",
      18,
      address(collateralToken),
      address(debtToken),
      DEFAULT_LLTV
    );

    assertTrue(positionManager != address(0), "Anyone should be able to create position manager");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      UPGRADE TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_beaconUpgrade_onlyOwner() public {
    address beacon = factory.POSITION_MANAGER_BEACON();

    // Deploy new implementation
    PositionManager newImplementation = new PositionManager();

    // Non-owner cannot upgrade
    vm.prank(user);
    vm.expectRevert();
    UpgradeableBeacon(beacon).upgradeTo(address(newImplementation));

    // Owner can upgrade
    vm.prank(beaconOwner);
    UpgradeableBeacon(beacon).upgradeTo(address(newImplementation));

    assertEq(UpgradeableBeacon(beacon).implementation(), address(newImplementation), "Implementation should be updated");
  }

  function test_beaconUpgrade_affectsAllProxies() public {
    // Create two position managers
    address pm1 = factory.createPositionManager(
      positionManagerOwner, "PM1", "PM1", 18, address(collateralToken), address(debtToken), DEFAULT_LLTV
    );

    address pm2 =
      factory.createPositionManager(user, "PM2", "PM2", 18, address(collateralToken), address(debtToken), DEFAULT_LLTV);

    // Verify both work before upgrade
    assertEq(PositionManager(pm1).name(), "PM1");
    assertEq(PositionManager(pm2).name(), "PM2");

    // Upgrade beacon
    address beacon = factory.POSITION_MANAGER_BEACON();
    PositionManager newImplementation = new PositionManager();

    vm.prank(beaconOwner);
    UpgradeableBeacon(beacon).upgradeTo(address(newImplementation));

    // Both proxies should still work after upgrade
    assertEq(PositionManager(pm1).name(), "PM1");
    assertEq(PositionManager(pm2).name(), "PM2");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_createPositionManager(
    address owner,
    string memory name,
    string memory symbol,
    uint8 decimals,
    uint256 lltv
  ) public {
    vm.assume(owner != address(0));
    lltv = bound(lltv, 0, 1e18); // LLTV should be <= 100%

    address positionManager =
      factory.createPositionManager(owner, name, symbol, decimals, address(collateralToken), address(debtToken), lltv);

    PositionManager pm = PositionManager(positionManager);
    assertEq(pm.owner(), owner);
    assertEq(pm.name(), name);
    assertEq(pm.symbol(), symbol);
    assertEq(pm.decimals(), decimals);
    assertEq(pm.lltv(), lltv);
  }
}
