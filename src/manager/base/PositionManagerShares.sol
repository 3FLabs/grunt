// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {PositionManagerStorageData} from "../../libs/manager/PositionManagerTypes.sol";
import {LibPositionManagerStorage} from "../../libs/manager/LibPositionManagerStorage.sol";
import {LibPositionManagerView} from "../../libs/manager/LibPositionManagerView.sol";
import {PositionManagerFees} from "./PositionManagerFees.sol";

/// @title PositionManagerShares
/// @notice Abstract contract handling share calculations with inflation attack protection.
/// @dev Uses virtual offset pattern for secure share/asset conversions.
abstract contract PositionManagerShares is PositionManagerFees {
  using LibPositionManagerView for PositionManagerStorageData;
  using LibPositionManagerView for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    SHARE CALCULATIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Settles share changes based on total assets delta.
  ///      Mints shares if assets increased, burns shares if assets decreased.
  /// @param totalAssetsBefore The total assets before the operation
  /// @param _totalSupply The total supply before the operation
  /// @return sharesDelta Positive if shares minted, negative if shares burned
  function _settleShares(uint256 totalAssetsBefore, uint256 _totalSupply) internal returns (int256 sharesDelta) {
    uint256 totalAssetsAfter = LibPositionManagerStorage.load().totalAssets();

    if (totalAssetsAfter > totalAssetsBefore) {
      // Assets increased: mint shares to caller
      uint256 assetsAdded = totalAssetsAfter - totalAssetsBefore;
      uint256 sharesToMint = assetsAdded.convertToShares(_totalSupply, totalAssetsBefore);
      if (sharesToMint == 0) revert IPositionManager.ZeroShares();
      _mint(msg.sender, sharesToMint);
      // Safe: sharesToMint is capped by total supply which fits in uint128
      // forge-lint: disable-next-line(unsafe-typecast)
      sharesDelta = int256(sharesToMint);
    } else if (totalAssetsAfter < totalAssetsBefore) {
      // Assets decreased: burn shares from caller
      uint256 assetsRemoved = totalAssetsBefore - totalAssetsAfter;
      uint256 sharesToBurn = assetsRemoved.convertToShares(_totalSupply, totalAssetsBefore);
      if (sharesToBurn == 0) revert IPositionManager.ZeroShares();
      _burn(msg.sender, sharesToBurn);
      // Safe: sharesToBurn is capped by total supply which fits in uint128
      // forge-lint: disable-next-line(unsafe-typecast)
      sharesDelta = -int256(sharesToBurn);
    }
    // If equal, sharesDelta remains 0

    // Update snapshot for performance fees
    _updateSnapshot();
  }
}
