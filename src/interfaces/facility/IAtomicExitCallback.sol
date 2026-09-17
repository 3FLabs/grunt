// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IAtomicExitCallback
/// @author 3F Protocol
/// @notice Callback invoked by {IAtomicFacility.exit} when the caller passes non-empty `data`.
/// @dev Called on `msg.sender` of `exit` after the facility pulled the PM shares and before it
///      pulls exactly `debtIn` of the PM's debt asset from that same caller via allowance.
///      `debtIn` is final: PM state is untouched between its computation and `PM.burn`, and any
///      state change the callback itself makes that would move burn's figure (a Morpho repay or
///      collateral supply on behalf of a module, a nested pre-liquidation) makes the exit revert
///      with `DebtMirrorMismatch`. A flash loan taken inside this callback cannot be repaid from
///      the exit proceeds (the underlying is delivered after the callback frame ends);
///      flash-funded exits must wrap the whole `exit` call. Implementations MUST check
///      `msg.sender` is the facility.
interface IAtomicExitCallback {
  /// @notice Sources the debt asset the facility is about to pull.
  /// @param positionManager The position manager being exited.
  /// @param shares The PM shares already pulled from the caller (fee shares included).
  /// @param debtIn The exact debt-asset amount the facility pulls next.
  /// @param data The opaque data passed to `exit`.
  function onAtomicExit(address positionManager, uint256 shares, uint256 debtIn, bytes calldata data) external;
}
