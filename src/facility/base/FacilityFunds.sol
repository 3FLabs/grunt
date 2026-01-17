// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {FacilityRoles} from "./FacilityRoles.sol";

import {IFacilityFunds} from "src/interfaces/facility/base/IFacilityFunds.sol";
import {IFund} from "src/interfaces/funds/IFund.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibTokenBalances} from "src/libs/facility/LibTokenBalances.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";
import {Order, Mode, State} from "src/libs/Order.sol";

/// @title FacilityFunds
/// @notice Abstract contract implementing fund operations for intents.
/// @dev Allows creating, canceling, committing, unlocking, and recovering fund orders.
abstract contract FacilityFunds is IFacilityFunds, ReentrancyGuardTransient, FacilityRoles {
  using SafeTransferLib for address;
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityFunds
  /// @dev Creates a fund order for the intent. The intent must be in resolving state
  ///      and must not have an active order. The order is stored in the intent for later operations.
  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
    returns (Order memory order)
  {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    address _fund = _intent.fund;

    if (_fund == address(0)) revert LibErrors.MissingFund(id);
    if (_intent.hasActiveOrder()) revert LibErrors.ActiveOrder(id);

    order = Order({
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: minAmountOut,
      mode: mode,
      salt: keccak256(abi.encode(address(this), block.timestamp, id))
    });

    emit CreatingOrder(id, order.toId(_fund));
    IFund(_fund).create(order);

    _intent.order = order;
  }

  /// @inheritdoc IFacilityFunds
  /// @dev Cancels the current fund order for the intent.
  ///      The intent must have an active order.
  function cancel(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    if (!_intent.hasActiveOrder()) revert LibErrors.NoActiveOrder(id);

    IFund(_intent.fund).cancel(_intent.order);
    delete _intent.order;
  }

  /// @inheritdoc IFacilityFunds
  /// @dev Commits the current fund order for the intent.
  ///      Transfers the input tokens to the fund and calls commit on it.
  ///      The intent must have an active order.
  function commit(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    if (!_intent.hasActiveOrder()) revert LibErrors.NoActiveOrder(id);

    Order memory _order = _intent.order;
    address _fund = _intent.fund;
    address _tokenIn = _order.mode == Mode.DEPOSIT ? IFund(_fund).asset() : IFund(_fund).share();

    _intent.amounts.sub(_tokenIn, _order.input);
    _tokenIn.safeApproveWithRetry(_fund, _order.input);

    IFund(_fund).commit(_order);
    // TODO - emit event for sub
  }

  /// @inheritdoc IFacilityFunds
  /// @dev Unlocks the current fund order for the intent.
  ///      Receives the output tokens from the fund after successful processing.
  ///      Deletes the order if the state reaches ENDED.
  function unlock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    if (!_intent.hasActiveOrder()) revert LibErrors.NoActiveOrder(id);

    Order memory _order = _intent.order;
    address _fund = _intent.fund;

    (State _state, uint256 _unlockedAmount) = IFund(_fund).unlock(_order);
    address _tokenOut = _order.mode == Mode.DEPOSIT ? IFund(_fund).share() : IFund(_fund).asset();

    _intent.amounts.add(_tokenOut, _unlockedAmount);

    // TODO - emit event for add
    if (_state == State.ENDED) {
      delete _intent.order;
    }
  }

  /// @inheritdoc IFacilityFunds
  /// @dev Recovers assets from the current fund order for the intent after failed processing.
  ///      Receives the input tokens back from the fund.
  ///      Deletes the order if the state reaches ENDED.
  function recover(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    if (!_intent.hasActiveOrder()) revert LibErrors.NoActiveOrder(id);

    Order memory _order = _intent.order;
    address _fund = _intent.fund;

    (State _state, uint256 _recoveredAmount) = IFund(_fund).recover(_order);
    address _tokenIn = _order.mode == Mode.DEPOSIT ? IFund(_fund).asset() : IFund(_fund).share();

    _intent.amounts.add(_tokenIn, _recoveredAmount);

    // TODO - emit event for add
    if (_state == State.ENDED) {
      delete _intent.order;
    }
  }
}
