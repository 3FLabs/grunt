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