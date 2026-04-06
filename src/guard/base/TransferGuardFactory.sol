// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {TransferGuard} from "./TransferGuard.sol";
import {TransferGuardFactoryBase} from "../TransferGuardFactoryBase.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";

/// @title TransferGuardFactory
/// @author 3F Protocol
/// @notice Factory contract for deploying TransferGuard instances.
/// @dev Extends TransferGuardFactoryBase with TransferGuard-specific beacon deployment.
///
///      Architecture:
///      - One beacon is deployed at construction time with the TransferGuard implementation
///      - The beacon owner can upgrade all proxies by updating the beacon's implementation
///      - Each `createTransferGuard` call deploys one proxy: TransferGuard
///
///      Deployment Flow:
///      1. Factory is deployed with an initial beacon owner
///      2. Constructor deploys implementation and wraps it in an UpgradeableBeacon
///      3. Users call `createTransferGuard()` to deploy new TransferGuard instances
///      4. Each transfer guard is initialized with its owner
///
///      Upgrade Flow:
///      1. Beacon owner deploys new TransferGuard implementation contract
///      2. Beacon owner calls `upgradeTo()` on the beacon
///      3. All existing proxies immediately use the new implementation
contract TransferGuardFactory is TransferGuardFactoryBase {
  /// @notice Deploys the factory and creates the beacon contract with the TransferGuard implementation.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  constructor(address initialBeaconOwner)
    TransferGuardFactoryBase(address(new UpgradeableBeacon(initialBeaconOwner, address(new TransferGuard()))))
  {}

  /// @inheritdoc TransferGuardFactoryBase
  function _initializeGuard(address guard, address owner) internal override {
    TransferGuard(guard).initialize(owner);
  }
}
