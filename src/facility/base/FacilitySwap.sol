// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EIP712} from "lib/solady/src/utils/EIP712.sol";
import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {FacilityRoles} from "./FacilityRoles.sol";

import {IFacilitySwap, SwapParams} from "src/interfaces/facility/base/IFacilitySwap.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibTokenBalances} from "src/libs/facility/LibTokenBalances.sol";

import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title FacilitySwap
/// @notice Abstract contract implementing swap functionality between intents.
/// @dev Descendant contracts must implement `_checkSigner` to define signer validation logic.
abstract contract FacilitySwap is IFacilitySwap, EIP712, ReentrancyGuardTransient, FacilityRoles {
  using LibIntent for Intent;
  using LibStorage for FacilityStorageData;
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice EIP-712 typehash for SwapParams struct.
  /// @dev keccak256("SwapParams(uint256 id1,address token1,uint256 id2,address token2,uint256 amount1,uint256 amount2,uint256 deadline)")
  bytes32 internal constant SWAP_PARAMS_TYPEHASH = 0x8b4e182587850acdf21dcf7a0f61b2fd7267c2cdf71d4692b57fb97237a29be3;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SWAP                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilitySwap
  /// @dev The required quorum is the maximum of the two intent quorums.
  ///      Uses EIP-712 typed data hashing for digest computation.
  ///      Each digest can only be used once to prevent replay attacks.
  ///      Both intents must be in resolving state for the swap to succeed.
  function swap(SwapParams memory params, address[] calldata signers, bytes[] calldata signatures)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    // ensure the intent IDs are not the same
    if (params.id1 == params.id2) revert LibErrors.SameIntent();
    // ensure the swap is not expired
    if (block.timestamp > params.deadline) revert LibErrors.SwapExpired();
    // ensure the amounts are not zero
    if (params.amount1 == 0 || params.amount2 == 0) revert LibErrors.InvalidSwapAmount();

    // get existing intents
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage intent1 = _facilityStorage.getResolvingIntent(params.id1);
    Intent storage intent2 = _facilityStorage.getResolvingIntent(params.id2);

    { // get the higher quorum
      uint256 _quorum = FixedPointMathLib.max(intent1.properties.quorum, intent2.properties.quorum);

      // compute the digest and validate the signatures
      bytes32 _digest = _hashTypedData(keccak256(abi.encode(SWAP_PARAMS_TYPEHASH, params)));
      _facilityStorage.checkDigest(_digest);
      _checkSwapSignatures(_digest, signers, signatures, _quorum);
    }

    // swap between intents (ensures both intents are in resolving state)
    intent1.amounts.sub(params.token1, params.amount1);
    intent1.amounts.add(params.token2, params.amount2);
    intent2.amounts.sub(params.token2, params.amount2);
    intent2.amounts.add(params.token1, params.amount1);

    // emit the swap event
    emit Swap(params.id1, params.id2, params.token1, params.amount1, params.token2, params.amount2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Verifies swap signatures against the required quorum.
  ///      signers address must be sorted in ascending order and must be unique.
  /// @param digest The EIP-712 digest to verify against.
  /// @param signers The addresses of the signers.
  /// @param signatures The signatures from each signer.
  /// @param quorum The minimum number of valid signatures required.
  function _checkSwapSignatures(bytes32 digest, address[] calldata signers, bytes[] calldata signatures, uint256 quorum)
    internal
    view
  {
    // if there is no quorum, we don't need to check signatures
    if (quorum == 0) return;
    // ensure the number of signers and signatures match
    if (signers.length != signatures.length) revert LibErrors.InvalidSignatureLength();
    // ensure the number of signers is at least the quorum
    if (signers.length < quorum) revert LibErrors.InvalidSignatureCount(quorum, signers.length);

    address lastSigner;
    // loop until quorum is reached
    for (uint256 i = 0; i < quorum; i++) {
      address signer = signers[i];
      // ensure the signer is strictly increasing (avoids passing multiple times the same signer)
      if (signer <= lastSigner) revert LibErrors.InvalidSignerOrder();
      if (!hasAnyRole(signer, GUARDIAN_ROLE)) revert LibErrors.NotGuardian(signer);
      if (!SignatureCheckerLib.isValidSignatureNowCalldata(signer, digest, signatures[i])) {
        revert LibErrors.InvalidSignature(signer);
      }
      lastSigner = signer;
    }
  }
}
