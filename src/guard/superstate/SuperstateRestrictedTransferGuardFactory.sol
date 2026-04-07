// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {SuperstateRestrictedTransferGuard} from "./SuperstateRestrictedTransferGuard.sol";
import {TransferGuardFactoryBase} from "../TransferGuardFactoryBase.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";

/// @title SuperstateRestrictedTransferGuardFactory
/// @author 3F Protocol
/// @notice Factory for deploying SuperstateRestrictedTransferGuard instances via beacon proxy pattern.
/// @dev The Superstate token address is baked into the implementation at construction time,
///      so all proxies deployed by this factory enforce the same Superstate allowlist.
contract SuperstateRestrictedTransferGuardFactory is TransferGuardFactoryBase {
  /// @notice Deploys the factory with a beacon pointing to a SuperstateRestrictedTransferGuard implementation.
  /// @param initialBeaconOwner The address that will own the beacon
  /// @param superstateToken The Superstate token address for allowlist checks
  constructor(address initialBeaconOwner, address superstateToken)
    TransferGuardFactoryBase(address(
        new UpgradeableBeacon(initialBeaconOwner, address(new SuperstateRestrictedTransferGuard(superstateToken)))
      ))
  {}

  /// @inheritdoc TransferGuardFactoryBase
  function _initializeGuard(address guard, address owner) internal override {
    SuperstateRestrictedTransferGuard(guard).initialize(owner);
  }
}
