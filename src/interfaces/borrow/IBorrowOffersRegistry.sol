// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IBorrowOffersRegistry
/// @author 3F Protocol
/// @notice External surface of the {BorrowOffersRegistry}: the single, protocol-wide source of
///         truth for the offer roles (proposer, guardian) and the per-collateral offer
///         configuration (timelock and minimum bonus) shared by every {MorphoBorrowPosition}.
/// @dev Deployed once behind an ERC1967 proxy; each position implementation stores its address as
///      an immutable, so all beacon proxies (and future implementation upgrades) read the same
///      role book and configuration. The registry owner is the administrator: it manages roles
///      and configuration directly (transferable with Solady's built-in two-step handover) and is
///      always authorized by the `check*` functions. Roles are global (a proposer can post offers
///      on any position); configuration is keyed by collateral token (the economics of a veto
///      window and a bonus floor follow the collateral's volatility and liquidity, not the
///      individual position). Effective timelocks are floored to `MIN_OFFER_TIMELOCK`, so a
///      collateral that was never explicitly configured has the minimum veto window (the offer
///      band is open by default) rather than a disabled band.
interface IBorrowOffersRegistry {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new offer timelock is scheduled for a collateral (it becomes
  ///         effective only after the collateral's current timelock elapses).
  /// @param collateral The collateral token the timelock applies to.
  /// @param newTimelock The scheduled timelock value.
  /// @param effectiveAt The absolute timestamp at which `newTimelock` becomes effective.
  event OfferTimelockScheduled(address indexed collateral, uint40 newTimelock, uint40 effectiveAt);

  /// @notice Emitted when the minimum offer bonus is changed for a collateral.
  /// @param collateral The collateral token the floor applies to.
  /// @param minOfferBonusBps The new minimum offer bonus, in basis points.
  event MinOfferBonusSet(address indexed collateral, uint16 minOfferBonusBps);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Grants or revokes the proposer role for `account`. Gated to the registry owner.
  function setProposer(address account, bool enabled) external;

  /// @notice Grants or revokes the guardian role for `account`. Gated to the registry owner.
  function setGuardian(address account, bool enabled) external;

  /// @notice Reverts unless `account` may post offers (a proposer, or the registry owner).
  /// @dev The authorization check used by {MorphoBorrowPosition.proposeOffer}; reverts with
  ///      Solady's `Unauthorized()`. The owner is authorized by derivation rather than by holding
  ///      a role, so an ownership handover never leaves the new owner without powers.
  function checkCanCreateOffer(address account) external view;

  /// @notice Returns whether `account` may revoke any offer regardless of its proposer (a
  ///         guardian, or the registry owner): the veto power inside the timelock window, and the
  ///         kill switch for a bad standing offer.
  /// @dev Read once per batch by {MorphoBorrowPosition.revokeOffers}, which enforces the
  ///      per-offer proposer check itself for callers without this power. A boolean read rather
  ///      than a reverting check: a proposer revoking its own offer is authorized without it.
  function canRevokeOffer(address account) external view returns (bool);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CONFIGURATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Schedules a new offer timelock for `collateral`. Gated to the registry owner.
  /// @dev The change is itself timelocked: it becomes effective only after the collateral's
  ///      *current* effective timelock elapses (at least `MIN_OFFER_TIMELOCK`, since effective
  ///      timelocks are floored to it). `timelock` must be within
  ///      `[MIN_OFFER_TIMELOCK, MAX_OFFER_TIMELOCK]`. It affects future proposals only; existing
  ///      offers keep the `activeAt` timestamp fixed when they were proposed.
  function setOfferTimelock(address collateral, uint40 timelock) external;

  /// @notice Sets the minimum offer bonus for `collateral`, in basis points. Gated to the
  ///         registry owner.
  /// @dev The floor requires a fill's collateral value to exceed the debt value it repays by at
  ///      least this fraction of that debt value. It is enforced both when an offer is proposed
  ///      and again per fill at consume time, so a change takes effect on the next liquidation.
  ///      Raising it leaves live offers in the book but stops any whose current bonus is below
  ///      the new floor from being consumable. Lowering it instantly re-admits such offers with
  ///      no new veto window: their terms were fixed at proposal, passed admission under a floor
  ///      at least as strict, and already served their veto timelock, and every fill still
  ///      requires strict profitability and a strict LTV reduction, so no floor value creates
  ///      fund exposure. Guardians must therefore revoke any standing offer that should not
  ///      remain consumable rather than rely on the current floor gating it. Effective
  ///      immediately, not timelocked: the floor only ever gates consumption (it can skip fills,
  ///      never force or enlarge one), and any offer proposed under a lowered floor still faces
  ///      its own veto timelock before becoming consumable. `minOfferBonusBps` must be at most
  ///      `MAX_MIN_OFFER_BONUS_BPS`; an explicit 0 disables the floor (leaving only the strict
  ///      profitability check), while a never-configured collateral reads the fail-safe
  ///      `DEFAULT_MIN_OFFER_BONUS_BPS`.
  function setMinOfferBonus(address collateral, uint16 minOfferBonusBps) external;

  /// @notice Returns the effective offer configuration for `collateral` in one call.
  /// @param collateral The collateral token to read the configuration of.
  /// @return offerTimelock The collateral's current effective offer timelock (accounting for a
  ///         due, not-yet-promoted pending change), floored to `MIN_OFFER_TIMELOCK`; a
  ///         never-configured collateral reads the floor.
  /// @return minOfferBonusBps The collateral's minimum offer bonus, in basis points; a
  ///         never-configured collateral reads `DEFAULT_MIN_OFFER_BONUS_BPS` (an explicit 0 set
  ///         via {setMinOfferBonus} reads 0).
  function offerConfig(address collateral) external view returns (uint40 offerTimelock, uint16 minOfferBonusBps);

  /// @notice Returns the scheduled (pending) offer timelock for `collateral` and when it becomes
  ///         effective.
  /// @param collateral The collateral token to read the pending timelock of.
  /// @return value The pending timelock value (0 if none scheduled or the scheduled change is
  ///         already due, i.e. already the effective value reported by {offerConfig}).
  /// @return effectiveAt The timestamp at which it becomes effective (0 under the same rule).
  function pendingOfferTimelock(address collateral) external view returns (uint40 value, uint40 effectiveAt);
}
