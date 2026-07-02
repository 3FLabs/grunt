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
/// @param tickThreshold The grace before promoting to the next tick, strictly below tickDuration
/// @param maxYieldBps The owner ceiling on per-operation yield caps, at most 5000
/// @param principalBufferBps The headroom over the computed principal cap, at most 2000
/// @param estimates The yield estimates for the bound asset pair
struct RetargetterConfig {
  uint32 horizon;
  uint24 tickDuration;
  uint24 tickThreshold;
  uint16 maxYieldBps;
  uint16 principalBufferBps;
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

  /// @notice Emitted when a fund is whitelisted.
  /// @param fund The whitelisted fund
  event FundAdded(address indexed fund);

  /// @notice Emitted when a fund is removed from the whitelist.
  /// @param fund The removed fund
  event FundRemoved(address indexed fund);

  /// @notice Emitted when a flash-loan module is whitelisted.
  /// @param module The whitelisted module
  event FlashLoanModuleAdded(address indexed module);

  /// @notice Emitted when a flash-loan module is removed from the whitelist.
  /// @param module The removed module
  event FlashLoanModuleRemoved(address indexed module);

  /// @notice Emitted when the yield estimates are updated.
  /// @param estimates The new estimates
  event EstimatesSet(YieldEstimates estimates);

  /// @notice Emitted when the configuration is updated.
  /// @param config The new configuration
  event ConfigSet(RetargetterConfig config);

  /// @notice Emitted when the owner sweeps a token out of the Retargetter.
  /// @param token The swept token
  /// @param to The recipient
  /// @param amount The swept amount
  event Rescued(address indexed token, address indexed to, uint256 amount);

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
  /// @dev The first consume starts the loan clock.
  /// @param offer The signed offer
  /// @param signature The maker's EIP-712 signature
  /// @param ptAmount The principal amount to consume
  /// @return ytAmount The yield amount minted to the maker
  function consume(Offer calldata offer, bytes calldata signature, uint256 ptAmount) external returns (uint256 ytAmount);

  /// @notice Pulls consumed funds from the operation's Request to the Retargetter.
  /// @param amount The amount to pull
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
  ///      corresponding asset.
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
  ///         pending and the Retargetter holds none of the bound assets.
  function resolve() external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         SYNC FLOW                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Runs a whole retargetting operation atomically inside a flash loan.
  /// @dev The steps are supplied as a multicall payload executed inside the flash-loan
  ///      callback. At window close no order may be stored and the Retargetter's balances
  ///      of both bound assets must be exactly zero.
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

  /// @notice Whitelists a fund after checking its tokens match the bound pair.
  /// @param fund The fund to whitelist
  function addFund(address fund) external;

  /// @notice Removes a fund from the whitelist; reverts while it is bound to the
  ///         active operation.
  /// @param fund The fund to remove
  function removeFund(address fund) external;

  /// @notice Whitelists a flash-loan module.
  /// @param module The module to whitelist
  function addFlashLoanModule(address module) external;

  /// @notice Removes a flash-loan module from the whitelist.
  /// @param module The module to remove
  function removeFlashLoanModule(address module) external;

  /// @notice Sweeps the Retargetter's full balance of a token to a recipient.
  /// @dev Owner escape hatch for donation griefing of the zero-residual gate and for
  ///      stuck third-party tokens.
  /// @param token The token to sweep
  /// @param to The recipient
  /// @return amount The swept amount
  function rescue(address token, address to) external returns (uint256 amount);

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
  /// @return startedAt The loan clock origin (zero until the first consume)
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
