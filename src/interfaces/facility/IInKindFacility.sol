// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @dev Entry offer of a position manager. Enabled iff `block.timestamp < expiry`.
/// @param capacityCap LibCaps word consumed with the gross debt every entry borrows.
/// @param expiry Timestamp the offer expires at (0 or past = disabled).
/// @param feeBps Share of the minted PM shares sent to the fee recipient, in basis points.
/// @param allowUnlevered Whether entries are served while the pool carries no debt. Such an
///        entry borrows nothing, so it consumes no cap and no auth: the flag and the expiry are
///        its only gates.
struct EntryOffer {
  uint256 capacityCap;
  uint40 expiry;
  uint24 feeBps;
  bool allowUnlevered;
}

/// @dev Exit offer of a position manager. Enabled iff `block.timestamp < expiry`.
/// @param cap LibCaps word consumed with the gross debt every exit repays.
/// @param expiry Timestamp the offer expires at (0 or past = disabled).
/// @param feeBps Share of the pulled PM shares sent to the fee recipient, in basis points.
struct ExitOffer {
  uint256 cap;
  uint40 expiry;
  uint24 feeBps;
}

/// @dev Per-user borrow allowance on an underlying asset, consumed before the asset's security cap.
/// @param amount Debt units still borrowable under the auth.
/// @param expiry Timestamp the auth expires at (0 or past = no auth).
struct Auth {
  uint128 amount;
  uint40 expiry;
}

/// @title IInKindFacility
/// @author 3F Protocol
/// @notice Permissionless in-kind entry and exit over PositionManager (PM) vaults. An entry wraps
///         the PM collateral's underlying 1:1, supplies it and borrows debt at the pool's live
///         debt-per-collateral ratio; an exit repays a proportional debt slice and removes
///         proportional collateral. No price enters the economics.
/// @dev Every cap is denominated in the PM's debt asset (what an entry borrows or an exit repays):
///      - `entries[pm].capacityCap`: the borrowable-liquidity budget of the PM;
///      - `securityCaps[asset]`: how much may be borrowed in kind against one underlying asset,
///        shared by every PM whose collateral wraps it;
///      - `auths[asset][user]`: a user allowance consumed before the security cap (spill-over).
///      An exit consumes `exits[pm].cap` only; a negative multiplier on a shared absolute pool
///      gives entry capacity back.
///
///      A pool with no debt moves no debt, so every one of those caps reads as zero on it: an
///      entry into an unlevered pool is gated by `entries[pm].allowUnlevered` and the offer
///      expiry alone, and an exit from one by the offer expiry alone (a pool that repays to
///      zero must stay exitable). Size is uncapped on both; disable the offer to stop them.
interface IInKindFacility {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when an entry offer is set (or disabled via `expiry = 0`).
  event EntrySet(
    address indexed positionManager, uint256 capacityCap, uint40 expiry, uint24 feeBps, bool allowUnlevered
  );

  /// @notice Emitted when an exit offer is set (or disabled via `expiry = 0`).
  event ExitSet(address indexed positionManager, uint256 cap, uint40 expiry, uint24 feeBps);

  /// @notice Emitted when the security cap word of an underlying asset is set.
  event SecurityCapSet(address indexed asset, uint256 cap);

  /// @notice Emitted when a user auth on an underlying asset is set (or revoked via `expiry = 0`).
  event AuthSet(address indexed asset, address indexed user, uint128 amount, uint40 expiry);

  /// @notice Emitted when an entry consumes a user auth.
  /// @param asset The underlying asset.
  /// @param user The authed user.
  /// @param consumed The debt taken from the auth.
  /// @param remaining The auth amount left.
  event AuthConsumed(address indexed asset, address indexed user, uint256 consumed, uint128 remaining);

  /// @notice Emitted when the fee recipient is set.
  event FeeRecipientSet(address indexed feeRecipient);

  /// @notice Emitted when the pause state is set.
  /// @param pausedUntil The pause-until timestamp (0 = not paused, type(uint40).max = permanent).
  event InKindFacilityPausedSet(uint40 pausedUntil);

  /// @notice Emitted on an entry.
  /// @param positionManager The position manager entered.
  /// @param sender The caller who supplied the underlying.
  /// @param receiver The receiver of the shares and the debt.
  /// @param amount The underlying wrapped and supplied.
  /// @param debt The debt borrowed at the live ratio and sent to `receiver`.
  /// @param shares The PM shares sent to `receiver` (net of fee).
  /// @param feeShares The PM shares sent to the fee recipient.
  event Entered(
    address indexed positionManager,
    address indexed sender,
    address indexed receiver,
    uint256 amount,
    uint256 debt,
    uint256 shares,
    uint256 feeShares
  );

  /// @notice Emitted on an exit.
  /// @param positionManager The position manager exited.
  /// @param sender The caller who supplied the shares and the debt.
  /// @param receiver The receiver of the underlying.
  /// @param underlyingOut The underlying unwrapped and sent to `receiver`.
  /// @param debt The debt repaid.
  /// @param shares The PM shares burned (net of fee).
  /// @param feeShares The PM shares sent to the fee recipient.
  event Exited(
    address indexed positionManager,
    address indexed sender,
    address indexed receiver,
    uint256 underlyingOut,
    uint256 debt,
    uint256 shares,
    uint256 feeShares
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERRORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the entry offer of a position manager is disabled or expired.
  error UnknownEntry(address positionManager);

  /// @notice Thrown when the exit offer of a position manager is disabled or expired.
  error UnknownExit(address positionManager);

  /// @notice Thrown when setting a fee above the maximum.
  error FeeExceedsMax();

  /// @notice Thrown when a position manager does not expose the surface this facility needs.
  error InvalidPositionManager(address positionManager);

  /// @notice Thrown when the position manager reports bad debt (pricing undefined).
  error BadDebtState(address positionManager);

  /// @notice Thrown on an entry into a pool with no collateral: there is no fraction to match
  ///         and no ratio to bootstrap one from.
  error EmptyPool(address positionManager);

  /// @notice Thrown on an entry into a pool carrying no debt while the offer does not allow it
  ///         (`EntryOffer.allowUnlevered`). Nothing about the pool is wrong: no cap can bound
  ///         such an entry, so it is served only on an explicit opt-in.
  error UnleveredEntryDisabled(address positionManager);

  /// @notice Thrown when the ratio-derived debt of an entry into a levered pool rounds to zero:
  ///         the entry would consume none of the debt-denominated caps. Enter more.
  error DustEntry(uint256 amount);

  /// @notice Thrown when the ratio-derived debt falls outside the caller's bounds.
  error DebtOutOfBounds(uint256 debt, uint256 minDebt, uint256 maxDebt);

  /// @notice Thrown when the net shares minted fall below the caller's bound (zero when the PM
  ///         minted nothing or burned).
  error InsufficientSharesOut(uint256 shares, uint256 minSharesOut);

  /// @notice Thrown when the PM minted more than the ratio-matched fraction plus rounding.
  error NonNeutralMint(uint256 shares, uint256 expected);

  /// @notice Thrown when the debt pulled up front (mirror plus headroom) exceeds the caller's bound.
  error ExcessiveDebtIn(uint256 debtRequired, uint256 maxDebtIn);

  /// @notice Thrown when the underlying received falls below the caller's bound.
  error InsufficientUnderlyingOut(uint256 underlyingOut, uint256 minUnderlyingOut);

  /// @notice Thrown when the exit fee consumes every share passed.
  error NothingToBurn();

  /// @notice Thrown when an entry capacity or security word is EXTERNAL with a zero or negative
  ///         multiplier, which would consume nothing.
  error NonConsumingCap(uint256 word);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the entry offer of a position manager (owner or FACILITATOR).
  /// @dev Reverts with FeeExceedsMax above 10%, InvalidPositionManager when `positionManager`
  ///      does not expose `assets()` over a wrapped collateral, like LibCaps.validate on the
  ///      word, and NonConsumingCap on an EXTERNAL word with a non-positive multiplier.
  ///      Overwrites the remaining capacity of an ABSOLUTE word. `allowUnlevered` opens entries
  ///      into a pool with no debt, which no cap bounds: only set it on PMs whose size is
  ///      acceptable unbounded.
  function setEntry(address positionManager, uint256 capacityCap, uint40 expiry, uint24 feeBps, bool allowUnlevered)
    external;

  /// @notice Sets the exit offer of a position manager (owner or FACILITATOR).
  /// @dev Same checks as {setEntry} except the multiplier: a negative one on a shared absolute
  ///      pool gives entry capacity back.
  function setExit(address positionManager, uint256 cap, uint40 expiry, uint24 feeBps) external;

  /// @notice Sets the security cap word of an underlying asset (owner or OPERATOR).
  /// @dev Keyed by `IWrappedAsset(collateral).underlying()` of the served PMs. Validated like
  ///      {setEntry}. An unset asset reads as a zero ABSOLUTE cap: closed to unauthed users.
  function setSecurityCap(address asset, uint256 cap) external;

  /// @notice Sets the auth of a user on an underlying asset (owner or OPERATOR).
  /// @dev Overwrites any remaining amount. `expiry = 0` revokes. Auths are read on the caller of
  ///      {enter}: a user entering through a router needs the auth on the router.
  function setAuth(address asset, address user, uint128 amount, uint40 expiry) external;

  /// @notice Sets the recipient of the share fees (owner).
  function setFeeRecipient(address feeRecipient) external;

  /// @notice Pauses entries and exits for `duration` seconds (owner or COMPLIANCE, 0 = unpause).
  function pauseFor(uint256 duration) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the entry offer of a position manager.
  function getEntry(address positionManager) external view returns (EntryOffer memory offer);

  /// @notice Returns the exit offer of a position manager.
  function getExit(address positionManager) external view returns (ExitOffer memory offer);

  /// @notice Returns the security cap word of an underlying asset.
  function getSecurityCap(address asset) external view returns (uint256 cap);

  /// @notice Returns the auth of a user on an underlying asset.
  function getAuth(address asset, address user) external view returns (Auth memory auth);

  /// @notice Returns the fee recipient and pause state.
  function config() external view returns (address feeRecipient, bool isPaused, uint40 pausedUntil);

  /// @notice Previews an entry of `amount` underlying.
  /// @dev Reverts like {enter} except for the caps and the caller's bounds. `shares` is a
  ///      best-effort estimate; derive `minSharesOut` from it with a tolerance.
  /// @return debt The debt the entry borrows.
  /// @return shares The net PM shares the receiver gets.
  /// @return feeShares The PM shares the fee recipient gets.
  function previewEnter(address positionManager, uint256 amount)
    external
    view
    returns (uint256 debt, uint256 shares, uint256 feeShares);

  /// @notice Previews an exit of `shares` PM shares.
  /// @dev Reverts like {exit} except for the cap and the caller's bounds. Both debt figures
  ///      drift up with interest accrual between preview and execution: approve headroom or
  ///      source `debtRequired` through the callback.
  /// @return debtIn The debt the exit is expected to repay (burn's exact mirror).
  /// @return underlyingOut The underlying the receiver gets.
  /// @return feeShares The PM shares the fee recipient gets.
  /// @return debtRequired The debt the exit pulls up front (`debtIn` plus headroom); the part
  ///         `PM.burn` does not use is refunded.
  function previewExit(address positionManager, uint256 shares)
    external
    view
    returns (uint256 debtIn, uint256 underlyingOut, uint256 feeShares, uint256 debtRequired);

  /// @notice Returns an underlying amount `user` can enter right now under the capacity cap, the
  ///         security cap and the user's auth.
  /// @dev Reverts like {enter} on a disabled offer, pause, bad debt, an empty pool or an
  ///      unlevered pool the offer does not allow. Rounded down: the bound always fits, a few
  ///      more wei may fit too. Saturates at type(uint256).max (an ABSOLUTE word near
  ///      MAX_ABSOLUTE scaled by the pool ratio), and returns it outright on an unlevered pool
  ///      the offer allows: no cap binds there.
  function maxEnter(address positionManager, address user) external view returns (uint256 amount);

  /// @notice Returns an estimate of the PM shares (fee included) that can exit right now under
  ///         the exit cap.
  /// @dev An estimate: the pool debt it reads is what the borrow modules quote, which a module
  ///      that does not simulate accrual reports stale until the market is touched, and the
  ///      rounding is down like {maxEnter}. Reverts like {exit} on a disabled offer, pause or
  ///      bad debt. type(uint256).max when the pool has no debt; saturates otherwise.
  function maxExit(address positionManager) external view returns (uint256 shares);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Enters a position manager: wraps `amount` underlying 1:1, supplies it and borrows
  ///         `debt = amount * D / C` at the live pool ratio, then forwards the borrowed debt and
  ///         the minted PM shares net of fee to `receiver`.
  /// @dev Consumes the capacity cap, then the caller's auth and the security cap, with the gross
  ///      debt before any token moves. The mint is checked against the ratio-matched fraction
  ///      (see `NonNeutralMint`). A pool with no debt borrows nothing: the entry is a plain
  ///      ratio-matched deposit, allowed only under `allowUnlevered` and consuming no cap.
  /// @param positionManager The position manager to enter.
  /// @param amount The underlying to wrap and supply (pulled from the caller).
  /// @param minDebt The minimum debt to borrow (a flash-funded router needs a floor on the cash leg).
  /// @param maxDebt The maximum debt to borrow.
  /// @param minSharesOut The minimum net PM shares the receiver must get.
  /// @param receiver The receiver of the debt and the shares.
  /// @return shares The net PM shares sent to `receiver`.
  /// @return debt The debt sent to `receiver`.
  function enter(
    address positionManager,
    uint256 amount,
    uint256 minDebt,
    uint256 maxDebt,
    uint256 minSharesOut,
    address receiver
  ) external returns (uint256 shares, uint256 debt);

  /// @notice Exits a position manager: pulls `shares` PM shares, optionally calls back the
  ///         caller with the debt to source (non-empty `data`), pulls that debt, repays and
  ///         removes proportional collateral via `PM.burn`, refunds the debt burn did not use,
  ///         sends the fee shares to the recipient, unwraps and forwards the underlying to
  ///         `receiver`.
  /// @dev The debt pulled up front is burn's mirrored slice (post-accrual supply + virtual
  ///      offset, rounded up) plus a small headroom, final before the callback; the exit cap is
  ///      consumed with the mirrored slice. A pool that became unlevered stays exitable: a zero
  ///      slice skips the cap and the pull (the callback still runs when `data` is non-empty).
  /// @param positionManager The position manager to exit.
  /// @param shares The PM shares to pull (fee included).
  /// @param maxDebtIn The maximum debt to pull up front (headroom included).
  /// @param minUnderlyingOut The minimum underlying the receiver must get.
  /// @param receiver The receiver of the underlying.
  /// @param data Opaque callback data; empty skips the callback (see IInKindExitCallback).
  /// @return underlyingOut The underlying sent to `receiver`.
  /// @return debtIn The debt repaid, net of the refund.
  function exit(
    address positionManager,
    uint256 shares,
    uint256 maxDebtIn,
    uint256 minUnderlyingOut,
    address receiver,
    bytes calldata data
  ) external returns (uint256 underlyingOut, uint256 debtIn);
}
