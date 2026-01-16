// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Facility} from "src/Facility.sol";
import {IIntentDescriptor} from "src/interfaces/IIntentDescriptor.sol";
import {Asset, CreateIntentParams} from "src/interfaces/IFacility.sol";

import {Order, Mode, State} from "src/libs/Order.sol";

import {PositionManagerBaseTest} from "test/manager/PositionManagerBase.t.sol";

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

contract FacilityHarness is Facility {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

  function amountOf(uint256 id, address token) external view returns (uint256) {
    FacilityStorage storage $ = _facilityStorage();
    (bool exists, uint256 value) = $.intents[id].amounts.tryGet(token);
    return exists ? value : 0;
  }
}

contract MockFund {
  using SafeTransferLib for address;

  address internal immutable ASSET;
  address internal immutable SHARE;

  mapping(bytes32 => State) internal _state;

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

  function _orderKey(Order calldata order) internal pure returns (bytes32) {
    return keccak256(abi.encode(order.owner, order.receiver, order.input, order.output, order.mode, order.salt));
  }

  function create(Order calldata order) external returns (State) {
    bytes32 key = _orderKey(order);
    require(_state[key] == State.EMPTY, "not empty");
    _state[key] = State.ACCEPTED;
    return State.ACCEPTED;
  }

  function cancel(Order calldata order) external returns (State) {
    bytes32 key = _orderKey(order);
    require(_state[key] == State.ACCEPTED || _state[key] == State.PENDING, "not cancelable");
    _state[key] = State.EMPTY;
    return State.EMPTY;
  }

  function commit(Order calldata order) external returns (State, uint256) {
    bytes32 key = _orderKey(order);
    require(_state[key] == State.ACCEPTED, "not accepted");

    address input = order.mode == Mode.DEPOSIT ? ASSET : SHARE;
    input.safeTransferFrom(msg.sender, address(this), order.input);

    _state[key] = State.UNLOCKING;
    return (State.UNLOCKING, order.input);
  }

  function recover(Order calldata order) external returns (State, uint256) {
    bytes32 key = _orderKey(order);
    require(_state[key] == State.RECOVERING, "not recovering");

    address input = order.mode == Mode.DEPOSIT ? ASSET : SHARE;
    input.safeTransfer(order.receiver, order.input);

    _state[key] = State.ENDED;
    return (State.ENDED, order.input);
  }

  function unlock(Order calldata order) external returns (State, uint256) {
    bytes32 key = _orderKey(order);
    require(_state[key] == State.UNLOCKING, "not unlocking");

    address output = order.mode == Mode.DEPOSIT ? SHARE : ASSET;
    output.safeTransfer(order.receiver, order.output);

    _state[key] = State.ENDED;
    return (State.ENDED, order.output);
  }

  function state(Order calldata order) external view returns (State) {
    return _state[_orderKey(order)];
  }

  function totalAssets() external pure returns (uint256) {
    return 0;
  }

  function maxDeposit(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function maxRedeem(address) external pure returns (uint256) {
    return type(uint256).max;
  }
}

contract FacilityPositionManagerOpsTest is PositionManagerBaseTest {
  FacilityHarness internal facility;
  MockFund internal fund;
  uint256 internal intentId;

  function setUp() public override {
    super.setUp();

    facility = new FacilityHarness();
    facility.initialize(address(this), address(this), address(0));

    vm.prank(owner);
    positionManager.grantRoles(address(facility), 1 << 0);

    fund = new MockFund(address(debtToken), address(collateralToken));

    Asset memory depositAsset = Asset({asset: address(debtToken), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(positionManager), isPositionManager: true});

    intentId = facility.createIntent(
      CreateIntentParams({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(positionManager),
        fund: address(fund),
        request: address(0),
        depositCap: type(uint256).max,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0
      })
    );

    uint256 debtDeposit = 1_000e18;
    _mintDebt(user, debtDeposit);

    vm.startPrank(user);
    debtToken.approve(address(facility), debtDeposit);
    facility.deposit(intentId, debtDeposit);
    vm.stopPrank();

    facility.lock(intentId);
  }

  function test_RevertWhen_DepositManager_SelectedSideNotPM() public {
    vm.expectRevert(abi.encodeWithSelector(Facility.AssetNotPositionManager.selector, address(debtToken)));
    facility.depositManager(intentId, 1, 0, false);
  }

  function test_PositionManagerOps_UpdateAccountingMatchesBalances() public {
    uint256 fundIn = 400e18;
    uint256 fundOut = 400e18;

    _mintCollateral(address(fund), fundOut);

    facility.create(intentId, fundIn, fundOut, Mode.DEPOSIT);
    facility.commit(intentId);
    facility.unlock(intentId);

    assertEq(
      facility.amountOf(intentId, address(collateralToken)),
      collateralToken.balanceOf(address(facility)),
      "after fund unlock: collateral"
    );
    assertEq(
      facility.amountOf(intentId, address(debtToken)), debtToken.balanceOf(address(facility)), "after fund unlock: debt"
    );

    uint256 depositAmount = fundOut;
    uint256 borrowAmount = 200e18;

    facility.depositManager(intentId, depositAmount, borrowAmount, true);

    assertEq(
      facility.amountOf(intentId, address(collateralToken)),
      collateralToken.balanceOf(address(facility)),
      "after depositManager: collateral"
    );
    assertEq(
      facility.amountOf(intentId, address(debtToken)),
      debtToken.balanceOf(address(facility)),
      "after depositManager: debt"
    );
    assertEq(
      facility.amountOf(intentId, address(positionManager)),
      positionManager.balanceOf(address(facility)),
      "after depositManager: pm shares"
    );

    uint256 withdrawAmount = 100e18;
    uint256 repayAmount = 50e18;

    facility.withdrawManager(intentId, withdrawAmount, repayAmount, true);

    assertEq(
      facility.amountOf(intentId, address(collateralToken)),
      collateralToken.balanceOf(address(facility)),
      "after withdrawManager: collateral"
    );
    assertEq(
      facility.amountOf(intentId, address(debtToken)),
      debtToken.balanceOf(address(facility)),
      "after withdrawManager: debt"
    );
    assertEq(
      facility.amountOf(intentId, address(positionManager)),
      positionManager.balanceOf(address(facility)),
      "after withdrawManager: pm shares"
    );

    uint256 sharesToBurn = positionManager.balanceOf(address(facility)) / 2;
    assertGt(sharesToBurn, 0, "shares to burn");

    facility.burnManager(intentId, sharesToBurn, true);

    assertEq(
      facility.amountOf(intentId, address(collateralToken)),
      collateralToken.balanceOf(address(facility)),
      "after burnManager: collateral"
    );
    assertEq(
      facility.amountOf(intentId, address(debtToken)), debtToken.balanceOf(address(facility)), "after burnManager: debt"
    );
    assertEq(
      facility.amountOf(intentId, address(positionManager)),
      positionManager.balanceOf(address(facility)),
      "after burnManager: pm shares"
    );
  }
}
