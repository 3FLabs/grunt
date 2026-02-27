// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "../IFund.sol";
import {Mode} from "../../../libs/funds/Order.sol";

/// @title IParetoFund
/// @author 3F Protocol
/// @notice Interface for the ParetoFund contract that wraps the Pareto (Idle Finance) CDO Epoch Variant.
/// @dev Extends IFund with Pareto-specific events, initialization, and view functions.
///      No recovery functions are needed: deposits are atomic (depositAA succeeds or reverts),
///      and withdrawals always complete after the epoch ends (no cancel mechanism in the CDO).
interface IParetoFund is IFund {
  // EVENTS
  event OrderCreated(
    bytes32 indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);

  // INITIALIZATION
  function initialize(address owner_, address depositor_, address vault_, address wrappedShare_) external;

  // VIEWS
  function vault() external view returns (address);
}
