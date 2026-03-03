// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibTokenController} from "../../../libs/request/LibTokenController.sol";
import {ControlledToken} from "./ControlledToken.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";
import {LibAllowance} from "../../../libs/request/LibAllowance.sol";
import {ITokenController} from "../../../interfaces/request/ITokenController.sol";
import {LibRequestErrors} from "../../../libs/request/LibRequestErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../../libs/common/LibCommonErrors.sol";
import {LibChecks} from "../../../libs/common/LibChecks.sol";

/// @title TokenController
/// @author 3F Protocol
/// @notice Abstract contract for managing dual-token systems (Principal Token and Yield Token)
/// @dev Manages PT and YT tokens with packed storage for gas efficiency. All balances, supplies, and
///      allowances are stored as uint128 pairs in a single uint256 slot using LibTokenController.
///      The controller handles transfers, approvals, minting, and burning for both tokens simultaneously.
abstract contract TokenController is ITokenController {
  using LibTokenController for address;
  using SafeCastLib for uint256;
  using LibAllowance for uint128;
  using LibChecks for address;
  using FixedPointMathLib for bool;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           Internal                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Checks that the caller is the appropriate token contract (PT or YT).
  ///      Reverts with {UnauthorizedTokenContract} if the caller is not the expected token contract.
  ///      This prevents unauthorized external calls to internal token functions.
  /// @param yt True if checking for YT token, false if checking for PT token
  function _checkToken(bool yt) internal view virtual {
    if (msg.sender != (yt ? _ytToken() : _ptToken())) revert LibRequestErrors.UnauthorizedTokenContract();
  }

  /// @dev Consumes (decreases) the allowance granted by `from` to `spender` for both PT and YT tokens.
  ///      Implements standard ERC20 allowance consumption with infinite allowance support.
  ///      If both PT and YT allowances are set to type(uint128).max, no allowance is consumed (infinite approval).
  ///      Otherwise, the allowances are decreased by the specified amounts.
  /// @param from The address that granted the allowance
  /// @param spender The address spending the tokens
  /// @param pt The amount of PT tokens to consume from the allowance
  /// @param yt The amount of YT tokens to consume from the allowance
  /// @custom:reverts InsufficientAllowance if either pt > ptAllowance or yt > ytAllowance
  function _consumeAllowance(address from, address spender, uint256 pt, uint256 yt) internal virtual {
    // casting to 'uint128' is safe because [The allowance is checked if higher than a 128 bit number]
    // forge-lint: disable-next-item(unsafe-typecast)
    unchecked {
      (uint128 ptAllowance, uint128 ytAllowance) = from.allowances(spender);
      if (pt > ptAllowance || yt > ytAllowance) revert LibRequestErrors.InsufficientAllowance();
      if (ptAllowance == type(uint128).max && ytAllowance == type(uint128).max) return;
      ptAllowance = ptAllowance.consume(uint128(pt));
      ytAllowance = ytAllowance.consume(uint128(yt));
      from.updateAllowance(spender, ptAllowance, ytAllowance);
    }
  }

  /// @dev Transfers PT and/or YT tokens from one address to another.
  ///      Updates balances in packed storage and emits Transfer events for non-zero amounts.
  ///      Performs balance checks before transferring to ensure sufficient funds.
  /// @param from The address to transfer tokens from
  /// @param to The address to transfer tokens to
  /// @param pt The amount of PT tokens to transfer
  /// @param yt The amount of YT tokens to transfer
  /// @return success Always returns true if the transfer succeeds (reverts on failure)
  /// @custom:reverts InsufficientBalance if from has insufficient PT or YT balance
  function _transfer(address from, address to, uint256 pt, uint256 yt) internal virtual returns (bool) {
    to.checkNotZero();
    // casting to 'uint128' is safe because [The balance is checked if higher than a 128 bit number]
    // forge-lint: disable-next-item(unsafe-typecast)
    unchecked {
      (uint128 ptBalanceSender, uint128 ytBalanceSender) = from.balances();
      if (pt > ptBalanceSender || yt > ytBalanceSender) revert CommonErrors.InsufficientBalance();
      if (from != to) {
        (uint128 ptBalanceReceiver, uint128 ytBalanceReceiver) = to.balances();
        from.updateBalances(ptBalanceSender - uint128(pt), ytBalanceSender - uint128(yt));
        to.updateBalances(ptBalanceReceiver + uint128(pt), ytBalanceReceiver + uint128(yt));
      }
      if (pt > 0) ControlledToken(_ptToken())._emitTransfer(from, to, pt);
      if (yt > 0) ControlledToken(_ytToken())._emitTransfer(from, to, yt);
      return true;
    }
  }

  /// @dev Sets the allowance for both PT and YT tokens.
  ///      Caps allowances at type(uint128).max if a higher value is provided. Emits Approval events
  ///      for each token if the allowance changes. The normalized allowance (type(uint256).max for
  ///      uint128 max) is emitted in the event.
  ///
  ///      NOTE FOR INTEGRATORS: Any value in the range [type(uint128).max, type(uint256).max] is
  ///      stored as type(uint128).max (infinite allowance). The `allowance` view then normalizes
  ///      type(uint128).max back to type(uint256).max. As a result, approving any value >= 2^128
  ///      produces an infinite allowance that is never consumed on transfers.
  /// @param from The address granting the allowance (token owner)
  /// @param spender The address receiving the allowance
  /// @param pt The PT token allowance amount to set
  /// @param yt The YT token allowance amount to set
  /// @return success Always returns true if the operation succeeds
  function _setAllowance(address from, address spender, uint256 pt, uint256 yt) internal virtual returns (bool) {
    // casting to 'uint128' is safe because [The allowance is ceiled to the max value of a 128 bit number]
    // forge-lint: disable-next-item(unsafe-typecast)
    unchecked {
      (uint128 ptAllowance, uint128 ytAllowance) = from.allowances(spender);
      uint128 ptMin = uint128(FixedPointMathLib.min(pt, type(uint128).max));
      uint128 ytMin = uint128(FixedPointMathLib.min(yt, type(uint128).max));
      from.updateAllowance(spender, ptMin, ytMin);
      if (ptMin != ptAllowance) ControlledToken(_ptToken())._emitApproval(from, spender, ptMin.normalize());
      if (ytMin != ytAllowance) ControlledToken(_ytToken())._emitApproval(from, spender, ytMin.normalize());
      return true;
    }
  }

  /// @dev Mints new PT and/or YT tokens to an address.
  ///      Increases total supply and recipient balance in packed storage. Emits Transfer events
  ///      from address(0) for non-zero amounts. Assumes amounts fit in uint128 (enforced by toUint128).
  /// @param to The address to mint tokens to
  /// @param pt The amount of PT tokens to mint
  /// @param yt The amount of YT tokens to mint
  function _mint(address to, uint256 pt, uint256 yt) internal virtual {
    (uint128 ptSupply, uint128 ytSupply) = LibTokenController.totalSupplies();
    LibTokenController.updateTotalSupply((pt + ptSupply).toUint128(), (yt + ytSupply).toUint128());

    unchecked {
      (uint128 ptBalance, uint128 ytBalance) = to.balances();
      // casting to 'uint128' is safe because [The balance cannot be higher than the total supply which does not overflow a 128 bit number]
      // forge-lint: disable-next-line(unsafe-typecast)
      to.updateBalances(ptBalance + uint128(pt), ytBalance + uint128(yt));
      if (pt > 0) ControlledToken(_ptToken())._emitTransfer(address(0), to, pt);
      if (yt > 0) ControlledToken(_ytToken())._emitTransfer(address(0), to, yt);
    }
  }

  /// @dev Burns PT and/or YT tokens from an address.
  ///      Decreases total supply and owner balance in packed storage. Performs checks to ensure
  ///      sufficient supply and balance exist. Emits Transfer events to address(0) for non-zero amounts.
  /// @param from The address to burn tokens from
  /// @param pt The amount of PT tokens to burn
  /// @param yt The amount of YT tokens to burn
  /// @custom:reverts InsufficientBalance if total supply or account balance is insufficient
  function _burn(address from, uint256 pt, uint256 yt) internal virtual {
    unchecked {
      (uint128 ptSupply, uint128 ytSupply) = LibTokenController.totalSupplies();
      if (pt > ptSupply || yt > ytSupply) revert CommonErrors.InsufficientBalance();
      // casting to 'uint128' is safe because [The total supply cannot be higher than the total supply which does not overflow a 128 bit number]
      // forge-lint: disable-next-line(unsafe-typecast)
      LibTokenController.updateTotalSupply(ptSupply - uint128(pt), ytSupply - uint128(yt));

      (uint128 ptBalance, uint128 ytBalance) = from.balances();
      if (pt > ptBalance || yt > ytBalance) revert CommonErrors.InsufficientBalance();
      // casting to 'uint128' is safe because [These amounts are lower than 128 bits numbers]
      // forge-lint: disable-next-line(unsafe-typecast)
      from.updateBalances(ptBalance - uint128(pt), ytBalance - uint128(yt));
      if (pt > 0) ControlledToken(_ptToken())._emitTransfer(from, address(0), pt);
      if (yt > 0) ControlledToken(_ytToken())._emitTransfer(from, address(0), yt);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     Abstract Metadata                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the PT token address. Must be implemented by derived contracts.
  function _ptToken() internal view virtual returns (address);

  /// @dev Returns the YT token address. Must be implemented by derived contracts.
  function _ytToken() internal view virtual returns (address);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           Metadata                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ITokenController
  function ptToken() external view virtual returns (address) {
    return _ptToken();
  }

  /// @inheritdoc ITokenController
  function ytToken() external view virtual returns (address) {
    return _ytToken();
  }

  /// @inheritdoc ITokenController
  /// @dev Reads from packed storage where both balances are stored in a single uint256 slot.
  function balancesOf(address account) public view returns (uint128 pt, uint128 yt) {
    (pt, yt) = LibTokenController.balances(account);
  }

  /// @inheritdoc ITokenController
  /// @dev Reads from packed storage where both supplies are stored in a single uint256 slot.
  function totalSupplies() public view returns (uint128 pt, uint128 yt) {
    (pt, yt) = LibTokenController.totalSupplies();
  }

  /// @inheritdoc ITokenController
  /// @dev Reads from packed storage where both allowances are stored in a single uint256 slot.
  function allowancesOf(address owner, address spender) public view returns (uint128 pt, uint128 yt) {
    (pt, yt) = LibTokenController.allowances(owner, spender);
  }

  /// @inheritdoc ITokenController
  function totalSupply(bool yt) public view returns (uint128) {
    return LibTokenController.totalSupply(yt);
  }

  /// @inheritdoc ITokenController
  function balanceOf(address account, bool yt) external view returns (uint128) {
    return LibTokenController.balanceOf(account, yt);
  }

  /// @inheritdoc ITokenController
  /// @dev Returns type(uint256).max if the stored allowance is type(uint128).max (infinite allowance).
  ///      This provides EIP-20 compatibility where infinite allowance is represented as uint256 max.
  ///
  ///      NOTE FOR INTEGRATORS: Because `_setAllowance` clamps values to type(uint128).max, any
  ///      approval with amount >= 2^128 will read back as type(uint256).max (infinite). Only
  ///      values below 2^128 behave as finite, decreasing allowances.
  function allowance(address owner, address spender, bool yt) external view returns (uint256 result) {
    result = LibTokenController.allowance(owner, spender, yt);
    if (result == type(uint128).max) result = type(uint256).max;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       Tokens batches                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ITokenController
  /// @dev More gas efficient than calling transfer on both tokens separately.
  /// @custom:reverts InsufficientBalance if the caller has insufficient PT or YT balance
  function transferBatch(address to, uint256 ptAmount, uint256 ytAmount) public virtual returns (bool) {
    return _transfer(msg.sender, to, ptAmount, ytAmount);
  }

  /// @inheritdoc ITokenController
  /// @dev If the caller is not the owner, allowance is consumed. More gas efficient than calling
  ///      transferFrom on both tokens separately.
  /// @custom:reverts InsufficientAllowance if allowance is insufficient (when from != msg.sender)
  /// @custom:reverts InsufficientBalance if the sender has insufficient PT or YT balance
  function transferFromBatch(address from, address to, uint256 ptAmount, uint256 ytAmount)
    public
    virtual
    returns (bool)
  {
    if (from != msg.sender) {
      _consumeAllowance(from, msg.sender, ptAmount, ytAmount);
    }
    return _transfer(from, to, ptAmount, ytAmount);
  }

  /// @inheritdoc ITokenController
  /// @dev More gas efficient than calling approve on both tokens separately. Amounts exceeding
  ///      type(uint128).max are capped at that value for storage, producing an infinite allowance.
  ///      See `_setAllowance` for details on the clamping behavior.
  function approveBatch(address spender, uint256 ptAmount, uint256 ytAmount) public virtual returns (bool) {
    return _setAllowance(msg.sender, spender, ptAmount, ytAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       Tokens internal                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Internal transfer function called by individual token contracts (PT or YT).
  ///      This function is called by ControlledToken.transfer and ControlledToken.transferFrom.
  ///      It handles both direct transfers and allowance-based transfers. The `yt` parameter
  ///      determines which token (PT or YT) is being transferred while the other amount is set to 0.
  /// @param caller The address initiating the transfer (msg.sender from the token contract)
  /// @param from The address to transfer tokens from
  /// @param to The address to transfer tokens to
  /// @param amount The amount of tokens to transfer (for the specific token type)
  /// @param yt True if this is a YT transfer, false if this is a PT transfer
  /// @return success Always returns true if the transfer succeeds
  /// @custom:reverts UnauthorizedTokenContract if not called by the appropriate token contract
  /// @custom:reverts InsufficientAllowance if allowance is insufficient (when caller != from)
  /// @custom:reverts InsufficientBalance if the sender has insufficient balance
  function _transfer(address caller, address from, address to, uint256 amount, bool yt) public virtual returns (bool) {
    _checkToken(yt);
    uint256 ptAmount = yt.ternary(0, amount);
    uint256 ytAmount = yt.ternary(amount, 0);
    if (caller != from) {
      _consumeAllowance(from, caller, ptAmount, ytAmount);
    }
    return _transfer(from, to, ptAmount, ytAmount);
  }

  /// @dev Internal approve function called by individual token contracts (PT or YT).
  ///      This function is called by ControlledToken.approve. The `yt` parameter determines
  ///      which token (PT or YT) allowance is being set while the other is set to 0.
  ///      Delegates to `_setAllowance` which clamps values >= type(uint128).max to infinite.
  /// @param from The address granting the allowance (token owner)
  /// @param spender The address receiving the allowance
  /// @param amount The allowance amount to set (for the specific token type)
  /// @param yt True if this is a YT approval, false if this is a PT approval
  /// @return success Always returns true if the approval succeeds
  /// @custom:reverts UnauthorizedTokenContract if not called by the appropriate token contract
  function _approve(address from, address spender, uint256 amount, bool yt) public virtual returns (bool) {
    _checkToken(yt);
    (uint128 existingPt, uint128 existingYt) = from.allowances(spender);
    uint256 ptAmount = yt.ternary(uint256(existingPt), amount);
    uint256 ytAmount = yt.ternary(amount, uint256(existingYt));
    return _setAllowance(from, spender, ptAmount, ytAmount);
  }
}
