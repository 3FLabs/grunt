// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {RetargetterBaseTest} from "./RetargetterBase.t.sol";
import {Retargetter} from "src/manager/rebalancer/Retargetter.sol";
import {RetargetterFactory} from "src/manager/rebalancer/RetargetterFactory.sol";
import {IRetargetter, RetargetterConfig, YieldEstimates} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {
  MIN_HORIZON,
  MAX_HORIZON,
  MAX_TICK_DURATION,
  MAX_YIELD_CAP_BPS,
  MAX_PRINCIPAL_BUFFER_BPS,
  ASSETS_STORAGE_SLOT,
  CONFIG_STORAGE_SLOT,
  WHITELISTS_STORAGE_SLOT,
  OPERATION_STORAGE_SLOT,
  WINDOW_TSLOT,
  MODULE_TSLOT,
  AMOUNT_TSLOT,
  REENTRANCY_TSLOT
} from "src/libs/manager/rebalancer/LibRetargetterConstants.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {Offer} from "src/interfaces/request/IOfferReceiver.sol";
import {Order, Mode} from "src/libs/funds/Order.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockRetargetterFund, ReenteringMockFund} from "test/mock/manager/rebalancer/MockRetargetterFund.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title RetargetterTest
/// @notice Unit coverage for the Retargetter's initialization, configuration, whitelists,
///         roles, views, factory wiring and storage layout.
contract RetargetterTest is RetargetterBaseTest {
  uint256 internal constant BPS = 10_000;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          FACTORY                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_factory_createRetargetterDeploysInitializesAndRegisters() public {
    address instance = retargetterFactory.createRetargetter(
      owner, address(collateralToken), address(debtToken), address(0), _defaultConfig()
    );

    assertGt(instance.code.length, 0, "proxy deployed");
    assertTrue(retargetterFactory.isRetargetter(instance), "registered");
    assertTrue(retargetterFactory.isRetargetter(address(retargetter)), "fixture instance registered");
    assertFalse(retargetterFactory.isRetargetter(makeAddr("notARetargetter")), "unknown address not registered");

    (address collateralAsset, address debtAsset) = Retargetter(instance).assets();
    assertEq(collateralAsset, address(collateralToken), "collateral asset initialized");
    assertEq(debtAsset, address(debtToken), "debt asset initialized");
    assertEq(Retargetter(instance).owner(), owner, "owner initialized");
    assertEq(Retargetter(instance).boundPositionManager(), address(0), "unbound when created with the zero address");
  }

  function test_factory_createRetargetterBindsPositionManagerAtInit() public {
    // Passing a position manager at creation binds it through the init path
    address instance = retargetterFactory.createRetargetter(
      owner, address(collateralToken), address(debtToken), address(positionManager), _defaultConfig()
    );
    assertEq(Retargetter(instance).boundPositionManager(), address(positionManager), "bound at init");
  }

  function test_factory_createRetargetterRevertsOnPairMismatchAtInit() public {
    // The init bind runs the same pair check as the setter
    MockERC20 otherDebt = new MockERC20("Other Debt", "ODEBT", 18);
    vm.expectRevert(LibRetargetterErrors.AssetMismatch.selector);
    retargetterFactory.createRetargetter(
      owner, address(collateralToken), address(otherDebt), address(positionManager), _defaultConfig()
    );
  }

  function test_factory_createRetargetterEmitsEvent() public {
    // The proxy address is not known ahead of the call, so topic 1 is unchecked
    vm.expectEmit(false, true, true, true, address(retargetterFactory));
    emit RetargetterFactory.RetargetterCreated(address(0), owner, address(collateralToken), address(debtToken));
    retargetterFactory.createRetargetter(
      owner, address(collateralToken), address(debtToken), address(0), _defaultConfig()
    );
  }

  function test_factory_permissionlessCreation() public {
    address randomCreator = makeAddr("randomCreator");
    vm.prank(randomCreator);
    address instance = retargetterFactory.createRetargetter(
      user, address(collateralToken), address(debtToken), address(0), _defaultConfig()
    );

    assertTrue(retargetterFactory.isRetargetter(instance), "registered");
    assertEq(Retargetter(instance).owner(), user, "owner is the passed owner, not the creator");
  }

  function test_factory_beaconImplementationWired() public view {
    address beacon = retargetterFactory.RETARGETTER_BEACON();
    assertTrue(beacon != address(0), "beacon set");

    address implementation = UpgradeableBeacon(beacon).implementation();
    assertGt(implementation.code.length, 0, "implementation deployed");
    assertEq(Retargetter(implementation).quoter(), address(retargetterQuoter), "quoter immutable");
    assertEq(Retargetter(implementation).requestFactory(), address(requestFactory), "request factory immutable");
  }

  function test_factory_implementationCannotBeInitialized() public {
    Retargetter implementation =
      Retargetter(UpgradeableBeacon(retargetterFactory.RETARGETTER_BEACON()).implementation());

    vm.expectRevert(Initializable.InvalidInitialization.selector);
    implementation.initialize(owner, address(collateralToken), address(debtToken), address(0), _defaultConfig());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_constructor_revertNonContractQuoter() public {
    address nonContract = makeAddr("nonContract");
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, nonContract));
    new Retargetter(nonContract, address(requestFactory));
  }

  function test_constructor_revertNonContractRequestFactory() public {
    address nonContract = makeAddr("nonContract");
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, nonContract));
    new Retargetter(address(retargetterQuoter), nonContract);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INITIALIZE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_setsAssetsConfigAndOwner() public view {
    (address collateralAsset, address debtAsset) = retargetter.assets();
    assertEq(collateralAsset, address(collateralToken), "collateral asset");
    assertEq(debtAsset, address(debtToken), "debt asset");
    assertEq(retargetter.owner(), owner, "owner");

    RetargetterConfig memory stored = retargetter.config();
    assertEq(stored.horizon, DEFAULT_HORIZON, "horizon");
    assertEq(stored.tickDuration, DEFAULT_TICK_DURATION, "tick duration");
    assertEq(stored.tickThreshold, DEFAULT_TICK_THRESHOLD, "tick threshold");
    assertEq(stored.maxYieldBps, DEFAULT_MAX_YIELD_BPS, "max yield bps");
    assertEq(stored.principalBufferBps, DEFAULT_PRINCIPAL_BUFFER_BPS, "principal buffer bps");
    assertEq(stored.collateralResidualExponent, 0, "collateral residual exponent");
    assertEq(stored.debtResidualExponent, 0, "debt residual exponent");
    assertEq(stored.estimates.requestYieldRate, 0, "request yield rate");
    assertEq(stored.estimates.borrowRate, 0, "borrow rate");
    assertEq(stored.estimates.collateralYieldRate, 0, "collateral yield rate");
    assertEq(stored.estimates.subscriptionDuration, 0, "subscription duration");
    assertEq(stored.estimates.redemptionDuration, 0, "redemption duration");
  }

  function test_initialize_revertZeroOwner() public {
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    retargetterFactory.createRetargetter(
      address(0), address(collateralToken), address(debtToken), address(0), _defaultConfig()
    );
  }

  function test_initialize_revertNonContractAssets() public {
    address nonContract = makeAddr("nonContract");

    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, nonContract));
    retargetterFactory.createRetargetter(owner, nonContract, address(debtToken), address(0), _defaultConfig());

    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, nonContract));
    retargetterFactory.createRetargetter(owner, address(collateralToken), nonContract, address(0), _defaultConfig());
  }

  function test_initialize_revertIdenticalAssets() public {
    vm.expectRevert(LibRetargetterErrors.AssetMismatch.selector);
    retargetterFactory.createRetargetter(owner, address(debtToken), address(debtToken), address(0), _defaultConfig());
  }

  function test_initialize_revertDoubleInitialize() public {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    retargetter.initialize(owner, address(collateralToken), address(debtToken), address(0), _defaultConfig());
  }

  function test_initialize_revertConfigBoundViolations() public {
    RetargetterConfig memory bad = _defaultConfig();
    bad.horizon = MIN_HORIZON - 1;
    _expectCreateInvalidParameters(bad);

    bad = _defaultConfig();
    bad.horizon = MAX_HORIZON + 1;
    _expectCreateInvalidParameters(bad);

    bad = _defaultConfig();
    bad.tickDuration = 0;
    _expectCreateInvalidParameters(bad);

    bad = _defaultConfig();
    bad.tickDuration = MAX_TICK_DURATION + 1;
    _expectCreateInvalidParameters(bad);

    bad = _defaultConfig();
    bad.tickThreshold = bad.tickDuration;
    _expectCreateInvalidParameters(bad);

    bad = _defaultConfig();
    bad.maxYieldBps = MAX_YIELD_CAP_BPS + 1;
    _expectCreateInvalidParameters(bad);

    bad = _defaultConfig();
    bad.principalBufferBps = MAX_PRINCIPAL_BUFFER_BPS + 1;
    _expectCreateInvalidParameters(bad);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CONFIGURATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setConfig_revertNonOwner() public {
    RetargetterConfig memory config_ = _defaultConfig();

    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setConfig(config_);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setConfig(config_);
  }

  function test_setConfig_validatesBounds() public {
    RetargetterConfig memory bad = _defaultConfig();
    bad.tickThreshold = bad.tickDuration;

    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    retargetter.setConfig(bad);
  }

  function test_setConfig_emitsAndTakesEffect() public {
    RetargetterConfig memory newConfig = RetargetterConfig({
      horizon: 180 days,
      tickDuration: 2 days,
      tickThreshold: 1 days,
      maxYieldBps: 500,
      principalBufferBps: 50,
      collateralResidualExponent: 12,
      debtResidualExponent: 20,
      estimates: YieldEstimates({
        requestYieldRate: 0.05e18,
        borrowRate: 0.02e18,
        collateralYieldRate: 0.01e18,
        subscriptionDuration: 2 days,
        redemptionDuration: 3 days
      })
    });

    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.ConfigSet(newConfig);
    retargetter.setConfig(newConfig);

    RetargetterConfig memory stored = retargetter.config();
    assertEq(stored.horizon, 180 days, "horizon");
    assertEq(stored.tickDuration, 2 days, "tick duration");
    assertEq(stored.tickThreshold, 1 days, "tick threshold");
    assertEq(stored.maxYieldBps, 500, "max yield bps");
    assertEq(stored.principalBufferBps, 50, "principal buffer bps");
    assertEq(stored.collateralResidualExponent, 12, "collateral residual exponent");
    assertEq(stored.debtResidualExponent, 20, "debt residual exponent");
    assertEq(stored.estimates.requestYieldRate, 0.05e18, "request yield rate");
    assertEq(stored.estimates.borrowRate, 0.02e18, "borrow rate");
    assertEq(stored.estimates.collateralYieldRate, 0.01e18, "collateral yield rate");
    assertEq(stored.estimates.subscriptionDuration, 2 days, "subscription duration");
    assertEq(stored.estimates.redemptionDuration, 3 days, "redemption duration");
  }

  /// @notice A started operation settles on the repayment terms snapshotted at start: a
  ///         later setConfig moves neither the owed pricing nor the consumption window.
  function test_setConfig_doesNotRepriceStartedOperation() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(4_000e18, 100);
    _consume(request, 1_000e18, 10e18, 1_000e18);

    // One tick on the snapshotted terms: 1 day over a 365-day horizon (yield rounds up)
    uint256 owedBefore = retargetter.owed();
    assertEq(owedBefore, 1_000e18 + (uint256(10e18) * 1 days + 365 days - 1) / 365 days, "one snapshot tick owed");

    // Read live, the new terms would owe a 30-day tick over a 90-day horizon
    RetargetterConfig memory config_ = retargetter.config();
    config_.horizon = 90 days;
    config_.tickDuration = 30 days;
    config_.tickThreshold = 1 days;
    vm.prank(owner);
    retargetter.setConfig(config_);

    assertEq(retargetter.owed(), owedBefore, "started operation keeps its snapshotted terms");
    (,,,,,, uint32 horizon, uint24 tickDuration, uint24 tickThreshold,,) = retargetter.operation();
    assertEq(horizon, DEFAULT_HORIZON, "snapshot horizon untouched");
    assertEq(tickDuration, DEFAULT_TICK_DURATION, "snapshot tick duration untouched");
    assertEq(tickThreshold, DEFAULT_TICK_THRESHOLD, "snapshot tick threshold untouched");
  }

  /// @notice The consumption window length is part of the operation snapshot: shrinking the
  ///         live tick threshold neither shortens a running window, nor does the snapshot
  ///         hold past its own boundary.
  function test_setConfig_windowLengthFixedAtStart() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(4_000e18, 100);
    _consume(request, 1_000e18, 10e18, 1_000e18);
    uint256 origin = block.timestamp;

    RetargetterConfig memory config_ = retargetter.config();
    config_.tickThreshold = 1 hours;
    vm.prank(owner);
    retargetter.setConfig(config_);

    // Five hours in: shut under the live 1-hour threshold, open under the 10-hour snapshot
    vm.warp(origin + 5 hours);
    _consume(request, 1_000e18, 10e18, 1_000e18);

    // Past the snapshot threshold the window closes (checked before the Request call)
    vm.warp(origin + uint256(DEFAULT_TICK_THRESHOLD) + 1);
    Offer memory offer = _createOffer(1_000e18, 10e18);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.ConsumptionWindowClosed.selector);
    retargetter.consume(offer, "", 1_000e18);
  }

  /// @notice Config changes bind the next operation: the snapshot is taken at start.
  function test_setConfig_appliesToNextOperation() public {
    RetargetterConfig memory config_ = retargetter.config();
    config_.horizon = 180 days;
    config_.tickDuration = 2 days;
    config_.tickThreshold = 12 hours;
    vm.prank(owner);
    retargetter.setConfig(config_);

    _seedPosition(10_000e18, 5_000e18);
    _startAsync(4_000e18, 100);
    (,,,,,, uint32 horizon, uint24 tickDuration, uint24 tickThreshold,,) = retargetter.operation();
    assertEq(horizon, 180 days, "new horizon snapshotted");
    assertEq(tickDuration, 2 days, "new tick duration snapshotted");
    assertEq(tickThreshold, 12 hours, "new tick threshold snapshotted");
  }

  function test_setEstimates_revertNonOwner() public {
    YieldEstimates memory estimates = _zeroEstimates();

    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setEstimates(estimates);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setEstimates(estimates);
  }

  function test_setEstimates_emitsAndChangesMaxPrincipal() public {
    _seedPosition(10_000e18, 5_000e18);
    uint256 collateralQuoted = positionManager.collateralAmountQuoted();
    uint256 debt = positionManager.debtAmount();
    uint256 yieldCapDenominator = WAD + uint256(DEFAULT_MAX_YIELD_BPS) * WAD / BPS - POSITION_MANAGER_LTV;

    // Zero-estimate cap: the one-trip bound (target * K - D) / (1 + yieldCap - target)
    // undercuts the buffered ideal (see test_maxPrincipal_upBranchZeroEstimates)
    uint256 capBefore = retargetter.maxPrincipal();
    assertEq(
      capBefore, (POSITION_MANAGER_LTV * collateralQuoted / WAD - debt) * WAD / yieldCapDenominator, "zero-estimate cap"
    );

    // A 10% per-year borrow rate over a full-year subscription makes Rb = 0.1
    YieldEstimates memory estimates = YieldEstimates({
      requestYieldRate: 0,
      borrowRate: 0.1e18,
      collateralYieldRate: 0,
      subscriptionDuration: 365 days,
      redemptionDuration: 0
    });

    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.EstimatesSet(estimates);
    retargetter.setEstimates(estimates);

    // The drifted debt D * 1.1 tightens both formulas; the one-trip bound still binds
    uint256 capAfter = retargetter.maxPrincipal();
    uint256 driftedDebt = debt * (WAD + 0.1e18) / WAD;
    assertEq(
      capAfter,
      (POSITION_MANAGER_LTV * collateralQuoted / WAD - driftedDebt) * WAD / yieldCapDenominator,
      "estimated cap"
    );
    assertLt(capAfter, capBefore, "borrow estimate tightens the cap");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        WHITELISTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setFund_revertNonOwner() public {
    MockRetargetterFund fund2 = new MockRetargetterFund(address(debtToken), address(collateralToken));

    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setFund(address(fund2), true);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setFund(address(fund), false);
  }

  function test_setFund_revertNonContract() public {
    address nonContract = makeAddr("nonContract");

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, nonContract));
    retargetter.setFund(nonContract, true);
  }

  function test_setFund_revertAssetMismatch() public {
    // Swapped tokens: asset() returns the collateral asset, share() the debt asset
    MockRetargetterFund swappedFund = new MockRetargetterFund(address(collateralToken), address(debtToken));

    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.AssetMismatch.selector);
    retargetter.setFund(address(swappedFund), true);
  }

  function test_setFund_emitsAndWhitelists() public {
    MockRetargetterFund fund2 = new MockRetargetterFund(address(debtToken), address(collateralToken));
    assertFalse(retargetter.isFund(address(fund2)), "not whitelisted before");

    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.FundSet(address(fund2), true);
    retargetter.setFund(address(fund2), true);
    assertTrue(retargetter.isFund(address(fund2)), "whitelisted after");

    // Removal skips the token-compatibility checks and emits the same event, flag down
    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.FundSet(address(fund2), false);
    retargetter.setFund(address(fund2), false);
    assertFalse(retargetter.isFund(address(fund2)), "removed after");
  }

  function test_setFund_revertOperationActiveForBoundFund() public {
    MockRetargetterFund fund2 = new MockRetargetterFund(address(debtToken), address(collateralToken));
    vm.prank(owner);
    retargetter.setFund(address(fund2), true);

    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);

    // The operation's fund cannot be removed while the operation is active
    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.setFund(address(fund), false);

    // Re-whitelisting the bound fund is a harmless no-op, and other funds stay removable
    vm.prank(owner);
    retargetter.setFund(address(fund), true);
    vm.prank(owner);
    retargetter.setFund(address(fund2), false);
    assertFalse(retargetter.isFund(address(fund2)), "other fund removed");
    assertTrue(retargetter.isFund(address(fund)), "bound fund still whitelisted");
  }

  function test_setFlashLoanModule_revertNonOwnerAndNonContract() public {
    address module = makeAddr("module");

    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setFlashLoanModule(address(fund), true);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, module));
    retargetter.setFlashLoanModule(module, true);
  }

  function test_setFlashLoanModule_emitsAndWhitelists() public {
    // Any contract address works: the module whitelist only checks code presence
    address module = address(new MockERC20("Module", "MOD", 18));
    assertFalse(retargetter.isFlashLoanModule(module), "not whitelisted before");

    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.FlashLoanModuleSet(module, true);
    retargetter.setFlashLoanModule(module, true);

    assertTrue(retargetter.isFlashLoanModule(module), "whitelisted after");
  }

  function test_setFlashLoanModule_emitsAndRemoves() public {
    assertTrue(retargetter.isFlashLoanModule(address(flashLoanAdapter)), "fixture adapter whitelisted");

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setFlashLoanModule(address(flashLoanAdapter), false);

    // Removal skips the code-presence check, so even a destroyed module can be delisted
    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.FlashLoanModuleSet(address(flashLoanAdapter), false);
    retargetter.setFlashLoanModule(address(flashLoanAdapter), false);

    assertFalse(retargetter.isFlashLoanModule(address(flashLoanAdapter)), "removed");
  }

  function test_setPositionManager_revertNonOwnerAndNonContract() public {
    address stranger = makeAddr("strangerPositionManager");

    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setPositionManager(address(positionManager));

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, stranger));
    retargetter.setPositionManager(stranger);
  }

  function test_setPositionManager_revertAssetMismatch() public {
    // A position manager on a different asset pair cannot be bound
    MockERC20 otherCollateral = new MockERC20("Other Collateral", "OCOLL", 18);
    MockERC20 otherDebt = new MockERC20("Other Debt", "ODEBT", 18);
    PositionManager otherPositionManager = PositionManager(LibClone.clone(address(new PositionManager())));
    otherPositionManager.initialize(
      owner,
      PositionManagerMetadata({
        name: "Other Position Manager",
        symbol: "OPMS",
        collateralAsset: address(otherCollateral),
        debtAsset: address(otherDebt)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );

    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.AssetMismatch.selector);
    retargetter.setPositionManager(address(otherPositionManager));
  }

  function test_setPositionManager_rebindsWhileIdle() public {
    // The fixture bound its manager at creation
    assertEq(retargetter.boundPositionManager(), address(positionManager), "fixture manager bound");

    // A fresh manager on the bound pair rebinds cleanly while idle
    PositionManager second = PositionManager(LibClone.clone(address(new PositionManager())));
    second.initialize(
      owner,
      PositionManagerMetadata({
        name: "Second Position Manager",
        symbol: "PMS2",
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );

    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.PositionManagerBound(address(second));
    retargetter.setPositionManager(address(second));
    assertEq(retargetter.boundPositionManager(), address(second), "rebound to the new manager");
  }

  function test_setPositionManager_revertOperationActive() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(4_000e18, 100);

    // The binding cannot move while an operation is active
    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.setPositionManager(address(positionManager));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     NO ESCAPE HATCH                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_noRescueSurface_selectorReverts() public {
    // The Retargetter deliberately exposes no token sweep: dust lives within the residual
    // tolerance and anything above folds into the position through the rebalance sentinels
    vm.prank(owner);
    (bool success,) = address(retargetter).call(abi.encodeWithSignature("rescue(address,address)", debtToken, owner));
    assertFalse(success, "no rescue selector");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isActive_lifecycle() public {
    assertFalse(retargetter.isActive(), "inactive before start");

    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);
    assertTrue(retargetter.isActive(), "active after start");

    // Abandon path: nothing consumed, repay owes zero and marks the Request repaid
    vm.startPrank(rebalancer);
    uint256 owedAmount = retargetter.repay();
    retargetter.resolve();
    vm.stopPrank();

    assertEq(owedAmount, 0, "nothing owed");
    assertFalse(retargetter.isActive(), "inactive after resolve");
  }

  function test_operation_fieldsAfterStartAndConsume() public {
    _seedPosition(10_000e18, 5_000e18);
    uint256 startTime = block.timestamp;
    address request = _startAsync(6_000e18, 100);

    // Block-scoped so the wide destructuring does not deepen the stack for the rest
    {
      (
        address positionManager_,
        address request_,
        address fund_,
        uint40 startedAt_,
        uint40 repaymentDeadline,
        uint16 operationMaxYieldBps,
        uint32 horizon,
        uint24 tickDuration,
        uint24 tickThreshold,
        Order memory order,
        bool orderLive
      ) = retargetter.operation();
      assertEq(positionManager_, address(positionManager), "position manager");
      assertEq(request_, request, "request");
      assertEq(fund_, address(fund), "fund");
      assertEq(startedAt_, 0, "loan clock not started");
      assertEq(uint256(repaymentDeadline), startTime + 90 days, "mirrored Request deadline");
      assertEq(operationMaxYieldBps, 100, "effective yield cap");
      assertEq(horizon, DEFAULT_HORIZON, "snapshotted horizon");
      assertEq(tickDuration, DEFAULT_TICK_DURATION, "snapshotted tick duration");
      assertEq(tickThreshold, DEFAULT_TICK_THRESHOLD, "snapshotted tick threshold");
      assertFalse(orderLive, "no stored order");
      assertEq(order.owner, address(retargetter), "rebuilt order owner");
      assertEq(order.receiver, address(retargetter), "rebuilt order receiver");
      assertEq(order.input, 0, "empty order input");
    }

    // The first consume sets the loan clock origin, not the operation start
    vm.warp(startTime + 3 days);
    _consume(request, 1_000e18, 10e18, 1_000e18);
    (,,, uint40 startedAt,,,,,,,) = retargetter.operation();
    assertEq(startedAt, startTime + 3 days, "startedAt is the first consume time");

    // Later consumes inside the consumption window leave the origin untouched
    vm.warp(startTime + 3 days + 5 hours);
    _consume(request, 1_000e18, 10e18, 1_000e18);
    (,,, startedAt,,,,,,,) = retargetter.operation();
    assertEq(startedAt, startTime + 3 days, "startedAt unchanged by later consumes");
  }

  function test_owed_revertNoActiveOperation() public {
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.owed();
  }

  function test_owed_zeroAfterStart() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);

    assertEq(retargetter.owed(), 0, "nothing consumed, nothing owed");
    vm.warp(block.timestamp + 10 days);
    assertEq(retargetter.owed(), 0, "time alone accrues nothing before the first consume");
  }

  function test_views_quoterAndRequestFactory() public view {
    assertEq(retargetter.quoter(), address(retargetterQuoter), "quoter");
    assertEq(retargetter.requestFactory(), address(requestFactory), "request factory");
  }

  function test_maxPrincipal_revertEmptyPosition() public {
    vm.expectRevert(LibRetargetterErrors.EmptyPosition.selector);
    retargetter.maxPrincipal();
  }

  function test_maxPrincipal_revertBadDebtPosition() public {
    _seedPosition(10_000e18, 5_000e18);
    // A zero oracle price quotes the collateral to zero while the debt persists
    oracle.setPrice(0);

    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.BadDebtPosition.selector, address(positionManager)));
    retargetter.maxPrincipal();
  }

  function test_maxPrincipal_zeroExactlyAtTarget() public {
    // LTV 7000/10000 == the 0.7 target: neither direction applies, the cap is zero
    _seedPosition(10_000e18, 7_000e18);
    assertEq(_currentLtv(), POSITION_MANAGER_LTV, "position exactly at target");
    assertEq(retargetter.maxPrincipal(), 0, "cap is zero at target");
  }

  function test_maxPrincipal_upBranchZeroEstimates() public {
    _seedPosition(10_000e18, 5_000e18);
    uint256 collateralQuoted = positionManager.collateralAmountQuoted();
    uint256 debt = positionManager.debtAmount();

    // Buffered ideal x = (target * K - D) / (1 - target) times 1.01 (100 bps buffer), capped
    // by the one-trip repayment bound (target * K - D) / (1 + yieldCap - target) sized on
    // the config ceiling (10%); the bound is the smaller of the two here
    uint256 numerator = POSITION_MANAGER_LTV * collateralQuoted / WAD - debt;
    uint256 buffered = numerator * WAD / (WAD - POSITION_MANAGER_LTV) * (BPS + DEFAULT_PRINCIPAL_BUFFER_BPS) / BPS;
    uint256 oneTrip = numerator * WAD / (WAD + uint256(DEFAULT_MAX_YIELD_BPS) * WAD / BPS - POSITION_MANAGER_LTV);
    assertLt(oneTrip, buffered, "the one-trip bound binds");

    assertEq(retargetter.maxPrincipal(), oneTrip, "up cap");
  }

  function test_maxPrincipal_downBranchZeroEstimates() public {
    _seedPosition(10_000e18, 5_000e18);
    // LTV 0.5 with a 0.3 target: above target, LTV-down direction
    uint256 target = 0.3e18;
    _setTargetLtv(target);
    uint256 collateralQuoted = positionManager.collateralAmountQuoted();
    uint256 debt = positionManager.debtAmount();

    // x = (D - target * K) / (1 - target); cap = x * 1.01 (100 bps buffer)
    uint256 idealPrincipal = (debt - target * collateralQuoted / WAD) * WAD / (WAD - target);
    uint256 expectedCap = idealPrincipal * (BPS + DEFAULT_PRINCIPAL_BUFFER_BPS) / BPS;

    assertEq(retargetter.maxPrincipal(), expectedCap, "down cap");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     START RETARGETTING                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_startRetargetting_revertOperationActive() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.startRetargetting(1e18, 100, address(fund), REQUEST_NAME, REQUEST_SYMBOL);
  }

  function test_startRetargetting_revertFundNotWhitelisted() public {
    MockRetargetterFund strangerFund = new MockRetargetterFund(address(debtToken), address(collateralToken));

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.FundNotWhitelisted.selector);
    retargetter.startRetargetting(1e18, 100, address(strangerFund), REQUEST_NAME, REQUEST_SYMBOL);
  }

  function test_startRetargetting_revertPositionManagerNotBound() public {
    // A fresh instance created without a bound position manager (address(0) at init)
    Retargetter unbound = Retargetter(
      retargetterFactory.createRetargetter(
        owner, address(collateralToken), address(debtToken), address(0), _defaultConfig()
      )
    );
    vm.prank(owner);
    unbound.grantRoles(rebalancer, RETARGETTER_REBALANCER_ROLE);
    vm.prank(owner);
    unbound.setFund(address(fund), true);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.PositionManagerNotBound.selector);
    unbound.startRetargetting(1e18, 100, address(fund), REQUEST_NAME, REQUEST_SYMBOL);
  }

  function test_startRetargetting_revertPrincipalCapExceeded() public {
    _seedPosition(10_000e18, 5_000e18);
    // The view sizes the cap on the config yield-cap ceiling; a start at that same ceiling
    // is gated by exactly this value
    uint256 cap = retargetter.maxPrincipal();

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.startRetargetting(cap + 1, DEFAULT_MAX_YIELD_BPS, address(fund), REQUEST_NAME, REQUEST_SYMBOL);
  }

  function test_startRetargetting_revertUnauthorized() public {
    _seedPosition(10_000e18, 5_000e18);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.startRetargetting(6_000e18, 100, address(fund), REQUEST_NAME, REQUEST_SYMBOL);
  }

  function test_startRetargetting_effectiveYieldCapCallerLower() public {
    _seedPosition(10_000e18, 5_000e18);

    // Caller cap 100 below the config's 1000: the caller cap binds
    vm.prank(rebalancer);
    vm.expectEmit(true, false, true, true, address(retargetter));
    emit IRetargetter.RetargettingStarted(address(positionManager), address(0), address(fund), 6_000e18, 100);
    retargetter.startRetargetting(6_000e18, 100, address(fund), REQUEST_NAME, REQUEST_SYMBOL);

    (,,,,, uint16 operationMaxYieldBps,,,,,) = retargetter.operation();
    assertEq(operationMaxYieldBps, 100, "caller cap recorded");
  }

  function test_startRetargetting_effectiveYieldCapConfigLower() public {
    _seedPosition(10_000e18, 5_000e18);

    // Caller cap 2000 above the config's 1000: the config cap binds (and sizes the one-trip
    // principal bound, so the announced principal sits under that tighter cap)
    vm.prank(rebalancer);
    vm.expectEmit(true, false, true, true, address(retargetter));
    emit IRetargetter.RetargettingStarted(
      address(positionManager), address(0), address(fund), 4_000e18, DEFAULT_MAX_YIELD_BPS
    );
    retargetter.startRetargetting(4_000e18, 2_000, address(fund), REQUEST_NAME, REQUEST_SYMBOL);

    (,,,,, uint16 operationMaxYieldBps,,,,,) = retargetter.operation();
    assertEq(operationMaxYieldBps, DEFAULT_MAX_YIELD_BPS, "config cap recorded");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSUME                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_revertNoActiveOperation() public {
    Offer memory offer = _createOffer(1_000e18, 10e18);

    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.consume(offer, "", 1_000e18);
  }

  function test_consume_revertYieldTooHigh() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);

    // 61 over 6000 is above the 1% operation cap
    Offer memory offer = _createOffer(6_000e18, 61e18);
    bytes memory signature = _signOffer(offer, request);

    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.YieldTooHigh.selector);
    retargetter.consume(offer, signature, 6_000e18);
  }

  function test_consume_partialFillKeepsOfferRatio() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);

    // Fat offer at a 2% ratio: a small partial fill keeps the ratio and still fails
    Offer memory fatOffer = _createOffer(10_000e18, 200e18);
    bytes memory fatSignature = _signOffer(fatOffer, request);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.YieldTooHigh.selector);
    retargetter.consume(fatOffer, fatSignature, 100e18);

    // Fat offer exactly at the 1% cap ratio: a partial fill passes and yields pro rata
    Offer memory okOffer = _createOffer(10_000e18, 100e18);
    bytes memory okSignature = _signOffer(okOffer, request);
    vm.prank(maker.addr);
    debtToken.approve(request, 1_000e18);
    vm.prank(consumer);
    uint256 ytAmount = retargetter.consume(okOffer, okSignature, 1_000e18);
    assertEq(ytAmount, 10e18, "pro-rata yield on the partial fill");
  }

  function test_consume_revertPrincipalCapExceededCumulative() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    uint256 cap = retargetter.maxPrincipal();
    assertLt(cap, 7_000e18, "cap sanity");

    _consume(request, 6_000e18, 60e18, 6_000e18);

    // PT supply 6000 plus another 1000 crosses the cap. The maker approves the transfer:
    // the gate now runs after the Request call, so the revert must come from the cap
    // re-check, not from a failed pull
    Offer memory offer = _createOffer(1_000e18, 10e18);
    bytes memory signature = _signOffer(offer, request);
    vm.prank(maker.addr);
    debtToken.approve(request, 1_000e18);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.consume(offer, signature, 1_000e18);
  }

  function test_consume_revertUnauthorized() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    Offer memory offer = _createOffer(1_000e18, 10e18);
    bytes memory signature = _signOffer(offer, request);

    // The rebalancer role does not include the consumer surface
    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.consume(offer, signature, 1_000e18);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.consume(offer, signature, 1_000e18);
  }

  function test_consume_ownerCanConsume() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);

    Offer memory offer = _createOffer(1_000e18, 10e18);
    bytes memory signature = _signOffer(offer, request);
    vm.prank(maker.addr);
    debtToken.approve(request, 1_000e18);

    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.OfferConsumed(request, maker.addr, 1_000e18, 10e18);
    uint256 ytAmount = retargetter.consume(offer, signature, 1_000e18);

    assertEq(ytAmount, 10e18, "yield minted");
    assertEq(debtToken.balanceOf(request), 1_000e18, "principal pulled to the request");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MINT AUTHORIZATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_authorizeMinting_revertNoActiveOperation() public {
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.authorizeMinting(broker, 1_000e18, 10e18);
  }

  function test_authorizeMinting_revertUnauthorized() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);

    // The rebalancer role does not include the consumer surface
    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.authorizeMinting(broker, 1_000e18, 10e18);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.authorizeMinting(broker, 1_000e18, 10e18);
  }

  function test_authorizedAccounts_emptyWithoutOperation() public view {
    assertEq(retargetter.authorizedAccounts().length, 0, "no registered accounts");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     PULL REQUEST FUNDS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pullRequestFunds_revertNoActiveOperation() public {
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.pullRequestFunds(1e18);
  }

  function test_pullRequestFunds_pullsAndEmits() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    _consume(request, 6_000e18, 60e18, 6_000e18);

    vm.prank(rebalancer);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.RequestFundsPulled(request, 2_500e18);
    retargetter.pullRequestFunds(2_500e18);

    assertEq(debtToken.balanceOf(address(retargetter)), 2_500e18, "funds landed on the retargetter");
    assertEq(debtToken.balanceOf(request), 3_500e18, "remainder stays on the request");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         MULTICALL                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_multicall_batchesSteps() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    _consume(request, 6_000e18, 60e18, 6_000e18);
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(6_000e18);

    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeCall(retargetter.create, (_order(Mode.DEPOSIT, 6_000e18, 6_000e18, bytes32(uint256(7)))));
    calls[1] = abi.encodeCall(retargetter.commit, ());

    vm.prank(rebalancer);
    retargetter.multicall(calls);

    assertEq(debtToken.balanceOf(address(fund)), 6_000e18, "commit pulled the order input");
    (,,,,,,,,,, bool orderLive) = retargetter.operation();
    assertTrue(orderLive, "order stored by the batched create");
  }

  function test_multicall_subCallAuthorizationEnforced() public {
    // Sub-calls keep msg.sender, so a random caller fails the step's own modifier
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeCall(retargetter.create, (_order(Mode.DEPOSIT, 1e18, 1e18, bytes32(uint256(9)))));

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.multicall(calls);
  }

  function test_multicall_revertNonzeroValue() public {
    vm.expectRevert();
    retargetter.multicall{value: 1}(new bytes[](0));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      REENTRANCY GUARD                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The transient guard blocks reentry through an external call made by a guarded
  ///         function: a whitelisted fund holding the rebalancer role (so the reentrant call
  ///         passes authorization and reaches the guard) reenters cancelOrder from inside
  ///         cancel and the whole call reverts Reentrancy.
  function test_nonReentrant_blocksReentrantCall() public {
    ReenteringMockFund reenteringFund = new ReenteringMockFund(address(debtToken), address(collateralToken));
    vm.startPrank(owner);
    retargetter.setFund(address(reenteringFund), true);
    retargetter.grantRoles(address(reenteringFund), RETARGETTER_REBALANCER_ROLE);
    vm.stopPrank();

    _seedPosition(10_000e18, 5_000e18);
    vm.startPrank(rebalancer);
    retargetter.startRetargetting(0, 100, address(reenteringFund), REQUEST_NAME, REQUEST_SYMBOL);
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(1))));

    vm.expectRevert(LibRetargetterErrors.Reentrancy.selector);
    retargetter.cancelOrder();
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       STORAGE LAYOUT                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_storageLayout_erc7201SlotConstants() public pure {
    assertEq(ASSETS_STORAGE_SLOT, _erc7201Slot("retargetter.assets"), "assets slot");
    assertEq(CONFIG_STORAGE_SLOT, _erc7201Slot("retargetter.config"), "config slot");
    assertEq(WHITELISTS_STORAGE_SLOT, _erc7201Slot("retargetter.whitelists"), "whitelists slot");
    assertEq(OPERATION_STORAGE_SLOT, _erc7201Slot("retargetter.operation"), "operation slot");
  }

  function test_storageLayout_transientSlotConstants() public pure {
    assertEq(WINDOW_TSLOT, bytes32(uint256(keccak256("retargetter.transient.window")) - 1), "window tslot");
    assertEq(MODULE_TSLOT, bytes32(uint256(keccak256("retargetter.transient.module")) - 1), "module tslot");
    assertEq(AMOUNT_TSLOT, bytes32(uint256(keccak256("retargetter.transient.amount")) - 1), "amount tslot");
    assertEq(REENTRANCY_TSLOT, bytes32(uint256(keccak256("retargetter.transient.reentrancy")) - 1), "reentrancy tslot");
  }

  function test_storageLayout_operationPacking() public {
    _seedPosition(10_000e18, 5_000e18);
    uint256 startTime = block.timestamp;
    address request = _startAsync(6_000e18, 100);
    vm.warp(startTime + 1 days);
    _consume(request, 1_000e18, 10e18, 1_000e18);
    _authorize(broker, 500e18, 5e18);
    vm.prank(rebalancer);
    retargetter.create(_order(Mode.REDEEM, 123e18, 456e18, bytes32(uint256(42))));

    // The mint-authorization set registers through the enumerable view
    address[] memory accounts = retargetter.authorizedAccounts();
    assertEq(accounts.length, 1, "one registered account");
    assertEq(accounts[0], broker, "broker registered");

    // Slot A: positionManager (bits 0..159) | startedAt (160..199) | operationMaxYieldBps
    // (200..215) | consumptionClosed (216..223) | horizon (224..255): full, no wasted bits
    uint256 slotA = uint256(vm.load(address(retargetter), OPERATION_STORAGE_SLOT));
    assertEq(address(uint160(slotA)), address(positionManager), "position manager bits");
    assertEq(uint40(slotA >> 160), uint40(startTime + 1 days), "startedAt bits");
    assertEq(uint16(slotA >> 200), 100, "operation max yield bits");
    assertEq(uint8(slotA >> 216), 0, "consumption closed bit clear");
    assertEq(slotA >> 224, DEFAULT_HORIZON, "horizon bits");

    // Slot B: request (bits 0..159) | repaymentDeadline (160..199) | tickDuration (200..223)
    // | tickThreshold (224..247)
    uint256 slotB = uint256(vm.load(address(retargetter), bytes32(uint256(OPERATION_STORAGE_SLOT) + 1)));
    assertEq(address(uint160(slotB)), request, "request bits");
    assertEq(uint40(slotB >> 160), uint40(startTime + 90 days), "repayment deadline bits");
    assertEq(uint24(slotB >> 200), DEFAULT_TICK_DURATION, "tick duration bits");
    assertEq(uint24(slotB >> 224), DEFAULT_TICK_THRESHOLD, "tick threshold bits");
    assertEq(slotB >> 248, 0, "slot B upper bits clean");

    // Slot C: fund (bits 0..159) | orderMode (160..167) | orderLive (168..175)
    uint256 slotC = uint256(vm.load(address(retargetter), bytes32(uint256(OPERATION_STORAGE_SLOT) + 2)));
    assertEq(address(uint160(slotC)), address(fund), "fund bits");
    assertEq(uint8(slotC >> 160), uint8(Mode.REDEEM), "order mode bits");
    assertEq(uint8(slotC >> 168), 1, "order live bits");
    assertEq(slotC >> 176, 0, "slot C upper bits clean");

    // Slots D to F: the stored order's input, output and salt
    assertEq(
      uint256(vm.load(address(retargetter), bytes32(uint256(OPERATION_STORAGE_SLOT) + 3))), 123e18, "order input"
    );
    assertEq(
      uint256(vm.load(address(retargetter), bytes32(uint256(OPERATION_STORAGE_SLOT) + 4))), 456e18, "order output"
    );
    assertEq(
      vm.load(address(retargetter), bytes32(uint256(OPERATION_STORAGE_SLOT) + 5)), bytes32(uint256(42)), "order salt"
    );

    // Pulling funds flips the consumption-closed bit (216..223) and nothing else in slot A
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(1);
    slotA = uint256(vm.load(address(retargetter), OPERATION_STORAGE_SLOT));
    assertEq(address(uint160(slotA)), address(positionManager), "position manager bits unchanged");
    assertEq(uint40(slotA >> 160), uint40(startTime + 1 days), "startedAt bits unchanged");
    assertEq(uint16(slotA >> 200), 100, "operation max yield bits unchanged");
    assertEq(uint8(slotA >> 216), 1, "consumption closed bit set");
    assertEq(slotA >> 224, DEFAULT_HORIZON, "horizon bits unchanged by the pull");
  }

  function test_storageLayout_assetsPacking() public view {
    uint256 slot0 = uint256(vm.load(address(retargetter), ASSETS_STORAGE_SLOT));
    assertEq(address(uint160(slot0)), address(collateralToken), "collateral asset in first slot");
    assertEq(slot0 >> 160, 0, "assets slot 0 upper bits clean");

    uint256 slot1 = uint256(vm.load(address(retargetter), bytes32(uint256(ASSETS_STORAGE_SLOT) + 1)));
    assertEq(address(uint160(slot1)), address(debtToken), "debt asset in second slot");
    assertEq(slot1 >> 160, 0, "assets slot 1 upper bits clean");

    // The bound position manager occupies the third slot (bound at creation in the fixture)
    uint256 slot2 = uint256(vm.load(address(retargetter), bytes32(uint256(ASSETS_STORAGE_SLOT) + 2)));
    assertEq(address(uint160(slot2)), address(positionManager), "bound position manager in third slot");
    assertEq(slot2 >> 160, 0, "assets slot 2 upper bits clean");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Expects the next factory creation with the given config to revert InvalidParameters.
  function _expectCreateInvalidParameters(RetargetterConfig memory config_) internal {
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    retargetterFactory.createRetargetter(owner, address(collateralToken), address(debtToken), address(0), config_);
  }

  /// @dev Computes an ERC-7201 slot: keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~0xff.
  function _erc7201Slot(string memory namespace) internal pure returns (bytes32) {
    return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(0xff));
  }
}
