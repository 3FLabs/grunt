// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibStorage, PositionManagerStorageData} from "src/libs/manager/LibStorage.sol";
import {LibOperations} from "src/libs/manager/LibOperations.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @dev Harness contract to expose internal LibOperations functions for testing
contract LibOperationsHarness {
  using LibOperations for PositionManagerStorageData;
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  LibOperations FUNCTIONS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Expose processDeposit
  function processDeposit(uint256 collateral, uint256 debt) external {
    LibStorage.positionManagerStorage().processDeposit(collateral, debt);
  }

  /// @dev Expose processWithdrawal
  function processWithdrawal(uint256 collateral, uint256 debt) external {
    LibStorage.positionManagerStorage().processWithdrawal(collateral, debt);
  }

  /// @dev Expose processBurn
  function processBurn(uint256 collateralToWithdraw, uint256 debtToRepay, uint256 totalCollateral, uint256 totalDebt)
    external
  {
    LibStorage.positionManagerStorage().processBurn(collateralToWithdraw, debtToRepay, totalCollateral, totalDebt);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      TEST HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Set metadata
  function setMetadata(
    string calldata name,
    string calldata symbol,
    uint8 decimals,
    address collateralAsset,
    address debtAsset
  ) external {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();
    ps.metadata.name = name;
    ps.metadata.symbol = symbol;
    ps.metadata.decimals = decimals;
    ps.metadata.collateralAsset = collateralAsset;
    ps.metadata.debtAsset = debtAsset;
  }

  /// @dev Set ltv
  function setLtv(uint64 ltv) external {
    LibStorage.positionManagerStorage().ltv = ltv;
  }

  /// @dev Add supply queue entry
  function addSupplyQueueEntry(address position, uint96 maxBorrow) external {
    LibStorage.positionManagerStorage().supplyQueue.push(SupplyQueueEntry({position: position, maxBorrow: maxBorrow}));
  }

  /// @dev Add withdrawal queue entry
  function addWithdrawalQueueEntry(address position) external {
    LibStorage.positionManagerStorage().withdrawalQueue.push(position);
  }

  /// @dev Clear supply queue
  function clearSupplyQueue() external {
    delete LibStorage.positionManagerStorage().supplyQueue;
  }

  /// @dev Clear withdrawal queue
  function clearWithdrawalQueue() external {
    delete LibStorage.positionManagerStorage().withdrawalQueue;
  }

  /// @dev Get collateral asset
  function getCollateralAsset() external view returns (address) {
    return LibStorage.positionManagerStorage().metadata.collateralAsset;
  }

  /// @dev Get debt asset
  function getDebtAsset() external view returns (address) {
    return LibStorage.positionManagerStorage().metadata.debtAsset;
  }

  /// @dev Approve tokens for testing
  function approveToken(address token, address spender, uint256 amount) external {
    token.safeApprove(spender, amount);
  }
}
