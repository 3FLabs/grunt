// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title ITokenController
/// @author 3F Protocol
/// @notice Interface for managing dual-token systems (Principal Token and Yield Token).
interface ITokenController {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           METADATA                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the number of decimals used by both PT and YT tokens.
  /// @return decimals The number of decimals (e.g., 18 for most tokens)
  function decimals() external view returns (uint8);

  /// @notice Returns the base name used by both PT and YT tokens.
  /// @return name The base name string
  function name() external view returns (string memory);

  /// @notice Returns the base symbol used by both PT and YT tokens.
  /// @return symbol The base symbol string
  function symbol() external view returns (string memory);

  /// @notice Returns the address of the Principal Token (PT) contract.
  /// @return pt The PT token contract address
  function ptToken() external view returns (address);

  /// @notice Returns the address of the Yield Token (YT) contract.
  /// @return yt The YT token contract address
  function ytToken() external view returns (address);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         BALANCES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the balances of both PT and YT tokens for a given account.
  /// @param account The address to query balances for
  /// @return pt The PT token balance
  /// @return yt The YT token balance
  function balancesOf(address account) external view returns (uint128 pt, uint128 yt);

  /// @notice Returns the total supplies of both PT and YT tokens.
  /// @return pt The total PT token supply
  /// @return yt The total YT token supply
  function totalSupplies() external view returns (uint128 pt, uint128 yt);

  /// @notice Returns the allowances for both PT and YT tokens for a given owner-spender pair.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @return pt The PT token allowance
  /// @return yt The YT token allowance
  function allowancesOf(address owner, address spender) external view returns (uint128 pt, uint128 yt);

  /// @notice Returns the total supply of either PT or YT tokens.
  /// @param yt True to return YT supply, false to return PT supply
  /// @return supply The total supply of the specified token
  function totalSupply(bool yt) external view returns (uint128);

  /// @notice Returns the balance of either PT or YT tokens for a given account.
  /// @param account The address to query the balance for
  /// @param yt True to return YT balance, false to return PT balance
  /// @return balance The balance of the specified token
  function balanceOf(address account, bool yt) external view returns (uint128);

  /// @notice Returns the allowance of either PT or YT tokens for a given owner-spender pair.
  /// @dev NOTE FOR INTEGRATORS: Allowances are stored as uint128. Any approval with amount >= 2^128
  ///      is stored as type(uint128).max and returned here as type(uint256).max (infinite allowance).
  ///      Only values below 2^128 behave as finite, decreasing allowances.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @param yt True to return YT allowance, false to return PT allowance
  /// @return result The allowance of the specified token (normalized to uint256.max if infinite)
  function allowance(address owner, address spender, bool yt) external view returns (uint256 result);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TOKENS BATCHES                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Transfers both PT and YT tokens from the caller to a recipient in a single transaction.
  /// @param to The address to transfer tokens to
  /// @param ptAmount The amount of PT tokens to transfer
  /// @param ytAmount The amount of YT tokens to transfer
  /// @return success Always returns true if the transfer succeeds
  function transferBatch(address to, uint256 ptAmount, uint256 ytAmount) external returns (bool);

  /// @notice Transfers both PT and YT tokens from one address to another using allowance.
  /// @param from The address to transfer tokens from
  /// @param to The address to transfer tokens to
  /// @param ptAmount The amount of PT tokens to transfer
  /// @param ytAmount The amount of YT tokens to transfer
  /// @return success Always returns true if the transfer succeeds
  function transferFromBatch(address from, address to, uint256 ptAmount, uint256 ytAmount) external returns (bool);

  /// @notice Approves a spender to use both PT and YT tokens on behalf of the caller.
  /// @dev Amounts >= type(uint128).max are capped and treated as infinite allowance.
  ///      See {ITokenController-allowance} for details on the clamping behavior.
  /// @param spender The address to grant allowance to
  /// @param ptAmount The PT token allowance to grant
  /// @param ytAmount The YT token allowance to grant
  /// @return success Always returns true if the approval succeeds
  function approveBatch(address spender, uint256 ptAmount, uint256 ytAmount) external returns (bool);
}

