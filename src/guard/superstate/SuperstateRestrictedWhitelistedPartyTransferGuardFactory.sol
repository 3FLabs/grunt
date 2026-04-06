// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {SuperstateRestrictedWhitelistedPartyTransferGuard} from
  "./SuperstateRestrictedWhitelistedPartyTransferGuard.sol";
import {TransferGuardFactoryBase} from "../TransferGuardFactoryBase.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";

/// @title SuperstateRestrictedWhitelistedPartyTransferGuardFactory
/// @author 3F Protocol
/// @notice Factory for deploying SuperstateRestrictedWhitelistedPartyTransferGuard instances.
/// @dev Combines the whitelisted-party guard with Superstate allowlist enforcement.
///      The Superstate token address is baked into the implementation at construction time.
contract SuperstateRestrictedWhitelistedPartyTransferGuardFactory is TransferGuardFactoryBase {
  /// @notice Deploys the factory with a beacon pointing to the guard implementation.
  /// @param initialBeaconOwner The address that will own the beacon
  /// @param superstateToken The Superstate token address for allowlist checks
  constructor(address initialBeaconOwner, address superstateToken)
    TransferGuardFactoryBase(
      address(
        new UpgradeableBeacon(
          initialBeaconOwner,
          address(new SuperstateRestrictedWhitelistedPartyTransferGuard(superstateToken))
        )
      )
    )
  {}

  /// @inheritdoc TransferGuardFactoryBase
  function _initializeGuard(address guard, address owner) internal override {
    SuperstateRestrictedWhitelistedPartyTransferGuard(guard).initialize(owner);
  }
}
