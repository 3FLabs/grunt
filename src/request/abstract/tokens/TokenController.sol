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
  ///      Updates balances in packed storage and performs balance checks. Does NOT emit Transfer
  ///      events — emission is the responsibility of public callers, which know which token(s)
  ///      the user is acting on (so single-token paths do not emit a spurious zero event on the
  ///      sibling token).
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
      return true;
    }
  }

  /// @dev Sets the allowance for both PT and YT tokens. Does NOT emit Approval events — emission
  ///      is the responsibility of public callers, which use the original caller-supplied amount
  ///      (so the event value matches what the user passed, per EIP-20).
  ///
  ///      Each amount must be either strictly below type(uint128).max (stored exactly) or exactly
  ///      type(uint256).max (stored as the type(uint128).max infinite-allowance sentinel that is
  ///      not decremented on transferFrom and reads back as type(uint256).max via {allowance}).
  ///      Any value in [type(uint128).max, type(uint256).max - 1] reverts with {AllowanceTooLarge}
  ///      because it cannot be represented exactly in uint128 storage.
  /// @param from The address granting the allowance (token owner)
  /// @param spender The address receiving the allowance
  /// @param pt The PT token allowance amount to set
  /// @param yt The YT token allowance amount to set
  /// @return success Always returns true if the operation succeeds
  /// @custom:reverts AllowanceTooLarge if pt or yt is in [type(uint128).max, type(uint256).max - 1]
  function _setAllowance(address from, address spender, uint256 pt, uint256 yt) internal virtual returns (bool) {
    from.updateAllowance(spender, _toStored(pt), _toStored(yt));
    return true;
  }

  /// @dev Validates and converts a uint256 approve amount to the uint128 stored form.
  ///      - `type(uint256).max` is the canonical infinite-allowance value; it is stored as the
  ///        `type(uint128).max` sentinel and read back as `type(uint256).max` from {allowance}.
  ///      - Values strictly below `type(uint128).max` are stored as-is.
  ///      - Any value in `[type(uint128).max, type(uint256).max - 1]` cannot be represented
  ///        exactly (the sentinel slot is reserved for "infinite") and is rejected.
  /// @param amount The approve amount supplied by the caller
  /// @return stored The uint128 value to write to packed allowance storage
  /// @custom:reverts AllowanceTooLarge if amount cannot be represented exactly
  function _toStored(uint256 amount) private pure returns (uint128 stored) {
    if (amount == type(uint256).max) return type(uint128).max;
    if (amount >= type(uint128).max) revert LibRequestErrors.AllowanceTooLarge();
    // casting to 'uint128' is safe because [the branch above ensures amount < type(uint128).max]
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint128(amount);
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
  /// @dev Returns `type(uint256).max` if the stored allowance is the `type(uint128).max` sentinel
  ///      (infinite allowance), for EIP-20 compatibility. Otherwise returns the stored value.
  ///
  ///      Under the new approve contract, the sentinel is only written when the caller approves
  ///      exactly `type(uint256).max`; all other accepted values (strictly below `type(uint128).max`)
  ///      round-trip exactly. Values in `[type(uint128).max, type(uint256).max - 1]` are rejected at
  ///      approve time with {AllowanceTooLarge}.
  function allowance(address owner, address spender, bool yt) external view returns (uint256 result) {
    result = LibTokenController.allowance(owner, spender, yt);
    if (result == type(uint128).max) result = type(uint256).max;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       Tokens batches                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ITokenController
  /// @dev More gas efficient than calling transfer on both tokens separately. Always emits a
  ///      Transfer event on each of the PT and YT tokens (per EIP-20, including for zero-value
  ///      sides), since each batch call is logically two ERC-20 transfers.
  /// @custom:reverts InsufficientBalance if the caller has insufficient PT or YT balance
  function transferBatch(address to, uint256 ptAmount, uint256 ytAmount) public virtual returns (bool) {
    bool result = _transfer(msg.sender, to, ptAmount, ytAmount);
    ControlledToken(_ptToken())._emitTransfer(msg.sender, to, ptAmount);
    ControlledToken(_ytToken())._emitTransfer(msg.sender, to, ytAmount);
    return result;
  }

  /// @inheritdoc ITokenController
  /// @dev If the caller is not the owner, allowance is consumed. More gas efficient than calling
  ///      transferFrom on both tokens separately. Always emits a Transfer event on each of the PT
  ///      and YT tokens (per EIP-20, including for zero-value sides).
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
    bool result = _transfer(from, to, ptAmount, ytAmount);
    ControlledToken(_ptToken())._emitTransfer(from, to, ptAmount);
    ControlledToken(_ytToken())._emitTransfer(from, to, ytAmount);
    return result;
  }

  /// @inheritdoc ITokenController
  /// @dev More gas efficient than calling approve on both tokens separately. Always emits an
  ///      Approval event on each of the PT and YT tokens (per EIP-20, on every successful approve).
  ///      Each amount must be either strictly below `type(uint128).max` or exactly `type(uint256).max`;
  ///      values in `[type(uint128).max, type(uint256).max - 1]` revert with {AllowanceTooLarge}.
  ///      See {_setAllowance} for details.
  /// @custom:reverts AllowanceTooLarge if ptAmount or ytAmount cannot be represented exactly
  function approveBatch(address spender, uint256 ptAmount, uint256 ytAmount) public virtual returns (bool) {
    bool result = _setAllowance(msg.sender, spender, ptAmount, ytAmount);
    ControlledToken(_ptToken())._emitApproval(msg.sender, spender, ptAmount);
    ControlledToken(_ytToken())._emitApproval(msg.sender, spender, ytAmount);
    return result;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       Tokens internal                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Internal transfer function called by individual token contracts (PT or YT).
  ///      This function is called by ControlledToken.transfer and ControlledToken.transferFrom.
  ///      It handles both direct transfers and allowance-based transfers. The `yt` parameter
  ///      determines which token (PT or YT) is being transferred while the other amount is set to 0.
  ///      Emits exactly one Transfer event on the relevant token (PT or YT), even when amount is 0,
  ///      and never emits a spurious zero-value event on the sibling token.
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
    bool result = _transfer(from, to, ptAmount, ytAmount);
    ControlledToken(yt ? _ytToken() : _ptToken())._emitTransfer(from, to, amount);
    return result;
  }

  /// @dev Internal approve function called by individual token contracts (PT or YT).
  ///      This function is called by ControlledToken.approve. The `yt` parameter determines
  ///      which token (PT or YT) allowance is being set; the sibling allowance is preserved
  ///      verbatim (the sentinel value, if present, is left intact rather than re-validated).
  ///      Emits exactly one Approval event on the relevant token, with the original caller-supplied
  ///      `amount`, on every successful call.
  ///      `amount` must be either strictly below `type(uint128).max` or exactly `type(uint256).max`.
  /// @param from The address granting the allowance (token owner)
  /// @param spender The address receiving the allowance
  /// @param amount The allowance amount to set (for the specific token type)
  /// @param yt True if this is a YT approval, false if this is a PT approval
  /// @return success Always returns true if the approval succeeds
  /// @custom:reverts UnauthorizedTokenContract if not called by the appropriate token contract
  /// @custom:reverts AllowanceTooLarge if amount is in [type(uint128).max, type(uint256).max - 1]
  function _approve(address from, address spender, uint256 amount, bool yt) public virtual returns (bool) {
    _checkToken(yt);
    uint128 stored = _toStored(amount);
    (uint128 existingPt, uint128 existingYt) = from.allowances(spender);
    if (yt) {
      from.updateAllowance(spender, existingPt, stored);
      ControlledToken(_ytToken())._emitApproval(from, spender, amount);
    } else {
      from.updateAllowance(spender, stored, existingYt);
      ControlledToken(_ptToken())._emitApproval(from, spender, amount);
    }
    return true;
  }
}
