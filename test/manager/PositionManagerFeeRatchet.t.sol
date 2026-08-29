// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";

/// @title PositionManagerFeeRatchetTest
/// @notice Demonstrates that the performance fee has no high-water mark, so the total fee
///         charged over a price path depends on how often `_accrueFees()` happens to run
///         rather than on realised performance.
///
///         The basis is clamped at zero on down-legs (`scaledLastDebt > currentDebt`) but the
///         snapshot is still rewritten, so a loss is never carried forward. Each up-leg is
///         therefore charged in full against a snapshot that was reset at the previous trough.
contract PositionManagerFeeRatchetTest is PositionManagerBaseTest {
  uint24 constant PERF_FEE = 1000; // 10% — matches the deployed wJAAA / wUSCC / wFalconX tiers

  /// @dev Dust deposit purely to reach `_accrueFees()`; deposit/withdraw/burn are the only
  ///      entry points that accrue, and all are MINTER_ROLE gated.
  function _touch() internal {
    _mintCollateral(minter, 1);
    vm.prank(minter);
    positionManager.deposit(1, 0);
  }

  function _openLeveredPosition() internal returns (uint256 startPrice) {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, PERF_FEE); // no management fee, isolate perf

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    startPrice = oracle.price();
  }

  /// @notice Price ends exactly where it started, so realised performance is zero —
  ///         but accruing at each local high mints performance fees anyway.
  function test_performanceFee_ratchetsOnRoundTripPrice() public {
    uint256 startPrice = _openLeveredPosition();
    uint256 highPrice = startPrice * 102 / 100; // +2% swing

    for (uint256 i = 0; i < 4; i++) {
      oracle.setPrice(highPrice);
      _touch(); // accrue at the local high  -> basis > 0, fee charged
      oracle.setPrice(startPrice);
      _touch(); // accrue back at the start  -> basis < 0, clamped, snapshot still reset
    }

    assertEq(oracle.price(), startPrice, "price must round-trip to its starting value");

    uint256 feeShares = positionManager.balanceOf(feeRecipient);
    emit log_named_uint("fee shares minted on a zero-return path", feeShares);
    emit log_named_uint("minter shares", positionManager.balanceOf(minter));

    assertGt(feeShares, 0, "performance fees charged despite zero net performance");
  }

  /// @notice Control: identical price path, accrued once at the end. No fee is due.
  function test_performanceFee_zeroOnSameRoundTripWhenAccruedOnce() public {
    uint256 startPrice = _openLeveredPosition();
    uint256 highPrice = startPrice * 102 / 100;

    for (uint256 i = 0; i < 4; i++) {
      oracle.setPrice(highPrice);
      oracle.setPrice(startPrice);
    }
    _touch(); // single accrual at the end

    assertEq(oracle.price(), startPrice, "price must round-trip to its starting value");
    assertEq(
      positionManager.balanceOf(feeRecipient), 0, "no fee is due on a zero-return path accrued once"
    );
  }

  /// @notice Monotonically rising price: every leg is a gain, so nothing is ever clamped.
  ///         The residual cadence effect here is second-order (~1.3%), attributable to the
  ///         deliberate `mulDivUp` bias on the basis plus share-dilution compounding between
  ///         accruals. Contrast with the round-trip case above, where the ratio is unbounded
  ///         (a strictly positive fee against a zero-fee control). This isolates the clamp —
  ///         not rounding or compounding — as the cause of the ratchet.
  function test_performanceFee_cadenceEffectIsSecondOrderWhenPriceOnlyRises() public {
    uint256 startPrice = _openLeveredPosition();

    for (uint256 i = 1; i <= 4; i++) {
      oracle.setPrice(startPrice * (100 + i) / 100);
      _touch();
    }
    uint256 steppedFee = positionManager.balanceOf(feeRecipient);

    // Fresh run, same endpoint, single accrual.
    setUp();
    startPrice = _openLeveredPosition();
    oracle.setPrice(startPrice * 104 / 100);
    _touch();
    uint256 singleFee = positionManager.balanceOf(feeRecipient);

    emit log_named_uint("stepped accrual fee", steppedFee);
    emit log_named_uint("single accrual fee ", singleFee);
    assertApproxEqRel(
      steppedFee, singleFee, 0.02e18, "monotonic-path cadence effect should stay second-order"
    );
  }
}
