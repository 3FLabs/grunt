// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Offer} from "../../request/IOfferReceiver.sol";
import {RebalancingData} from "../base/IPositionManagerRebalancing.sol";
import {Order} from "../../../libs/funds/Order.sol";

/// @notice Owner-set yield and duration estimates feeding the principal-cap formulas.
/// @param requestYieldRate The expected bridge-loan yield rate (WAD per 365 days)
/// @param borrowRate The expected venue borrow rate on existing debt (WAD per 365 days)
/// @param collateralYieldRate The expected collateral yield rate (WAD per 365 days)
/// @param subscriptionDuration The expected DEPOSIT settlement duration in seconds
/// @param redemptionDuration The expected REDEEM settlement duration in seconds
struct YieldEstimates {
  uint64 requestYieldRate;
  uint64 borrowRate;
  uint64 collateralYieldRate;
  uint32 subscriptionDuration;
  uint32 redemptionDuration;
}

/// @notice Owner-set global configuration of a Retargetter instance.
/// @param horizon The yield annualization basis in seconds, in [90 days, 366 days]
/// @param tickDuration The repayment granularity in seconds, in [1, 30 days]
/// @param tickThreshold The grace before promoting to the next tick, strictly below
///        tickDuration; doubles as the consumption window length (capital entry closes this
///        long after the loan clock origin)
/// @param maxYieldBps The owner ceiling on per-operation yield caps, at most 5000
/// @param principalBufferBps The headroom over the computed principal cap, at most 2000
/// @param collateralResidualExponent The settlement tolerance for the collateral asset:
///        balances strictly below 2^exponent pass the residual gate, so dust donations
///        cannot grief settlement (zero keeps the gate exact)
/// @param debtResidualExponent The settlement tolerance for the debt asset, same convention
/// @param estimates The yield estimates for the bound asset pair
struct RetargetterConfig {
  uint32 horizon;
  uint24 tickDuration;
  uint24 tickThreshold;
  uint16 maxYieldBps;
  uint16 principalBufferBps;
  uint8 collateralResidualExponent;
  uint8 debtResidualExponent;
  YieldEstimates estimates;
}

/// @title IRetargetter
/// @author 3F Protocol
/// @notice Interface for the Retargetter, a small orchestrator that brings PositionManagers
///         back to their target LTV by composing Requests (bridge loans), funds
///         (subscription/redemption) and PositionManager rebalancing.
interface IRetargetter {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when an asynchronous retargetting operation starts.
  /// @param positionManager The position manager the operation targets
  /// @param request The freshly deployed Request funding the operation
  /// @param fund The whitelisted fund bound to the operation
  /// @param principal The caller-announced principal (fail-fast checked against the cap)
  /// @param maxYieldBps The effective per-operation yield cap
  event RetargettingStarted(
    address indexed positionManager,
    address indexed request,
    address indexed fund,
    uint256 principal,
    uint16 maxYieldBps
  );

  /// @notice Emitted when a signed offer is consumed against the operation's Request.
  /// @param request The operation's Request
  /// @param maker The offer maker (the lender)
  /// @param ptAmount The principal amount consumed
  /// @param ytAmount The yield amount minted to the maker
  event OfferConsumed(address indexed request, address indexed maker, uint256 ptAmount, uint256 ytAmount);

  /// @notice Emitted when a mint authorization is set or revoked on the operation's Request.
  /// @param request The operation's Request
  /// @param to The account whose authorization was set
  /// @param ptAmount The authorized principal amount (zero when revoking)
  /// @param ytAmount The authorized yield amount (zero when revoking)
  event MintingAuthorized(address indexed request, address indexed to, uint128 ptAmount, uint128 ytAmount);

  /// @notice Emitted when funds are pulled from the operation's Request.
  /// @param request The operation's Request
  /// @param amount The amount pulled to the Retargetter
  event RequestFundsPulled(address indexed request, uint256 amount);

  /// @notice Emitted when a fund order is created.
  /// @param fund The resolved fund
  /// @param order The full order
  event OrderCreated(address indexed fund, Order order);

  /// @notice Emitted when the stored fund order is committed.
  /// @param fund The resolved fund
  /// @param order The full order
  event OrderCommitted(address indexed fund, Order order);

  /// @notice Emitted when the stored fund order is unlocked (possibly partially).
  /// @param fund The resolved fund
  /// @param order The full order
  event OrderUnlocked(address indexed fund, Order order);

  /// @notice Emitted when the stored fund order is canceled.
  /// @param fund The resolved fund
  /// @param order The full order
  event OrderCanceled(address indexed fund, Order order);

  /// @notice Emitted when the stored fund order is recovered (possibly partially).
  /// @param fund The resolved fund
  /// @param order The full order
  event OrderRecovered(address indexed fund, Order order);

  /// @notice Emitted after a rebalance driven through the Retargetter.
  /// @param positionManager The rebalanced position manager
  /// @param collateralIn The collateral amount supplied to the position manager
  /// @param debtIn The debt amount supplied to the position manager
  event Rebalanced(address indexed positionManager, uint256 collateralIn, uint256 debtIn);

  /// @notice Emitted when the operation's Request is trustlessly repaid.
  /// @param request The operation's Request
  /// @param owed The formula-computed amount owed
  /// @param shortfall The amount transferred by the Retargetter to cover the balance gap
  event RequestRepaid(address indexed request, uint256 owed, uint256 shortfall);

  /// @notice Emitted when the owner force-repays the operation's Request.
  /// @param request The operation's Request
  /// @param amount The amount transferred to the Request
  /// @param minBalance The owner-chosen lower balance bound passed to setRepaid
  /// @param maxBalance The owner-chosen upper balance bound passed to setRepaid
  event RequestForceRepaid(address indexed request, uint256 amount, uint256 minBalance, uint256 maxBalance);

  /// @notice Emitted when an asynchronous operation settles and its state is cleared.
  /// @param positionManager The operation's position manager
  /// @param request The operation's Request
  event RetargettingResolved(address indexed positionManager, address indexed request);

  /// @notice Emitted when a synchronous (flash-loan) retargetting operation completes.
  /// @param positionManager The operation's position manager
  /// @param module The flash-loan module that lent the funds
  /// @param flashLoanAmount The flash-loan size
  event SyncRetargettingExecuted(address indexed positionManager, address indexed module, uint256 flashLoanAmount);

  /// @notice Emitted when a fund's whitelist entry is set.
  /// @param fund The fund
  /// @param whitelisted Whether the fund is now whitelisted
  event FundSet(address indexed fund, bool whitelisted);

  /// @notice Emitted when a flash-loan module's whitelist entry is set.
  /// @param module The module
  /// @param whitelisted Whether the module is now whitelisted
  event FlashLoanModuleSet(address indexed module, bool whitelisted);

  /// @notice Emitted when the yield estimates are updated.
  /// @param estimates The new estimates
  event EstimatesSet(YieldEstimates estimates);

  /// @notice Emitted when the configuration is updated.
  /// @param config The new configuration
  event ConfigSet(RetargetterConfig config);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ASYNC FLOW                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Starts an asynchronous retargetting operation by deploying a fresh Request.
  /// @param positionManager The position manager to retarget (must match the bound pair)
  /// @param principal The intended principal, fail-fast checked against the cap
  /// @param maxYieldBps_ The caller's yield cap; the effective cap is min(config, caller)
  /// @param fund The whitelisted fund to bind to the operation
  /// @param requestName The base name for the Request's PT/YT tokens
  /// @param requestSymbol The base symbol for the Request's PT/YT tokens
  /// @return request The deployed Request
  function startRetargetting(
    address positionManager,
    uint256 principal,
    uint16 maxYieldBps_,
    address fund,
    string calldata requestName,
    string calldata requestSymbol
  ) external returns (address request);

  /// @notice Consumes a signed lender offer against the operation's Request.
  /// @dev The first consume (or nonzero mint authorization) starts the loan clock. From then
  ///      on capital only enters while the consumption window is open (the tick threshold past
  ///      the origin, and never once funds were pulled), for everyone including the owner:
  ///      repayment prices every yield token from the origin, so capital arriving later would
  ///      be overpaid for time it never covered and, on a default, would dilute the earlier
  ///      lenders' recovery.
  /// @param offer The signed offer
  /// @param signature The maker's EIP-712 signature
  /// @param ptAmount The principal amount to consume
  /// @return ytAmount The yield amount minted to the maker
  function consume(Offer calldata offer, bytes calldata signature, uint256 ptAmount) external returns (uint256 ytAmount);

  /// @notice Sets (or revokes) a mint authorization on the operation's Request.
  /// @dev A nonzero authorization is a principal commitment: it passes the same flat
  ///      yield-ratio gate as consume, counts toward the live principal cap until the account
  ///      mints or the authorization is revoked, starts the loan clock, and must land inside
  ///      the consumption window (open through the tick threshold and shut by the first pull
  ///      of funds, which also revokes every authorization still pending). Setting both
  ///      amounts to zero revokes the account's authorization and stays possible at any time,
  ///      window open or closed: an unminted authorization can still be minted on the Request
  ///      directly, so the operator revokes leftovers once the funding round is over. A mint
  ///      front-running that revocation or the settlement itself is bounded by the yield gate
  ///      and the prorated accrual, and requires the consumer to have authorized the account
  ///      in the first place.
  /// @param to The account allowed to call the Request's mint
  /// @param ptAmount The principal tokens to authorize; the account transfers this much asset
  ///        when it mints
  /// @param ytAmount The yield tokens to authorize
  function authorizeMinting(address to, uint128 ptAmount, uint128 ytAmount) external;

  /// @notice Pulls consumed funds from the operation's Request to the Retargetter.
  /// @dev Pulling ends the funding round: every pending mint authorization is revoked and
  ///      capital entry (consume or new authorizations) stays closed for the rest of the
  ///      operation, so funds being deployed can no longer be diluted by late lenders.
  /// @param amount The amount to pull; the full-balance sentinel `type(uint256).max` resolves
  ///        to the Request's whole balance
  function pullRequestFunds(uint256 amount) external;

  /// @notice Creates a fund order owned by and payable to the Retargetter.
  /// @param order_ The order to create (owner and receiver must be the Retargetter)
  function create(Order calldata order_) external;

  /// @notice Commits the stored fund order, approving exactly its input amount.
  function commit() external;

  /// @notice Unlocks the stored fund order's output; clears the order once ENDED.
  /// @return amountOut The settled output amount (authoritative)
  function unlock() external returns (uint256 amountOut);

  /// @notice Cancels the stored fund order and clears it.
  function cancelOrder() external;

  /// @notice Recovers the stored fund order's input; clears the order once ENDED.
  /// @return amountIn The recovered input amount (authoritative)
  function recoverOrder() external returns (uint256 amountIn);

  /// @notice Rebalances the resolved position manager under the direction guardrails.
  /// @dev Input legs (collateral, debt, SUPPLY, REPAY) support the full-balance sentinel
  ///      `type(uint256).max`, resolved to the Retargetter's current balance of the
  ///      corresponding asset; a REPAY leg is further capped at its module's live debt, so
  ///      folding a balance larger than the module owes repays the whole debt instead of
  ///      reverting in the venue. The module reports that debt rounded down, so the cap can
  ///      sit one or more wei below the true debt and a capped repayment can leave that
  ///      remainder on the module rather than clearing it exactly. Sentinels resolve against
  ///      one balance snapshot taken before any leg executes and do not compose: every leg
  ///      resolves against the same pre-call balances, never the state left by earlier legs,
  ///      so REPAY sentinels across several modules can together commit more than the shared
  ///      balance and revert.
  /// @param data The rebalancing data forwarded to the position manager
  function rebalance(RebalancingData calldata data) external;

  /// @notice Trustlessly repays the operation's Request with the formula-computed amount.
  /// @return owedAmount The amount owed and settled
  function repay() external returns (uint256 owedAmount);

  /// @notice Owner override to settle the Request outside the trustless formula.
  /// @param amount The amount to transfer to the Request before marking it repaid
  /// @param minBalance The lower balance bound passed to setRepaid
  /// @param maxBalance The upper balance bound passed to setRepaid
  function forceRepay(uint256 amount, uint256 minBalance, uint256 maxBalance) external;

  /// @notice Settles the asynchronous operation once the Request is repaid, no order is
  ///         pending and the Retargetter's balances of both bound assets are within the
  ///         configured residual tolerance.
  function resolve() external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         SYNC FLOW                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Runs a whole retargetting operation atomically inside a flash loan.
  /// @dev The steps are supplied as a multicall payload executed inside the flash-loan
  ///      callback. At window close no order may be stored and the Retargetter's balances
  ///      of both bound assets must be within the configured residual tolerance.
  /// @param positionManager The position manager to retarget (must match the bound pair)
  /// @param flashLoanModule The whitelisted flash-loan module to borrow through
  /// @param flashLoanAmount The flash-loan size, checked against the principal cap
  /// @param fund The whitelisted fund the payload may create orders against
  /// @param data The step calls executed inside the flash-loan window
  function startSyncRetargetting(
    address positionManager,
    address flashLoanModule,
    uint256 flashLoanAmount,
    address fund,
    bytes[] calldata data
  ) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CONFIGURATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the full configuration (scalars and estimates).
  /// @param config_ The new configuration, validated against the documented bounds
  function setConfig(RetargetterConfig calldata config_) external;

  /// @notice Sets only the yield estimates.
  /// @param estimates_ The new estimates
  function setEstimates(YieldEstimates calldata estimates_) external;

  /// @notice Sets a fund's whitelist entry.
  /// @dev Whitelisting checks the fund is a contract and its tokens match the bound pair;
  ///      removal skips those checks but reverts while the fund is bound to the active
  ///      operation.
  /// @param fund The fund
  /// @param whitelisted Whether the fund should be whitelisted
  function setFund(address fund, bool whitelisted) external;

  /// @notice Sets a flash-loan module's whitelist entry.
  /// @dev Whitelisting checks the module is a contract; removal skips the check and works
  ///      any time.
  /// @param module The module
  /// @param whitelisted Whether the module should be whitelisted
  function setFlashLoanModule(address module, bool whitelisted) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the bound asset pair, set once at initialization.
  /// @return collateralAsset The collateral asset of the pair
  /// @return debtAsset The debt asset of the pair
  function assets() external view returns (address collateralAsset, address debtAsset);

  /// @notice Returns the in-flight operation.
  /// @dev A SYNC flash-loan window registers here for the duration of its transaction, with
  ///      only the position manager and the fund populated.
  /// @return positionManager The operation's position manager (zero when inactive)
  /// @return request The operation's Request (zero inside a SYNC window)
  /// @return fund The operation's fund
  /// @return startedAt The loan clock origin (zero until the first consume or nonzero mint
  ///         authorization)
  /// @return operationMaxYieldBps The effective per-operation yield cap
  /// @return order The stored fund order rebuilt in memory
  /// @return orderLive Whether a fund order is stored
  function operation()
    external
    view
    returns (
      address positionManager,
      address request,
      address fund,
      uint40 startedAt,
      uint16 operationMaxYieldBps,
      Order memory order,
      bool orderLive
    );

  /// @notice Returns whether an operation is active (an ASYNC operation, or a SYNC
  ///         flash-loan window for the duration of its transaction).
  function isActive() external view returns (bool);

  /// @notice Computes the current principal cap for a position manager.
  /// @dev Quoter formula on live state with the owner estimates, auto-detected direction,
  ///      times one plus the principal buffer.
  /// @param positionManager The position manager to size against
  /// @return The principal cap in debt-asset units
  function maxPrincipal(address positionManager) external view returns (uint256);

  /// @notice Returns the current amount owed on the active operation's Request.
  function owed() external view returns (uint256);

  /// @notice Returns the accounts holding a registered mint authorization for the operation.
  /// @dev Revocation and the first pull of funds remove accounts eagerly; an account whose
  ///      authorization was minted lingers until the next consume or nonzero authorization
  ///      prunes it lazily. The outstanding authorized principal is the sum of the Request's
  ///      mintAuthorization over these accounts.
  /// @return accounts The registered accounts
  function authorizedAccounts() external view returns (address[] memory accounts);

  /// @notice Returns the current configuration.
  function config() external view returns (RetargetterConfig memory);

  /// @notice Returns whether a fund is whitelisted.
  /// @param fund The fund to check
  function isFund(address fund) external view returns (bool);

  /// @notice Returns whether a flash-loan module is whitelisted.
  /// @param module The module to check
  function isFlashLoanModule(address module) external view returns (bool);

  /// @notice Returns the quoter holding the sizing math.
  function quoter() external view returns (address);

  /// @notice Returns the factory used to deploy operation Requests.
  function requestFactory() external view returns (address);
}
