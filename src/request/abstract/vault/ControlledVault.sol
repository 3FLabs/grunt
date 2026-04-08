// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ControlledToken} from "../tokens/ControlledToken.sol";
import {VaultController} from "./VaultController.sol";
import {IERC4626} from "../../../interfaces/integrations/IERC4626.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibRequestErrors} from "../../../libs/request/LibRequestErrors.sol";

/// @title ControlledVault
/// @author 3F Protocol
/// @notice ERC4626-compliant vault wrapper for either PT (Principal Token) or YT (Yield Token).
/// @dev Combines ControlledToken (for ERC20 functionality) with ERC4626 (for vault functionality).
///      This contract is read-only for deposits/mints (always reverts) as shares are minted by the
///      VaultController. Users can only withdraw or redeem their shares. No inflation attack protection
///      is needed since direct minting is disabled. Each instance represents either PT or YT vault.
abstract contract ControlledVault is ControlledToken, IERC4626 {
  using FixedPointMathLib for bool;
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ERC4626 INTERFACE                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IERC4626
  /// @dev Returns the underlying asset address from the VaultController.
  function asset() external view returns (address) {
    return VaultController(_controller()).asset();
  }

  /// @inheritdoc IERC4626
  /// @dev Returns either principal assets (for PT vault) or yield assets (for YT vault) based on
  ///      the asset distribution formula: pAssets = min(balance, ptSupply), yAssets = balance - pAssets.
  function totalAssets() public view returns (uint256 assets) {
    (uint256 pAssets, uint256 yAssets) = VaultController(_controller()).totalAssets();
    assets = _isYtToken().ternary(yAssets, pAssets);
  }

  /// @inheritdoc IERC4626
  /// @dev Converts assets to shares for this vault type (PT or YT). Delegates to VaultController
  ///      which applies the appropriate conversion rate based on current asset distribution.
  function convertToShares(uint256 assets) public view returns (uint256 shares) {
    bool yt = _isYtToken();
    uint256 pAssets = yt.ternary(0, assets);
    uint256 yAssets = yt.ternary(assets, 0);
    (uint256 ptShares, uint256 ytShares) = VaultController(_controller()).convertToShares(pAssets, yAssets);
    shares = yt.ternary(ytShares, ptShares);
  }

  /// @inheritdoc IERC4626
  /// @dev Converts shares to assets for this vault type (PT or YT). Delegates to VaultController
  ///      which applies the appropriate conversion rate based on current asset distribution.
  function convertToAssets(uint256 shares) public view returns (uint256 assets) {
    bool yt = _isYtToken();
    uint256 ptShares = yt.ternary(0, shares);
    uint256 ytShares = yt.ternary(shares, 0);
    (uint256 pAssets, uint256 yAssets) = VaultController(_controller()).convertToAssets(ptShares, ytShares);
    assets = yt.ternary(yAssets, pAssets);
  }

  /// @inheritdoc IERC4626
  /// @dev Always returns 0 since direct deposits are disabled. Shares must be minted via VaultController.
  function maxDeposit(address) external pure returns (uint256) {
    return 0;
  }

  /// @inheritdoc IERC4626
  /// @dev Always returns 0 since deposit() always reverts. Per ERC-4626, preview functions must
  ///      reflect the actual outcome of the corresponding operation.
  function previewDeposit(uint256) external pure returns (uint256) {
    return 0;
  }

  /// @inheritdoc IERC4626
  /// @dev Always reverts with {CannotMintShares}. Shares can only be minted through the VaultController.
  function deposit(uint256, address) external pure returns (uint256) {
    revert LibRequestErrors.CannotMintShares();
  }

  /// @inheritdoc IERC4626
  /// @dev Always returns 0 since direct minting is disabled. Shares must be minted via VaultController.
  function maxMint(address) external pure returns (uint256) {
    return 0;
  }

  /// @inheritdoc IERC4626
  /// @dev Always returns 0 since mint() always reverts. Per ERC-4626, preview functions must
  ///      reflect the actual outcome of the corresponding operation.
  function previewMint(uint256) external pure returns (uint256) {
    return 0;
  }

  /// @inheritdoc IERC4626
  /// @dev Always reverts with {CannotMintShares}. Shares can only be minted through the VaultController.
  function mint(uint256, address) external pure returns (uint256) {
    revert LibRequestErrors.CannotMintShares();
  }

  /// @inheritdoc IERC4626
  /// @dev Returns the maximum assets the owner could withdraw. Zero when withdrawals are locked.
  function maxWithdraw(address owner) external view returns (uint256) {
    if (!VaultController(_controller()).canWithdraw()) return 0;
    return convertToAssets(this.balanceOf(owner));
  }

  /// @inheritdoc IERC4626
  /// @dev Previews how many shares would be burned to withdraw a given amount of assets.
  function previewWithdraw(uint256 assets) external view returns (uint256 shares) {
    shares = convertToShares(assets);
  }

  /// @inheritdoc IERC4626
  /// @dev Withdraws assets by burning the required shares. Delegates to VaultController which handles
  ///      asset distribution, allowance checking, and the actual withdrawal operation.
  function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
    return VaultController(_controller())._withdraw(msg.sender, assets, receiver, owner, _isYtToken());
  }

  /// @inheritdoc IERC4626
  /// @dev Returns the maximum shares the owner could redeem. Zero when withdrawals are locked.
  function maxRedeem(address owner) external view returns (uint256) {
    if (!VaultController(_controller()).canWithdraw()) return 0;
    return this.balanceOf(owner);
  }

  /// @inheritdoc IERC4626
  /// @dev Previews how many assets would be received for redeeming a given amount of shares.
  function previewRedeem(uint256 shares) external view returns (uint256 assets) {
    assets = convertToAssets(shares);
  }

  /// @inheritdoc IERC4626
  /// @dev Redeems shares for assets. Delegates to VaultController which handles asset distribution,
  ///      allowance checking, and the actual redemption operation.
  function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
    return VaultController(_controller())._redeem(msg.sender, shares, receiver, owner, _isYtToken());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONTROLLER SPECIFIC                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Emits the ERC4626 Deposit event for this vault.
  ///      Only the VaultController can call this function. Used when shares are minted through
  ///      the controller's deposit operations (not via the vault's deposit function which is disabled).
  /// @param sender The address that initiated the deposit
  /// @param owner The address receiving the shares
  /// @param assets The amount of assets deposited (may be 0 for YT)
  /// @param shares The amount of shares minted
  function _emitDeposit(address sender, address owner, uint256 assets, uint256 shares) external virtual {
    _checkController();
    emit Deposit(sender, owner, assets, shares);
  }

  /// @dev Emits the ERC4626 Withdraw event for this vault.
  ///      Only the VaultController can call this function. Used when shares are burned and assets
  ///      are transferred during withdraw or redeem operations.
  /// @param sender The address that initiated the withdrawal
  /// @param receiver The address receiving the assets
  /// @param owner The address whose shares are being burned
  /// @param assets The amount of assets withdrawn
  /// @param shares The amount of shares burned
  function _emitWithdraw(address sender, address receiver, address owner, uint256 assets, uint256 shares)
    external
    virtual
  {
    _checkController();
    emit Withdraw(sender, receiver, owner, assets, shares);
  }
}
