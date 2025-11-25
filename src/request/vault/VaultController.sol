// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TokenController} from "../tokens/TokenController.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {LibTokenController} from "../libraries/LibTokenController.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {ControlledVault} from "./ControlledVault.sol";

/// @title VaultController
/// @notice Abstract base contract for managing dual-vault systems with Principal and Yield token separation.
/// @dev Extends TokenController to add ERC4626-style vault functionality. Implements the redemption model
///      where principal holders are prioritized (receive up to 1:1 redemption) and yield holders receive
///      any excess assets. Asset distribution follows: principalAssets = min(totalAssets, ptSupply) and
///      yieldAssets = totalAssets - principalAssets. See README for detailed examples and formulas.
abstract contract VaultController is TokenController {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for bool;

  /// @notice Error thrown when attempting to withdraw or redeem while withdrawals are locked.
  /// @dev Withdrawals are typically locked during the deposit phase and unlocked during redemption.
  error CannotWithdraw();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        METADATA/STATUS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the address of the underlying asset (ERC20) held by the vault.
  /// @dev This is the asset that backs both PT and YT tokens (e.g., USDC).
  /// @return assetAddress The ERC20 token address
  function asset() public view virtual returns (address);

  /// @notice Returns whether withdrawals and redemptions are currently permitted.
  /// @dev Typically false during deposit phase, true during redemption phase.
  /// @return allowed True if withdrawals/redemptions are enabled
  function canWithdraw() public view virtual returns (bool);

  /// @dev Reverts if withdrawals are not currently permitted.
  ///      Called before any withdraw or redeem operation to enforce the withdrawal lock.
  /// @custom:reverts CannotWithdraw if withdrawals are locked
  function _checkCanWithdraw() internal view virtual {
    if (!canWithdraw()) revert CannotWithdraw();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL HELPERS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Calculates the current asset distribution and token supplies.
  ///      Implements the core redemption formula where principal assets are prioritized:
  ///      - pAssets = min(totalAssets, ptSupply): Principal holders get up to 1:1 redemption
  ///      - yAssets = totalAssets - pAssets: Yield holders get any excess assets
  ///      This ensures principal holders are paid first, with yield capturing upside/downside.
  /// @return pAssets The assets allocated to PT holders
  /// @return yAssets The assets allocated to YT holders
  /// @return ptSupply The total supply of PT tokens
  /// @return ytSupply The total supply of YT tokens
  function _assetsAndSupplies()
    internal
    view
    virtual
    returns (uint256 pAssets, uint256 yAssets, uint256 ptSupply, uint256 ytSupply)
  {
    unchecked {
      (ptSupply, ytSupply) = LibTokenController.totalSupplies();
      uint256 assets = asset().balanceOf(address(this));
      pAssets = FixedPointMathLib.min(assets, ptSupply);
      yAssets = assets - pAssets;
    }
  }

  /// @dev Returns true if either of the two values is zero.
  ///      Used to determine if initial conversion logic should be used (when supply or assets are zero).
  /// @param a First value to check
  /// @param b Second value to check
  /// @return result True if a == 0 OR b == 0
  function _eitherIsZero(uint256 a, uint256 b) internal pure returns (bool result) {
    /// @solidity memory-safe-assembly
    assembly {
      result := or(iszero(a), iszero(b))
    }
  }

  /// @dev Converts assets to shares when supply or assets are zero (initial state).
  ///      For PT: returns 1:1 conversion. For YT: returns max uint256 if assets > 0 (indicating
  ///      infinite price since there are no assets backing the yield yet), or the asset amount otherwise.
  /// @param assets Amount of assets to convert
  /// @param yt True if converting for YT, false if converting for PT
  /// @return shares Amount of shares corresponding to the assets
  function _initialConvertToShares(uint256 assets, bool yt) internal pure returns (uint256 shares) {
    shares = (yt && assets > 0).ternary(type(uint256).max, assets);
  }

  /// @dev Converts shares to assets when supply or assets are zero (initial state).
  ///      For PT: returns 1:1 conversion. For YT: returns 0 (since no yield exists yet).
  /// @param shares Amount of shares to convert
  /// @param yt True if converting for YT, false if converting for PT
  /// @return assets Amount of assets corresponding to the shares
  function _initialConvertToAssets(uint256 shares, bool yt) internal pure returns (uint256 assets) {
    assets = yt.ternary(0, shares);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  WITHDRAW & REDEEM INTERNALS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Core withdrawal operation that burns shares and transfers assets.
  ///      Checks withdrawal permissions, consumes allowances if needed, burns shares, and transfers
  ///      assets to the receiver. Emits ERC4626 Withdraw events for non-zero amounts. This function
  ///      is used by both withdraw (assets-based) and redeem (shares-based) operations.
  /// @param caller The address initiating the operation (msg.sender)
  /// @param receiver The address receiving the assets
  /// @param owner The address whose shares are being burned
  /// @param pAssets The amount of principal assets to withdraw
  /// @param yAssets The amount of yield assets to withdraw
  /// @param ptShares The amount of PT shares to burn
  /// @param ytShares The amount of YT shares to burn
  function _withdrawalOperation(
    address caller,
    address receiver,
    address owner,
    uint256 pAssets,
    uint256 yAssets,
    uint256 ptShares,
    uint256 ytShares
  ) internal virtual {
    unchecked {
      _checkCanWithdraw();
      if (caller != owner) {
        _consumeAllowance(owner, caller, ptShares, ytShares);
      }
      _burn(owner, ptShares, ytShares);
      asset().safeTransfer(receiver, yAssets + pAssets);
      if (pAssets > 0 || ptShares > 0) {
        ControlledVault(ytToken())._emitWithdraw(caller, receiver, owner, pAssets, ptShares);
      }
      if (yAssets > 0 || ytShares > 0) {
        ControlledVault(ptToken())._emitWithdraw(caller, receiver, owner, yAssets, ytShares);
      }
    }
  }

  /// @dev Withdraws a specified amount of assets by burning the required shares.
  ///      Converts the requested assets to shares using current exchange rate, then performs
  ///      the withdrawal operation. This is the ERC4626 "withdraw" flow.
  /// @param caller The address initiating the withdrawal
  /// @param pAssets The amount of principal assets to withdraw
  /// @param yAssets The amount of yield assets to withdraw
  /// @param receiver The address receiving the assets
  /// @param owner The address whose shares will be burned
  /// @return ptShares The amount of PT shares burned
  /// @return ytShares The amount of YT shares burned
  function _withdraw(address caller, uint256 pAssets, uint256 yAssets, address receiver, address owner)
    internal
    virtual
    returns (uint256 ptShares, uint256 ytShares)
  {
    (ptShares, ytShares) = convertToShares(pAssets, yAssets);
    _withdrawalOperation(caller, receiver, owner, pAssets, yAssets, ptShares, ytShares);
  }

  /// @dev Redeems a specified amount of shares for the corresponding assets.
  ///      Converts the shares to assets using current exchange rate, then performs the
  ///      withdrawal operation. This is the ERC4626 "redeem" flow.
  /// @param caller The address initiating the redemption
  /// @param pShares The amount of PT shares to redeem
  /// @param yShares The amount of YT shares to redeem
  /// @param receiver The address receiving the assets
  /// @param owner The address whose shares will be burned
  /// @return pAssets The amount of principal assets received
  /// @return yAssets The amount of yield assets received
  function _redeem(address caller, uint256 pShares, uint256 yShares, address receiver, address owner)
    internal
    virtual
    returns (uint256 pAssets, uint256 yAssets)
  {
    (pAssets, yAssets) = convertToAssets(pShares, yShares);
    _withdrawalOperation(caller, receiver, owner, pAssets, yAssets, pShares, yShares);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                ERC4626 SHARE-ASSET CONVERSIONS             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Converts principal and yield assets to the equivalent amount of PT and YT shares.
  /// @dev Uses `mulDivUp` for share calculation to favor the vault (rounds up shares needed).
  ///      Falls back to initial conversion logic when supply or assets are zero. The conversion
  ///      rate reflects the current redemption value based on asset distribution.
  /// @param pAssets Amount of principal assets to convert
  /// @param yAssets Amount of yield assets to convert
  /// @return ptShares Amount of PT shares equivalent to pAssets
  /// @return ytShares Amount of YT shares equivalent to yAssets
  function convertToShares(uint256 pAssets, uint256 yAssets) public view returns (uint256 ptShares, uint256 ytShares) {
    (uint256 totalPAssets, uint256 totalYAssets, uint256 totalPtSupply, uint256 totalYtSupply) = _assetsAndSupplies();
    ptShares = _eitherIsZero(totalPAssets, totalPtSupply)
      ? _initialConvertToShares(pAssets, false)
      : pAssets.mulDivUp(totalPtSupply, totalPAssets);
    ytShares = _eitherIsZero(totalYAssets, totalYtSupply)
      ? _initialConvertToShares(yAssets, true)
      : yAssets.mulDivUp(totalYtSupply, totalYAssets);
  }

  /// @notice Converts PT and YT shares to the equivalent amount of principal and yield assets.
  /// @dev Uses `mulDiv` for asset calculation to favor the vault (rounds down assets received).
  ///      Falls back to initial conversion logic when supply or assets are zero. The conversion
  ///      rate reflects the current redemption value based on asset distribution.
  /// @param ptShares Number of PT shares to convert
  /// @param ytShares Number of YT shares to convert
  /// @return pAssets Amount of principal assets equivalent to ptShares
  /// @return yAssets Amount of yield assets equivalent to ytShares
  function convertToAssets(uint256 ptShares, uint256 ytShares) public view returns (uint256 pAssets, uint256 yAssets) {
    (uint256 totalPAssets, uint256 totalYAssets, uint256 totalPtSupply, uint256 totalYtSupply) = _assetsAndSupplies();
    pAssets = _eitherIsZero(totalPAssets, totalPtSupply)
      ? _initialConvertToAssets(ptShares, false)
      : ptShares.mulDiv(totalPAssets, totalPtSupply);
    yAssets = _eitherIsZero(totalYAssets, totalYtSupply)
      ? _initialConvertToAssets(ytShares, true)
      : ytShares.mulDiv(totalYAssets, totalYtSupply);
  }

  /// @notice Returns the current asset distribution between principal and yield.
  /// @dev Implements the redemption formula where pAssets = min(balance, ptSupply) and
  ///      yAssets = balance - pAssets. This ensures principal holders are prioritized.
  /// @return pAssets The amount of assets allocated to principal holders
  /// @return yAssets The amount of assets allocated to yield holders
  function totalAssets() public view virtual returns (uint256 pAssets, uint256 yAssets) {
    (pAssets, yAssets,,) = _assetsAndSupplies();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 ADMIN/UTILITY (PT+YT FORFEIT)              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Burns all PT and YT shares owned by an account and sends the redeemed assets to a receiver.
  /// @dev Convenient function for fully exiting a position. Redeems both PT and YT shares in a single
  ///      transaction using the current exchange rate. Requires appropriate allowances if caller != owner.
  ///      Respects withdrawal permissions via `_checkCanWithdraw()`.
  /// @param owner The account whose entire position will be burned
  /// @param receiver The address that will receive all redeemed assets
  /// @return ptShares The amount of PT shares burned
  /// @return ytShares The amount of YT shares burned
  /// @return pAssets The amount of principal assets transferred to receiver
  /// @return yAssets The amount of yield assets transferred to receiver
  function burnAll(address owner, address receiver)
    public
    virtual
    returns (uint256 ptShares, uint256 ytShares, uint256 pAssets, uint256 yAssets)
  {
    (ptShares, ytShares) = balancesOf(owner);
    (pAssets, yAssets) = _redeem(msg.sender, ptShares, ytShares, receiver, owner);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*         CONTROLLER ENTRYPOINTS FOR CONTROLLED VAULTS       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice ERC4626 withdraw entrypoint called by individual PT or YT vault contracts.
  /// @dev This function is called by ControlledVault.withdraw(). The `yt` parameter determines
  ///      which token type is being withdrawn. Only the appropriate vault contract can call this.
  ///      The function converts the asset amount to shares, burns the shares, and transfers assets.
  /// @param caller The address that initiated the withdraw call (from the vault contract)
  /// @param assets The amount of assets to withdraw (for the specific vault type)
  /// @param receiver The address that will receive the assets
  /// @param owner The address whose shares will be burned
  /// @param yt True if called by YT vault, false if called by PT vault
  /// @return shares The amount of shares burned (PT shares if yt=false, YT shares if yt=true)
  /// @custom:reverts Unauthorized if not called by the appropriate vault contract
  /// @custom:reverts CannotWithdraw if withdrawals are locked
  function _withdraw(address caller, uint256 assets, address receiver, address owner, bool yt)
    external
    virtual
    returns (uint256 shares)
  {
    _checkToken(yt);
    uint256 pAssets = yt.ternary(0, assets);
    uint256 yAssets = yt.ternary(assets, 0);
    (uint256 ptShares, uint256 ytShares) = _withdraw(caller, pAssets, yAssets, receiver, owner);
    shares = yt.ternary(ytShares, ptShares);
  }

  /// @notice ERC4626 redeem entrypoint called by individual PT or YT vault contracts.
  /// @dev This function is called by ControlledVault.redeem(). The `yt` parameter determines
  ///      which token type is being redeemed. Only the appropriate vault contract can call this.
  ///      The function converts the shares to assets, burns the shares, and transfers assets.
  /// @param caller The address that initiated the redeem call (from the vault contract)
  /// @param shares The amount of shares to redeem (for the specific vault type)
  /// @param receiver The address that will receive the assets
  /// @param owner The address whose shares will be burned
  /// @param yt True if called by YT vault, false if called by PT vault
  /// @return assets The amount of assets transferred (principal if yt=false, yield if yt=true)
  /// @custom:reverts Unauthorized if not called by the appropriate vault contract
  /// @custom:reverts CannotWithdraw if withdrawals are locked
  function _redeem(address caller, uint256 shares, address receiver, address owner, bool yt)
    external
    virtual
    returns (uint256 assets)
  {
    _checkToken(yt);
    uint256 pShares = yt.ternary(0, shares);
    uint256 yShares = yt.ternary(shares, 0);
    (uint256 pAssets, uint256 yAssets) = _redeem(caller, pShares, yShares, receiver, owner);
    assets = yt.ternary(yAssets, pAssets);
  }

  /// @inheritdoc TokenController
  /// @dev Emits ERC4626 Deposit events for non-zero amounts.
  function _mint(address to, uint256 pt, uint256 yt) internal virtual override {
    super._mint(to, pt, yt);
    if (pt > 0) ControlledVault(ptToken())._emitDeposit(msg.sender, to, pt, pt);
    if (yt > 0) ControlledVault(ytToken())._emitDeposit(msg.sender, to, 0, yt);
  }
}
