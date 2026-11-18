// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

// Kept free of imports so interfaces can use these types without importing LibIntent,
// which imports IFacility (an import cycle breaks inheritance linearization under Solar).

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
/// @param depositCap Encoded deposit cap word: the max total supply of the intent, or a
///                   reference to a cap in an IFacilityCaps contract (see LibCaps for the layout).
/// @param guardKey Address of the position manager whose transfer guard authorizes intent transfers.
///                  Must equal the deposit asset, the target asset, or both (when both are position managers).
/// @param resolveStart Timestamp at which the deposit phase ends and the resolving phase begins.
/// @param quorum Quorum threshold required for guard approvals.
/// @param transferableIntent If false, intent token transfers are disabled (mint/burn unaffected).
struct IntentProperties {
  Asset depositAsset;
  Asset targetAsset;
  uint256 depositCap;
  address guardKey;
  uint40 resolveStart;
  uint8 quorum;
  bool transferableIntent;
}
