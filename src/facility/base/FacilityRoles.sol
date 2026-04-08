// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";

/// @title FacilityRoles
/// @author 3F Protocol
/// @notice Facility role constants and shared guardian-signature quorum validation.
/// @dev Inherits OwnableRoles from solady for role-based access control.
abstract contract FacilityRoles is OwnableRoles {
  using LibStorage for FacilityStorageData;
  /// @notice Role for addresses authorized to facilitate intent operations.
  uint256 internal constant FACILITATOR_ROLE = _ROLE_0;

  /// @notice Role for addresses authorized to sign guardian-gated intents and swaps.
  uint256 internal constant GUARDIAN_ROLE = _ROLE_1;

  /// @notice Role for addresses authorized to pause/unpause the facility and revert deposits.
  uint256 internal constant COMPLIANCE_ROLE = _ROLE_2;

  /// @dev Verifies signatures against quorum and guardian-role constraints.
  ///      Signers must be sorted in strictly ascending order and unique.
  function _checkSignatures(
    FacilityStorageData storage _facilityStorage,
    bytes32 digest,
    address[] calldata signers,
    bytes[] calldata signatures,
    uint256 quorum
  ) internal {
    if (quorum == 0) return;
    _facilityStorage.checkDigest(digest);
    if (signers.length != signatures.length) revert LibFacilityErrors.InvalidSignatureLength();
    if (signers.length < quorum) revert LibFacilityErrors.InvalidSignatureCount(quorum, signers.length);

    address lastSigner;
    for (uint256 i = 0; i < quorum; i++) {
      address signer = signers[i];
      if (signer <= lastSigner) revert LibFacilityErrors.InvalidSignerOrder();
      if (!hasAnyRole(signer, GUARDIAN_ROLE)) revert LibFacilityErrors.NotGuardian(signer);
      if (!SignatureCheckerLib.isValidSignatureNowCalldata(signer, digest, signatures[i])) {
        revert LibFacilityErrors.InvalidSignature(signer);
      }
      lastSigner = signer;
    }
  }
}
