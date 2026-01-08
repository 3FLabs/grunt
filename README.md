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
| ------------ | ---------------- | ------------ | -------- | -------- |
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
- **OwnableRoles**: Restricts admin functions to the contract owner and allows for the "puller" role to pull funds from the contract

### Request Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           REQUEST LIFECYCLE                                  │
└─────────────────────────────────────────────────────────────────────────────┘

1. DEPLOYMENT
   └─> Factory creates Request + PT Vault + YT Vault (beacon proxies)
   └─> Owner and puller role are set, contract initialized

2. FUNDING PHASE (canWithdraw = false)
   ├─> Method A: consume() - Process signed offers from prime brokers
   │   └─> Callback triggers → Funds pulled → PT/YT minted to maker
   └─> Method B: authorizeMinting() + mint() - Whitelist approach
       └─> Owner authorizes → Prime broker calls mint() → PT/YT minted

3. FUND UTILIZATION
   └─> Puller calls pullFunds(amount, data) to transfer assets to themselves
   └─> If data is provided, onPullFunds() callback is invoked on the puller

4. REPAYMENT
   └─> Puller (or borrower) transfers assets back to Request contract
   └─> Optional: Use repay(amount) helper function

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
5. Contract pulls `ptAmount` of underlying asset from the maker (offer.maker)
6. PT and YT tokens are minted to the maker
7. The maker's offer nonce is updated

```solidity
// Offer struct
struct Offer {
  address maker;        // Prime broker address that receives tokens
  uint256 amount;       // Reference principal amount
  uint256 expectedReturn; // Expected yield amount
  uint256 nonce;        // Sequential nonce (must be > stored nonce)
  uint256 expiration;   // Timestamp when offer expires
}

// YT amount is calculated proportionally
ytAmount = offer.expectedReturn * ptAmount / offer.amount

// The ptAmount parameter determines how many PT tokens are minted
// and scales the YT amount proportionally from the offer's expectedReturn
```

**Callback Interface:**

Prime brokers implementing automated strategies can implement `IRequestCallback`:

```solidity
interface IRequestCallback {
  function onRequestConsumed(
    Offer calldata offer,
    bytes calldata signature,
    uint256 principal,  // PT amount being minted
    uint256 yield       // YT amount being minted
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

1. **Pull Funds**: Address with puller role calls `pullFunds(amount, data)` to transfer collected assets to themselves
2. **Callback Invocation**: If `data.length > 0`, the contract calls `onPullFunds(amount, data)` on the puller address
3. **Fund Utilization**: The puller uses the funds for their intended purpose
4. **Repayment**: Puller (or borrower) transfers assets back to the Request contract
5. **Enable Redemptions**: Owner calls `setRepaid()` to unlock withdrawals

```solidity
// After funding phase - puller pulls funds
// Funds are transferred to msg.sender (the puller)
request.pullFunds(totalFunded, ""); // No callback

// With callback data - useful for automated position management
bytes memory positionData = abi.encode(positionId, strategy);
request.pullFunds(totalFunded, positionData); // Calls onPullFunds() on puller

// After repayment (optional helper function)
request.repay(repaymentAmount);
// Or direct transfer:
asset.transfer(address(request), repaymentAmount);

// Enable redemptions
request.setRepaid(); // Enables PT/YT holders to redeem
```

**Puller Role:**
- The puller role is set during contract initialization via the factory
- Only addresses with the puller role can call `pullFunds()`
- Funds are always transferred to `msg.sender` (the puller), not a separate recipient
- The puller can be a smart contract implementing `IPositionManagerRequestCallback` for automated fund management

**Callback Interface:**

Position managers implementing automated strategies can implement `IPositionManagerRequestCallback`:

```solidity
interface IPositionManagerRequestCallback {
  function onPullFunds(uint256 amount, bytes calldata data) external;
}
```

The callback is invoked **after** funds are transferred, allowing the position manager to:
- Open positions in DeFi protocols
- Update internal accounting
- Execute automated strategies based on the provided data

The `pullFunds()` function can be called multiple times by the puller during the funding phase. The `setRepaid()` function toggles the withdrawal lock, enabling PT/YT holders to redeem their tokens for the underlying assets held by the contract.

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
  puller,         // Address with puller role (can call pullFunds)
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
- **Hard Cancel**: Set nonce on-chain to invalidate all offers at or below that nonce

### Offer Validation

When an offer is consumed, the protocol validates:
1. **Maker validity**: Maker address is not zero
2. **Amount validity**: Amount and expectedReturn are non-zero
3. **Expiration**: Current timestamp < expiration
4. **Nonce freshness**: Offer nonce > current stored nonce for maker
5. **Signature validity**: EIP-712 or EIP-1271 signature verification

Upon successful validation, the offer's nonce is stored, preventing replay attacks.

## Borrow Module

The borrow module enables protocol participants to open and manage collateralized borrow positions across different lending protocols through a common `IBorrowPosition` interface.

```
┌─────────────────────────────────────────────────────────────────┐
│                      BORROW MODULE ARCHITECTURE                  │
└─────────────────────────────────────────────────────────────────┘

  ┌──────────────────────┐
  │  IBorrowPosition     │  <-- Common interface for all protocols
  │  (interface)         │
  └──────────┬───────────┘
             │
             │ implements
             ▼
  ┌──────────────────────────────┐
  │   MorphoBorrowPosition       │  <-- Morpho Blue integration
  │   - Initializable            │
  │   - Ownable                  │
  │   - ERC-7201 Storage         │
  │   - PreLiquidation Support   │
  └──────────────────────────────┘
```

### MorphoBorrowPosition

Implementation of a borrow position for the Morpho Blue lending protocol with integrated PreLiquidation system support.

**Key Features:**
- **PreLiquidation Integration**: Connects to Morpho's PreLiquidation system for custom liquidation thresholds
- **Dual LLTV Enforcement**: Enforces both market LLTV (by Morpho) and stricter preLltv (by this contract)
- **ERC-7201 Namespaced Storage**: Proxy-compatible storage pattern preventing storage collisions
- **Ownable Access Control**: Position manager has exclusive control over operations

**Initialization:**
Requires:
- `morpho` - The Morpho Blue protocol contract
- `marketId` - The Morpho market ID for this position
- `positionManager` - The owner address controlling this position
- `preLiquidation` - The PreLiquidation contract (must be from the factory)

The contract validates that the PreLiquidation contract:
1. Exists in the PreLiquidation factory's registry
2. Has a market ID matching the provided marketId
3. Authorizes the PreLiquidation contract to manage position liquidations

**Operations:**
- `supplyCollateral(amount)` - Add collateral to increase borrowing capacity
- `withdrawCollateral(amount)` - Remove collateral (enforces preLltv health check)
- `borrow(amount)` - Borrow assets against collateral (enforces preLltv health check)
- `repay(amount)` - Repay borrowed assets

**Views:**
- `totalBorrowed()` - Current debt including accrued interest
- `totalCollateral()` - Current collateral value **quoted in borrowed asset terms** (using oracle price)
- `isHealthy(lltv)` - Whether position is above the specified LLTV threshold
- `maxBorrow(lltv)` - Maximum borrowable amount given current collateral and specified LLTV
- `availableLiquidity()` - Available liquidity in the market (totalSupplyAssets - totalBorrowAssets)

### Health Factor & PreLiquidation

Position health is determined by comparing borrowed amount against maximum capacity at a given LLTV:

```
collateralValue = collateral × oraclePrice / ORACLE_PRICE_SCALE
maxBorrow = collateralValue × lltv
isHealthy(lltv) = maxBorrow ≥ totalBorrowed
```

## Position Manager

The `PositionManager` aggregates multiple `IBorrowPosition` contracts into a single vault with ERC20 share-based accounting. It enables complex multi-protocol borrowing strategies while presenting a unified interface to users.

### Architecture Overview

The Position Manager is built with a modular architecture, split into abstract base contracts and libraries for separation of concerns:

```
┌─────────────────────────────────────────────────────────────────┐
│                   POSITION MANAGER ARCHITECTURE                   │
└─────────────────────────────────────────────────────────────────┘

                      ┌──────────────────────┐
                      │   PositionManager    │  <-- Main entry point
                      │   (ERC20 Shares)     │
                      └──────────┬───────────┘
                                 │ inherits
        ┌────────────────────────┼────────────────────────┐
        ▼                        ▼                        ▼
┌───────────────────┐  ┌─────────────────────┐  ┌────────────────────────┐
│PositionManager-   │  │PositionManager-     │  │PositionManager-        │
│Shares             │  │Admin                │  │Rebalancing             │
│ - Share calc      │  │ - Queue management  │  │ - Rebalance operations │
│ - Virtual offset  │  │ - Borrow modules    │  │ - Max loss checks      │
└────────┬──────────┘  │ - LLTV setting      │  └────────────────────────┘
         │             └─────────────────────┘
         ▼
┌───────────────────┐
│PositionManager-   │
│Fees               │
│ - Management fee  │
│ - Performance fee │
└───────────────────┘

Libraries (stateless logic):
┌─────────────────────────────────────────────────────────────────┐
│ LibPositionManagerStorage   │ ERC-7201 storage accessor         │
│ LibPositionManagerOperations│ Deposit/withdraw/burn logic       │
│ LibPositionManagerView      │ View functions & conversions      │
│ LibPositionExecutor         │ Low-level position interactions   │
│ LibPositionManagerConstants │ Roles, virtual offsets, limits    │
│ LibPositionManagerTypes     │ Struct definitions                │
└─────────────────────────────────────────────────────────────────┘
```

### File Structure

```
src/
├── manager/
│   ├── PositionManager.sol           # Main contract (start here)
│   ├── PositionManagerFactory.sol    # Beacon proxy factory
│   ├── base/
│   │   ├── PositionManagerShares.sol     # Share calculation & settlement
│   │   ├── PositionManagerAdmin.sol      # Admin functions & access control
│   │   ├── PositionManagerFees.sol       # Fee accrual & management
│   │   └── PositionManagerRebalancing.sol# Rebalancing operations
│   └── rebalancer/
│       └── MorphoRebalancer.sol      # Flash-loan based rebalancer
├── libs/manager/
│   ├── PositionManagerTypes.sol          # Type definitions
│   ├── LibPositionManagerStorage.sol     # ERC-7201 storage
│   ├── LibPositionManagerConstants.sol   # Constants & roles
│   ├── LibPositionManagerOperations.sol  # Core operation logic
│   ├── LibPositionManagerView.sol        # View functions
│   └── LibPositionExecutor.sol           # Position interaction helpers
└── interfaces/manager/
    └── IPositionManager.sol          # Interface definition
```

**Reading Order:**
1. `IPositionManager.sol` - Understand the interface
2. `PositionManagerTypes.sol` - Learn the data structures
3. `PositionManager.sol` - Main contract that ties everything together
4. Base contracts in `base/` - Understand specific concerns
5. Libraries in `libs/manager/` - Deep dive into implementation details

### Role-Based Access Control

The Position Manager uses Solady's `OwnableRoles` for granular permission management:

| Role | Bit Flag | Permission |
|------|----------|------------|
| `PM_ROLE_MINTER` | `1 << 0` | Call `deposit`, `withdraw`, `burn` |
| `PM_ROLE_CURATOR` | `1 << 1` | Set supply/withdrawal queues |
| `PM_ROLE_REBALANCER` | `1 << 2` | Execute rebalancing operations |

The **owner** has exclusive control over:
- Adding/removing borrow modules (whitelisting)
- Setting LLTV
- Setting fee configuration
- Setting max rebalance loss threshold
- Granting/revoking roles

### High-Level Design

```
  ┌──────────────────────┐
  │   PositionManager    │
  │                      │
  │  - Supply Queue      │──> [Position A, Position B, Position C]
  │  - Withdrawal Queue  │──> [Position C, Position B, Position A]
  │  - LLTV              │
  │  - Fee Configuration │
  └──────────┬───────────┘
             │
             │ manages
             ▼
  ┌─────────────────────────────────────────────────────────────┐
  │                    IBorrowPosition Pool                       │
  ├─────────────────┬─────────────────┬─────────────────────────┤
  │ MorphoPosition1 │ MorphoPosition2 │ ... (other protocols)   │
  │  - Collateral   │  - Collateral   │                         │
  │  - Debt         │  - Debt         │                         │
  └─────────────────┴─────────────────┴─────────────────────────┘
```

### Key Concepts

**Total Assets**: The net value of all positions, calculated as:
```
totalAssets = Σ(collateralQuoted) - Σ(debt)
```
Where `collateralQuoted` is collateral value expressed in debt asset terms using each position's oracle.

**Shares**: ERC20 tokens representing ownership of the aggregated position. Share price is derived from total assets with virtual offset protection against inflation attacks.

**Supply Queue**: Ordered list of positions with borrow caps, used for deposits. Each entry contains:
- `position`: The IBorrowPosition contract address
- `maxBorrow`: Maximum amount to borrow from this position per deposit

**Withdrawal Queue**: Ordered list of position addresses, used for withdrawals and burns.

**LLTV**: Loan-to-Liquidation-Threshold-Value used for calculating available collateral during withdrawals.

### Share Calculation

Shares use a virtual offset to prevent inflation attacks (similar to ERC4626 with virtual shares):

```
// Converting assets to shares
shares = assets × (totalSupply + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS)

// Converting shares to assets
assets = shares × (totalAssets + VIRTUAL_ASSETS) / (totalSupply + VIRTUAL_SHARES)

// Constants
VIRTUAL_SHARES = 1e6
VIRTUAL_ASSETS = 1
```

### Operations

#### Deposit

Deposits collateral and borrows debt across positions in the supply queue.

```solidity
function deposit(uint256 collateral, uint256 debt) external returns (int256 shares);
```

**Flow:**
1. Accrue fees to fee recipient
2. Pull collateral from caller
3. If `debt == 0`: supply all collateral to first position in queue
4. If `debt > 0`: iterate through supply queue:
   - For each position, borrow up to `min(availableLiquidity, maxBorrow, remainingDebt)`
   - Supply collateral proportionally: `collateral × (amountBorrowed / totalDebt)`
   - Always supply collateral before borrowing
5. Transfer borrowed debt to caller
6. Calculate share delta based on total assets change:
   - If assets increased → mint shares (positive return)
   - If assets decreased → burn shares (negative return)
7. Update snapshot for performance fees

**Example:**
```
Supply Queue: [(PositionA, maxBorrow=1000), (PositionB, maxBorrow=2000)]
Deposit: collateral=1500, debt=2000

Position A:
  - Available: 800, MaxBorrow: 1000 → borrows 800
  - Collateral: 1500 × (800/2000) = 600

Position B:
  - Remaining debt: 1200
  - Available: 5000, MaxBorrow: 2000 → borrows 1200
  - Collateral: 900 (remaining)

Result: 1500 collateral supplied, 2000 debt borrowed, shares minted
```

#### Withdraw

Withdraws collateral and repays debt across positions in the withdrawal queue.

```solidity
function withdraw(uint256 collateral, uint256 debt) external returns (int256 shares);
```

**Flow:**
1. Accrue fees to fee recipient
2. Pull debt from caller for repayment
3. **First pass** - Repay debt through withdrawal queue:
   - For each position, repay up to `min(positionDebt, remainingDebt)`
4. **Second pass** - Withdraw collateral through withdrawal queue:
   - For each position, withdraw up to `min(availableCollateral(lltv), positionCollateral, remainingCollateral)`
   - Reverts with `InsufficientAvailableCollateral` if unable to withdraw requested amount
5. Transfer collateral to caller
6. Calculate share delta based on total assets change:
   - If assets decreased → burn shares (negative return)
   - If assets increased → mint shares (positive return)
7. Update snapshot for performance fees

**Available Collateral:**
```
availableCollateral = totalCollateral - requiredCollateral
requiredCollateral = debt × ORACLE_PRICE_SCALE / (lltv × collateralPrice)
```

Only "available" collateral can be withdrawn without repaying debt, ensuring positions remain healthy.

#### Burn

Burns shares to exit the position proportionally, maintaining average LTV across all positions.

```solidity
function burn(uint256 shares) external returns (uint256 collateral, uint256 debt);
```

**Flow:**
1. Accrue fees to fee recipient
2. Calculate proportional amounts:
   ```
   collateral = totalCollateral × shares / totalSupply  (round down)
   debt = totalDebt × shares / totalSupply  (round up)
   ```
3. Burn shares from caller
4. Pull debt from caller for repayment
5. Process through withdrawal queue - for each position:
   - Repay: `debtToRepay × positionDebt / totalDebt` (capped at remaining)
   - Withdraw: `collateralToWithdraw × positionCollateral / totalCollateral` (capped at remaining)
6. Transfer collateral to caller
7. Update snapshot for performance fees

**Key Property:** Burns maintain the average LTV across all positions, making exit cost predictable regardless of withdrawal queue order.

### Fee Mechanism

The PositionManager supports two types of fees, accrued before every operation:

#### Management Fee
Annual fee on total assets, expressed in basis points per year:
```
managementFeeAssets = totalAssets × managementFee × elapsedTime / (BPS × SECONDS_PER_YEAR)
```

#### Performance Fee
Fee on gains since last snapshot, expressed in basis points:
```
if (currentTotalAssets > lastTotalAssets):
    gains = currentTotalAssets - lastTotalAssets
    performanceFeeAssets = gains × performanceFee / BPS
```

Fees are minted as shares to the fee recipient, diluting existing shareholders proportionally.

### Admin Functions

```solidity
// Owner-only: Add/remove positions to the whitelist
function addBorrowModule(address module) external;
function removeBorrowModule(address module) external;

// Owner-only: Set the LLTV for available collateral calculations
function setLltv(uint256 lltv) external;

// Owner-only: Set fee configuration (accrues pending fees first)
function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external;

// Owner-only: Set max allowed loss during rebalance (in basis points)
function setMaxRebalanceLoss(uint16 maxRebalanceLoss) external;

// Curator role: Set the supply queue for deposits
function setSupplyQueue(SupplyQueueEntry[] calldata queue) external;

// Curator role: Set the withdrawal queue for withdrawals and burns
function setWithdrawalQueue(address[] calldata queue) external;

// Rebalancer role: Rebalance positions without minting/burning shares
function rebalance(RebalancingData calldata data) external returns (uint256 collateralExcess, uint256 debtExcess);
```

### Rebalancing

The `rebalance` function allows accounts with the `PM_ROLE_REBALANCER` role to redistribute collateral and debt across positions without affecting shares:

```solidity
struct RebalancingData {
    uint256 collateral;  // Collateral to pull from caller
    uint256 debt;        // Debt to pull from caller
    RebalancingOperation[] operations;
}

struct RebalancingOperation {
    address position;
    RebalancingOperationType operationType;  // REPAY, WITHDRAW, BORROW, SUPPLY
    uint256 amount;
}
```

**Example - Move liquidity from Position A to Position B:**
```solidity
RebalancingData({
    collateral: 0,
    debt: 1000,  // Need USDC to repay on A
    operations: [
        (positionA, REPAY, 1000),     // Repay 1000 USDC on A
        (positionA, WITHDRAW, 2000),  // Withdraw 2000 collateral from A
        (positionB, SUPPLY, 2000),    // Supply 2000 collateral to B
        (positionB, BORROW, 1000)     // Borrow 1000 USDC from B
    ]
})
// Returns excess collateral and debt to caller
```

### Security Considerations

1. **Inflation Attack Protection**: Virtual share offset prevents first-depositor attacks
2. **Conservative Rounding**: Debt rounds up, collateral rounds down to protect the vault
3. **LLTV Enforcement**: Withdrawals check available collateral to maintain position health
4. **Fee Accrual**: Fees are always accrued before operations to ensure fair accounting
5. **Access Control**: Operations restricted to MINTER role, admin functions to owner
6. **Reentrancy Protection**: Uses `ReentrancyGuardTransient` on main operations
7. **Whitelisted Positions**: Only positions in `borrowModules` set can be used in queues
8. **Max Rebalance Loss**: Rebalancing reverts if total assets decrease beyond threshold

### PositionManagerFactory

Deploys Position Manager instances using the **beacon proxy pattern**:

```
┌────────────────────────┐
│ PositionManagerFactory │
│                        │
│ BEACON ────────────────┼──> UpgradeableBeacon ──> PositionManager Implementation
└────────────────────────┘
           │
           │ createPositionManager()
           ▼
    ┌────────────────┐
    │ PM Proxy       │
    │ (ERC1967)      │──> delegates to beacon
    └────────────────┘
```

```solidity
// Deploy factory
PositionManagerFactory factory = new PositionManagerFactory(beaconOwner);

// Create a new Position Manager
address pm = factory.createPositionManager(
    owner,           // Owner address
    collateralAsset, // e.g., WETH
    debtAsset,       // e.g., USDC
    "PM Shares",     // Share token name
    "PMS"            // Share token symbol
);
```

### Transfer Guard

The Position Manager supports an optional `TransferGuard` for compliance controls on share transfers. When set, all transfers (including mints and burns) are validated through the guard.

**Setting the Guard:**
```solidity
// Owner sets the transfer guard (address(0) disables)
positionManager.setTransferGuard(address(guard));

// Query current guard
(,, address transferGuard) = positionManager.config();
```

**Pause Integration:**
The guard's pause status is also checked before rebalancing operations. When paused:
- All share transfers are blocked
- Deposits/withdrawals are blocked (they mint/burn shares)
- Rebalancing operations revert with `Paused()`

See the [Transfer Guard](#transfer-guard-1) section for full documentation.

### MorphoRebalancer

A standalone rebalancer contract that uses Morpho flash loans to execute rebalancing operations without requiring upfront capital:

```
┌─────────────────────────────────────────────────────────────────┐
│                    MORPHO REBALANCER FLOW                         │
└─────────────────────────────────────────────────────────────────┘

1. Owner calls rebalance(positionManager, data)
           │
           ▼
2. Initiate flash loan from Morpho for data.debt amount
           │
           ▼
3. Morpho calls onMorphoFlashLoan() callback
           │
           ▼
4. Callback executes positionManager.rebalance(data)
           │
           ▼
5. Callback approves Morpho to pull back flash loaned amount
```

The rebalancer requires:
- `PM_ROLE_REBALANCER` role on the Position Manager
- Owner permission to initiate rebalances
- Sufficient liquidity in Morpho for the flash loan

## Funds Module (USCC)

The funds module wraps external assets behind a standardized order lifecycle (`IFund`) with create/commit/unlock/recover operations.

### USCCFund

USCCFund integrates Superstate's USCC using a single-order state machine:
- **Deposit flow**: depositor creates a DEPOSIT order, commits USDC to the Superstate recipient, then unlocks wUSCC after USCC is minted to the fund.
- **Redeem flow**: depositor creates a REDEEM order, commits by burning wUSCC and calling `offchainRedeem`, then unlocks USDC when it arrives.
- The fund holds USCC; users receive wUSCC. Redemptions return USDC.
- Total assets use a Chainlink USCC oracle.
- Owner/operator roles can set the oracle, mark recovering, or resolve stuck orders.

### WrappedAsset (wUSCC)

`WrappedAsset` is an ERC20 wrapper minted/burned by authorized issuers. Multiple USCCFund instances can share the same wUSCC token; each new fund must be granted `ISSUER_ROLE`.

## Transfer Guard

The `TransferGuard` contract provides compliance controls for token transfers, supporting blocklists, whitelists, large transfer thresholds, and pause functionality.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRANSFER GUARD ARCHITECTURE                    │
└─────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────┐
  │  TransferGuardFactory    │
  │                          │
  │  BEACON ─────────────────┼──> UpgradeableBeacon ──> TransferGuard Implementation
  └──────────────────────────┘
             │
             │ createTransferGuard()
             ▼
      ┌────────────────┐
      │ Guard Proxy    │
      │ (ERC1967)      │──> delegates to beacon
      └────────────────┘
             │
             │ canTransfer()
             ▼
  ┌──────────────────────────┐
  │    PositionManager       │
  │                          │
  │  _beforeTokenTransfer()  │──> Validates via guard
  │  rebalance()             │──> Checks pause status
  └──────────────────────────┘
```

### Address Status

Each address can have one of four statuses per guard:

| Status | Value | Behavior |
|--------|-------|----------|
| `NONE` | 0 | Default - subject to threshold checks and validator |
| `WHITELIST` | 1 | Allowed for transfers below threshold |
| `BLOCKLIST` | 2 | Always blocked from transfers |
| `WHITELIST_ALL_AMOUNTS` | 3 | Allowed for any transfer amount |

### Token Configuration

Each token registered with the guard has:
- **paused**: Whether all transfers are blocked
- **threshold**: Minimum amount considered a "large transfer" (scaled by 1e6)
- **validator**: Optional external contract for NONE-status addresses

```solidity
// Set token configuration
guard.setTokenConfig(
    tokenAddress,
    false,           // paused
    1_000_000e18,    // threshold (1M tokens)
    address(0)       // validator (none)
);

// Pause/unpause a token
guard.pause(tokenAddress);
guard.unpause(tokenAddress);
```

**Threshold Scaling:**
Thresholds are stored scaled down by `THRESHOLD_SCALE` (1e6) for storage efficiency:
- Minimum granularity: 1e6 (values below this round to 0, disabling the threshold)
- Maximum threshold: ~3.09e32

### Transfer Validation Logic

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRANSFER VALIDATION FLOW                       │
└─────────────────────────────────────────────────────────────────┘

canTransfer(token, from, to, amount)
           │
           ▼
    ┌──────────────┐
    │ Token Paused?│──Yes──> BLOCK
    └──────┬───────┘
           │ No
           ▼
    ┌──────────────┐
    │ Is Mint?     │──Yes──> Check only 'to' address
    │ (from == 0)  │
    └──────┬───────┘
           │ No
           ▼
    ┌──────────────┐
    │ Is Burn?     │──Yes──> Check only 'from' address
    │ (to == 0)    │
    └──────┬───────┘
           │ No (Regular Transfer)
           ▼
    Check both 'from' AND 'to' addresses
           │
           ▼
    ┌──────────────────────────────────┐
    │ For each address:                │
    │                                  │
    │ BLOCKLIST ──────────────> BLOCK  │
    │ WHITELIST_ALL_AMOUNTS ──> ALLOW  │
    │ WHITELIST + small ──────> ALLOW  │
    │ WHITELIST + large ──────> BLOCK  │
    │ NONE + no validator ────> ALLOW  │
    │ NONE + validator ───────> ASK    │
    └──────────────────────────────────┘
```

### Role-Based Access Control

| Role | Bit Flag | Permission |
|------|----------|------------|
| `PAUSER_ROLE` | `1 << 1` | Pause/unpause tokens |
| `COMPLIANCE_ROLE` | `1 << 0` | Set address statuses |

The **owner** has exclusive control over:
- Setting token configuration (threshold, validator)
- Granting/revoking roles

### External Validator

For addresses with `NONE` status, an optional validator contract can be configured:

```solidity
interface ITransferGuardValidator {
    function isAuthorized(address account) external view returns (bool);
}

// Set validator for a token
guard.setTokenConfig(token, false, threshold, validatorAddress);
```

If no validator is set (`address(0)`), NONE-status addresses are allowed by default.

### Usage Example

```solidity
// Deploy guard via factory
TransferGuardFactory factory = new TransferGuardFactory(beaconOwner);
address guard = factory.createTransferGuard(guardOwner);

// Configure the guard
TransferGuard(guard).setTokenConfig(
    address(positionManager),
    false,        // not paused
    100_000e18,   // 100k threshold
    address(0)    // no validator
);

// Set address statuses
TransferGuard(guard).setAddressStatus(blockedUser, AddressStatus.BLOCKLIST);
TransferGuard(guard).setAddressStatus(whitelistedUser, AddressStatus.WHITELIST_ALL_AMOUNTS);

// Batch updates
address[] memory accounts = new address[](2);
accounts[0] = user1;
accounts[1] = user2;
AddressStatus[] memory statuses = new AddressStatus[](2);
statuses[0] = AddressStatus.WHITELIST;
statuses[1] = AddressStatus.WHITELIST;
TransferGuard(guard).setAddressStatusBatch(accounts, statuses);

// Connect to Position Manager
positionManager.setTransferGuard(guard);
```

### TransferGuardFactory

Deploys TransferGuard instances using the **beacon proxy pattern**:

```solidity
// Deploy factory
TransferGuardFactory factory = new TransferGuardFactory(beaconOwner);

// Create a new guard
address guard = factory.createTransferGuard(owner);

// Upgrade all guards (beacon owner only)
UpgradeableBeacon(factory.BEACON()).upgradeTo(newImplementation);
```

### Security Considerations

1. **Centralization Risk**: Guard owner can blocklist any address. Use multisig/timelock for production.
2. **Reentrancy Protection**: Position Manager's `rebalance` function uses `nonReentrant` to prevent guard state manipulation via callbacks.
3. **Validator Trust**: External validators are called during transfers. Only use trusted validator contracts.
4. **Threshold Granularity**: Thresholds below 1e6 round to 0, effectively disabling large transfer restrictions.
