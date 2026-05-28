// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibStorage, PositionManagerStorageData} from "src/libs/manager/LibStorage.sol";
import {LibView} from "src/libs/manager/LibView.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";

/// @dev Harness contract to expose internal manager LibStorage and LibView functions for testing
contract LibManagerStorageHarness {
  using LibStorage for PositionManagerStorageData;
  using LibView for PositionManagerStorageData;
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    LibStorage FUNCTIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Expose setLtv
  function setLtv(uint256 ltv_) external {
    LibStorage.positionManagerStorage().setLtv(ltv_);
  }

  /// @dev Expose updateSnapshot
  function updateSnapshot() external {
    LibStorage.positionManagerStorage().updateSnapshot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LibView FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Expose collateralAmount
  function collateralAmount() external view returns (uint256) {
    return LibStorage.positionManagerStorage().collateralAmount();
  }

  /// @dev Expose collateralAmountQuoted
  function collateralAmountQuoted() external view returns (uint256) {
    return LibStorage.positionManagerStorage().collateralAmountQuoted();
  }

  /// @dev Expose debtAmount
  function debtAmount() external view returns (uint256) {
    return LibStorage.positionManagerStorage().debtAmount();
  }

  /// @dev Expose totalAssets (returns the NAV component only; aggregates are dropped)
  function totalAssets() external view returns (uint256 amount) {
    (amount,,) = LibStorage.positionManagerStorage().totalAssets();
  }

  /// @dev Expose the full triple-return totalAssets (NAV + non-bad-debt aggregate debt + aggregate collateral)
  function totalAssetsAndDebt() external view returns (uint256 amount, uint256 totalDebt, uint256 totalCollateral) {
    return LibStorage.positionManagerStorage().totalAssets();
  }

  /// @dev Get lastDebt value
  function getLastDebt() external view returns (uint256) {
    return LibStorage.positionManagerStorage().lastDebt;
  }

  /// @dev Expose convertToShares (pure function)
  function convertToShares(
    uint256 assets,
    uint256 _totalSupply,
    uint256 _totalAssets,
    uint256 virtualShareOffset_,
    bool roundUp
  ) external pure returns (uint256) {
    return LibView.convertToShares(assets, _totalSupply, _totalAssets, virtualShareOffset_, roundUp);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      TEST HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Get ltv value
  function getLtv() external view returns (uint64) {
    return LibStorage.positionManagerStorage().ltv;
  }

  /// @dev Get lastTotalAssets value
  function getLastTotalAssets() external view returns (uint256) {
    return LibStorage.positionManagerStorage().lastTotalAssets;
  }

  /// @dev Add a borrow module
  function addBorrowModule(address module) external {
    LibStorage.positionManagerStorage().borrowModules.add(module);
  }

  /// @dev Remove a borrow module
  function removeBorrowModule(address module) external {
    LibStorage.positionManagerStorage().borrowModules.remove(module);
  }

  /// @dev Get borrow modules
  function getBorrowModules() external view returns (address[] memory) {
    return LibStorage.positionManagerStorage().borrowModules.values();
  }

  /// @dev Set metadata
  function setMetadata(string calldata name, string calldata symbol, address collateralAsset, address debtAsset)
    external
  {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();
    ps.metadata.name = name;
    ps.metadata.symbol = symbol;
    ps.metadata.collateralAsset = collateralAsset;
    ps.metadata.debtAsset = debtAsset;
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
}
