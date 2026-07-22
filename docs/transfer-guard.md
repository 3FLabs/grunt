# Transfer Guard

`TransferGuard` centralizes transfer compliance for the protocol's tokens. A token contract calls `canTransfer(token, from, to, amount)` on the guard; the guard answers from two pieces of state it keeps per token and per address.

Each **address** has one status: `NONE` (default), `WHITELIST`, `BLOCKLIST`, or `NATIVE` (a protocol-internal address such as the Facility). Each **token** has a config: paused flag, a mode, and whether to run the collateral allowlist check.

## Modes

A mode combines two questions: are `NONE` addresses allowed, and must at least one party be `NATIVE`?

| Mode | NONE allowed | NATIVE required |
|------|--------------|-----------------|
| `BLOCKLIST` (default) | yes | no |
| `WHITELIST` | no | no |
| `NATIVE_ONLY` | yes | yes |
| `NATIVE_WHITELIST` | no | yes |

Rules that apply in every mode: a paused token blocks everything; a `BLOCKLIST` party blocks the transfer; mints and burns (a zero-address party) are exempt from the NATIVE requirement, so the modes with a NATIVE requirement still allow direct mints/burns to whitelisted users.

## Collateral Allowlist Check

When `checkCollateralAllowed` is enabled on a token (used for PositionManager shares), the guard additionally calls `PositionManager(token).assets()` to find the collateral asset and then `WrappedAsset(collateral).isAllowed(account, amount)` for each non-null party. This delegates compliance to the wrapped asset's own allowlist (for example the Superstate allowlist behind wUSCC), so the share token automatically inherits the collateral's transfer restrictions.

## Configuration

The owner sets token configs and grants roles, the pauser flips the paused flag, and compliance sets address statuses (individually or in batch). See [Architecture](architecture.md#roles).

```solidity
TransferGuard(guard).setTokenConfig(address(positionManager), false, TokenMode.NATIVE_ONLY, true);
TransferGuard(guard).setAddressStatus(facility, AddressStatus.NATIVE);
TransferGuard(guard).setAddressStatus(user, AddressStatus.WHITELIST);
positionManager.setTransferGuard(guard);
```
