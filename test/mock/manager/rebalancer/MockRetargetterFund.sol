// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "src/interfaces/funds/IFund.sol";
import {IRetargetter} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title MockRetargetterFund
/// @notice Mock IFund with a realistic single-slot order lifecycle and settable settlement,
///         used to exercise the Retargetter end to end.
/// @dev Mirrors the real funds' semantics: owner == receiver == msg.sender enforced at create,
///      one live order at a time (PendingOrder), ended order ids archived (OrderAlreadyExists
///      on salt reuse), state derived dynamically from the settlement flags. Tokens really
///      move: commit pulls the input from the caller, unlock mints the output to the receiver
///      at the current share price, recover returns the pulled input.
///
///      Test controls:
///      - `setSharePrice`: asset value of one share (WAD); conversions happen at unlock time,
///        so changing it between commit and unlock simulates settlement price drift
///      - `setSyncSettlement(true)`: orders become unlockable in the commit transaction
///      - `settle()`: makes an asynchronous order unlockable
///      - `failProcessing()`: moves a committed order to RECOVERING
///      - `setPartialUnlockBps`: the next unlock pays only that fraction and stays live
///      - `setCreateReturnsPending(true)`: create parks the order in PENDING
///      - `forceEnd()`: out-of-band termination, archiving the order as ENDED
contract MockRetargetterFund is IFund {
  using SafeTransferLib for address;
  using LibOrder for Order;

  uint256 internal constant WAD = 1e18;
  uint256 internal constant BPS = 10_000;

  address public immutable ASSET;
  address public immutable SHARE;

  uint256 public sharePrice = WAD;
  bool public syncSettlement;
  bool public createReturnsPending;
  uint16 public partialUnlockBps;

  bytes32 public currentOrderId;
  State internal _internalState;
  bool internal _settled;
  bool internal _recovering;
  Mode internal _mode;
  uint256 internal _pendingInput;
  mapping(bytes32 => bool) public endedOrders;

  constructor(address asset_, address share_) {
    ASSET = asset_;
    SHARE = share_;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST CONTROLS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setSharePrice(uint256 sharePrice_) external {
    sharePrice = sharePrice_;
  }

  function setSyncSettlement(bool syncSettlement_) external {
    syncSettlement = syncSettlement_;
  }

  function setCreateReturnsPending(bool pending_) external {
    createReturnsPending = pending_;
  }

  function setPartialUnlockBps(uint16 partialUnlockBps_) external {
    partialUnlockBps = partialUnlockBps_;
  }

  /// @notice Makes the committed order unlockable (asynchronous settlement completing).
  function settle() external {
    _settled = true;
  }

  /// @notice Moves the committed order to RECOVERING (asynchronous settlement failing).
  function failProcessing() external {
    _recovering = true;
  }

  /// @notice Ends the live order out of band, mirroring a fund-operator force-end.
  function forceEnd() external {
    endedOrders[currentOrderId] = true;
    _clearCurrent();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      IFund OPERATIONS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function create(Order calldata order) external override returns (State) {
    if (order.input == 0) revert LibFundsErrors.InvalidState(State.EMPTY);
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();
    if (order.receiver != msg.sender) revert LibFundsErrors.InvalidReceiver();
    if (currentOrderId != bytes32(0)) revert LibFundsErrors.PendingOrder();
    bytes32 orderId = order.toId(address(this));
    if (endedOrders[orderId]) revert LibFundsErrors.OrderAlreadyExists(orderId);
    currentOrderId = orderId;
    _internalState = createReturnsPending ? State.PENDING : State.ACCEPTED;
    _mode = order.mode;
    return _internalState;
  }

  function cancel(Order calldata order) public virtual override returns (State) {
    _checkOrder(order);
    State current = _state();
    if (current != State.ACCEPTED && current != State.PENDING) revert LibFundsErrors.InvalidState(current);
    _clearCurrent();
    return State.EMPTY;
  }

  function commit(Order calldata order) external override returns (State, uint256) {
    _checkOrder(order);
    if (_state() != State.ACCEPTED) revert LibFundsErrors.InvalidState(_state());
    address inputToken = order.mode == Mode.DEPOSIT ? ASSET : SHARE;
    inputToken.safeTransferFrom(msg.sender, address(this), order.input);
    _pendingInput = order.input;
    _internalState = State.PROCESSING;
    if (syncSettlement) _settled = true;
    return (State.PROCESSING, order.input);
  }

  function unlock(Order calldata order) external override returns (State, uint256) {
    _checkOrder(order);
    if (_state() != State.UNLOCKING) revert LibFundsErrors.InvalidState(_state());
    uint256 inputConsumed = _pendingInput;
    if (partialUnlockBps > 0) {
      inputConsumed = _pendingInput * partialUnlockBps / BPS;
      partialUnlockBps = 0;
    }
    uint256 payout = _convertOutput(order.mode, inputConsumed);
    address outputToken = order.mode == Mode.DEPOSIT ? SHARE : ASSET;
    MockERC20(outputToken).mint(order.receiver, payout);
    _pendingInput -= inputConsumed;
    if (_pendingInput > 0) return (State.PROCESSING, payout);
    endedOrders[currentOrderId] = true;
    _clearCurrent();
    return (State.ENDED, payout);
  }

  function recover(Order calldata order) external override returns (State, uint256) {
    _checkOrder(order);
    if (_state() != State.RECOVERING) revert LibFundsErrors.InvalidState(_state());
    uint256 recovered = _pendingInput;
    address inputToken = order.mode == Mode.DEPOSIT ? ASSET : SHARE;
    inputToken.safeTransfer(order.receiver, recovered);
    _pendingInput = 0;
    endedOrders[currentOrderId] = true;
    _clearCurrent();
    return (State.ENDED, recovered);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        IFund VIEWS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function state(Order calldata order) external view override returns (State) {
    bytes32 orderId = order.toId(address(this));
    if (endedOrders[orderId]) return State.ENDED;
    if (orderId != currentOrderId) return State.EMPTY;
    return _state();
  }

  function asset() external view override returns (address) {
    return ASSET;
  }

  function share() external view override returns (address) {
    return SHARE;
  }

  function totalAssets() external view override returns (uint256) {
    return ASSET.balanceOf(address(this));
  }

  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  function maxRedeem(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _checkOrder(Order calldata order) internal view {
    bytes32 orderId = order.toId(address(this));
    if (orderId != currentOrderId || orderId == bytes32(0)) revert LibFundsErrors.InvalidState(State.EMPTY);
  }

  function _state() internal view returns (State) {
    if (_internalState == State.PROCESSING) {
      if (_recovering) return State.RECOVERING;
      if (_settled) return State.UNLOCKING;
    }
    return _internalState;
  }

  function _convertOutput(Mode mode, uint256 input) internal view returns (uint256) {
    return mode == Mode.DEPOSIT ? input * WAD / sharePrice : input * sharePrice / WAD;
  }

  function _clearCurrent() internal {
    currentOrderId = bytes32(0);
    _internalState = State.EMPTY;
    _settled = false;
    _recovering = false;
    _pendingInput = 0;
  }
}

/// @title ReenteringMockFund
/// @notice MockRetargetterFund whose cancel calls back into the calling Retargetter's
///         cancelOrder before proceeding, exercising the reentrancy guard end to end. The
///         test grants the fund the rebalancer role so the reentrant call passes
///         authorization and reaches the guard.
contract ReenteringMockFund is MockRetargetterFund {
  constructor(address asset_, address share_) MockRetargetterFund(asset_, share_) {}

  function cancel(Order calldata order) public override returns (State) {
    IRetargetter(msg.sender).cancelOrder();
    return super.cancel(order);
  }
}

/// @title StickyCancelMockFund
/// @notice MockRetargetterFund whose cancel acknowledges the call but reports the order
///         still PROCESSING instead of EMPTY, mirroring a future fund that keeps processing
///         a canceled order; used to pin the Retargetter's cancel state check.
contract StickyCancelMockFund is MockRetargetterFund {
  constructor(address asset_, address share_) MockRetargetterFund(asset_, share_) {}

  function cancel(Order calldata order) public view override returns (State) {
    _checkOrder(order);
    return State.PROCESSING;
  }
}
