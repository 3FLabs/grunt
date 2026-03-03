// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title Order
/// @author 3F Protocol
/// @notice Defines order types, states, and the Order struct used in the async deposit/redeem flow.

/// @notice The order mode indicating the type of operation.
/// @dev Used to distinguish between deposit and redeem operations in the async flow.
enum Mode {
  /// @notice A deposit operation where the user provides assets to receive shares.
  DEPOSIT,
  /// @notice A redeem operation where the user provides shares to receive assets.
  REDEEM
}

/// @notice The seven possible states of an order lifecycle.
/// @dev Orders progress through these states during the async deposit/redeem process.
enum State {
  /// @notice No order exists (default state).
  EMPTY,
  /// @notice Order has been accepted but not yet committed.
  ACCEPTED,
  /// @notice Order is pending execution (committed but not yet processed).
  PENDING,
  /// @notice Order is being processed by an external system (e.g., Superstate).
  PROCESSING,
  /// @notice Order is unlocking and ready for user to claim.
  UNLOCKING,
  /// @notice Order is in recovery mode due to an error or timeout.
  RECOVERING,
  /// @notice Order has completed (successfully or via recovery).
  ENDED
}

/// @notice The structure defining a deposit or redemption order.
/// @dev Orders are identified by their keccak256 hash including chain ID and fund address.
/// @param mode The mode of the order (DEPOSIT or REDEEM).
/// @param owner The address initiating the order.
/// @param receiver The address receiving the output of the order.
/// @param input The amount of input assets for DEPOSIT, or shares for REDEEM.
/// @param output The amount of output shares for DEPOSIT, or assets for REDEEM.
/// @param salt A unique salt to differentiate orders with the same parameters.
struct Order {
  Mode mode;
  address owner;
  address receiver;
  uint256 input;
  uint256 output;
  bytes32 salt;
}

/// @title LibOrder
/// @author 3F Protocol
/// @notice Library for computing order IDs.
library LibOrder {
  /// @notice Computes the unique ID of an order.
  /// @dev The ID is chain-specific and includes the fund address to prevent cross-chain/cross-fund collisions.
  ///      Computes `keccak256(abi.encode(block.chainid, fund, order))` using memory-safe assembly.
  /// @param order The order to compute the ID for.
  /// @param fund The address of the fund (IFund) creating the order.
  /// @return id The unique ID of the order as bytes32.
  function toId(Order memory order, address fund) internal view returns (bytes32 id) {
    if (order.owner == address(0)) return id;
    assembly ("memory-safe") {
      // load the free memory pointer
      let start := mload(0x40)
      // store the chain ID
      mstore(start, chainid())
      // store the fund address
      mstore(add(start, 0x20), fund)
      // store the order
      mcopy(add(start, 0x40), order, 0xC0)
      // compute the hash
      id := keccak256(start, 0x100)
    }
  }
}
