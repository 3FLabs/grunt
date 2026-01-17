// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

import {IFacilityLP} from "src/interfaces/facility/base/IFacilityLP.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";

/// @title FacilityLP
/// @notice Abstract contract implementing liquidity provider operations for intents.
/// @dev Inherits ERC6909 for multi-token accounting. Descendant contracts must implement
///      ERC6909 metadata functions (name, symbol, tokenURI, decimals).
abstract contract FacilityLP is IFacilityLP, ERC6909 {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
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
    Intent storage _intent = LibStorage.facilityStorage().getDepositingIntent(id);

    // ensure we do not exceed the deposit cap
    _intent.checkCap(id, amount);

    // receive the tokens from the sender
    _intent.receiveTokenFrom(id, _intent.properties.depositAsset.asset, msg.sender, amount);

    // mint the LP tokens
    _mint(msg.sender, id, amount);
  }

  /// @inheritdoc IFacilityLP
  /// @dev Burns LP tokens 1:1 with the withdrawn amount.
  ///      The intent must be in depositing phase (not yet resolving or resolved).
  function withdraw(uint256 id, uint256 amount) external override {
    Intent storage _intent = LibStorage.facilityStorage().getDepositingIntent(id);

    // transfer the tokens to the sender
    _intent.transferTokenTo(id, _intent.properties.depositAsset.asset, msg.sender, amount);

    // burn the LP tokens
    _burn(msg.sender, id, amount);
  }

  /// @inheritdoc IFacilityLP
  /// @dev Distributes all tokens held by the intent proportionally to the caller's LP share.
  ///      The intent must be resolved before claims can be made.
  ///      Burns all of the caller's LP tokens for this intent.
  function claim(uint256 id) external override {
    Intent storage _intent = LibStorage.facilityStorage().getResolvedIntent(id);

    // get the user's balance
    uint256 balance = balanceOf(msg.sender, id);
    // if the user has no balance, return
    if (balance == 0) return;

    // get the total supply (always non null at this point)
    uint256 supply = _intent.totalSupply;

    // transfer all tokens proportionally to the user's balance (rounding down)
    address[] memory tokens = _intent.amounts.keys();
    for (uint256 i = 0; i < tokens.length; i++) {
      address token = tokens[i];
      // get the user's balance of this token
      uint256 userBalance = _intent.amounts.get(token).mulDiv(balance, supply);
      // transfer the tokens to the user
      _intent.transferTokenTo(id, token, msg.sender, userBalance);
    }

    // burn the LP tokens
    _burn(msg.sender, id, balance);
  }
}
