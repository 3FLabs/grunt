// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IFacilityFunds} from "../../interfaces/facility/base/IFacilityFunds.sol";
import {IMorphoAllocator} from "../../interfaces/request/IMorphoAllocator.sol";
import {Mode} from "../../libs/funds/Order.sol";
import {MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title SyncAllocatorDeposit
/// @notice Stateless script designed to be delegatecalled from MorphoFlashLoanRequest.
///         Executes a synchronous deposit flow: create → commit → allocator.run, delegating the
///         unlock, Morpho Vault V2 rebalancing, and depositManager steps to the MorphoAllocator.
/// @dev Must NOT have any storage variables. The fund must be set on the intent before execute().
///      Runs under delegatecall, so allocator.run executes with msg.sender == MorphoFlashLoanRequest,
///      which must hold EXECUTOR_ROLE on the allocator; the allocator must hold FACILITATOR_ROLE on the
///      facility and be a whitelisted allocator on the Vault V2.
/// @author 3F Protocol
contract SyncAllocatorDeposit {
  /// @notice Parameters forwarded to IMorphoAllocator.run, grouped into a struct to keep run() under
  ///         the ABI decoder stack limit (the project compiles without via-ir).
  /// @dev The allocator deposits the measured unlocked amount via depositManager, so no deposit
  ///      amount is passed here and the intent is left with no collateral dust.
  /// @param deallocations Vault V2 liquidity sources to gather before allocating; see IMorphoAllocator.
  /// @param allocateAdapter Destination Morpho V1 Market adapter, or address(0) to skip allocation.
  /// @param allocateMarket Destination market, ignored when allocateAdapter is address(0).
  /// @param borrowAmount The amount to borrow via the position manager.
  /// @param useTarget Whether to use the target asset for the position manager deposit.
  /// @param minSharesUnlocked The minimum amount that must be unlocked (allocator unlock slippage guard).
  struct AllocatorParams {
    IMorphoAllocator.Deallocation[] deallocations;
    address allocateAdapter;
    MarketParams allocateMarket;
    uint256 borrowAmount;
    bool useTarget;
    uint256 minSharesUnlocked;
  }

  /// @notice Executes the synchronous allocator-backed deposit flow for a facility intent.
  /// @param facility The facility contract address.
  /// @param allocator The deployed MorphoAllocator to delegate unlock and depositManager to.
  /// @param intentId The intent ID on the facility.
  /// @param fundDepositAmount The amount to deposit into the fund order.
  /// @param minSharesOut The minimum shares expected from the deposit.
  /// @param params The parameters forwarded to IMorphoAllocator.run.
  function run(
    address facility,
    address allocator,
    uint256 intentId,
    uint256 fundDepositAmount,
    uint256 minSharesOut,
    AllocatorParams calldata params
  ) external {
    // 1. Create deposit order on fund
    IFacilityFunds(facility).create(intentId, fundDepositAmount, minSharesOut, Mode.DEPOSIT);

    // 2. Commit order (facility sends tokens to fund)
    IFacilityFunds(facility).commit(intentId);

    // 3. Delegate unlock, vault rebalance, and depositManager to the allocator
    IMorphoAllocator(allocator)
      .run(
        intentId,
        params.deallocations,
        params.allocateAdapter,
        params.allocateMarket,
        params.borrowAmount,
        params.useTarget,
        params.minSharesUnlocked
      );
  }
}
