// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

import {IFacilityLP} from "src/interfaces/facility/base/IFacilityLP.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibTokenBalances} from "src/libs/facility/LibTokenBalances.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";

/// @title FacilityLP
/// @notice Abstract contract implementing liquidity provider operations for intents.
/// @dev Inherits ERC6909 for multi-token accounting. Descendant contracts must implement
///      ERC6909 metadata functions (name, symbol, tokenURI, decimals).
abstract contract FacilityLP is IFacilityLP, ERC6909 {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityLP
  /// @dev Mints LP tokens 1:1 with the deposited amount.
  ///      The intent must be in depositing phase (not yet resolving or resolved).
  ///      Reverts if the deposit would exceed the intent's deposit cap.
  function deposit(uint256 id, uint256 amount) external override {
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    if (!_intent.isDepositing()) revert LibErrors.NotDepositing(id);

    _intent.checkCap(id, amount);

    address depositAsset = _intent.properties.depositAsset.asset;
    depositAsset.safeTransferFrom(msg.sender, address(this), amount);
    _intent.amounts.add(depositAsset, amount);
    _mint(msg.sender, id, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacilityLP
  /// @dev Burns LP tokens 1:1 with the withdrawn amount.
  ///      The intent must be in depositing phase (not yet resolving or resolved).
  function withdraw(uint256 id, uint256 amount) external override {
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    if (!_intent.isDepositing()) revert LibErrors.NotDepositing(id);

    address depositAsset = _intent.properties.depositAsset.asset;
    _intent.amounts.sub(depositAsset, amount);
    depositAsset.safeTransfer(msg.sender, amount);
    _burn(msg.sender, id, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacilityLP
  /// @dev Distributes all tokens held by the intent proportionally to the caller's LP share.
  ///      The intent must be resolved before claims can be made.
  ///      Burns all of the caller's LP tokens for this intent.
  function claim(uint256 id) external override {
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    if (!_intent.isResolved()) revert LibErrors.NotResolved(id);

    uint256 balance = balanceOf(msg.sender, id);
    if (balance == 0) return;

    uint256 supply = _intent.totalSupply;
    if (supply == 0) return;

    address[] memory tokens = _intent.amounts.keys();
    for (uint256 i = 0; i < tokens.length; i++) {
      address token = tokens[i];
      uint256 userBalance = _intent.amounts.get(token).mulDiv(balance, supply);
      _intent.amounts.sub(token, userBalance);
      token.safeTransfer(msg.sender, userBalance);
    }

    _burn(msg.sender, id, balance);

    // TODO - Emits event
  }
}
