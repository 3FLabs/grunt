// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {TokenController} from "../tokens/TokenController.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {LibTokenController} from "../../../libs/request/LibTokenController.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {ControlledVault} from "./ControlledVault.sol";
import {IVaultController} from "../../../interfaces/request/IVaultController.sol";
import {IHasAsset} from "../../../interfaces/request/IHasAsset.sol";
import {LibRequestErrors} from "../../../libs/request/LibRequestErrors.sol";

/// @title VaultController
/// @author 3F Protocol
/// @notice Abstract base contract for managing dual-vault systems with Principal and Yield token separation.
/// @dev Extends TokenController to add ERC4626-style vault functionality. Implements the redemption model
///      where principal holders are prioritized (receive up to 1:1 redemption) and yield holders receive
///      any excess assets. Asset distribution follows: principalAssets = min(totalAssets, ptSupply) and
///      yieldAssets = totalAssets - principalAssets. See README for detailed examples and formulas.
abstract contract VaultController is TokenController, IVaultController {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for bool;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      Abstract Metadata                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the underlying asset address. Must be implemented by derived contracts.
  function _asset() internal view virtual returns (address);

  /// @dev Returns whether withdrawals are permitted. Must be implemented by derived contracts.
  function _canWithdraw() internal view virtual returns (bool);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        METADATA/STATUS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IHasAsset
  function asset() external view virtual override returns (address) {
    return _asset();
  }

  /// @inheritdoc IVaultController
  /// @dev Typically false during deposit phase, true during redemption phase.
  function canWithdraw() external view virtual returns (bool) {
    return _canWithdraw();
  }

  /// @dev Synchronizes the status for withdrawal.
  ///      This can be used to update the repayment status above deadline and emit events if repayment happens here.
  /// @return True if withdrawals are permitted
  function _syncWithdrawalStatus() internal virtual returns (bool);

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
      uint256 assets = _asset().balanceOf(address(this));
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
    assembly ("memory-safe") {
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
      if (!_syncWithdrawalStatus()) revert LibRequestErrors.CannotWithdraw();
      if (caller != owner) {
        _consumeAllowance(owner, caller, ptShares, ytShares);
      }
      _burn(owner, ptShares, ytShares);
      uint256 totalAssets_ = yAssets + pAssets;
      if (totalAssets_ > 0) _asset().safeTransfer(receiver, totalAssets_);
      if (pAssets > 0 || ptShares > 0) {
        ControlledVault(_ptToken())._emitWithdraw(caller, receiver, owner, pAssets, ptShares);
      }
      if (yAssets > 0 || ytShares > 0) {
        ControlledVault(_ytToken())._emitWithdraw(caller, receiver, owner, yAssets, ytShares);
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

  /// @inheritdoc IVaultController
  /// @dev Uses `mulDivUp` for share calculation to favor the vault (rounds up shares needed).
  ///      Falls back to initial conversion logic when supply or assets are zero. The conversion
  ///      rate reflects the current redemption value based on asset distribution.
  function convertToShares(uint256 pAssets, uint256 yAssets) public view returns (uint256 ptShares, uint256 ytShares) {
    (uint256 totalPAssets, uint256 totalYAssets, uint256 totalPtSupply, uint256 totalYtSupply) = _assetsAndSupplies();
    ptShares = _eitherIsZero(totalPAssets, totalPtSupply)
      ? _initialConvertToShares(pAssets, false)
      : pAssets.mulDivUp(totalPtSupply, totalPAssets);
    ytShares = _eitherIsZero(totalYAssets, totalYtSupply)
      ? _initialConvertToShares(yAssets, true)
      : yAssets.mulDivUp(totalYtSupply, totalYAssets);
  }

  /// @inheritdoc IVaultController
  /// @dev Uses `mulDiv` for asset calculation to favor the vault (rounds down assets received).
  ///      The conversion rate reflects the current redemption value based on asset distribution.
  ///
  ///      Falls back to initial conversion (PT 1:1, YT 0) when:
  ///      - The token supply is zero (avoids division by zero), OR
  ///      - The total assets are zero AND the request has NOT been repaid yet (pre-repayment estimate).
  ///
  ///      Once repaid, if assets are zero but supply is non-zero, `mulDiv` is used which correctly
  ///      yields zero — allowing `burnAll` to succeed without reverting on a zero-balance `safeTransfer`.
  ///      Previously, the initial conversion would return `ptShares` (1:1) even when no assets existed,
  ///      causing the subsequent transfer to revert (CS-GRUNT-014).
  function convertToAssets(uint256 ptShares, uint256 ytShares) public view returns (uint256 pAssets, uint256 yAssets) {
    (uint256 totalPAssets, uint256 totalYAssets, uint256 totalPtSupply, uint256 totalYtSupply) = _assetsAndSupplies();
    bool repaid = _canWithdraw();
    // Use initial conversion only when supply is zero (div-by-zero guard) or when not yet repaid
    // and assets are zero (pre-repayment 1:1 estimate). After repayment, zero assets with non-zero
    // supply correctly yields zero via mulDiv, preventing burnAll from reverting on empty vaults.
    pAssets = (totalPtSupply == 0 || (totalPAssets == 0 && !repaid))
      ? _initialConvertToAssets(ptShares, false)
      : ptShares.mulDiv(totalPAssets, totalPtSupply);
    yAssets = (totalYtSupply == 0 || (totalYAssets == 0 && !repaid))
      ? _initialConvertToAssets(ytShares, true)
      : ytShares.mulDiv(totalYAssets, totalYtSupply);
  }

  /// @inheritdoc IVaultController
  /// @dev Implements the redemption formula where pAssets = min(balance, ptSupply) and
  ///      yAssets = balance - pAssets. This ensures principal holders are prioritized.
  function totalAssets() public view virtual returns (uint256 pAssets, uint256 yAssets) {
    (pAssets, yAssets,,) = _assetsAndSupplies();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 ADMIN/UTILITY (PT+YT FORFEIT)              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IVaultController
  /// @dev Convenient function for fully exiting a position. Redeems both PT and YT shares in a single
  ///      transaction using the current exchange rate. Requires appropriate allowances if caller != owner.
  ///      Respects withdrawal permissions via `_checkCanWithdraw()`.
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

  /// @dev ERC4626 withdraw entrypoint called by individual PT or YT vault contracts.
  ///      This function is called by ControlledVault.withdraw(). The `yt` parameter determines
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
    if (assets == 0) return 0;
    uint256 pAssets = yt.ternary(0, assets);
    uint256 yAssets = yt.ternary(assets, 0);
    (uint256 ptShares, uint256 ytShares) = _withdraw(caller, pAssets, yAssets, receiver, owner);
    shares = yt.ternary(ytShares, ptShares);
  }

  /// @dev ERC4626 redeem entrypoint called by individual PT or YT vault contracts.
  ///      This function is called by ControlledVault.redeem(). The `yt` parameter determines
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
    if (pt > 0) ControlledVault(_ptToken())._emitDeposit(msg.sender, to, pt, pt);
    if (yt > 0) ControlledVault(_ytToken())._emitDeposit(msg.sender, to, 0, yt);
  }
}
