// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IInKindExitCallback
/// @author 3F Protocol
/// @notice Callback invoked by {IInKindFacility.exit} when the caller passes non-empty `data`.
/// @dev Called on `msg.sender` of `exit` after the facility pulled the PM shares and before it
///      pulls exactly `debtIn` of the PM's debt asset from that same caller via allowance.
///      `debtIn` is burn's mirrored slice plus a small headroom, final before the callback: PM
///      state is untouched between its computation and `PM.burn`, so burn pulls at most `debtIn`
///      and the rest is refunded to the caller after burn. A state change the callback itself
///      makes that lowers burn's figure (a Morpho repay on behalf of a module) only grows the
///      refund; one that raises it beyond the headroom makes burn's pull fail. A flash loan taken
///      inside this callback cannot be repaid from the exit proceeds (the underlying is
///      delivered after the callback frame ends); flash-funded exits must wrap the whole `exit`
///      call. Bad debt is checked again after it. `debtIn` equals {previewExit}'s `debtRequired`.
///      Implementations MUST check `msg.sender` is the facility.
interface IInKindExitCallback {
  /// @notice Sources the debt asset the facility is about to pull.
  /// @param positionManager The position manager being exited.
  /// @param shares The PM shares already pulled from the caller (fee shares included).
  /// @param debtIn The debt-asset amount the facility pulls next (headroom included).
  /// @param data The opaque data passed to `exit`.
  function onInKindExit(address positionManager, uint256 shares, uint256 debtIn, bytes calldata data) external;
}
