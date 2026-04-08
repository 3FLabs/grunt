// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {EIP712} from "lib/solady/src/utils/EIP712.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {FacilityRoles} from "./FacilityRoles.sol";

import {IFacilitySwap, SwapParams} from "src/interfaces/facility/base/IFacilitySwap.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibTokenBalances} from "src/libs/facility/LibTokenBalances.sol";

import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title FacilitySwap
/// @author 3F Protocol
/// @notice Abstract contract implementing swap functionality between intents.
/// @dev Uses shared guardian-signature quorum validation from `FacilityRoles`.
abstract contract FacilitySwap is IFacilitySwap, EIP712, ReentrancyGuardTransient, FacilityRoles {
  using LibIntent for Intent;
  using LibStorage for FacilityStorageData;
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice EIP-712 typehash for SwapParams struct.
  /// @dev keccak256("SwapParams(uint256 id1,address token1,uint256 id2,address token2,uint256 amount1,uint256 amount2,uint256 deadline)")
  ///
  /// @custom:security-note The signer address is intentionally NOT hashed into the swap digest.
  ///      This means the same digest is verified against every signer in the quorum array via
  ///      `SignatureCheckerLib.isValidSignatureNowCalldata`, which performs `ecrecover` for EOAs
  ///      and `EIP-1271 isValidSignature` for smart contract wallets.
  ///
  ///      **SC wallet replay risk:** If a single EOA serves as the underlying signer for multiple
  ///      smart contract (SC) wallets, a signature produced by that EOA could pass EIP-1271
  ///      validation on more than one SC wallet. Faulty SC wallet implementations — notably some
  ///      older EIP-4337 fallback handlers — may forward `isValidSignature` directly to the
  ///      underlying EOA signer without binding the caller's own address into the check.
  ///
  ///      This is a known limitation. Quorum guardians that use SC wallets
  ///      MUST use implementations that bind their own address into `isValidSignature` validation
  ///      (e.g., Safe ≥ 1.3.0, which already hashes `msg.sender`). Older or custom SC wallets that
  ///      do NOT do this MUST NOT be used as quorum signers.
  bytes32 internal constant SWAP_PARAMS_TYPEHASH = 0x8b4e182587850acdf21dcf7a0f61b2fd7267c2cdf71d4692b57fb97237a29be3;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SWAP                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilitySwap
  /// @dev The required quorum is the maximum of the two intent quorums.
  ///      Uses EIP-712 typed data hashing for digest computation.
  ///      Each digest can only be used once to prevent replay attacks.
  ///      Both intents must be in resolving state for the swap to succeed.
  ///
  /// @custom:security-note The EIP-712 digest does not include the signer address. See the
  ///      security note on {SWAP_PARAMS_TYPEHASH} for SC wallet replay considerations.
  ///      Quorum guardians using smart contract wallets must ensure their wallet implementation
  ///      binds its own address into EIP-1271 `isValidSignature` validation.
  function swap(SwapParams memory params, address[] calldata signers, bytes[] calldata signatures)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    LibStorage.checkNotPaused();
    // ensure the intent IDs are not the same
    if (params.id1 == params.id2) revert LibFacilityErrors.SameIntent();
    // ensure the swap is not expired
    if (block.timestamp > params.deadline) revert LibFacilityErrors.SwapExpired();
    // ensure the amounts are not zero
    if (params.amount1 == 0 || params.amount2 == 0) revert LibFacilityErrors.InvalidSwapAmount();
    // prevent same-token swaps
    if (params.token1 == params.token2) revert LibFacilityErrors.SameTokenSwap();

    // get existing intents
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage intent1 = _facilityStorage.getResolvingIntent(params.id1);
    Intent storage intent2 = _facilityStorage.getResolvingIntent(params.id2);

    _checkSignatures(
      _facilityStorage,
      _hashTypedData(keccak256(abi.encode(SWAP_PARAMS_TYPEHASH, params))),
      signers,
      signatures,
      // get the highest quorum of the two intents
      uint256(intent1.properties.quorum).max(intent2.properties.quorum)
    );

    // swap between intents (ensures both intents are in resolving state)
    intent1.amounts.sub(params.token1, params.amount1);
    intent1.amounts.add(params.token2, params.amount2);
    intent2.amounts.sub(params.token2, params.amount2);
    intent2.amounts.add(params.token1, params.amount1);

    // emit the swap event
    emit Swap(params.id1, params.id2, params.token1, params.amount1, params.token2, params.amount2);
  }
}
