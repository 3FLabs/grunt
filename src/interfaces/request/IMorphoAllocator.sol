// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title IMorphoAllocator
/// @author 3F Protocol
/// @notice Local minimal interface for the externally-deployed MorphoAllocator facilitator.
/// @dev The canonical contract lives in the facilitators repo; grunt does not depend on it, so only the
///      `run` entrypoint and its `Deallocation` struct are mirrored here. The encoding is ABI-compatible
///      because grunt's `MarketParams` is structurally identical to the facilitators copy. Keep this
///      signature in sync with the deployed MorphoAllocator.
interface IMorphoAllocator {
  /// @notice A single source from which `run` gathers liquidity before allocating the total.
  /// @param adapter Morpho V1 Market adapter to deallocate from, or address(0) for idle liquidity.
  /// @param marketParams Source market identifier, ignored when adapter is address(0).
  /// @param amount Assets to source from this entry; contributes to the allocated total.
  /// @param maxUtilisation Post-deallocation utilisation cap in WAD, ignored when adapter is address(0).
  struct Deallocation {
    address adapter;
    MarketParams marketParams;
    uint256 amount;
    uint256 maxUtilisation;
  }

  /// @notice Unlocks a matured fund DEPOSIT order, rebalances Morpho Vault V2 liquidity, then runs
  ///         depositManager and borrows. The measured unlocked amount is deposited in full, so the
  ///         intent is left with no collateral dust regardless of unlock slippage or fund price
  ///         movement.
  /// @param intentId The intent ID.
  /// @param deallocations Sources to gather liquidity from (markets and/or idle); see {Deallocation}.
  /// @param allocateAdapter Destination Morpho V1 Market adapter, or address(0) to skip allocation.
  /// @param allocateMarket Destination market, ignored when allocateAdapter is address(0).
  /// @param borrowAmount The amount to borrow via depositManager.
  /// @param useTarget Whether to use the target asset for the position manager deposit.
  /// @param minSharesUnlocked The minimum amount that must be unlocked (slippage guard on unlock).
  function run(
    uint256 intentId,
    Deallocation[] calldata deallocations,
    address allocateAdapter,
    MarketParams calldata allocateMarket,
    uint256 borrowAmount,
    bool useTarget,
    uint256 minSharesUnlocked
  ) external;
}
