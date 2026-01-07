// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @dev The order types.
enum Mode {
  DEPOSIT,
  REDEEM
}

/// @dev The seven possible states of an order lifecycle.
enum State {
  EMPTY,
  ACCEPTED,
  PENDING,
  PROCESSING,
  UNLOCKING,
  RECOVERING,
  ENDED
}

/// @dev The structure defining a deposit or redemption order.
/// @param owner The address initiating the order.
/// @param receiver The address receiving the output of the order.
/// @param input The amount of input assets for DEPOSIT, or shares for REDEEM.
/// @param output The amount of output shares for DEPOSIT, or assets for REDEEM.
/// @param mode The mode of the order (DEPOSIT or REDEEM).
/// @param salt A unique salt to differentiate orders (with same parameters)
struct Order {
  address owner;
  address receiver;
  uint256 input;
  uint256 output;
  Mode mode;
  bytes32 salt;
}

type Id is bytes32;

/// @notice Library for computing the ID of an order
library IdLibrary {
  /// @dev Returns the unique Id of an order equal to keccak256(abi.encode(block.chainid, fund, order)).
  /// @param order The order to compute the Id for.
  /// @param fund The address of the fund (IFund) creating the order.
  /// @return The unique Id of the order.
  function toId(Order memory order, address fund) internal view returns (Id) {
    return Id.wrap(keccak256(abi.encode(block.chainid, fund, order)));
  }

  /// @dev Compares two Ids.
  /// @param self The first Id.
  /// @param other The second Id.
  /// @return True if the Ids are equal.
  function eq(Id self, Id other) internal pure returns (bool) {
    return Id.unwrap(self) == Id.unwrap(other);
  }
}

using IdLibrary for Order global;
using IdLibrary for Id global;
