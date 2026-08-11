# Known Issues & Assumptions

This registry records intentional constraints that require deployment or integration controls. The entries below are documentation-only audit resolutions; changing the behavior requires revisiting the underlying finding.

## Facility and fees

- **The Facility must not receive PositionManager fees (Cantina #9).** `depositManager`, `withdrawManager`, and `burnManager` snapshot the Facility's PositionManager-share balance around an operation. Because the PositionManager accrues fees inside that window, setting its `feeRecipient` to the Facility includes the fee mint in the balance delta and credits it to the resolving intent. Use an external fee recipient.
- **Zero pending fee shares do not imply zero fee state (Cantina #10).** A fee-asset amount can be blocked by the total-assets cap or floor to zero during share conversion. An accrual still advances its timestamp; the performance reference follows its documented advance/hold rule, and `feeData().heldManagementFees` can remain non-zero.
- **`heldManagementFees` tracks charged assets, not minted shares (Cantina #11).** It is an asset-denominated deduction from the next positive performance basis and can grow when the corresponding share conversion floors to zero.

## Offer pre-liquidation

- **The offer walk may return less than the requested target (Cantina #19).** Offers that fail profitability or the bonus floor, or whose fill rounds to zero raw units, are skipped because a later offer may fill. A fill that cannot strictly lower LTV stops the price-ordered walk because later offers cannot qualify at the unchanged LTV. Fill shares round up; collateral caps, position-clamp rescaling, and collateral values round down; debt values round up. `previewConsume` uses this walk, while `preLiquidate` also applies a final post-settlement LTV guard.
