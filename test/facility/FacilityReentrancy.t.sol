// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IIntentDescriptor} from "src/interfaces/IIntentDescriptor.sol";
import {Asset, CreateIntentParams} from "src/interfaces/IFacility.sol";

import {IFund} from "src/interfaces/funds/IFund.sol";
import {Order, Mode, State} from "src/libs/Order.sol";

import {PositionManager} from "src/manager/PositionManager.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

contract FacilityReentrancyHarness is Facility {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

  function amountOf(uint256 id, address token) external view returns (uint256) {
    FacilityStorage storage $ = _facilityStorage();
    (bool exists, uint256 value) = $.intents[id].amounts.tryGet(token);
    return exists ? value : 0;
  }
}

contract ReentrantFund is IFund {
  using SafeTransferLib for address;

  Facility public immutable facility;
  uint256 public immutable intentId;

  address public immutable ASSET;
  address public immutable SHARE;

  bool public attackTriggered;
  bytes public lastRevertReason;

  bytes32 public currentOrderId;

  constructor(Facility facility_, uint256 intentId_, address asset_, address share_) {
    facility = facility_;
    intentId = intentId_;
    ASSET = asset_;
    SHARE = share_;
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

  function _id(Order calldata order) internal view returns (bytes32) {
    return keccak256(abi.encode(block.chainid, address(this), order));
  }

  function state(Order calldata order) external view returns (State) {
    return _id(order) == currentOrderId ? State.ACCEPTED : State.EMPTY;
  }

  function create(Order calldata order) external returns (State) {
    currentOrderId = _id(order);
    return State.ACCEPTED;
  }

  function cancel(Order calldata order) external returns (State) {
    require(_id(order) == currentOrderId, "bad order");
    currentOrderId = bytes32(0);
    return State.EMPTY;
  }

  function commit(Order calldata order) external returns (State, uint256) {
    require(_id(order) == currentOrderId, "bad order");

    address tokenIn = order.mode == Mode.DEPOSIT ? ASSET : SHARE;
    tokenIn.safeTransferFrom(msg.sender, address(this), order.input);

    if (!attackTriggered) {
      attackTriggered = true;
      try facility.commit(intentId) {}
      catch (bytes memory reason) {
        lastRevertReason = reason;
      }
    }

    return (State.PROCESSING, order.input);
  }

  function recover(Order calldata) external pure returns (State, uint256) {
    revert("not used");
  }

  function unlock(Order calldata) external pure returns (State, uint256) {
    revert("not used");
  }

  function wasReentrancyError() external view returns (bool) {
    bytes memory reason = lastRevertReason;
    if (reason.length < 4) return false;
    bytes4 selector;
    assembly {
      selector := mload(add(reason, 32))
    }
    return selector == ReentrancyGuardTransient.Reentrancy.selector;
  }
}

contract FacilityReentrancyTest is Test {
  FacilityReentrancyHarness internal facility;
  MockERC20 internal asset;
  MockERC20 internal share;
  PositionManager internal pm;

  function test_ReentrancyGuard_BlocksReenteringCommit() public {
    facility = new FacilityReentrancyHarness();
    facility.initialize(address(this), address(this), address(0));

    asset = new MockERC20("Debt", "DEBT", 6);
    share = new MockERC20("Collateral", "COL", 18);

    pm = new PositionManager();
    pm.initialize(address(this), "PM", "PM", 18, address(share), address(asset), 0.8e18);

    // Create the intent first with a placeholder fund, then swap in the reentrant fund.
    Asset memory depositAsset = Asset({asset: address(asset), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    uint256 id = facility.createIntent(
      CreateIntentParams({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(pm),
        fund: address(0),
        request: address(0),
        depositCap: type(uint256).max,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0
      })
    );

    // Deploy reentrant fund and set as intent fund via updateTarget (keeps invariants) is not possible.
    // Use storage-level fact: createIntent already stored fund=0, but fund ops require fund!=0.
    // For this test we create a second intent that includes the fund from the start.
    ReentrantFund fund = new ReentrantFund(facility, id + 1, address(asset), address(share));

    uint256 id2 = facility.createIntent(
      CreateIntentParams({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(pm),
        fund: address(fund),
        request: address(0),
        depositCap: type(uint256).max,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0
      })
    );

    // Give the fund facilitator role so it can reenter a guarded path.
    facility.grantRoles(address(fund), 1 << 0);

    // Seed the intent with assets (deposit phase).
    asset.mint(address(this), 1_000_000);
    asset.approve(address(facility), 1_000_000);
    facility.deposit(id2, 1_000_000);

    facility.lock(id2);

    facility.create(id2, 100_000, 0, Mode.DEPOSIT);
    facility.commit(id2);

    assertTrue(fund.attackTriggered(), "attack triggered");
    assertTrue(fund.wasReentrancyError(), "reentrancy blocked");

    // Accounting still consistent after outer commit.
    assertEq(facility.amountOf(id2, address(asset)), asset.balanceOf(address(facility)), "asset accounting");
  }
}
