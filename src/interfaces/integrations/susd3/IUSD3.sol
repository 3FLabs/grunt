// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC4626} from "../IERC4626.sol";

/// @title IUSD3
/// @author 3F Protocol
/// @notice Minimal interface for the USD3 senior tranche strategy.
/// @dev USD3 is a Yearn V3 TokenizedStrategy (ERC4626-compatible) whose asset is USDC.
///      The fund uses the standard ERC4626 surface plus `minDeposit()` (a floor enforced only for
///      first-time depositors) and `minCommitmentTime()` (a post-deposit withdrawal lock).
interface IUSD3 is IERC4626 {
  /// @notice Minimum deposit (in USDC) enforced when the receiver's USD3 balance is 0.
  function minDeposit() external view returns (uint256);

  /// @notice Minimum commitment time (seconds) a deposit is locked before it can be withdrawn.
  function minCommitmentTime() external view returns (uint256);
}
