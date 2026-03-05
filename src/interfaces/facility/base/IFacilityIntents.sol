// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IntentProperties, Asset} from "../../../libs/facility/LibIntent.sol";

/// @title IFacilityIntents
/// @author 3F Protocol
/// @notice Interface for intent management operations.
interface IFacilityIntents {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new intent is created.
  /// @param id The intent ID.
  /// @param depositAsset The deposit asset configuration.
  /// @param quorum The quorum threshold for guard approvals.
  /// @param transferableIntent Whether intent token transfers are allowed.
  event IntentCreated(uint256 indexed id, Asset depositAsset, uint8 quorum, bool transferableIntent);

  /// @notice Emitted when an intent is resolved.
  /// @param id The intent ID.
  event IntentResolved(uint256 indexed id);

  /// @notice Emitted when the resolve start timestamp is updated.
  /// @param id The intent ID.
  /// @param newResolveStart The new resolve start timestamp.
  event ResolveStartUpdated(uint256 indexed id, uint40 newResolveStart);

  /// @notice Emitted when the deposit cap is updated.
  /// @param id The intent ID.
  /// @param newDepositCap The new deposit cap.
  event DepositCapUpdated(uint256 indexed id, uint256 newDepositCap);

  /// @notice Emitted when the intent target is updated.
  /// @param id The intent ID.
  /// @param newTargetAsset The new target asset configuration.
  /// @param newGuardKey The new guard key address.
  event IntentTargetUpdated(uint256 indexed id, Asset newTargetAsset, address newGuardKey);

  /// @notice Emitted when the fund address is updated.
  /// @param id The intent ID.
  /// @param newFund The new fund address.
  event FundUpdated(uint256 indexed id, address newFund);

  /// @notice Emitted when the request address is updated.
  /// @param id The intent ID.
  /// @param newRequest The new request address.
  event RequestUpdated(uint256 indexed id, address newRequest);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns all data for an intent.
  /// @param id The intent ID.
  /// @return properties The intent configuration.
  /// @return fund The fund address (or address(0) if none).
  /// @return request The request address (or address(0) if none).
  /// @return resolved Whether the intent has been resolved.
  function getIntent(uint256 id)
    external
    view
    returns (IntentProperties memory properties, address fund, address request, bool resolved);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTENT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new intent and returns its ID.
  /// @param params Configuration values for the new intent.
  function createIntent(IntentProperties calldata params) external returns (uint256 id);

  /// @notice Updates the target asset and guard key for an intent.
  /// @param id The intent ID.
  /// @param newTargetAsset The new target asset configuration.
  /// @param newGuardKey The new guard key address.
  function updateTarget(uint256 id, Asset calldata newTargetAsset, address newGuardKey) external;

  /// @notice Closes the intent with the given ID, stopping withdrawals.
  /// @param id The intent ID.
  function lock(uint256 id) external;

  /// @notice Resolves the intent with the given ID, opening claims to users.
  /// @param id The intent ID.
  function resolve(uint256 id) external;

  /// @notice Sets a new deposit cap for a given intent ID.
  /// @param id The intent ID.
  /// @param newDepositCap The new deposit cap value.
  function setDepositCap(uint256 id, uint256 newDepositCap) external;

  /// @notice Sets a new fund address for a given intent ID.
  /// @dev The EIP-712 digest is computed from `(id, newFund, deadline)` and is independent from
  ///      swap digests and request digests. Smart contract wallet guardians must use implementations
  ///      that bind their own address into EIP-1271 `isValidSignature` (e.g., Safe >= 1.3.0). Older SC
  ///      wallets with faulty EIP-1271 fallbacks must not be used as quorum signers.
  /// @param id The intent ID.
  /// @param newFund The new fund address or address(0) to remove the fund.
  /// @param deadline Timestamp after which this approval is no longer valid.
  /// @param signers Sorted guardian signer list.
  /// @param signatures Signatures corresponding to each signer.
  function setFund(
    uint256 id,
    address newFund,
    uint256 deadline,
    address[] calldata signers,
    bytes[] calldata signatures
  ) external;

  /// @notice Sets a new request address for a given intent ID.
  /// @dev The EIP-712 digest is computed from `(id, newRequest, deadline)` and is independent from
  ///      swap digests and fund digests. Smart contract wallet guardians must use implementations
  ///      that bind their own address into EIP-1271 `isValidSignature` (e.g., Safe >= 1.3.0). Older SC
  ///      wallets with faulty EIP-1271 fallbacks must not be used as quorum signers.
  /// @param id The intent ID.
  /// @param newRequest The new request address or address(0) to remove the request.
  /// @param deadline Timestamp after which this approval is no longer valid.
  /// @param signers Sorted guardian signer list.
  /// @param signatures Signatures corresponding to each signer.
  function setRequest(
    uint256 id,
    address newRequest,
    uint256 deadline,
    address[] calldata signers,
    bytes[] calldata signatures
  ) external;
}
