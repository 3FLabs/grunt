// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IRetargetterAdmin
/// @author 3F Protocol
/// @notice Owner-driven configuration surface of the Retargetter.
/// @dev All setters are owner-only (Solady's OwnableRoles `onlyOwner`). Views are open. The auction
///      parameters ({setAuctionParams}) can only be changed when no batch is open; the timelocks
///      ({setTimelocks}) can be updated at any time but only affect future batches / proposals.
interface IRetargetterAdmin {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the governance timelocks are set (at init and via {setTimelocks}).
  /// @param consumeTimelock The new consume timelock (seconds).
  /// @param proposalTimelock The new proposal timelock (seconds).
  event TimelocksSet(uint40 consumeTimelock, uint40 proposalTimelock);

  /// @notice Emitted when the auction parameters are set (at init and via {setAuctionParams}).
  /// @param horizon The new auction horizon (seconds).
  /// @param tickDuration The new yield-gate tick duration (seconds).
  /// @param tickThreshold The new yield-gate tick threshold (seconds).
  /// @param mintToRepaidDelay The new mint-to-repaid delay (seconds).
  /// @param maxYieldBps The new global per-PM yield cap (basis points, absolute over the horizon).
  event AuctionParamsSet(
    uint40 horizon, uint40 tickDuration, uint40 tickThreshold, uint40 mintToRepaidDelay, uint16 maxYieldBps
  );

  /// @notice Emitted when a flash-loan / orchestration module is added to the whitelist.
  /// @param module The newly-whitelisted module.
  event ModuleAdded(address indexed module);

  /// @notice Emitted when a module is removed from the whitelist.
  /// @param module The removed module.
  event ModuleRemoved(address indexed module);

  /// @notice Emitted when the Retargetter is paused or unpaused.
  /// @param pauseUntil The pause-until timestamp (0 = unpaused).
  event PauseSet(uint40 pauseUntil);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          SETTERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Updates the governance timelocks in one call.
  /// @dev Callable any time; only affects future batches / proposals (the in-flight batch keeps its
  ///      `consumeAvailableAt` and the in-flight proposal its `executableAt`). Both fields share the
  ///      packed config slot, so they are written together.
  /// @param consumeTimelock The new consume timelock (seconds), capped at `MAX_CONSUME_TIMELOCK`.
  /// @param proposalTimelock The new proposal timelock (seconds), capped at `MAX_PROPOSAL_TIMELOCK`.
  function setTimelocks(uint40 consumeTimelock, uint40 proposalTimelock) external;

  /// @notice Updates the auction parameters in one call.
  /// @dev Only callable when no batch is open, so PT/YT holders never get their maturity / cap
  ///      curve rugged mid-flight. `tickThreshold` is validated against the supplied `tickDuration`,
  ///      so there is no set-ordering hazard. The five fields share the packed config slot and are
  ///      written together. `maxYieldBps` only bounds per-PM caps at the next {openBatch}.
  /// @param horizon The new horizon (seconds), within `[MIN_HORIZON, MAX_HORIZON]`.
  /// @param tickDuration The new tick duration (seconds), within `[MIN_TICK_DURATION, MAX_TICK_DURATION]`.
  /// @param tickThreshold The new tick threshold (seconds), `<= tickDuration`.
  /// @param mintToRepaidDelay The new mint-to-repaid delay (seconds), capped at `MAX_MINT_TO_REPAID_DELAY`.
  /// @param maxYieldBps The new global per-PM yield cap (basis points), capped at `MAX_MAX_YIELD_BPS`.
  function setAuctionParams(
    uint40 horizon,
    uint40 tickDuration,
    uint40 tickThreshold,
    uint40 mintToRepaidDelay,
    uint16 maxYieldBps
  ) external;

  /// @notice Adds `module` to the flash-loan / orchestration module whitelist.
  /// @param module The module to add. Must be a contract; reverts on duplicates.
  function addModule(address module) external;

  /// @notice Removes `module` from the whitelist.
  /// @param module The module to remove. Reverts if not registered.
  function removeModule(address module) external;

  /// @notice Pauses the Retargetter for `duration` seconds.
  /// @dev Pausing blocks {openBatch}, {consumeOffer}, {authorizeMinting}, {propose}, and
  ///      {executeProposal}. {closeBatch} and {cancelProposal} remain callable so governance can
  ///      tear down in-flight state during an incident.
  /// @param duration The pause duration (seconds, 0 unpauses).
  function pause(uint40 duration) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            VIEWS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the configured collateral / debt asset pair (immutable after init).
  /// @return collateralAsset The common collateral asset every batch PM must declare.
  /// @return debtAsset The common debt asset; also each deployed Request's auction asset.
  function assets() external view returns (address collateralAsset, address debtAsset);

  /// @notice Returns the RequestFactory used to deploy auction Requests (immutable after init).
  function requestFactory() external view returns (address);

  /// @notice Returns the tunable policy configuration in one call.
  /// @dev Reads the packed config slot once; consumers that need a single value just ignore the
  ///      rest. The asset pair and factory are split out into {assets} / {requestFactory} since they
  ///      are immutable.
  /// @return consumeTimelock Seconds between {openBatch} and the first {consumeOffer} window.
  /// @return proposalTimelock Seconds between {propose} and {executeProposal}.
  /// @return mintToRepaidDelay Seconds between the last mint/consume and the earliest repaid mark.
  /// @return horizon Seconds defining each Request's lifetime (the auction horizon).
  /// @return tickDuration Granularity of the yield gate's tick-rounded paid duration (seconds).
  /// @return tickThreshold Grace period (seconds) before the gate promotes to the next tick.
  /// @return maxYieldBps Global per-PM yield cap (basis points, absolute over the horizon).
  function config()
    external
    view
    returns (
      uint40 consumeTimelock,
      uint40 proposalTimelock,
      uint40 mintToRepaidDelay,
      uint40 horizon,
      uint40 tickDuration,
      uint40 tickThreshold,
      uint16 maxYieldBps
    );

  /// @notice Returns the pause state in one call.
  /// @return pauseUntil The pause-until timestamp (0 = unpaused).
  /// @return paused Whether the Retargetter is currently paused (`block.timestamp < pauseUntil`).
  function pauseStatus() external view returns (uint40 pauseUntil, bool paused);

  /// @notice Returns the full module whitelist.
  function modules() external view returns (address[] memory);

  /// @notice Returns whether `module` is on the whitelist.
  function isModule(address module) external view returns (bool);
}
