// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {Order} from "../Order.sol";

/// @dev Asset configuration for intents and swaps.
/// @param asset Address of the asset.
/// @param isPositionManager Whether the asset represents a position manager.
struct Asset {
  address asset;
  bool isPositionManager;
}

/// @dev Configuration values that define an intent's behavior.
/// @param depositAsset Asset deposited into the intent.
/// @param targetAsset Target asset or position manager for the intent.
/// @param depositCap Maximum amount that can be deposited into the intent.
/// @param guardKey Guard key address associated with intent authorization.
/// @param resolveStart Earliest timestamp when the intent can be resolved.
/// @param quorum Quorum threshold required for guard approvals.
struct IntentProperties {
  Asset depositAsset;
  Asset targetAsset;
  uint256 depositCap;
  address guardKey;
  uint40 resolveStart;
  uint8 quorum;
}

/// @dev Intent state for a facility request, including configuration and accounting.
/// @param properties Static configuration for the intent.
/// @param fund Fund address associated with the intent.
/// @param request Request contract address associated with the intent.
/// @param resolved Whether the intent has been resolved and claims are enabled.
/// @param amounts Per-address accounting balances for the intent.
/// @param order Current fund order associated with the intent.
/// @param totalSupply Total supply tracked for the intent.
struct Intent {
  IntentProperties properties;
  address fund;
  address request;
  bool resolved;
  EnumerableMapLib.AddressToUint256Map amounts;
  Order order;
  uint256 totalSupply;
}
