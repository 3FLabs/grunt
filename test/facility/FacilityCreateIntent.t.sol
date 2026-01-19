// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/facility/Facility.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract MockFund {
  address internal immutable ASSET;
  address internal immutable SHARE;

  constructor(address asset_, address share_) {
    ASSET = asset_;
    SHARE = share_;
  }

  function asset() external view returns (address) {
    return ASSET;
  }

  function share() external view returns (address) {
    return SHARE;
  }

  function create(Order calldata) external pure returns (State) {
    return State.ACCEPTED;
  }
}

contract MockRequest {
  address internal immutable ASSET;
  bool internal _isRepaid = true;

  constructor(address asset_) {
    ASSET = asset_;
  }

  function asset() external view returns (address) {
    return ASSET;
  }

  function isRepaid() external view returns (bool) {
    return _isRepaid;
  }

  function syncRepaidStatus() external returns (bool) {
    return _isRepaid;
  }

  function setIsRepaid(bool value) external {
    _isRepaid = value;
  }
}

contract FacilityCreateIntentTest is Test {
  event IntentCreated(uint256 indexed id, Asset depositAsset, uint8 quorum);

  Facility internal facility;

  MockERC20 internal collateral;
  MockERC20 internal collateral2;
  MockERC20 internal debt;

  PositionManager internal pm;
  PositionManager internal pmSame;
  PositionManager internal pmMismatch;

  function setUp() public {
    facility = new Facility();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    collateral = new MockERC20("Collateral", "COL", 18);
    collateral2 = new MockERC20("Collateral2", "COL2", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    pm = _newPositionManager(address(collateral), address(debt));
    pmSame = _newPositionManager(address(collateral), address(debt));
    pmMismatch = _newPositionManager(address(collateral2), address(debt));
  }

  function _newPositionManager(address collateralAsset, address debtAsset) internal returns (PositionManager manager) {
    manager = new PositionManager();
    manager.initialize(address(this), "PM", "PM", 6, collateralAsset, debtAsset, 0.8e18, address(0));
  }

  function _createIntent(
    Asset memory depositAsset,
    Asset memory targetAsset,
    address guardKey,
    uint256 depositCap,
    uint40 resolveStart,
    uint8 quorum
  ) internal returns (uint256 id) {
    id = facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: guardKey,
        depositCap: depositCap,
        resolveStart: resolveStart,
        quorum: quorum
      })
    );
  }

  function test_RevertWhen_CreateIntent_ResolveStartNotInFuture() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    vm.expectRevert(
      abi.encodeWithSelector(LibErrors.InvalidResolveStart.selector, uint40(block.timestamp), uint40(block.timestamp))
    );
    _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp), 0);
  }

  function test_RevertWhen_CreateIntent_NoPositionManager() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(collateral), isPositionManager: false});

    vm.expectRevert(LibErrors.MissingPositionManager.selector);
    _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
  }

  function test_RevertWhen_CreateIntent_BothPMAssetsMismatch() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(pmMismatch), isPositionManager: true});

    vm.expectRevert(abi.encodeWithSelector(LibErrors.AssetMismatch.selector, address(collateral2), address(collateral)));
    _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
  }

  function test_RevertWhen_CreateIntent_GuardKeyNotPMSide() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    vm.expectRevert(abi.encodeWithSelector(LibErrors.InvalidGuardKey.selector, address(pmMismatch)));
    _createIntent(depositAsset, targetAsset, address(pmMismatch), 1, uint40(block.timestamp + 1 days), 0);
  }

  function test_CreateIntent_Succeeds_WhenDepositIsCollateral() public {
    Asset memory depositAsset = Asset({asset: address(collateral), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
    assertEq(id, 1);
  }

  function test_CreateIntent_Succeeds_WhenDepositIsDebt() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
    assertEq(id, 1);
  }

  function test_RevertWhen_CreateIntent_DepositAssetNotPmCollateralOrDebt() public {
    MockERC20 wrongAsset = new MockERC20("Wrong", "WRONG", 18);
    Asset memory depositAsset = Asset({asset: address(wrongAsset), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    vm.expectRevert(abi.encodeWithSelector(LibErrors.AssetMismatch.selector, address(collateral), address(wrongAsset)));
    _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
  }

  function test_RevertWhen_CreateIntent_FundAssetMismatch() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockERC20 wrongDebt = new MockERC20("WrongDebt", "WDEBT", 6);
    MockFund fund = new MockFund(address(wrongDebt), address(collateral));

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    vm.expectRevert(abi.encodeWithSelector(LibErrors.AssetMismatch.selector, address(wrongDebt), address(debt)));
    facility.setFund(id, address(fund));
  }

  function test_RevertWhen_CreateIntent_RequestAssetMismatch() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockRequest request = new MockRequest(address(collateral));

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    vm.expectRevert(abi.encodeWithSelector(LibErrors.AssetMismatch.selector, address(collateral), address(debt)));
    facility.setRequest(id, address(request));
  }

  function test_CreateIntent_Succeeds_WhenDepositIsPM() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    vm.expectEmit(true, false, false, true);
    emit IntentCreated(1, depositAsset, 7);

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 123, uint40(block.timestamp + 1 days), 7);

    assertEq(id, 1);
  }

  function test_CreateIntent_Succeeds_WhenTargetIsPM() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    vm.expectEmit(true, false, false, true);
    emit IntentCreated(1, depositAsset, 0);

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 456, uint40(block.timestamp + 1 days), 0);

    assertEq(id, 1);
  }

  function test_CreateIntent_Succeeds_WhenBothArePMAndMatchAssets() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(pmSame), isPositionManager: true});

    vm.expectEmit(true, false, false, true);
    emit IntentCreated(1, depositAsset, 1);

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 1);

    assertEq(id, 1);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FUND/REQUEST TRACKING                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_RevertWhen_SetFund_FundAlreadyInUse() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockFund fund = new MockFund(address(debt), address(collateral));

    uint256 id1 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
    uint256 id2 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Set fund on intent 1
    facility.setFund(id1, address(fund));

    // Try to set the same fund on intent 2 - should revert
    vm.expectRevert(abi.encodeWithSelector(LibErrors.FundAlreadyInUse.selector, address(fund), id1));
    facility.setFund(id2, address(fund));
  }

  function test_SetFund_SameFundOnSameIntent_Succeeds() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockFund fund = new MockFund(address(debt), address(collateral));

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Set fund on intent
    facility.setFund(id, address(fund));

    // Set same fund on same intent - should succeed
    facility.setFund(id, address(fund));
  }

  function test_SetFund_RemoveFund() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockFund fund = new MockFund(address(debt), address(collateral));

    uint256 id1 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
    uint256 id2 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Set fund on intent 1
    facility.setFund(id1, address(fund));

    // Remove fund from intent 1
    facility.setFund(id1, address(0));

    // Now intent 2 can use the fund
    facility.setFund(id2, address(fund));
  }

  function test_SetFund_SwitchFundFreesOldFund() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockFund fundA = new MockFund(address(debt), address(collateral));
    MockFund fundB = new MockFund(address(debt), address(collateral));

    uint256 id1 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
    uint256 id2 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Set fundA on intent 1
    facility.setFund(id1, address(fundA));

    // Switch intent 1 from fundA to fundB
    facility.setFund(id1, address(fundB));

    // Now intent 2 should be able to use fundA (since it was freed when intent 1 switched to fundB)
    facility.setFund(id2, address(fundA));
  }

  function test_RevertWhen_SetFund_RemoveFundWithActiveOrder() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    MockFund fund = new MockFund(address(debt), address(collateral));

    uint256 id =
      _createIntent(depositAsset, targetAsset, address(pm), type(uint256).max, uint40(block.timestamp + 1 days), 0);

    // Set fund on intent
    facility.setFund(id, address(fund));

    // Deposit some assets
    debt.mint(address(this), 1_000_000);
    debt.approve(address(facility), 1_000_000);
    facility.deposit(id, 1_000_000);

    // Lock the intent to move to resolving phase
    facility.lock(id);

    // Create an order on the intent
    facility.create(id, 500_000, 400_000, Mode.DEPOSIT);

    // Try to remove the fund - should revert because there's an active order
    vm.expectRevert(abi.encodeWithSelector(LibErrors.ActiveOrder.selector, id));
    facility.setFund(id, address(0));
  }

  function test_RevertWhen_SetRequest_RequestAlreadyInUse() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockRequest request = new MockRequest(address(debt));

    uint256 id1 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
    uint256 id2 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Set request on intent 1
    facility.setRequest(id1, address(request));

    // Try to set the same request on intent 2 - should revert
    vm.expectRevert(abi.encodeWithSelector(LibErrors.RequestAlreadyInUse.selector, address(request), id1));
    facility.setRequest(id2, address(request));
  }

  function test_SetRequest_SameRequestOnSameIntent_Succeeds() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockRequest request = new MockRequest(address(debt));

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Set request on intent
    facility.setRequest(id, address(request));

    // Set same request on same intent - should succeed
    facility.setRequest(id, address(request));
  }

  function test_SetRequest_RemoveRequest() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockRequest request = new MockRequest(address(debt));

    uint256 id1 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
    uint256 id2 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Set request on intent 1
    facility.setRequest(id1, address(request));

    // Remove request from intent 1
    facility.setRequest(id1, address(0));

    // Now intent 2 can use the request
    facility.setRequest(id2, address(request));
  }

  function test_SetRequest_SwitchRequestFreesOldRequest() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockRequest requestA = new MockRequest(address(debt));
    MockRequest requestB = new MockRequest(address(debt));

    uint256 id1 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
    uint256 id2 = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Set requestA on intent 1
    facility.setRequest(id1, address(requestA));

    // Switch intent 1 from requestA to requestB
    facility.setRequest(id1, address(requestB));

    // Now intent 2 should be able to use requestA (since it was freed when intent 1 switched to requestB)
    facility.setRequest(id2, address(requestA));
  }

  function test_SetFund_WorksOnResolvedIntent() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockFund fund = new MockFund(address(debt), address(collateral));

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Lock and resolve the intent
    facility.lock(id);
    facility.resolve(id);

    // Setting fund on resolved intent should succeed
    facility.setFund(id, address(fund));

    // Removing fund from resolved intent should also succeed
    facility.setFund(id, address(0));
  }

  function test_SetRequest_WorksOnResolvedIntent() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockRequest request = new MockRequest(address(debt));

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    // Lock and resolve the intent
    facility.lock(id);
    facility.resolve(id);

    // Setting request on resolved intent should succeed
    facility.setRequest(id, address(request));

    // Removing request from resolved intent should also succeed
    facility.setRequest(id, address(0));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       VIEW FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_GetIntent_ReturnsCorrectData() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1000, uint40(block.timestamp + 1 days), 3);

    MockFund fund = new MockFund(address(debt), address(collateral));
    MockRequest request = new MockRequest(address(debt));

    facility.setFund(id, address(fund));
    facility.setRequest(id, address(request));

    (IntentProperties memory props, address fundAddr, address requestAddr, bool resolved) = facility.getIntent(id);

    // Check properties
    assertEq(props.depositAsset.asset, address(debt));
    assertFalse(props.depositAsset.isPositionManager);
    assertEq(props.targetAsset.asset, address(pm));
    assertTrue(props.targetAsset.isPositionManager);
    assertEq(props.depositCap, 1000);
    assertEq(props.guardKey, address(pm));
    assertEq(props.resolveStart, uint40(block.timestamp + 1 days));
    assertEq(props.quorum, 3);

    // Check fund and request
    assertEq(fundAddr, address(fund));
    assertEq(requestAddr, address(request));
    assertFalse(resolved);
  }

  function test_GetIntent_ResolvedIntent() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1000, uint40(block.timestamp + 1 days), 0);

    // Lock and resolve
    facility.lock(id);
    facility.resolve(id);

    (,,, bool resolved) = facility.getIntent(id);
    assertTrue(resolved);
  }

  function test_RevertWhen_GetIntent_IntentNotFound() public {
    vm.expectRevert(abi.encodeWithSelector(LibErrors.IntentNotFound.selector, 999));
    facility.getIntent(999);
  }

  function test_IntentBalances_ReturnsCorrectTokensAndAmounts() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    uint256 id =
      _createIntent(depositAsset, targetAsset, address(pm), type(uint256).max, uint40(block.timestamp + 1 days), 0);

    // Deposit some tokens
    debt.mint(address(this), 500);
    debt.approve(address(facility), 500);
    facility.deposit(id, 500);

    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(id);
    assertEq(tokens.length, 1);
    assertEq(amounts.length, 1);
    assertEq(tokens[0], address(debt));
    assertEq(amounts[0], 500);
  }

  function test_IntentBalances_ReturnsEmptyArraysForNoTokens() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    uint256 id =
      _createIntent(depositAsset, targetAsset, address(pm), type(uint256).max, uint40(block.timestamp + 1 days), 0);

    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(id);
    assertEq(tokens.length, 0);
    assertEq(amounts.length, 0);
  }
}
