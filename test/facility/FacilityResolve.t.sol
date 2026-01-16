// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IIntentDescriptor} from "src/interfaces/IIntentDescriptor.sol";
import {Asset} from "src/interfaces/IFacility.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

import {IFund} from "src/interfaces/funds/IFund.sol";
import {Order, Mode, State, Id} from "src/libs/Order.sol";

contract MockFundState is IFund {
  address internal immutable ASSET;
  address internal immutable SHARE;

  mapping(bytes32 => State) internal _stateById;

  constructor(address asset_, address share_) {
    ASSET = asset_;
    SHARE = share_;
  }

  function _id(Order memory order) internal view returns (bytes32) {
    return Id.unwrap(order.toId(address(this)));
  }

  function forceState(Order calldata order, State state_) external {
    _stateById[Id.unwrap(order.toId(address(this)))] = state_;
  }

  function create(Order calldata order) external returns (State) {
    _stateById[_id(order)] = State.ACCEPTED;
    return State.ACCEPTED;
  }

  function cancel(Order calldata order) external returns (State) {
    delete _stateById[_id(order)];
    return State.EMPTY;
  }

  function commit(Order calldata order) external returns (State, uint256) {
    _stateById[_id(order)] = State.PROCESSING;
    return (State.PROCESSING, order.input);
  }

  function recover(Order calldata order) external returns (State, uint256) {
    _stateById[_id(order)] = State.ENDED;
    return (State.ENDED, order.input);
  }

  function unlock(Order calldata order) external returns (State, uint256) {
    _stateById[_id(order)] = State.ENDED;
    return (State.ENDED, order.output);
  }

  function state(Order calldata order) external view returns (State) {
    return _stateById[Id.unwrap(order.toId(address(this)))];
  }

  function asset() external view returns (address) {
    return ASSET;
  }

  function share() external view returns (address) {
    return SHARE;
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

contract FacilityResolveTest is Test {
  Facility internal facility;

  PositionManager internal pm;
  MockERC20 internal collateral;
  MockERC20 internal debt;

  MockFundState internal fund;

  function setUp() public {
    facility = new Facility();
    facility.initialize(address(this), address(this), IIntentDescriptor(address(0)));

    collateral = new MockERC20("Collateral", "COL", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    pm = new PositionManager();
    pm.initialize(address(this), "PM", "PM", 6, address(collateral), address(debt), 0.8e18);

    fund = new MockFundState(address(debt), address(collateral));
  }

  function _createIntentWithFund() internal returns (uint256 id) {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    id = facility.createIntent(
      depositAsset,
      targetAsset,
      address(pm),
      address(fund),
      address(0),
      type(uint256).max,
      uint40(block.timestamp + 1 days),
      0
    );
  }

  function test_Resolve_AcceptsWhen_NoActiveOrder() public {
    uint256 id = _createIntentWithFund();

    facility.lock(id);
    facility.resolve(id);

    vm.expectRevert(abi.encodeWithSelector(Facility.AlreadyResolved.selector, id));
    facility.lock(id);
  }

  function test_RevertWhen_Resolve_ActiveOrderNotEnded() public {
    uint256 id = _createIntentWithFund();

    facility.lock(id);

    facility.create(id, 1, 1, Mode.DEPOSIT);

    vm.expectRevert(abi.encodeWithSelector(Facility.OrderNotEnded.selector, id));
    facility.resolve(id);
  }
}
