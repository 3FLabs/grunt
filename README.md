```txt                                                                                                                          █████   
                                                     ░░███    
 ███████    ████████     █████ ████    ████████      ███████  
███░░███   ░░███░░███   ░░███ ░███    ░░███░░███    ░░░███░   
░███ ░███    ░███ ░░░     ░███ ░███     ░███ ░███      ░███    
░███ ░███    ░███         ░███ ░███     ░███ ░███      ░███ ███
░░███████    █████        ░░████████    ████ █████     ░░█████ 
 ░░░░░███   ░░░░░          ░░░░░░░░    ░░░░ ░░░░░       ░░░░░  
 ███ ░███                                                      
░░██████                                                       
 ░░░░░░                                                                                                      
```

<p align="center" style="font-size: smaller;">
  <i>(wip)</i>
</p>

## Principal and Yield Token Vaults

The vault system implements a dual-token structure separating principal and yield:

### Deposit Phase

When depositing into the vault, users receive two types of shares:
- **Principal Shares (PT)**: Equal to the amount of assets deposited
- **Yield Shares (YT)**: Equal to the expected yield amount

**Example**: Depositing 1,000,000 USDC with an expected 10% return:
- Receive: 1,000,000 PT + 100,000 YT

During the deposit phase, withdrawals are locked (`canWithdraw = false`).

### Redemption Phase

Once the vault receives assets and unlocks redemption (`canWithdraw = true`), the value of each share type is determined by the total assets in the vault.

#### Redemption Formula

```
principalAssets = min(totalAssets, principalTokenSupply)
yieldAssets = totalAssets - principalAssets

pricePerPrincipalShare = principalAssets / principalTokenSupply
pricePerYieldShare = yieldAssets / yieldTokenSupply
```

#### Redemption Examples

Given: 1,000,000 PT and 100,000 YT outstanding

| Total Assets | Principal Assets | Yield Assets | PT Price | YT Price |
|--------------|------------------|--------------|----------|----------|
| 900,000      | 900,000          | 0            | 0.9      | 0        |
| 1,000,000    | 1,000,000        | 0            | 1.0      | 0        |
| 1,050,000    | 1,000,000        | 50,000       | 1.0      | 0.5      |
| 1,200,000    | 1,000,000        | 200,000      | 1.0      | 2.0      |

**Key Properties:**
- Principal holders are prioritized: they receive up to 1:1 redemption of their shares
- Yield holders receive any assets beyond the principal supply
- If total assets < principal supply, principal holders share the loss proportionally
- If total assets > principal supply, yield holders capture all upside

## Prime Broker Offers

### Offer Creation and Signing

Prime brokers create cryptographically signed offers to lend assets to the protocol. Each offer specifies:
- **Amount**: The principal amount to lend
- **Expected Return**: The absolute return expected (not a rate)
- **Maker**: The address providing the funds
- **Nonce**: A sequential number for offer management (must start at 1)
- **Expiration**: Timestamp after which the offer is no longer valid

Offers are signed using either:
- **EIP-712**: Standard typed data signing for EOA accounts
- **EIP-1271**: Smart contract signature validation via `isValidSignature()`

### Nonce Management

Nonces enable flexible offer lifecycle management:

**Starting Value**: All nonces must start at 1 (nonce 0 is invalid)

**Offer Cancellation**:
- **Soft Cancel**: Communicate with the off-chain server to mark offers as cancelled (no on-chain transaction)
- **Hard Cancel**: Set nonce to a value higher than the offers to cancel on-chain

**Example**: 
- Broker creates offers with nonces 1, 2, 3
- To cancel offers 1 and 2: call `setNonce(3)` on-chain
- Any offer with nonce < 3 becomes invalid
- New offers must use nonce ≥ 3

### Offer Validation

When an offer is consumed, the protocol validates:
1. **Maker validity**: Maker address is not zero
2. **Amount validity**: Amount and expectedReturn are non-zero
3. **Expiration**: Current timestamp < expiration
4. **Nonce freshness**: Offer nonce > current stored nonce for maker
5. **Signature validity**: EIP-712 or EIP-1271 signature verification

Upon successful validation, the offer's nonce is stored, preventing replay attacks.