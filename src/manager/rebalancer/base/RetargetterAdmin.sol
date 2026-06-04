// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IRetargetterAdmin} from "../../../interfaces/manager/rebalancer/IRetargetterAdmin.sol";
import {RetargetterBase} from "./RetargetterBase.sol";
import {
  LibRetargetter,
  RetargetterStorage,
  RetargetterConfig
} from "../../../libs/manager/rebalancer/LibRetargetter.sol";
import {LibRetargetterErrors} from "../../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {
  MAX_CONSUME_TIMELOCK,
  MAX_PROPOSAL_TIMELOCK,
  MAX_HORIZON,
  MIN_HORIZON,
  MAX_MINT_TO_REPAID_DELAY,
  MAX_MAX_YIELD_BPS,
  MAX_PAUSE_DURATION,
  MIN_TICK_DURATION,
  MAX_TICK_DURATION
} from "../../../libs/manager/rebalancer/LibRetargetterConstants.sol";
import {LibChecks} from "../../../libs/common/LibChecks.sol";
import {LibPause} from "../../../libs/common/LibPause.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";

/// @title RetargetterAdmin
/// @author 3F Protocol
/// @notice Owner-driven configuration of the Retargetter.
/// @dev `setAuctionParams` is blocked while a batch is open, so PT/YT holders cannot have their
///      maturity / repayment window / cap curve changed under them. `setTimelocks` can be updated
///      at any time; the in-flight batch / proposal hold onto their own snapshots.
abstract contract RetargetterAdmin is IRetargetterAdmin, RetargetterBase {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using LibPause for uint40;
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          SETTERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterAdmin
  function setTimelocks(uint40 consumeTimelock_, uint40 proposalTimelock_) external override onlyOwner {
    if (consumeTimelock_ > MAX_CONSUME_TIMELOCK) revert LibRetargetterErrors.TimelockTooLong();
    if (proposalTimelock_ > MAX_PROPOSAL_TIMELOCK) revert LibRetargetterErrors.TimelockTooLong();
    // Both fields live in the packed config slot, so set them with a single read-modify-write.
    RetargetterConfig storage c = LibRetargetter.retargetterStorage().config;
    c.consumeTimelock = consumeTimelock_;
    c.proposalTimelock = proposalTimelock_;
    emit TimelocksSet(consumeTimelock_, proposalTimelock_);
  }

  /// @inheritdoc IRetargetterAdmin
  function setAuctionParams(
    uint40 horizon_,
    uint40 tickDuration_,
    uint40 tickThreshold_,
    uint40 mintToRepaidDelay_,
    uint16 maxYieldBps_
  ) external override onlyOwner {
    if (horizon_ < MIN_HORIZON || horizon_ > MAX_HORIZON) {
      revert LibRetargetterErrors.HorizonOutOfRange();
    }
    if (tickDuration_ < MIN_TICK_DURATION || tickDuration_ > MAX_TICK_DURATION) {
      revert LibRetargetterErrors.TickDurationOutOfRange();
    }
    // Validated against the new tick duration in the same call: no set-ordering hazard.
    if (tickThreshold_ > tickDuration_) revert LibRetargetterErrors.TickThresholdTooLong();
    if (mintToRepaidDelay_ > MAX_MINT_TO_REPAID_DELAY) revert LibRetargetterErrors.MintToRepaidDelayTooLong();
    if (uint256(maxYieldBps_) > MAX_MAX_YIELD_BPS) revert LibRetargetterErrors.MaxYieldTooHigh();

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (s.batch.active) revert LibRetargetterErrors.BatchAlreadyOpen();

    // All five fields share the packed config slot: one read-modify-write instead of five.
    RetargetterConfig storage c = s.config;
    c.horizon = horizon_;
    c.tickDuration = tickDuration_;
    c.tickThreshold = tickThreshold_;
    c.mintToRepaidDelay = mintToRepaidDelay_;
    c.maxYieldBps = maxYieldBps_;
    emit AuctionParamsSet(horizon_, tickDuration_, tickThreshold_, mintToRepaidDelay_, maxYieldBps_);
  }

  /// @inheritdoc IRetargetterAdmin
  function addModule(address module) external override onlyOwner {
    module.checkContract();
    if (!LibRetargetter.retargetterStorage().modules.add(module)) {
      revert LibRetargetterErrors.ModuleAlreadyRegistered();
    }
    emit ModuleAdded(module);
  }

  /// @inheritdoc IRetargetterAdmin
  function removeModule(address module) external override onlyOwner {
    if (!LibRetargetter.retargetterStorage().modules.remove(module)) {
      revert LibRetargetterErrors.ModuleNotRegistered();
    }
    emit ModuleRemoved(module);
  }

  /// @inheritdoc IRetargetterAdmin
  function pause(uint40 duration) external override onlyOwner {
    if (duration > MAX_PAUSE_DURATION) revert LibRetargetterErrors.PauseDurationTooLong();
    uint40 pauseUntil_ = LibPause.pauseFor(duration);
    LibRetargetter.retargetterStorage().pauseUntil = pauseUntil_;
    emit PauseSet(pauseUntil_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            VIEWS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterAdmin
  function assets() external view override returns (address collateralAsset, address debtAsset) {
    RetargetterConfig storage c = LibRetargetter.retargetterStorage().config;
    return (c.collateralAsset, c.debtAsset);
  }

  /// @inheritdoc IRetargetterAdmin
  function requestFactory() external view override returns (address) {
    return LibRetargetter.retargetterStorage().config.requestFactory;
  }

  /// @inheritdoc IRetargetterAdmin
  function config()
    external
    view
    override
    returns (
      uint40 consumeTimelock,
      uint40 proposalTimelock,
      uint40 mintToRepaidDelay,
      uint40 horizon,
      uint40 tickDuration,
      uint40 tickThreshold,
      uint16 maxYieldBps
    )
  {
    RetargetterConfig storage c = LibRetargetter.retargetterStorage().config;
    return (
      c.consumeTimelock,
      c.proposalTimelock,
      c.mintToRepaidDelay,
      c.horizon,
      c.tickDuration,
      c.tickThreshold,
      c.maxYieldBps
    );
  }

  /// @inheritdoc IRetargetterAdmin
  function pauseStatus() external view override returns (uint40 pauseUntil, bool paused) {
    uint40 pauseUntil_ = LibRetargetter.retargetterStorage().pauseUntil;
    return (pauseUntil_, pauseUntil_.paused());
  }

  /// @inheritdoc IRetargetterAdmin
  function modules() external view override returns (address[] memory) {
    return LibRetargetter.retargetterStorage().modules.values();
  }

  /// @inheritdoc IRetargetterAdmin
  function isModule(address module) external view override returns (bool) {
    return LibRetargetter.retargetterStorage().modules.contains(module);
  }
}
