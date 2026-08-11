# Known Issues & Assumptions

This registry records intentional constraints that require deployment or integration controls. The entries below are documentation-only audit resolutions; changing the behavior requires revisiting the underlying finding.

## Facility and fees

- **The Facility must not receive PositionManager fees (Cantina #9).** `depositManager`, `withdrawManager`, and `burnManager` snapshot the Facility's PositionManager-share balance around an operation. Because the PositionManager accrues fees inside that window, setting its `feeRecipient` to the Facility includes the fee mint in the balance delta and credits it to the resolving intent. Use an external fee recipient.
