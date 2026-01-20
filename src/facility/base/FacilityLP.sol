// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

import {IFacilityLP} from "src/interfaces/facility/base/IFacilityLP.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";

/// @title FacilityLP
/// @author 3F Protocol
/// @notice Abstract contract implementing liquidity provider operations for intents.
/// @dev Inherits ERC6909 for multi-token accounting. Descendant contracts must implement
///      ERC6909 metadata functions (name, symbol, tokenURI, decimals).
abstract contract FacilityLP is IFacilityLP, ERC6909, ReentrancyGuardTransient {
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
  function deposit(uint256 id, uint256 amount) external override nonReentrant {
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
  ///      If `from` is not `msg.sender`, the caller must be an operator for `from`.
  function withdraw(uint256 id, address from, address receiver, uint256 amount) external override nonReentrant {
    // if amount is 0, return early
    if (amount == 0) return;

    // check withdrawal params and burn shares
    _withdrawalLpChecks(id, from, amount);

    Intent storage _intent = LibStorage.facilityStorage().getDepositingIntent(id);

    // transfer the tokens to the receiver
    _intent.transferTokenTo(id, _intent.properties.depositAsset.asset, receiver, amount);
  }

  /// @inheritdoc IFacilityLP
  /// @dev Distributes tokens held by the intent proportionally to the shares being burned.
  ///      The intent must be resolved before claims can be made.
  ///      If `from` is not `msg.sender`, the caller must be an operator for `from`.
  function claim(uint256 id, address from, address receiver, uint256 shares)
    external
    override
    nonReentrant
    returns (address[] memory tokens, uint256[] memory amounts)
  {
    // if shares is 0, return early with empty arrays
    if (shares == 0) return (new address[](0), new uint256[](0));

    // check withdrawal params and burn shares
    _withdrawalLpChecks(id, from, shares);

    Intent storage _intent = LibStorage.facilityStorage().getResolvedIntent(id);

    // get the total supply (always non null at this point)
    // we add the shares to the total supply to get the supply before burning
    uint256 supply = _intent.totalSupply + shares;

    // transfer all tokens proportionally to the shares being burned (rounding down)
    tokens = _intent.amounts.keys();
    uint256 length = tokens.length;
    amounts = new uint256[](length);

    for (uint256 i = 0; i < length; i++) {
      address token = tokens[i];
      // get the proportional amount of this token
      uint256 userBalance = _intent.amounts.get(token).mulDiv(shares, supply);
      amounts[i] = userBalance;
      // transfer the tokens to the receiver
      _intent.transferTokenTo(id, token, receiver, userBalance);
    }

    return (tokens, amounts);
  }

  /// @dev Checks the withdrawal parameters and burns the shares.
  /// @param id The intent id.
  /// @param from The address to withdraw from.
  /// @param amount The amount to withdraw.
  function _withdrawalLpChecks(uint256 id, address from, uint256 amount) internal {
    // check operator if from is not msg.sender
    if (from != msg.sender && !isOperator(from, msg.sender)) revert InsufficientPermission();
    // check if the user has enough balance
    if (balanceOf(from, id) < amount) revert InsufficientBalance();
    // burn the shares
    _burn(from, id, amount);
  }
}
