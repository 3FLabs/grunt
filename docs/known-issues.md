# Known Issues & Assumptions

This registry records intentional constraints that require deployment or integration controls. The entries below are documentation-only audit resolutions; changing the behavior requires revisiting the underlying finding.

## Facility and fees

- **The Facility must not receive PositionManager fees (Cantina #9).** `depositManager`, `withdrawManager`, and `burnManager` snapshot the Facility's PositionManager-share balance around an operation. Because the PositionManager accrues fees inside that window, setting its `feeRecipient` to the Facility includes the fee mint in the balance delta and credits it to the resolving intent. Use an external fee recipient.
- **Zero pending fee shares do not imply zero fee state (Cantina #10).** A fee-asset amount can be blocked by the total-assets cap or floor to zero during share conversion. An accrual still advances its timestamp; the performance reference follows its documented advance/hold rule, and `feeData().heldManagementFees` can remain non-zero.
