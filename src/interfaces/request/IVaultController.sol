// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ITokenController} from "./ITokenController.sol";
import {IHasAsset} from "./IHasAsset.sol";

/// @title IVaultController
/// @author 3F Protocol
/// @notice Interface for managing dual-vault systems with Principal and Yield token separation.
interface IVaultController is ITokenController, IHasAsset {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        METADATA/STATUS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns whether withdrawals and redemptions are currently permitted.
  /// @return allowed True if withdrawals/redemptions are enabled
  function canWithdraw() external view returns (bool);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                ERC4626 SHARE-ASSET CONVERSIONS             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Converts principal and yield assets to the equivalent amount of PT and YT shares.
  /// @param pAssets Amount of principal assets to convert
  /// @param yAssets Amount of yield assets to convert
  /// @return ptShares Amount of PT shares equivalent to pAssets
  /// @return ytShares Amount of YT shares equivalent to yAssets
  function convertToShares(uint256 pAssets, uint256 yAssets) external view returns (uint256 ptShares, uint256 ytShares);

  /// @notice Converts PT and YT shares to the equivalent amount of principal and yield assets.
  /// @param ptShares Number of PT shares to convert
  /// @param ytShares Number of YT shares to convert
  /// @return pAssets Amount of principal assets equivalent to ptShares
  /// @return yAssets Amount of yield assets equivalent to ytShares
  function convertToAssets(uint256 ptShares, uint256 ytShares) external view returns (uint256 pAssets, uint256 yAssets);

  /// @notice Returns the current asset distribution between principal and yield.
  /// @return pAssets The amount of assets allocated to principal holders
  /// @return yAssets The amount of assets allocated to yield holders
  function totalAssets() external view returns (uint256 pAssets, uint256 yAssets);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 ADMIN/UTILITY (PT+YT FORFEIT)              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Burns all PT and YT shares owned by an account and sends the redeemed assets to a receiver.
  /// @param owner The account whose entire position will be burned
  /// @param receiver The address that will receive all redeemed assets
  /// @return ptShares The amount of PT shares burned
  /// @return ytShares The amount of YT shares burned
  /// @return pAssets The amount of principal assets transferred to receiver
  /// @return yAssets The amount of yield assets transferred to receiver
  function burnAll(address owner, address receiver)
    external
    returns (uint256 ptShares, uint256 ytShares, uint256 pAssets, uint256 yAssets);
}

