// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {WhitelistedPartyTransferGuard} from "./WhitelistedPartyTransferGuard.sol";
import {TransferGuardFactoryBase} from "../TransferGuardFactoryBase.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";

/// @title WhitelistedPartyTransferGuardFactory
/// @author 3F Protocol
/// @notice Factory for deploying WhitelistedPartyTransferGuard instances via beacon proxy pattern.
/// @dev Architecture mirrors TransferGuardFactory:
///      - One UpgradeableBeacon is deployed at construction time
///      - Each `createTransferGuard` call deploys an ERC1967 beacon proxy
///      - Beacon owner can upgrade all proxies by updating the beacon's implementation
contract WhitelistedPartyTransferGuardFactory is TransferGuardFactoryBase {
  /// @notice Deploys the factory and creates the beacon with a WhitelistedPartyTransferGuard implementation.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  constructor(address initialBeaconOwner)
    TransferGuardFactoryBase(address(
        new UpgradeableBeacon(initialBeaconOwner, address(new WhitelistedPartyTransferGuard()))
      ))
  {}

  /// @inheritdoc TransferGuardFactoryBase
  function _initializeGuard(address guard, address owner) internal override {
    WhitelistedPartyTransferGuard(guard).initialize(owner);
  }
}
