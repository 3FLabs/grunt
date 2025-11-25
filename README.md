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

## Request Contract

The `Request` contract is the core contract managing funding requests with dual-token (PT/YT) issuance. It combines multiple functionalities:

- **OfferReceiver**: Validates and processes signed offers using EIP-712 signatures
- **VaultController**: Manages PT/YT tokens with ERC4626-style redemptions
- **Ownable**: Restricts admin functions to the contract owner

### Request Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           REQUEST LIFECYCLE                                  │
└─────────────────────────────────────────────────────────────────────────────┘

1. DEPLOYMENT
   └─> Factory creates Request + PT Vault + YT Vault (beacon proxies)
   └─> Owner is set, contract initialized

2. FUNDING PHASE (canWithdraw = false)
   ├─> Method A: consume() - Process signed offers from prime brokers
   │   └─> Callback triggers → Funds pulled → PT/YT minted to maker
   └─> Method B: authorizeMinting() + mint() - Whitelist approach
       └─> Owner authorizes → Prime broker calls mint() → PT/YT minted

3. FUND UTILIZATION
   └─> Owner calls pullFunds() to transfer assets to borrower

4. REPAYMENT
   └─> Borrower transfers assets back to Request contract

5. REDEMPTION PHASE (canWithdraw = true)
   └─> Owner calls setRepaid()
   └─> PT/YT holders can redeem their tokens for underlying assets
```

### Funding Methods

The Request contract supports two methods for prime brokers to provide funds:

#### Method 1: Signed Offer Consumption (`consume`)

The owner broadcasts a signed EIP-712 offer to the contract. This method is ideal for prime brokers who implement automated fund management through smart contracts.

**Flow:**
1. Prime broker creates and signs an `Offer` struct (off-chain)
2. Owner calls `consume(offer, signature, ptAmount)`
3. Contract validates the signature and offer parameters
4. Contract calls `onRequestConsumed()` callback on the maker's contract
5. Maker prepares funds during the callback (e.g., withdraws from DeFi, sets allowances)
6. Contract pulls `ptAmount` of underlying asset from the owner
7. PT and YT tokens are minted to the maker

```solidity
// Offer struct
struct Offer {
  address maker;        // Prime broker address
  uint256 amount;       // Maximum principal amount
  uint256 expectedReturn; // Expected yield amount
  uint256 nonce;        // Sequential nonce (must be > stored nonce)
  uint256 expiration;   // Timestamp when offer expires
}

// YT amount is calculated proportionally
ytAmount = offer.expectedReturn * ptAmount / offer.amount
```

**Callback Interface:**

Prime brokers implementing automated strategies must implement `IRequestCallback`:

```solidity
interface IRequestCallback {
  function onRequestConsumed(
    Offer calldata offer,
    bytes calldata signature,
    uint256 principal,  // PT amount to be pulled
    uint256 yield       // YT amount to be minted
  ) external;
}
```

The callback is invoked **before** funds are pulled, allowing the maker to:
- Withdraw from DeFi positions
- Move funds from internal accounting
- Set ERC20 allowances for the Request contract

#### Method 2: Authorized Minting (`authorizeMinting` + `mint`)

The owner whitelists specific addresses to mint PT/YT tokens. This method is simpler and suitable for prime brokers who manage funds manually or through EOAs.

**Flow:**
1. Owner calls `authorizeMinting(primebroker, ptAmount, ytAmount)`
2. Prime broker approves the Request contract to spend their underlying asset
3. Prime broker calls `mint()`
4. Contract transfers `ptAmount` of underlying asset from the prime broker
5. PT and YT tokens are minted to the prime broker
6. Authorization is consumed (one-time use)

```solidity
// Owner authorizes minting
request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);

// Prime broker mints (after approving underlying asset)
asset.approve(address(request), 1_000_000e6);
request.mint(); // Receives 1M PT + 100k YT
```

### Fund Management

After offers are consumed or minting is complete:

1. **Pull Funds**: Owner calls `pullFunds(receiver, amount)` to transfer collected assets to the borrower
2. **Borrower Utilizes Funds**: The borrower uses the funds for their intended purpose
3. **Repayment**: Borrower transfers assets back to the Request contract
4. **Enable Redemptions**: Owner calls `setRepaid()` to unlock withdrawals

```solidity
// After funding phase
request.pullFunds(borrowerAddress, totalFunded);

// After borrower repays
request.setRepaid(); // Enables PT/YT holders to redeem
```

## RequestFactory

The `RequestFactory` deploys Request instances using the **beacon proxy pattern** for gas-efficient and upgradeable deployments.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     BEACON PROXY PATTERN                        │
└─────────────────────────────────────────────────────────────────┘

  ┌──────────────────┐
  │ RequestFactory   │
  │                  │
  │ REQUEST_BEACON ──┼──> UpgradeableBeacon ──> Request Implementation
  │ PT_VAULT_BEACON ─┼──> UpgradeableBeacon ──> Vault(isPT=false)
  │ YT_VAULT_BEACON ─┼──> UpgradeableBeacon ──> Vault(isPT=true)
  └──────────────────┘
           │
           │ createRequest()
           ▼
  ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
  │  Request Proxy   │     │  PT Vault Proxy  │     │  YT Vault Proxy  │
  │  (ERC1967)       │     │  (ERC1967)       │     │  (ERC1967)       │
  └────────┬─────────┘     └────────┬─────────┘     └────────┬─────────┘
           │                        │                        │
           └────────────────────────┼────────────────────────┘
                                    │
                         delegates to beacon
```

### Deployment

```solidity
// Deploy factory with beacon owner
RequestFactory factory = new RequestFactory(beaconOwner);

// Create a new request with PT/YT vaults
(address request, address ptVault, address ytVault) = factory.createRequest(
  owner,          // Request owner (admin)
  address(usdc),  // Underlying asset
  "USDC Request", // Base name (becomes "PT-USDC Request" / "YT-USDC Request")
  "USDC-REQ"      // Base symbol (becomes "PT-USDC-REQ" / "YT-USDC-REQ")
);
```

### Upgrades

The beacon owner can upgrade all proxies by updating the beacon's implementation:

```solidity
// All existing Request proxies now use the new implementation
UpgradeableBeacon(factory.REQUEST_BEACON()).upgradeTo(newImplementation);
```

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