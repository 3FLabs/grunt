// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TokenController} from "./TokenController.sol";
import {IERC20} from "../../integrations/interfaces/IERC20.sol";
import {LibString} from "lib/solady/src/utils/LibString.sol";

/// @title ControlledToken
/// @notice Abstract ERC20 token contract that delegates all logic to a TokenController.
/// @dev This contract serves as a lightweight wrapper around TokenController, implementing the
///      ERC20 interface by forwarding all calls to the controller. Each token (PT or YT) has its
///      own instance that identifies itself via `_isYtToken()`. Token names and symbols are
///      prefixed with "PT-" or "YT-" based on the token type.
abstract contract ControlledToken is IERC20 {
  using LibString for string;

  /// @notice Error thrown when the caller is not the authorized controller.
  /// @dev Only the TokenController can call functions that emit events.
  error Unauthorized();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           Internal                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns true if this token is a YT (Yield Token), false if PT (Principal Token).
  ///      Must be implemented by the concrete token contract to identify its type.
  /// @return isYt True for YT tokens, false for PT tokens
  function _isYtToken() internal view virtual returns (bool);

  /// @dev Returns the address of the TokenController that manages this token.
  ///      All token operations are delegated to this controller.
  /// @return controller The TokenController address
  function _controller() internal view virtual returns (address);

  /// @dev Checks that the caller is the authorized controller.
  ///      Reverts with {Unauthorized} if msg.sender is not the controller.
  ///      Used to restrict event emission to the controller only.
  function _checkController() internal view virtual {
    if (msg.sender != _controller()) revert Unauthorized();
  }

  /// @dev Returns the prefix for the token name and symbol based on token type.
  ///      Returns "YT-" for yield tokens, "PT-" for principal tokens.
  /// @return prefix The string prefix to prepend to base name/symbol
  function _prefix() internal view virtual returns (string memory) {
    return _isYtToken() ? "YT-" : "PT-";
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERC20                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IERC20
  function totalSupply() public view returns (uint256) {
    return TokenController(_controller()).totalSupply(_isYtToken());
  }

  /// @inheritdoc IERC20
  function balanceOf(address account) external view returns (uint256) {
    return TokenController(_controller()).balanceOf(account, _isYtToken());
  }

  /// @inheritdoc IERC20
  function transfer(address to, uint256 amount) external returns (bool) {
    return TokenController(_controller())._transfer(msg.sender, msg.sender, to, amount, _isYtToken());
  }

  /// @inheritdoc IERC20
  function allowance(address owner, address spender) external view returns (uint256) {
    return TokenController(_controller()).allowance(owner, spender, _isYtToken());
  }

  /// @inheritdoc IERC20
  function approve(address spender, uint256 amount) external returns (bool) {
    return TokenController(_controller())._approve(msg.sender, spender, amount, _isYtToken());
  }

  /// @inheritdoc IERC20
  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    return TokenController(_controller())._transfer(msg.sender, from, to, amount, _isYtToken());
  }

  /// @inheritdoc IERC20
  function name() external view returns (string memory) {
    return _prefix().concat(TokenController(_controller()).name());
  }

  /// @inheritdoc IERC20
  function symbol() external view returns (string memory) {
    return _prefix().concat(TokenController(_controller()).symbol());
  }

  /// @inheritdoc IERC20
  function decimals() external view returns (uint8) {
    return TokenController(_controller()).decimals();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONTROLLER SPECIFIC                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emits the ERC20 Approval event for this token.
  /// @dev Only the controller can call this function. Used when allowances are set via
  ///      the controller's batch operations or individual token approvals.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @param amount The approved amount
  function _emitApproval(address owner, address spender, uint256 amount) external virtual {
    _checkController();
    emit Approval(owner, spender, amount);
  }

  /// @notice Emits the ERC20 Transfer event for this token.
  /// @dev Only the controller can call this function. Used when tokens are transferred,
  ///      minted (from = address(0)), or burned (to = address(0)) via the controller.
  /// @param from The address tokens are transferred from (or address(0) for minting)
  /// @param to The address tokens are transferred to (or address(0) for burning)
  /// @param amount The amount of tokens transferred
  function _emitTransfer(address from, address to, uint256 amount) external virtual {
    _checkController();
    emit Transfer(from, to, amount);
  }
}
