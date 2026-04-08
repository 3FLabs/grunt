// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibFacilityErrors
/// @author 3F Protocol
/// @notice Error definitions for the Facility contract.
library LibFacilityErrors {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTENT STATE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the intent is already resolving.
  /// @param id The intent ID.
  error AlreadyResolving(uint256 id);

  /// @notice Thrown when the intent is already resolved.
  /// @param id The intent ID.
  error AlreadyResolved(uint256 id);

  /// @notice Thrown when the intent is not resolving.
  /// @param id The intent ID.
  error NotResolving(uint256 id);

  /// @notice Thrown when the intent is not resolved.
  /// @param id The intent ID.
  error NotResolved(uint256 id);

  /// @notice Thrown when the intent is not depositing.
  /// @param id The intent ID.
  error NotDepositing(uint256 id);

  /// @notice Thrown when an intent ID does not exist.
  /// @param id The intent ID.
  error IntentNotFound(uint256 id);

  /// @notice Thrown when intent token transfers are disabled.
  /// @param id The intent ID.
  error IntentTransfersLocked(uint256 id);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTENT VALIDATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when resolveStart is not in the future.
  /// @param resolveStart The provided resolve start timestamp.
  /// @param currentTime The current block timestamp.
  error InvalidResolveStart(uint40 resolveStart, uint40 currentTime);

  /// @notice Thrown when no position manager is provided on either side of the intent.
  error MissingPositionManager();

  /// @notice Thrown when the guard key does not match the required position manager.
  /// @param guardKey The provided guard key.
  error InvalidGuardKey(address guardKey);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         DEPOSITS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the deposit cap is exceeded.
  /// @param id The intent ID.
  /// @param depositCap The configured deposit cap.
  /// @param attemptedTotal The attempted total supply after deposit.
  error DepositCapExceeded(uint256 id, uint256 depositCap, uint256 attemptedTotal);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ASSETS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when an expected asset does not match the actual asset.
  /// @param expected The expected asset address.
  /// @param actual The actual asset address.
  error AssetMismatch(address expected, address actual);

  /// @notice Thrown when an asset is expected to be a position manager but is not.
  /// @param asset The asset address that is not a position manager.
  error AssetNotPositionManager(address asset);

  /// @notice Thrown when a position manager reports invalid asset configuration.
  /// @dev Reverts if collateralAsset == debtAsset, collateralAsset == positionManager,
  ///      or debtAsset == positionManager, preventing snapshot double-counting attacks.
  error InvalidPositionManagerAssets();

  /// @notice Thrown when an amount differs from the expected value.
  /// @param expected The expected amount.
  /// @param actual The actual amount.
  error AmountMismatch(uint256 expected, uint256 actual);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          FUNDS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a fund is required but not configured.
  /// @param id The intent ID.
  error MissingFund(uint256 id);

  /// @notice Thrown when a fund is already in use.
  /// @param fund The fund address.
  /// @param intentId The intent ID.
  error FundAlreadyInUse(address fund, uint256 intentId);

  /// @notice Thrown when a fund commits an amount different from the order input.
  /// @param id The intent ID.
  /// @param expected The expected committed amount (order input).
  /// @param actual The actual committed amount returned by the fund.
  error CommitAmountMismatch(uint256 id, uint256 expected, uint256 actual);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         REQUESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a request is required but not configured.
  /// @param id The intent ID.
  error MissingRequest(uint256 id);

  /// @notice Thrown when a request is already in use.
  /// @param request The request address.
  /// @param intentId The intent ID.
  error RequestAlreadyInUse(address request, uint256 intentId);

  /// @notice Thrown when the request has not reached a withdrawable state.
  /// @param request The request address.
  error RequestNotRepaid(address request);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ORDERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a fund order already exists.
  /// @param id The intent ID.
  error ActiveOrder(uint256 id);

  /// @notice Thrown when no fund order exists.
  /// @param id The intent ID.
  error NoActiveOrder(uint256 id);

  /// @notice Thrown when a fund order is not yet ended.
  /// @param id The intent ID.
  error OrderNotEnded(uint256 id);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          DIGEST                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a digest has already been consumed.
  /// @param digest The consumed digest.
  error DigestUsed(bytes32 digest);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           SWAP                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when swap params reference the same intent.
  error SameIntent();

  /// @notice Thrown when the swap deadline has passed.
  error SwapExpired();

  /// @notice Thrown when the signature deadline has passed (setFund/setRequest).
  error DeadlineExpired();

  /// @notice Thrown when swap amounts are zero.
  error InvalidSwapAmount();

  /// @notice Thrown when swap uses the same token on both sides.
  error SameTokenSwap();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       SIGNATURES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when signatures length mismatches.
  error InvalidSignatureLength();

  /// @notice Thrown when not enough guardian signatures are provided.
  /// @param required The required number of signatures.
  /// @param provided The number of signatures provided.
  error InvalidSignatureCount(uint256 required, uint256 provided);

  /// @notice Thrown when signers are not strictly increasing.
  error InvalidSignerOrder();

  /// @notice Thrown when a signer is not a guardian.
  /// @param signer The address of the signer.
  error NotGuardian(address signer);

  /// @notice Thrown when a signature is invalid.
  /// @param signer The address of the signer.
  error InvalidSignature(address signer);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TRANSFERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a TransferGuard blocks a transfer.
  /// @param guard The TransferGuard address.
  /// @param from The token sender.
  /// @param to The token receiver.
  /// @param amount The token amount.
  error TransferBlocked(address guard, address from, address to, uint256 amount);

  /// @notice Thrown when attempting to transfer tokens to address(0).
  /// @dev ERC6909 credits balances to address(0) on transfer, which would break totalSupply tracking.
  ///      Use burn() instead to properly remove tokens from circulation.
  error TransferToZeroAddress();
}
