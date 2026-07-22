# Request

The `Request` contract raises a bridge loan and tokenizes the obligation as two ERC20s: **PT** (principal tokens, minted 1:1 against the deposited assets) and **YT** (yield tokens, minted against the expected return). Funders hold PT and YT; the puller (the Facility) uses the raised assets and repays later; after repayment PT and YT redeem against whatever the request holds.

For example, funding 1,000,000 USDC at 10% expected return mints 1,000,000 PT and 100,000 YT.

## Redemption

Once `canWithdraw` is true (the owner called `setRepaid` or the repayment deadline passed), the asset balance is split with PT holders first:

```
principalAssets = min(totalAssets, ptSupply)
yieldAssets     = totalAssets - principalAssets

pricePerPT = principalAssets / ptSupply
pricePerYT = yieldAssets / ytSupply
```

PT redeems at most 1:1; any surplus beyond the principal goes to YT holders; a shortfall is borne proportionally by PT holders. With 1,000,000 PT and 100,000 YT outstanding:

| Total assets | PT price | YT price |
|--------------|----------|----------|
| 900,000 | 0.9 | 0 |
| 1,000,000 | 1.0 | 0 |
| 1,050,000 | 1.0 | 0.5 |
| 1,200,000 | 1.0 | 2.0 |

## Funding

There are two ways to fund a request, both only while `canWithdraw` is false.

**Signed offers.** The owner or consumer calls `consume(offer, signature, ptAmount)` with an EIP-712 offer signed by the maker:

```solidity
struct Offer {
    address maker;          // funder receiving PT/YT
    uint256 amount;         // reference principal
    uint256 expectedReturn; // expected yield on that principal
    uint256 nonce;          // must be greater than the maker's stored nonce
    uint256 expiration;     // validity deadline
    bool useCallback;       // whether to call onRequestConsumed on the maker
}
```

An offer can be consumed partially: YT is minted pro rata, `ytAmount = expectedReturn * ptAmount / amount`. If `useCallback` is set, the maker's `onRequestConsumed(offer, signature, principal, yield)` runs before assets are pulled, so the maker can unwind positions or set allowances just in time.

Maker nonces must start at 1 (nonce 0 is invalid) and are strictly increasing. An offer is cancelled off-chain by agreement, or on-chain by bumping the maker's stored nonce, which invalidates every offer at or below it.

**Authorized minting.** The owner or consumer calls `authorizeMinting(funder, principal, yield)`; the funder then approves the asset and calls `mint()` to deposit the principal and receive PT and YT.

## Using the Funds

The puller calls `pullFunds(amount, data)` to take raised assets; if `data` is non-empty, `onPullFunds(amount, data)` is invoked on the puller after the transfer. Repayment is `repay(amount)` or a direct transfer back. Redemptions open when the owner calls `setRepaid(minBalance)` (which requires the balance to be at least `minBalance`) or when `repaymentDeadline` passes.

Roles: the owner can do everything; the consumer can consume offers and authorize minting; the puller can pull funds. See [Architecture](architecture.md#roles) for who holds these.
