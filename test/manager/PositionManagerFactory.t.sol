// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManagerFactory} from "src/manager/PositionManagerFactory.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title PositionManagerFactoryTest
/// @notice Test suite for PositionManagerFactory contract
contract PositionManagerFactoryTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  PositionManagerFactory public factory;
  MockERC20 public collateralToken;
  MockERC20 public debtToken;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public beaconOwner;
  address public positionManagerOwner;
  address public user;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant DEFAULT_LTV = 0.7e18; // 70% LTV

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  event PositionManagerCreated(
    address indexed positionManager,
    address indexed owner,
    address indexed collateralAsset,
    address debtAsset,
    uint256 ltv,
    address transferGuard
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
    collateralToken = new MockERC20("Collateral Token", "COLL", 18);
    vm.label(address(collateralToken), "CollateralToken");

    debtToken = new MockERC20("Debt Token", "DEBT", 18);
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

  function test_createPositionManager_emitsEvent() public {
    // Skip checking first indexed param (positionManager address) since we can't predict it
    vm.expectEmit(false, true, true, true);
    emit PositionManagerCreated(
      address(0), // Ignored due to first expectEmit param being false
      positionManagerOwner,
      address(collateralToken),
      address(debtToken),
      DEFAULT_LTV,
      address(0)
    );

    factory.createPositionManager(
      positionManagerOwner,
      PositionManagerMetadata({
        name: "Test Position Manager",
        symbol: "TPM",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      DEFAULT_LTV,
      address(0),
      0,
      0
    );
  }

  function test_createPositionManager_multipleDeployments() public {
    address pm1 = factory.createPositionManager(
      positionManagerOwner,
      PositionManagerMetadata({
        name: "Position Manager 1",
        symbol: "PM1",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      DEFAULT_LTV,
      address(0),
      0,
      0
    );

    address pm2 = factory.createPositionManager(
      user,
      PositionManagerMetadata({
        name: "Position Manager 2",
        symbol: "PM2",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      0.6e18,
      address(0),
      0,
      0
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
      PositionManagerMetadata({
        name: "Test Position Manager",
        symbol: "TPM",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      DEFAULT_LTV,
      address(0),
      0,
      0
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
      positionManagerOwner,
      PositionManagerMetadata({
        name: "PM1",
        symbol: "PM1",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      DEFAULT_LTV,
      address(0),
      0,
      0
    );

    address pm2 = factory.createPositionManager(
      user,
      PositionManagerMetadata({
        name: "PM2",
        symbol: "PM2",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      DEFAULT_LTV,
      address(0),
      0,
      0
    );

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
    uint256 ltv,
    address transferGuard
  ) public {
    vm.assume(owner != address(0));
    ltv = bound(ltv, 1, 1e18); // LTV must be > 0 and <= 100%

    address positionManager = factory.createPositionManager(
      owner,
      PositionManagerMetadata({
        name: name,
        symbol: symbol,
        decimals: decimals,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      ltv,
      transferGuard,
      0,
      0
    );

    PositionManager pm = PositionManager(positionManager);
    assertEq(pm.owner(), owner);
    assertEq(pm.name(), name);
    assertEq(pm.symbol(), symbol);
    assertEq(pm.decimals(), decimals);
    (uint256 ltv_,, address transferGuard_,,) = pm.config();
    assertEq(ltv_, ltv);
    assertEq(transferGuard_, transferGuard);
  }
}
