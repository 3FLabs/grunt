// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Multicallable} from "lib/solady/src/utils/Multicallable.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

import {FacilitySwap} from "./base/FacilitySwap.sol";
import {FacilityLP} from "./base/FacilityLP.sol";
import {FacilityRequests} from "./base/FacilityRequests.sol";
import {FacilityPositionManager} from "./base/FacilityPositionManager.sol";
import {FacilityFunds} from "./base/FacilityFunds.sol";
import {FacilityIntents} from "./base/FacilityIntents.sol";

import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {IIntentDescriptor} from "src/interfaces/facility/IIntentDescriptor.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {ITransferGuard} from "src/interfaces/guard/ITransferGuard.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";

import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";
import {LibChecks} from "src/libs/common/LibChecks.sol";
import {LibPause} from "src/libs/common/LibPause.sol";

/// @title Facility
/// @author 3F Protocol
/// @notice Main contract combining all facility functionality for managing intents, funds, requests, position managers, LPs, and swaps.
/// @dev Inherits from all abstract facility components and implements required abstract functions.
contract Facility is
  IFacility,
  FacilitySwap,
  FacilityLP,
  FacilityRequests,
  FacilityPositionManager,
  FacilityFunds,
  FacilityIntents,
  Multicallable,
  Initializable
{
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;
  using LibChecks for address;
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using LibPause for uint40;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the Facility contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the facilitator can execute operations.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param facilitator_ The address to be granted the FACILITATOR_ROLE.
  /// @param descriptor_ The initial intent descriptor contract.
  function initialize(address owner_, address facilitator_, address descriptor_) public initializer {
    owner_.checkNotZero();
    _initializeOwner(owner_);
    _setDescriptor(descriptor_);
    _setRoles(facilitator_, FACILITATOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function paused() external view override returns (bool isPaused, uint40 pausedUntil) {
    pausedUntil = LibStorage.facilityStorage().pausedUntil;
    isPaused = pausedUntil.paused();
  }

  /// @inheritdoc IFacility
  function intentBalances(uint256 id)
    external
    view
    override
    returns (address[] memory tokens, uint256[] memory amounts)
  {
    Intent storage _intent = LibStorage.facilityStorage().getIntent(id);
    tokens = _intent.amounts.keys();
    uint256 length = tokens.length;
    amounts = new uint256[](length);
    for (uint256 i = 0; i < length; i++) {
      amounts[i] = _intent.amounts.get(tokens[i]);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         DESCRIPTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function setDescriptor(address descriptor_) external override onlyOwner {
    _setDescriptor(descriptor_);
  }

  /// @dev Internal function to set the intent descriptor contract.
  /// @param descriptor_ The new descriptor contract address.
  function _setDescriptor(address descriptor_) internal {
    descriptor_.checkContract();
    LibStorage.facilityStorage().descriptor = IIntentDescriptor(descriptor_);
    emit DescriptorSet(descriptor_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PAUSE                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function pause() external override onlyOwnerOrRoles(PAUSER_ROLE) {
    LibStorage.facilityStorage().pausedUntil = LibPause.PERMANENT_PAUSE;
    emit FacilityPausedSet(LibPause.PERMANENT_PAUSE);
  }

  /// @inheritdoc IFacility
  function pauseFor(uint256 duration) external override onlyOwnerOrRoles(PAUSER_ROLE) {
    uint40 pauseUntil = LibPause.pauseFor(duration);
    LibStorage.facilityStorage().pausedUntil = pauseUntil;
    emit FacilityPausedSet(pauseUntil);
  }

  /// @inheritdoc IFacility
  function unpause() external override onlyOwnerOrRoles(PAUSER_ROLE) {
    LibStorage.facilityStorage().pausedUntil = LibPause.NOT_PAUSED;
    emit FacilityPausedSet(LibPause.NOT_PAUSED);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERC-6909                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the decimals for the given intent's deposit asset.
  function decimals(uint256 id) public view override returns (uint8) {
    Intent storage _intent = LibStorage.facilityStorage().getIntent(id);
    return IERC20(_intent.properties.depositAsset.asset).decimals();
  }

  /// @dev Returns the name for the given intent from the descriptor.
  function name(uint256 id) public view override returns (string memory) {
    return LibStorage.facilityStorage().descriptor.name(IFacility(address(this)), id);
  }

  /// @dev Returns the symbol for the given intent from the descriptor.
  function symbol(uint256 id) public view override returns (string memory) {
    return LibStorage.facilityStorage().descriptor.symbol(IFacility(address(this)), id);
  }

  /// @dev Returns the token URI for the given intent from the descriptor.
  function tokenURI(uint256 id) public view override returns (string memory) {
    return LibStorage.facilityStorage().descriptor.tokenURI(IFacility(address(this)), id);
  }

  /// @notice Returns total supply for a given intent.
  /// @param id The intent ID.
  /// @return The total supply.
  function totalSupply(uint256 id) public view returns (uint256) {
    return LibStorage.facilityStorage().getIntent(id).totalSupply;
  }

  /// @dev Hook called before any token transfer. Handles transfer guards and total supply tracking.
  function _beforeTokenTransfer(address from, address to, uint256 id, uint256 amount) internal override {
    LibStorage.checkNotPaused();
    Intent storage _intent = LibStorage.facilityStorage().getIntent(id);

    if (from != address(0) && to != address(0) && !_intent.properties.transferableIntent) {
      revert LibErrors.IntentTransfersLocked(id);
    }

    (,, address guard) = IPositionManager(_intent.properties.guardKey).config();
    if (guard != address(0)) {
      if (!ITransferGuard(guard).canTransfer(_intent.properties.guardKey, from, to, amount)) {
        revert LibErrors.TransferBlocked(guard, from, to, amount);
      }
    }

    if (from == address(0) && to != address(0)) {
      _intent.totalSupply += amount;
    } else if (from != address(0) && to == address(0)) {
      _intent.totalSupply -= amount;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EIP-712                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the EIP-712 domain name and version.
  function _domainNameAndVersion() internal pure override returns (string memory name_, string memory version) {
    name_ = "3Facility";
    version = "1.0.0";
  }

  /// @dev Returns whether the domain name and version may change.
  function _domainNameAndVersionMayChange() internal pure override returns (bool) {
    return true;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   REENTRANCY GUARD TRANSIENT               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns whether to use transient reentrancy guard only on mainnet.
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
