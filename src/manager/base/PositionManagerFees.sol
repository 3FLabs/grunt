// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {FeeData, PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibView} from "../../libs/manager/LibView.sol";
import {BPS, SECONDS_PER_YEAR} from "../../libs/manager/LibConstants.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PositionManagerFees
/// @notice Abstract contract handling fee accrual and snapshot management for PositionManager.
/// @dev Implements management and performance fee calculation and distribution.
abstract contract PositionManagerFees is ERC20 {
  using FixedPointMathLib for uint256;
  using LibView for PositionManagerStorageData;
  using LibView for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FEE ACCRUAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Accrues fees (management + performance) and mints shares to the fee recipient.
  ///      Returns the current total assets after fee accrual for use in share calculations.
  /// @return currentTotalAssets The total assets after fee accrual
  function _accrueFees() internal returns (uint256 currentTotalAssets) {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();
    FeeData memory fd = ps.feeData;

    currentTotalAssets = ps.totalAssets();

    if (fd.feeRecipient == address(0)) {
      ps.lastTotalAssets = currentTotalAssets;
      // Safe: block.timestamp fits in uint40 for ~35,000 years
      // forge-lint: disable-next-line(unsafe-typecast)
      ps.lastFeeAccrualTimestamp = uint40(block.timestamp);
      return currentTotalAssets;
    }

    uint256 feeShares = 0;
    uint256 _totalSupply = totalSupply();

    // Management fee: based on time elapsed and total assets
    if (fd.managementFee > 0 && _totalSupply > 0) {
      uint256 elapsed = block.timestamp - ps.lastFeeAccrualTimestamp;
      // Fee = totalAssets * managementFee * elapsed / (BPS * SECONDS_PER_YEAR)
      uint256 managementFeeAssets = currentTotalAssets.mulDiv(fd.managementFee * elapsed, BPS * SECONDS_PER_YEAR);
      if (managementFeeAssets > 0) {
        feeShares += managementFeeAssets.convertToShares(_totalSupply, currentTotalAssets);
      }
    }

    // Performance fee: based on gains since last snapshot
    if (fd.performanceFee > 0 && currentTotalAssets > ps.lastTotalAssets && _totalSupply > 0) {
      uint256 gains = currentTotalAssets - ps.lastTotalAssets;
      uint256 performanceFeeAssets = gains.mulDiv(fd.performanceFee, BPS);
      if (performanceFeeAssets > 0) {
        feeShares += performanceFeeAssets.convertToShares(_totalSupply, currentTotalAssets);
      }
    }

    // Mint fee shares
    if (feeShares > 0) {
      _mint(fd.feeRecipient, feeShares);
      emit IPositionManager.FeesAccrued(fd.feeRecipient, feeShares);
    }

    // Update snapshot to prevent double-counting performance fees on the same gains
    ps.lastTotalAssets = currentTotalAssets;
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    ps.lastFeeAccrualTimestamp = uint40(block.timestamp);

    return currentTotalAssets;
  }

  /// @dev Updates the lastTotalAssets snapshot after an operation.
  function _updateSnapshot() internal {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();
    ps.lastTotalAssets = ps.totalAssets();
  }
}
