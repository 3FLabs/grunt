// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IRetargetter, RetargetterConfig, YieldEstimates} from "../../interfaces/manager/rebalancer/IRetargetter.sol";
import {IRetargetterQuoter} from "../../interfaces/manager/rebalancer/IRetargetterQuoter.sol";
import {IFlashLoanModule, IFlashLoanReceiver} from "../../interfaces/manager/rebalancer/IFlashLoanModule.sol";
import {IRequestFactory} from "../../interfaces/request/IRequestFactory.sol";
import {IRequest} from "../../interfaces/request/IRequest.sol";
import {IRequestInteractions} from "../../interfaces/request/IRequestInteractions.sol";
import {ITokenController} from "../../interfaces/request/ITokenController.sol";
import {Offer} from "../../interfaces/request/IOfferReceiver.sol";
import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {RebalancingData, RebalancingOperationType} from "../../interfaces/manager/base/IPositionManagerRebalancing.sol";
import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {Order, Mode, State} from "../../libs/funds/Order.sol";
import {LibRetargetterErrors} from "../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {
  REBALANCER_ROLE,
  CONSUMER_ROLE,
  MIN_HORIZON,
  MAX_HORIZON,
  MAX_TICK_DURATION,
  MAX_YIELD_CAP_BPS,
  MAX_PRINCIPAL_BUFFER_BPS,
  REPAYMENT_DEADLINE_OFFSET,
  FULL_BALANCE_SENTINEL,
  ASSETS_STORAGE_SLOT,
  CONFIG_STORAGE_SLOT,
  WHITELISTS_STORAGE_SLOT,
  OPERATION_STORAGE_SLOT,
  WINDOW_TSLOT,
  MODULE_TSLOT,
  POSITION_MANAGER_TSLOT,
  FUND_TSLOT,
  AMOUNT_TSLOT
} from "../../libs/manager/rebalancer/LibRetargetterConstants.sol";
import {BPS} from "../../libs/Constants.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Multicallable} from "lib/solady/src/utils/Multicallable.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibCall} from "lib/solady/src/utils/LibCall.sol";

/// @title Retargetter
/// @author 3F Protocol
/// @notice Orchestrator that brings PositionManagers back to their target LTV by composing
///         Requests (bridge loans), funds (subscription/redemption) and PositionManager
///         rebalancing. Bound to one (collateralAsset, debtAsset) pair at initialization and
///         runs one operation at a time against any PositionManager on that pair.
/// @dev Two entry points:
///      - ASYNC (`startRetargetting`): deploys a fresh Request through the audited
///        RequestFactory; the operation spans the fund's settlement window and ends with a
///        trustless, tick-priced repayment at `resolve`.
///      - SYNC (`startSyncRetargetting`): the whole operation runs atomically inside a flash
///        loan taken through an owner-whitelisted {IFlashLoanModule}; the steps are supplied
///        as a multicall payload executed inside the callback and no state persists.
///
///      Trust model: fully trusted owner, semi-trusted rebalancer boxed in by the guardrails
///      (direction checks, principal and yield caps, whitelists, zero-residual settlement),
///      untrusted everyone else. The Retargetter holds no value at rest: `resolve` and the end
///      of the flash-loan window both require its balances of the two bound assets to be zero.
///
///      Derive, do not store: everything readable from the composed contracts (direction,
///      consumed principal, order liveness progress, repaid status) is recomputed fresh at
///      every use; only the operation addresses, the loan clock origin, the per-operation
///      yield cap and the non-derivable order fields persist.
contract Retargetter is
  IRetargetter,
  IFlashLoanReceiver,
  OwnableRoles,
  Initializable,
  Multicallable,
  ReentrancyGuardTransient
{
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using LibCall for address;
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The stateless quoter holding the sizing and repayment math.
  address public immutable QUOTER;

  /// @notice The factory deploying the operation Requests.
  address public immutable REQUEST_FACTORY;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      ERC-7201 STORAGE                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The bound asset pair (namespace "retargetter.assets").
  /// @dev Written once at initialize, never mutated afterwards.
  /// @param collateralAsset The collateral asset every position manager and fund must match
  /// @param debtAsset The debt asset every position manager, fund and Request must match
  struct RetargetterAssets {
    address collateralAsset;
    address debtAsset;
  }

  /// @notice The whitelists (namespace "retargetter.whitelists").
  /// @dev Plain mappings without enumeration; indexers use the add/remove events.
  /// @param funds The owner-approved venues
  /// @param flashLoanModules The owner-approved flash-loan adapters
  struct RetargetterWhitelists {
    mapping(address fund => bool) funds;
    mapping(address module => bool) flashLoanModules;
  }

  /// @notice The one in-flight asynchronous operation (namespace "retargetter.operation").
  /// @dev `positionManager != address(0)` is the operation-active flag; the struct is zeroed
  ///      at resolve. The stored order is partial: `owner` and `receiver` are always the
  ///      Retargetter (enforced at create) so the wrappers rebuild the full Order in memory.
  /// @param positionManager The operation's position manager
  /// @param startedAt The loan clock origin, set at the first consume (0 until then)
  /// @param operationMaxYieldBps The effective yield cap, fixed at start
  /// @param request The Request deployed for the operation
  /// @param fund The operation's venue, owner-whitelisted at start
  /// @param orderMode The stored order's mode
  /// @param orderLive Whether an order is stored
  /// @param orderInput The stored order's input amount
  /// @param orderOutput The stored order's output amount
  /// @param orderSalt The stored order's salt
  struct RetargetterOperation {
    address positionManager;
    uint40 startedAt;
    uint16 operationMaxYieldBps;
    address request;
    address fund;
    Mode orderMode;
    bool orderLive;
    uint256 orderInput;
    uint256 orderOutput;
    bytes32 orderSalt;
  }

  /// @dev Returns the ERC-7201 storage pointer for the bound asset pair.
  function _assetsStorage() internal pure returns (RetargetterAssets storage $) {
    bytes32 slot = ASSETS_STORAGE_SLOT;
    assembly ("memory-safe") {
      $.slot := slot
    }
  }

  /// @dev Returns the ERC-7201 storage pointer for the configuration.
  function _configStorage() internal pure returns (RetargetterConfig storage $) {
    bytes32 slot = CONFIG_STORAGE_SLOT;
    assembly ("memory-safe") {
      $.slot := slot
    }
  }

  /// @dev Returns the ERC-7201 storage pointer for the whitelists.
  function _whitelistsStorage() internal pure returns (RetargetterWhitelists storage $) {
    bytes32 slot = WHITELISTS_STORAGE_SLOT;
    assembly ("memory-safe") {
      $.slot := slot
    }
  }

  /// @dev Returns the ERC-7201 storage pointer for the in-flight operation.
  function _operationStorage() internal pure returns (RetargetterOperation storage $) {
    bytes32 slot = OPERATION_STORAGE_SLOT;
    assembly ("memory-safe") {
      $.slot := slot
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         MODIFIERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Passes when a flash-loan window is open (the window is what lets the flash-loan
  ///      callback drive the steps, since `msg.sender` there is the module), when the caller
  ///      is the owner, or when the caller holds the rebalancer role.
  modifier onlyOwnerOrRebalancer() {
    if (!_isWindowOpen() && msg.sender != owner() && !hasAnyRole(msg.sender, REBALANCER_ROLE)) {
      revert Unauthorized();
    }
    _;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the Retargetter implementation contract.
  /// @param quoter_ The stateless quoter (immutable across all proxies)
  /// @param requestFactory_ The Request factory (immutable across all proxies)
  constructor(address quoter_, address requestFactory_) {
    quoter_.checkContract();
    requestFactory_.checkContract();
    QUOTER = quoter_;
    REQUEST_FACTORY = requestFactory_;
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the proxy instance and binds it to its asset pair.
  /// @dev The pair is never mutable afterwards. Whitelists start empty; zero estimates are
  ///      valid and degrade the principal cap to the zero-rate ideal formula.
  /// @param owner_ The address that will own the instance
  /// @param collateralAsset_ The collateral asset of the bound pair
  /// @param debtAsset_ The debt asset of the bound pair
  /// @param config_ The initial configuration, validated against the documented bounds
  function initialize(address owner_, address collateralAsset_, address debtAsset_, RetargetterConfig calldata config_)
    external
    initializer
  {
    owner_.checkNotZero();
    collateralAsset_.checkContract();
    debtAsset_.checkContract();
    if (collateralAsset_ == debtAsset_) revert LibRetargetterErrors.AssetMismatch();
    _setConfig(config_);
    RetargetterAssets storage assets_ = _assetsStorage();
    assets_.collateralAsset = collateralAsset_;
    assets_.debtAsset = debtAsset_;
    _initializeOwner(owner_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ASYNC FLOW                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetter
  /// @dev The deployed Request gets the maximum 90-day repayment deadline and a zero
  ///      mint-to-repaid delay (the minimum-one-tick rule already guarantees lenders a full
  ///      tick of yield). The Retargetter becomes its owner, puller and consumer.
  function startRetargetting(
    address positionManager,
    uint256 principal,
    uint16 maxYieldBps_,
    address fund,
    string calldata requestName,
    string calldata requestSymbol
  ) external onlyOwnerOrRebalancer nonReentrant returns (address request) {
    RetargetterOperation storage operation_ = _operationStorage();
    if (operation_.positionManager != address(0) || _isWindowOpen()) revert LibRetargetterErrors.OperationActive();
    if (operation_.orderLive) revert LibRetargetterErrors.OrderActive();
    _checkPair(positionManager);
    if (!_whitelistsStorage().funds[fund]) revert LibRetargetterErrors.FundNotWhitelisted();
    // Fail-fast principal check; the binding check re-runs at every consume
    if (principal > maxPrincipal(positionManager)) revert LibRetargetterErrors.PrincipalCapExceeded();

    uint16 configCap = _configStorage().maxYieldBps;
    uint16 effectiveYieldCap = maxYieldBps_ < configCap ? maxYieldBps_ : configCap;

    (request,,) = IRequestFactory(REQUEST_FACTORY)
      .createRequest(
        address(this),
        address(this),
        address(this),
        _assetsStorage().debtAsset,
        requestName,
        requestSymbol,
        // Safe: block.timestamp + 90 days fits in uint64 for hundreds of billions of years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64(block.timestamp + REPAYMENT_DEADLINE_OFFSET),
        0
      );

    operation_.positionManager = positionManager;
    operation_.operationMaxYieldBps = effectiveYieldCap;
    operation_.request = request;
    operation_.fund = fund;

    emit RetargettingStarted(positionManager, request, fund, principal, effectiveYieldCap);
  }

  /// @inheritdoc IRetargetter
  /// @dev The yield gate compares the offer's ratio (partial fills keep it), division-free:
  ///      `expectedReturn * BPS <= amount * operationMaxYieldBps`. The gate is flat because
  ///      repayment itself is duration-prorated by the tick formula. The principal gate is
  ///      cumulative through the Request's PT supply, which is the complete consumption
  ///      accounting since the Retargetter exposes no authorizeMinting passthrough.
  function consume(Offer calldata offer, bytes calldata signature, uint256 ptAmount)
    external
    onlyOwnerOrRoles(CONSUMER_ROLE)
    nonReentrant
    returns (uint256 ytAmount)
  {
    RetargetterOperation storage operation_ = _operationStorage();
    address positionManager = operation_.positionManager;
    address request = operation_.request;
    if (positionManager == address(0)) revert LibRetargetterErrors.NoActiveOperation();
    if (offer.expectedReturn * BPS > offer.amount * operation_.operationMaxYieldBps) {
      revert LibRetargetterErrors.YieldTooHigh();
    }
    (uint128 ptSupply,) = ITokenController(request).totalSupplies();
    if (ptSupply + ptAmount > maxPrincipal(positionManager)) revert LibRetargetterErrors.PrincipalCapExceeded();
    // The first consume starts the loan clock; later consumes accrue from the same origin
    if (operation_.startedAt == 0) {
      // Safe: block.timestamp fits in uint40 for ~35,000 years
      // forge-lint: disable-next-line(unsafe-typecast)
      operation_.startedAt = uint40(block.timestamp);
    }
    ytAmount = IRequest(request).consume(offer, signature, ptAmount);
    emit OfferConsumed(request, offer.maker, ptAmount, ytAmount);
  }

  /// @inheritdoc IRetargetter
  /// @dev Naturally bounded by the Request's balance, which the principal cap already bounded.
  function pullRequestFunds(uint256 amount) external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = _operationStorage();
    address request = operation_.request;
    if (operation_.positionManager == address(0)) revert LibRetargetterErrors.NoActiveOperation();
    IRequestInteractions(request).pullFunds(amount, "");
    emit RequestFundsPulled(request, amount);
  }

  /// @inheritdoc IRetargetter
  /// @dev With no consume the owed amount is zero and this simply marks the Request repaid,
  ///      which is how an untouched operation gets abandoned. Transfers only the shortfall
  ///      between the owed amount and the Request's balance, never more, so position-derived
  ///      funds cannot overpay YT holders. The open upper bound at setRepaid keeps third-party
  ///      donations to the Request from blocking repayment. Once the Request passes its
  ///      90-day deadline it auto-expires and this function reverts AlreadyRepaid; proceeds
  ///      settling after that point should be delivered to lenders through owner
  ///      rescue(debtAsset, request) before holders redeem, not folded into the position.
  function repay() external onlyOwnerOrRebalancer nonReentrant returns (uint256 owedAmount) {
    RetargetterOperation storage operation_ = _operationStorage();
    address request = operation_.request;
    if (operation_.positionManager == address(0)) revert LibRetargetterErrors.NoActiveOperation();
    owedAmount = _owed(operation_);
    address debtAsset = _assetsStorage().debtAsset;
    uint256 requestBalance = debtAsset.balanceOf(request);
    uint256 shortfall = owedAmount > requestBalance ? owedAmount - requestBalance : 0;
    if (shortfall > 0) {
      debtAsset.safeApproveWithRetry(request, shortfall);
      IRequestInteractions(request).repay(shortfall);
      debtAsset.safeApprove(request, 0);
    }
    IRequest(request).setRepaid(owedAmount, type(uint256).max);
    emit RequestRepaid(request, owedAmount, shortfall);
  }

  /// @inheritdoc IRetargetter
  /// @dev Owner path for defaults and disputes. For a true default nothing needs calling:
  ///      the Request auto-expires at its deadline and holders redeem what sits there.
  function forceRepay(uint256 amount, uint256 minBalance, uint256 maxBalance) external onlyOwner nonReentrant {
    RetargetterOperation storage operation_ = _operationStorage();
    address request = operation_.request;
    if (operation_.positionManager == address(0)) revert LibRetargetterErrors.NoActiveOperation();
    if (amount > 0) _assetsStorage().debtAsset.safeTransfer(request, amount);
    IRequest(request).setRepaid(minBalance, maxBalance);
    emit RequestForceRepaid(request, amount, minBalance, maxBalance);
  }

  /// @inheritdoc IRetargetter
  /// @dev Three settlement gates, never bypassed by anyone: Request repaid (through the
  ///      state-mutating sync so a past-deadline Request resolves instead of wedging), no
  ///      pending order (an ENDED or force-ended order is cleared here), and zero residual
  ///      on both bound assets (donations are unblocked by owner rescue).
  function resolve() external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = _operationStorage();
    address positionManager = operation_.positionManager;
    address request = operation_.request;
    if (positionManager == address(0)) revert LibRetargetterErrors.NoActiveOperation();
    if (!IRequest(request).syncRepaidStatus()) revert LibRetargetterErrors.RequestNotRepaid();
    _checkNoPendingOrder(operation_, operation_.fund);
    _checkZeroResidual();

    operation_.positionManager = address(0);
    operation_.startedAt = 0;
    operation_.operationMaxYieldBps = 0;
    operation_.request = address(0);
    operation_.fund = address(0);

    emit RetargettingResolved(positionManager, request);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ORDER WRAPPERS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetter
  /// @dev Operates against the resolved fund: the active operation's fund, or the window
  ///      fund inside a flash loan. Only the non-derivable order fields are stored; identical
  ///      re-submissions need a fresh salt because funds archive ended order ids. An order
  ///      created inside a flash-loan window must reach ENDED or be canceled before the
  ///      window closes. Operator note: size order.output at or below the venue-simulated
  ///      output; on venues whose deviation check is one-sided (Pareto rejects only outputs
  ///      below the rate), an overstated output commits into an order that never becomes
  ///      unlockable and stays pending until the fund operator resolves it fund-side.
  function create(Order calldata order_) external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = _operationStorage();
    address fund = _resolveFund(operation_);
    if (operation_.orderLive) revert LibRetargetterErrors.OrderActive();
    if (order_.owner != address(this) || order_.receiver != address(this)) {
      revert LibRetargetterErrors.InvalidOrder();
    }
    IFund(fund).create(order_);
    operation_.orderMode = order_.mode;
    operation_.orderLive = true;
    operation_.orderInput = order_.input;
    operation_.orderOutput = order_.output;
    operation_.orderSalt = order_.salt;
    emit OrderCreated(fund, order_);
  }

  /// @inheritdoc IRetargetter
  /// @dev Approves exactly the order input (debt asset for DEPOSIT, collateral asset for
  ///      REDEEM) and scrubs the approval after the call.
  function commit() external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = _operationStorage();
    address fund = _resolveFund(operation_);
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    Order memory order_ = _rebuildOrder(operation_);
    RetargetterAssets storage assets_ = _assetsStorage();
    address inputToken = order_.mode == Mode.DEPOSIT ? assets_.debtAsset : assets_.collateralAsset;
    inputToken.safeApproveWithRetry(fund, order_.input);
    IFund(fund).commit(order_);
    inputToken.safeApprove(fund, 0);
    emit OrderCommitted(fund, order_);
  }

  /// @inheritdoc IRetargetter
  /// @dev Partial fills leave the order live for a later call; the order is cleared once the
  ///      fund reports ENDED.
  function unlock() external onlyOwnerOrRebalancer nonReentrant returns (uint256 amountOut) {
    RetargetterOperation storage operation_ = _operationStorage();
    address fund = _resolveFund(operation_);
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    Order memory order_ = _rebuildOrder(operation_);
    State state_;
    (state_, amountOut) = IFund(fund).unlock(order_);
    if (state_ == State.ENDED) _clearOrder(operation_);
    emit OrderUnlocked(fund, order_);
  }

  /// @inheritdoc IRetargetter
  function cancelOrder() external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = _operationStorage();
    address fund = _resolveFund(operation_);
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    Order memory order_ = _rebuildOrder(operation_);
    IFund(fund).cancel(order_);
    _clearOrder(operation_);
    emit OrderCanceled(fund, order_);
  }

  /// @inheritdoc IRetargetter
  /// @dev Partial recoveries leave the order live for a later call; the order is cleared once
  ///      the fund reports ENDED.
  function recoverOrder() external onlyOwnerOrRebalancer nonReentrant returns (uint256 amountIn) {
    RetargetterOperation storage operation_ = _operationStorage();
    address fund = _resolveFund(operation_);
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    Order memory order_ = _rebuildOrder(operation_);
    State state_;
    (state_, amountIn) = IFund(fund).recover(order_);
    if (state_ == State.ENDED) _clearOrder(operation_);
    emit OrderRecovered(fund, order_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        REBALANCING                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetter
  /// @dev Snapshots the target and the aggregate and per-module LTVs before the call, so no
  ///      mid-call state change can move the goalposts. After the call (skipped for direct
  ///      owner calls, always applied inside a window): the aggregate and every module may
  ///      end above target only while strictly improving on their snapshot, and no module may
  ///      end with debt against zero collateral. LTV convention throughout: zero when debt is
  ///      zero (idle modules and an emptied position pass), the max sentinel for bad debt.
  ///      The position manager's own loss, cooldown and safe-LTV checks apply underneath.
  ///      A sentinel resolving to a zero balance produces a zero-amount leg, which the borrow
  ///      modules reject; the whole call reverts atomically.
  function rebalance(RebalancingData calldata data) external onlyOwnerOrRebalancer nonReentrant {
    address positionManager = _resolvePositionManager();
    RetargetterAssets storage assets_ = _assetsStorage();
    address collateralAsset = assets_.collateralAsset;
    address debtAsset = assets_.debtAsset;

    // Resolve the full-balance sentinels in memory before calling the position manager.
    // Input legs resolve to the current balance of the corresponding asset; the sentinel is
    // rejected on output legs (BORROW, WITHDRAW).
    RebalancingData memory resolved = data;
    uint256 collateralBalance = collateralAsset.balanceOf(address(this));
    uint256 debtBalance = debtAsset.balanceOf(address(this));
    if (resolved.collateral == FULL_BALANCE_SENTINEL) resolved.collateral = collateralBalance;
    if (resolved.debt == FULL_BALANCE_SENTINEL) resolved.debt = debtBalance;
    uint256 operationsLength = resolved.operations.length;
    for (uint256 i = 0; i < operationsLength; ++i) {
      if (resolved.operations[i].amount != FULL_BALANCE_SENTINEL) continue;
      RebalancingOperationType operationType = resolved.operations[i].operationType;
      if (operationType == RebalancingOperationType.SUPPLY) {
        resolved.operations[i].amount = collateralBalance;
      } else if (operationType == RebalancingOperationType.REPAY) {
        resolved.operations[i].amount = debtBalance;
      } else {
        revert LibRetargetterErrors.InvalidSentinel();
      }
    }

    // Snapshot the goalposts: target, aggregate LTV and per-module LTVs
    (uint256 target,) = IPositionManager(positionManager).config();
    uint256 ltvBefore = _positionManagerLtv(positionManager);
    address[] memory modules = IPositionManager(positionManager).borrowModules();
    uint256 modulesLength = modules.length;
    uint256[] memory moduleLtvsBefore = new uint256[](modulesLength);
    for (uint256 i = 0; i < modulesLength; ++i) {
      moduleLtvsBefore[i] = _moduleLtv(modules[i]);
    }

    // Approve exactly the nonzero input legs, execute with all excess swept back here, scrub
    if (resolved.collateral > 0) collateralAsset.safeApproveWithRetry(positionManager, resolved.collateral);
    if (resolved.debt > 0) debtAsset.safeApproveWithRetry(positionManager, resolved.debt);
    IPositionManager(positionManager).rebalance(resolved, address(this));
    if (resolved.collateral > 0) collateralAsset.safeApprove(positionManager, 0);
    if (resolved.debt > 0) debtAsset.safeApprove(positionManager, 0);

    // Direction checks; owner bypass is evaluated on msg.sender only, never through the
    // window (inside a window msg.sender is the flash-loan module)
    if (msg.sender != owner()) {
      uint256 ltvAfter = _positionManagerLtv(positionManager);
      if (ltvAfter > target && ltvAfter >= ltvBefore) {
        revert LibRetargetterErrors.AboveTargetLtv(ltvAfter, ltvBefore, target);
      }
      for (uint256 i = 0; i < modulesLength; ++i) {
        address module = modules[i];
        uint256 moduleLtvAfter = _moduleLtv(module);
        if (moduleLtvAfter == type(uint256).max) revert LibRetargetterErrors.BadDebtPosition(module);
        if (moduleLtvAfter > target && moduleLtvAfter >= moduleLtvsBefore[i]) {
          revert LibRetargetterErrors.PositionAboveTarget(module);
        }
      }
    }

    emit Rebalanced(positionManager, resolved.collateral, resolved.debt);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         SYNC FLOW                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetter
  /// @dev Deliberately not nonReentrant: the payload steps executed inside the callback are
  ///      themselves guarded and the guard lives in transient storage shared across the
  ///      delegatecalls, so a held outer guard would revert every inner step. Reentry
  ///      protection comes from the window flag doubling as the entry lock. Atomicity is the
  ///      settlement invariant: either the whole retarget lands (loan repaid, no stored
  ///      order, zero residual) or the transaction reverts.
  function startSyncRetargetting(
    address positionManager,
    address flashLoanModule,
    uint256 flashLoanAmount,
    address fund,
    bytes[] calldata data
  ) external onlyOwnerOrRebalancer {
    RetargetterOperation storage operation_ = _operationStorage();
    if (operation_.positionManager != address(0) || _isWindowOpen()) revert LibRetargetterErrors.OperationActive();
    if (operation_.orderLive) revert LibRetargetterErrors.OrderActive();
    RetargetterWhitelists storage whitelists = _whitelistsStorage();
    if (!whitelists.flashLoanModules[flashLoanModule]) revert LibRetargetterErrors.ModuleNotWhitelisted();
    if (!whitelists.funds[fund]) revert LibRetargetterErrors.FundNotWhitelisted();
    _checkPair(positionManager);
    if (flashLoanAmount > maxPrincipal(positionManager)) revert LibRetargetterErrors.PrincipalCapExceeded();

    // Open the window: the flag hands step authority to the flash-loan callback chain
    _tstoreUint(WINDOW_TSLOT, 1);
    _tstoreAddress(MODULE_TSLOT, flashLoanModule);
    _tstoreAddress(POSITION_MANAGER_TSLOT, positionManager);
    _tstoreAddress(FUND_TSLOT, fund);
    _tstoreUint(AMOUNT_TSLOT, flashLoanAmount);

    address debtAsset = _assetsStorage().debtAsset;
    IFlashLoanModule(flashLoanModule).flashLoan(debtAsset, flashLoanAmount, abi.encode(data));

    // The module has pulled its repayment; close the window and scrub any leftover approval
    _tstoreUint(WINDOW_TSLOT, 0);
    _tstoreAddress(MODULE_TSLOT, address(0));
    _tstoreAddress(POSITION_MANAGER_TSLOT, address(0));
    _tstoreAddress(FUND_TSLOT, address(0));
    _tstoreUint(AMOUNT_TSLOT, 0);
    debtAsset.safeApprove(flashLoanModule, 0);

    // Settlement gates on the function's own parameters, not the cleared transients
    _checkNoPendingOrder(operation_, fund);
    _checkZeroResidual();

    emit SyncRetargettingExecuted(positionManager, flashLoanModule, flashLoanAmount);
  }

  /// @notice Provider-agnostic flash-loan callback executing the operation payload.
  /// @dev Only callable by the transient module with the exact transient amount; the module
  ///      slot is zeroed on entry so the callback is single-shot (a nested or replayed
  ///      callback, including one smuggled into the payload, fails). Each payload element is
  ///      delegatecalled on this contract, so the steps run their own modifiers with
  ///      `msg.sender` being the module; authorization flows through the window flag.
  /// @param amount The flash-loaned amount
  /// @param data The ABI-encoded step calls supplied to startSyncRetargetting
  function onFlashLoan(uint256 amount, bytes calldata data) external {
    address module = _tloadAddress(MODULE_TSLOT);
    if (module == address(0) || msg.sender != module || amount != _tloadUint(AMOUNT_TSLOT)) {
      revert LibRetargetterErrors.UnauthorizedFlashLoanCallback();
    }
    _tstoreAddress(MODULE_TSLOT, address(0));
    bytes[] memory calls = abi.decode(data, (bytes[]));
    uint256 callsLength = calls.length;
    for (uint256 i = 0; i < callsLength; ++i) {
      address(this).delegateCallContract(calls[i]);
    }
    // The module pulls its repayment through this allowance after the callback returns
    _assetsStorage().debtAsset.safeApproveWithRetry(module, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CONFIGURATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetter
  /// @dev Changes take effect immediately, including for an in-flight operation; the
  ///      recorded per-operation yield cap is the exception, fixed at start.
  function setConfig(RetargetterConfig calldata config_) external onlyOwner nonReentrant {
    _setConfig(config_);
  }

  /// @inheritdoc IRetargetter
  /// @dev Zero estimates are valid and equal the zero-rate ideal principal cap. A change
  ///      moves only the cap, which binds future consumption, not past.
  function setEstimates(YieldEstimates calldata estimates_) external onlyOwner nonReentrant {
    _configStorage().estimates = estimates_;
    emit EstimatesSet(estimates_);
  }

  /// @inheritdoc IRetargetter
  /// @dev The pair is fixed, so token compatibility is checked once here instead of at every
  ///      operation start.
  function addFund(address fund) external onlyOwner nonReentrant {
    fund.checkContract();
    RetargetterAssets storage assets_ = _assetsStorage();
    if (IFund(fund).asset() != assets_.debtAsset || IFund(fund).share() != assets_.collateralAsset) {
      revert LibRetargetterErrors.AssetMismatch();
    }
    _whitelistsStorage().funds[fund] = true;
    emit FundAdded(fund);
  }

  /// @inheritdoc IRetargetter
  function removeFund(address fund) external onlyOwner nonReentrant {
    if (_operationStorage().fund == fund) revert LibRetargetterErrors.OperationActive();
    _whitelistsStorage().funds[fund] = false;
    emit FundRemoved(fund);
  }

  /// @inheritdoc IRetargetter
  function addFlashLoanModule(address module) external onlyOwner nonReentrant {
    module.checkContract();
    _whitelistsStorage().flashLoanModules[module] = true;
    emit FlashLoanModuleAdded(module);
  }

  /// @inheritdoc IRetargetter
  /// @dev Removable any time: an open window binds its module for the transaction through
  ///      the transient slots, not the whitelist.
  function removeFlashLoanModule(address module) external onlyOwner nonReentrant {
    _whitelistsStorage().flashLoanModules[module] = false;
    emit FlashLoanModuleRemoved(module);
  }

  /// @inheritdoc IRetargetter
  /// @dev Using it mid-operation on operation assets is an explicit owner override.
  function rescue(address token, address to) external onlyOwner nonReentrant returns (uint256 amount) {
    amount = token.safeTransferAll(to);
    emit Rescued(token, to, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetter
  function assets() external view returns (address collateralAsset, address debtAsset) {
    RetargetterAssets storage assets_ = _assetsStorage();
    return (assets_.collateralAsset, assets_.debtAsset);
  }

  /// @inheritdoc IRetargetter
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
    )
  {
    RetargetterOperation storage operation_ = _operationStorage();
    return (
      operation_.positionManager,
      operation_.request,
      operation_.fund,
      operation_.startedAt,
      operation_.operationMaxYieldBps,
      _rebuildOrder(operation_),
      operation_.orderLive
    );
  }

  /// @inheritdoc IRetargetter
  function isActive() external view returns (bool) {
    return _operationStorage().positionManager != address(0);
  }

  /// @inheritdoc IRetargetter
  /// @dev Recomputed from live position manager state, so the cap self-corrects: once a
  ///      rebalance moves the position to target the cap collapses toward zero and further
  ///      consumption is blocked. An empty position reverts EmptyPosition; debt against zero
  ///      collateral reverts BadDebtPosition.
  function maxPrincipal(address positionManager) public view returns (uint256) {
    uint256 collateralQuoted = IPositionManager(positionManager).collateralAmountQuoted();
    uint256 debt = IPositionManager(positionManager).debtAmount();
    if (collateralQuoted == 0) {
      if (debt == 0) revert LibRetargetterErrors.EmptyPosition();
      revert LibRetargetterErrors.BadDebtPosition(positionManager);
    }
    (uint256 target,) = IPositionManager(positionManager).config();
    uint256 current = debt.divWad(collateralQuoted);
    RetargetterConfig storage config_ = _configStorage();
    YieldEstimates storage estimates = config_.estimates;
    uint256 principal;
    if (current < target) {
      principal = IRetargetterQuoter(QUOTER)
        .ltvUpPrincipal(
          collateralQuoted,
          debt,
          target,
          estimates.requestYieldRate,
          estimates.borrowRate,
          estimates.collateralYieldRate,
          estimates.subscriptionDuration
        );
    } else if (current > target) {
      (principal,) = IRetargetterQuoter(QUOTER)
        .ltvDownPrincipal(
          collateralQuoted,
          debt,
          target,
          estimates.requestYieldRate,
          estimates.borrowRate,
          estimates.collateralYieldRate,
          estimates.redemptionDuration
        );
    }
    return principal * (BPS + config_.principalBufferBps) / BPS;
  }

  /// @inheritdoc IRetargetter
  function owed() external view returns (uint256) {
    RetargetterOperation storage operation_ = _operationStorage();
    if (operation_.positionManager == address(0)) revert LibRetargetterErrors.NoActiveOperation();
    return _owed(operation_);
  }

  /// @inheritdoc IRetargetter
  function config() external view returns (RetargetterConfig memory) {
    RetargetterConfig storage stored = _configStorage();
    return RetargetterConfig({
      horizon: stored.horizon,
      tickDuration: stored.tickDuration,
      tickThreshold: stored.tickThreshold,
      maxYieldBps: stored.maxYieldBps,
      principalBufferBps: stored.principalBufferBps,
      estimates: stored.estimates
    });
  }

  /// @inheritdoc IRetargetter
  function isFund(address fund) external view returns (bool) {
    return _whitelistsStorage().funds[fund];
  }

  /// @inheritdoc IRetargetter
  function isFlashLoanModule(address module) external view returns (bool) {
    return _whitelistsStorage().flashLoanModules[module];
  }

  /// @inheritdoc IRetargetter
  function quoter() external view returns (address) {
    return QUOTER;
  }

  /// @inheritdoc IRetargetter
  function requestFactory() external view returns (address) {
    return REQUEST_FACTORY;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Validates and stores the configuration, emitting {ConfigSet}.
  function _setConfig(RetargetterConfig calldata config_) internal {
    if (
      config_.horizon < MIN_HORIZON || config_.horizon > MAX_HORIZON || config_.tickDuration == 0
        || config_.tickDuration > MAX_TICK_DURATION || config_.tickThreshold >= config_.tickDuration
        || config_.maxYieldBps > MAX_YIELD_CAP_BPS || config_.principalBufferBps > MAX_PRINCIPAL_BUFFER_BPS
    ) {
      revert LibRetargetterErrors.InvalidParameters();
    }
    RetargetterConfig storage stored = _configStorage();
    stored.horizon = config_.horizon;
    stored.tickDuration = config_.tickDuration;
    stored.tickThreshold = config_.tickThreshold;
    stored.maxYieldBps = config_.maxYieldBps;
    stored.principalBufferBps = config_.principalBufferBps;
    stored.estimates = config_.estimates;
    emit ConfigSet(config_);
  }

  /// @dev Reverts unless the position manager's assets equal the bound pair. The fund's
  ///      tokens were validated against the pair at addFund and the Request is created with
  ///      the debt asset, so a matching position manager makes the whole operation match.
  function _checkPair(address positionManager) internal view {
    RetargetterAssets storage assets_ = _assetsStorage();
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();
    if (collateralAsset != assets_.collateralAsset || debtAsset != assets_.debtAsset) {
      revert LibRetargetterErrors.AssetMismatch();
    }
  }

  /// @dev Current owed amount on the operation's Request. PT supply is exactly what consume
  ///      issued, so with nothing consumed (startedAt still zero) both supplies are zero and
  ///      the owed amount is zero regardless of the elapsed time.
  function _owed(RetargetterOperation storage operation_) internal view returns (uint256) {
    (uint128 ptSupply, uint128 ytSupply) = ITokenController(operation_.request).totalSupplies();
    RetargetterConfig storage config_ = _configStorage();
    return IRetargetterQuoter(QUOTER)
      .repaymentOwed(
        ptSupply,
        ytSupply,
        block.timestamp - operation_.startedAt,
        config_.tickDuration,
        config_.tickThreshold,
        config_.horizon
      );
  }

  /// @dev Resolves the fund a step operates against: the active operation's fund, or the
  ///      window fund inside a flash loan.
  function _resolveFund(RetargetterOperation storage operation_) internal view returns (address fund) {
    fund = operation_.fund;
    if (fund == address(0)) fund = _tloadAddress(FUND_TSLOT);
    if (fund == address(0)) revert LibRetargetterErrors.NoActiveOperation();
  }

  /// @dev Resolves the position manager a step operates against: the active operation's, or
  ///      the window's inside a flash loan.
  function _resolvePositionManager() internal view returns (address positionManager) {
    positionManager = _operationStorage().positionManager;
    if (positionManager == address(0)) positionManager = _tloadAddress(POSITION_MANAGER_TSLOT);
    if (positionManager == address(0)) revert LibRetargetterErrors.NoActiveOperation();
  }

  /// @dev Rebuilds the full stored order in memory; owner and receiver are always this
  ///      contract (enforced at create), so they are never stored.
  function _rebuildOrder(RetargetterOperation storage operation_) internal view returns (Order memory) {
    return Order({
      mode: operation_.orderMode,
      owner: address(this),
      receiver: address(this),
      input: operation_.orderInput,
      output: operation_.orderOutput,
      salt: operation_.orderSalt
    });
  }

  /// @dev Clears the stored order fields and the liveness flag.
  function _clearOrder(RetargetterOperation storage operation_) internal {
    operation_.orderMode = Mode.DEPOSIT;
    operation_.orderLive = false;
    operation_.orderInput = 0;
    operation_.orderOutput = 0;
    operation_.orderSalt = bytes32(0);
  }

  /// @dev Settlement gate: with a stored order, an ENDED (or fund-side force-ended, reading
  ///      EMPTY) order is cleared, anything else reverts OrderPending.
  function _checkNoPendingOrder(RetargetterOperation storage operation_, address fund) internal {
    if (!operation_.orderLive) return;
    State state_ = IFund(fund).state(_rebuildOrder(operation_));
    if (state_ != State.ENDED && state_ != State.EMPTY) revert LibRetargetterErrors.OrderPending();
    _clearOrder(operation_);
  }

  /// @dev Settlement gate: the balances of both bound assets must be exactly zero. Every
  ///      borrowed or withdrawn unit must have returned to the position manager, to the
  ///      Request, or been rescued by the owner.
  function _checkZeroResidual() internal view {
    RetargetterAssets storage assets_ = _assetsStorage();
    address collateralAsset = assets_.collateralAsset;
    uint256 balance = collateralAsset.balanceOf(address(this));
    if (balance != 0) revert LibRetargetterErrors.ResidualBalance(collateralAsset, balance);
    address debtAsset = assets_.debtAsset;
    balance = debtAsset.balanceOf(address(this));
    if (balance != 0) revert LibRetargetterErrors.ResidualBalance(debtAsset, balance);
  }

  /// @dev Aggregate position manager LTV under the snapshot convention.
  function _positionManagerLtv(address positionManager) internal view returns (uint256) {
    return
      _ltv(IPositionManager(positionManager).debtAmount(), IPositionManager(positionManager).collateralAmountQuoted());
  }

  /// @dev Single borrow module LTV under the snapshot convention.
  function _moduleLtv(address module) internal view returns (uint256) {
    return _ltv(IBorrowPosition(module).totalBorrowed(), IBorrowPosition(module).totalCollateralQuoted());
  }

  /// @dev LTV convention: zero when debt is zero regardless of collateral (covers idle
  ///      modules and an emptied position without dividing by zero), the max sentinel when
  ///      debt is positive with zero quoted collateral (bad debt).
  function _ltv(uint256 debt, uint256 collateralQuoted) internal pure returns (uint256) {
    if (debt == 0) return 0;
    if (collateralQuoted == 0) return type(uint256).max;
    return debt.divWad(collateralQuoted);
  }

  /// @dev Whether a flash-loan window is open.
  function _isWindowOpen() internal view returns (bool) {
    return _tloadUint(WINDOW_TSLOT) != 0;
  }

  /// @dev Reads an address from a transient slot.
  function _tloadAddress(uint256 slot) internal view returns (address value) {
    assembly ("memory-safe") {
      value := tload(slot)
    }
  }

  /// @dev Reads a uint256 from a transient slot.
  function _tloadUint(uint256 slot) internal view returns (uint256 value) {
    assembly ("memory-safe") {
      value := tload(slot)
    }
  }

  /// @dev Writes an address to a transient slot.
  function _tstoreAddress(uint256 slot, address value) internal {
    assembly ("memory-safe") {
      tstore(slot, value)
    }
  }

  /// @dev Writes a uint256 to a transient slot.
  function _tstoreUint(uint256 slot, uint256 value) internal {
    assembly ("memory-safe") {
      tstore(slot, value)
    }
  }

  /// @inheritdoc ReentrancyGuardTransient
  /// @dev Returns false to use the transient reentrancy guard on all networks.
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
