// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {IInKindFacility, EntryOffer, ExitOffer, Auth} from "../../../interfaces/facility/IInKindFacility.sol";
import {LibCaps} from "../LibCaps.sol";
import {LibPause} from "../../common/LibPause.sol";
import {LibCommonErrors} from "../../common/LibCommonErrors.sol";

/// @notice Storage struct containing all persistent state for the InKindFacility contract.
/// @param entries Entry offer per position manager.
/// @param exits Exit offer per position manager.
/// @param securityCaps Security cap word per underlying asset.
/// @param auths User auths per underlying asset.
/// @param feeRecipient Recipient of the share fees of both sides.
/// @param pausedUntil Pause-until timestamp (see LibPause).
struct InKindStorageData {
  mapping(address positionManager => EntryOffer) entries;
  mapping(address positionManager => ExitOffer) exits;
  mapping(address asset => uint256) securityCaps;
  mapping(address asset => mapping(address user => Auth)) auths;
  address feeRecipient;
  uint40 pausedUntil;
}

/// @title LibInKindStorage
/// @author 3F Protocol
/// @notice Storage accessor, offer gating and cap consumption for the InKindFacility contract.
library LibInKindStorage {
  using LibCaps for uint256;
  using LibPause for uint40;
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage slot of the facility state.
  /// @dev Computed as: keccak256("facility.inkind.storage")
  /// @custom:value 0xca588c75c16c13263b4eb28c18c53ab9e5eef731302e0192c05b7a1eaaf2f463
  bytes32 internal constant STORAGE_SLOT = 0xca588c75c16c13263b4eb28c18c53ab9e5eef731302e0192c05b7a1eaaf2f463;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       STORAGE ACCESS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns a reference to the contract's storage struct.
  function inKindStorage() internal pure returns (InKindStorageData storage data) {
    bytes32 slot = STORAGE_SLOT;
    assembly ("memory-safe") {
      data.slot := slot
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OFFERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts with Paused while the facility-wide pause is active.
  function checkNotPaused(InKindStorageData storage self) internal view {
    if (self.pausedUntil.paused()) revert LibCommonErrors.Paused();
  }

  /// @dev Returns the entry offer of `positionManager`, reverting with Paused while the facility
  ///      is paused and with UnknownEntry when the offer is disabled or expired.
  function getEnabledEntry(InKindStorageData storage self, address positionManager)
    internal
    view
    returns (EntryOffer storage offer)
  {
    checkNotPaused(self);
    offer = self.entries[positionManager];
    if (block.timestamp >= offer.expiry) revert IInKindFacility.UnknownEntry(positionManager);
  }

  /// @dev Returns the exit offer of `positionManager`, reverting with Paused while the facility
  ///      is paused and with UnknownExit when the offer is disabled or expired.
  function getEnabledExit(InKindStorageData storage self, address positionManager)
    internal
    view
    returns (ExitOffer storage offer)
  {
    checkNotPaused(self);
    offer = self.exits[positionManager];
    if (block.timestamp >= offer.expiry) revert IInKindFacility.UnknownExit(positionManager);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       SECURITY LEG                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The cap ID a LibCaps consumption reports for an address-keyed word.
  function capId(address key) internal pure returns (uint256) {
    return uint256(uint160(key));
  }

  /// @dev Debt still borrowable under `auth` right now (zero once expired).
  function available(Auth memory auth) internal view returns (uint256 amount) {
    if (block.timestamp >= auth.expiry) return 0;
    return auth.amount;
  }

  /// @dev Debt `user` can still borrow under its auth on `asset` right now (zero once expired).
  ///      One word, loaded once.
  function authAvailable(InKindStorageData storage self, address asset, address user)
    internal
    view
    returns (uint256 amount)
  {
    return available(self.auths[asset][user]);
  }

  /// @dev Debt of `debtAsset` `user` can borrow against `asset` right now: its auth plus what
  ///      the asset's security cap can absorb, saturating at type(uint256).max.
  function securityLimit(InKindStorageData storage self, address asset, address user, address debtAsset)
    internal
    view
    returns (uint256 limit)
  {
    return authAvailable(self, asset, user).saturatingAdd(self.securityCaps[asset].available(debtAsset));
  }

  /// @dev Consumes `debt` of `debtAsset` for a borrow of `user` against `asset`: the auth first,
  ///      the remainder from the asset's security cap (reverting like LibCaps.consume when it
  ///      cannot absorb it).
  function consumeSecurity(InKindStorageData storage self, address asset, address user, uint256 debt, address debtAsset)
    internal
  {
    Auth memory auth = self.auths[asset][user];
    uint256 fromAuth = available(auth).min(debt);
    if (fromAuth > 0) {
      // casting to 'uint128' is safe because fromAuth <= auth.amount, which is a uint128
      // forge-lint: disable-next-line(unsafe-typecast)
      uint128 remaining = uint128(auth.amount - fromAuth);
      self.auths[asset][user].amount = remaining;
      emit IInKindFacility.AuthConsumed(asset, user, fromAuth, remaining);
    }
    uint256 fromSecurity = debt - fromAuth;
    if (fromSecurity > 0) {
      self.securityCaps[asset] = self.securityCaps[asset].consume(capId(asset), fromSecurity, debtAsset);
    }
  }
}
