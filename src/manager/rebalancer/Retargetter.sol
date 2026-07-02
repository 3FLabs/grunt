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
  LibStorage,
  RetargetterAssets,
  RetargetterWhitelists,
  RetargetterOperation
} from "../../libs/manager/rebalancer/LibStorage.sol";
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
  WINDOW_TSLOT,
  MODULE_TSLOT,
  AMOUNT_TSLOT
} from "../../libs/manager/rebalancer/LibRetargetterConstants.sol";
import {BPS} from "../../libs/Constants.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {LibTransientSlot} from "../../libs/common/LibTransientSlot.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Multicallable} from "lib/solady/src/utils/Multicallable.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

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
///        as a multicall payload executed inside the callback and nothing persists past the
///        transaction.
///
///      Trust model: fully trusted owner, semi-trusted rebalancer boxed in by the guardrails
///      (direction checks, principal and yield caps, whitelists, residual settlement gates),
///      untrusted everyone else. The Retargetter holds no value at rest: `resolve` and the end
///      of the flash-loan window both require its balances of the two bound assets to stay
///      within the configured residual tolerance (exact zero by default).
///
///      Derive, do not store: everything readable from the composed contracts (direction,
///      consumed principal, order liveness progress, repaid status) is recomputed fresh at
///      every use; only the operation addresses, the loan clock origin, the per-operation
///      yield cap and the non-derivable order fields persist (see {LibStorage}).
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
  using LibChecks for address;
  using LibStorage for RetargetterOperation;
  using LibTransientSlot for bytes32;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The stateless quoter holding the sizing and repayment math.
  address public immutable QUOTER;

  /// @notice The factory deploying the operation Requests.
  address public immutable REQUEST_FACTORY;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         MODIFIERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Passes when a flash-loan window is open (the window is what lets the flash-loan
  ///      callback drive the steps, since `msg.sender` there is the module), when the caller
  ///      is the owner, or when the caller holds the rebalancer role.
  modifier onlyOwnerOrRebalancer() {
    if (WINDOW_TSLOT.tLoadUint() == 0 && msg.sender != owner() && !hasAnyRole(msg.sender, REBALANCER_ROLE)) {
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
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
    assets_.collateralAsset = collateralAsset_;
    assets_.debtAsset = debtAsset_;
    _initializeOwner(owner_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ASYNC FLOW                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetter
  /// @dev The deployed Request gets the maximum 90-day repayment deadline (treated as
  ///      effectively infinite; see REPAYMENT_DEADLINE_OFFSET for the acknowledgment) and a
  ///      zero mint-to-repaid delay (the minimum-one-tick rule already guarantees lenders a
  ///      full tick of yield). The Retargetter becomes its owner, puller and consumer.
  function startRetargetting(
    address positionManager,
    uint256 principal,
    uint16 maxYieldBps_,
    address fund,
    string calldata requestName,
    string calldata requestSymbol
  ) external onlyOwnerOrRebalancer nonReentrant returns (address request) {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    // The position manager doubles as the active flag; a SYNC window keeps it populated, so
    // this also locks out starts smuggled into a window payload
    if (operation_.positionManager != address(0)) revert LibRetargetterErrors.OperationActive();
    if (operation_.orderLive) revert LibRetargetterErrors.OrderActive();
    _checkPair(positionManager);
    if (!LibStorage.whitelistsStorage().funds[fund]) revert LibRetargetterErrors.FundNotWhitelisted();
    // Fail-fast principal check; the binding check re-runs at every consume
    if (principal > maxPrincipal(positionManager)) revert LibRetargetterErrors.PrincipalCapExceeded();

    uint16 configCap = LibStorage.configStorage().maxYieldBps;
    uint16 effectiveYieldCap = maxYieldBps_ < configCap ? maxYieldBps_ : configCap;

    (request,,) = IRequestFactory(REQUEST_FACTORY)
      .createRequest(
        address(this),
        address(this),
        address(this),
        LibStorage.assetsStorage().debtAsset,
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
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    address request = operation_.checkRequest();
    if (offer.expectedReturn * BPS > offer.amount * operation_.operationMaxYieldBps) {
      revert LibRetargetterErrors.YieldTooHigh();
    }
    (uint128 ptSupply,) = ITokenController(request).totalSupplies();
    if (ptSupply + ptAmount > maxPrincipal(operation_.positionManager)) {
      revert LibRetargetterErrors.PrincipalCapExceeded();
    }
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
    address request = LibStorage.operationStorage().checkRequest();
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
  ///      The expiry bypassing the local repayment flow is an acknowledged limitation;
  ///      see REPAYMENT_DEADLINE_OFFSET for the remediation posture.
  function repay() external onlyOwnerOrRebalancer nonReentrant returns (uint256 owedAmount) {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    address request = operation_.checkRequest();
    owedAmount = _owed(operation_);
    address debtAsset = LibStorage.assetsStorage().debtAsset;
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
    address request = LibStorage.operationStorage().checkRequest();
    if (amount > 0) LibStorage.assetsStorage().debtAsset.safeTransfer(request, amount);
    IRequest(request).setRepaid(minBalance, maxBalance);
    emit RequestForceRepaid(request, amount, minBalance, maxBalance);
  }

  /// @inheritdoc IRetargetter
  /// @dev Three settlement gates, never bypassed by anyone: Request repaid (through the
  ///      state-mutating sync so a past-deadline Request resolves instead of wedging), no
  ///      pending order (an ENDED or force-ended order is cleared here), and residual within
  ///      the configured tolerance on both bound assets (dust donations below the tolerance
  ///      cannot grief settlement; anything above is unblocked by owner rescue).
  function resolve() external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    address request = operation_.checkRequest();
    address positionManager = operation_.positionManager;
    if (!IRequest(request).syncRepaidStatus()) revert LibRetargetterErrors.RequestNotRepaid();
    operation_.checkNoPendingOrder(operation_.fund);
    _checkResidual();
    operation_.clearOperation();
    emit RetargettingResolved(positionManager, request);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ORDER WRAPPERS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetter
  /// @dev Operates against the operation's fund (ASYNC operations and SYNC windows both
  ///      record it in the operation storage). Only the non-derivable order fields are
  ///      stored; identical re-submissions need a fresh salt because funds archive ended
  ///      order ids. An order created inside a flash-loan window must reach ENDED or be
  ///      canceled before the window closes. Operator note: size order.output at or below
  ///      the venue-simulated output; on venues whose deviation check is one-sided (Pareto
  ///      rejects only outputs below the rate), an overstated output commits into an order
  ///      that never becomes unlockable and stays pending until the fund operator resolves
  ///      it fund-side.
  function create(Order calldata order_) external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    operation_.checkActive();
    address fund = operation_.fund;
    if (operation_.orderLive) revert LibRetargetterErrors.OrderActive();
    if (order_.owner != address(this) || order_.receiver != address(this)) {
      revert LibRetargetterErrors.InvalidOrder();
    }
    IFund(fund).create(order_);
    operation_.setOrder(order_);
    emit OrderCreated(fund, order_);
  }

  /// @inheritdoc IRetargetter
  /// @dev Approves exactly the order input (debt asset for DEPOSIT, collateral asset for
  ///      REDEEM) and scrubs the approval after the call.
  function commit() external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    operation_.checkActive();
    address fund = operation_.fund;
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    Order memory order_ = operation_.order();
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
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
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    operation_.checkActive();
    address fund = operation_.fund;
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    Order memory order_ = operation_.order();
    State state_;
    (state_, amountOut) = IFund(fund).unlock(order_);
    if (state_ == State.ENDED) operation_.clearOrder();
    emit OrderUnlocked(fund, order_);
  }

  /// @inheritdoc IRetargetter
  function cancelOrder() external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    operation_.checkActive();
    address fund = operation_.fund;
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    Order memory order_ = operation_.order();
    IFund(fund).cancel(order_);
    operation_.clearOrder();
    emit OrderCanceled(fund, order_);
  }

  /// @inheritdoc IRetargetter
  /// @dev Partial recoveries leave the order live for a later call; the order is cleared once
  ///      the fund reports ENDED.
  function recoverOrder() external onlyOwnerOrRebalancer nonReentrant returns (uint256 amountIn) {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    operation_.checkActive();
    address fund = operation_.fund;
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    Order memory order_ = operation_.order();
    State state_;
    (state_, amountIn) = IFund(fund).recover(order_);
    if (state_ == State.ENDED) operation_.clearOrder();
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
    address positionManager = LibStorage.operationStorage().checkActive();
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
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
  ///      protection comes from the operation storage doubling as the entry lock. The window
  ///      populates the same operation storage the steps read during an ASYNC operation
  ///      (minus the Request, whose absence gates the ASYNC-only steps) and zeroes it at
  ///      window close, so nothing persists past the transaction. Atomicity is the
  ///      settlement invariant: either the whole retarget lands (loan repaid, no stored
  ///      order, residual within the configured tolerance) or the transaction reverts.
  function startSyncRetargetting(
    address positionManager,
    address flashLoanModule,
    uint256 flashLoanAmount,
    address fund,
    bytes[] calldata data
  ) external onlyOwnerOrRebalancer {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    if (operation_.positionManager != address(0)) revert LibRetargetterErrors.OperationActive();
    if (operation_.orderLive) revert LibRetargetterErrors.OrderActive();
    RetargetterWhitelists storage whitelists = LibStorage.whitelistsStorage();
    if (!whitelists.flashLoanModules[flashLoanModule]) revert LibRetargetterErrors.ModuleNotWhitelisted();
    if (!whitelists.funds[fund]) revert LibRetargetterErrors.FundNotWhitelisted();
    _checkPair(positionManager);
    if (flashLoanAmount > maxPrincipal(positionManager)) revert LibRetargetterErrors.PrincipalCapExceeded();

    // Open the window: the operation storage carries the addresses the steps read (and locks
    // out nested starts); the transient slots carry the window flag, which hands step
    // authority to the flash-loan callback chain, and the callback authentication
    operation_.positionManager = positionManager;
    operation_.fund = fund;
    WINDOW_TSLOT.tStoreUint(1);
    MODULE_TSLOT.tStoreAddress(flashLoanModule);
    AMOUNT_TSLOT.tStoreUint(flashLoanAmount);

    address debtAsset = LibStorage.assetsStorage().debtAsset;
    IFlashLoanModule(flashLoanModule).flashLoan(debtAsset, flashLoanAmount, abi.encode(data));

    // The module has pulled its repayment; close the window and scrub any leftover approval
    WINDOW_TSLOT.tStoreUint(0);
    MODULE_TSLOT.tStoreAddress(address(0));
    AMOUNT_TSLOT.tStoreUint(0);
    debtAsset.safeApprove(flashLoanModule, 0);

    // Settlement gates, then zero the operation storage so nothing survives the window
    operation_.checkNoPendingOrder(fund);
    _checkResidual();
    operation_.clearOperation();

    emit SyncRetargettingExecuted(positionManager, flashLoanModule, flashLoanAmount);
  }

  /// @notice Provider-agnostic flash-loan callback executing the operation payload.
  /// @dev Only callable by the transient module with the exact transient amount; the module
  ///      slot is zeroed on entry so the callback is single-shot (a nested or replayed
  ///      callback, including one smuggled into the payload, fails). The payload runs through
  ///      Solady's `_multicall`: each element is delegatecalled on this contract, so the
  ///      steps run their own modifiers with `msg.sender` being the module; authorization
  ///      flows through the window flag.
  /// @param amount The flash-loaned amount
  /// @param data The ABI-encoded step calls supplied to startSyncRetargetting
  function onFlashLoan(uint256 amount, bytes calldata data) external {
    address module = MODULE_TSLOT.tLoadAddress();
    if (module == address(0) || msg.sender != module || amount != AMOUNT_TSLOT.tLoadUint()) {
      revert LibRetargetterErrors.UnauthorizedFlashLoanCallback();
    }
    MODULE_TSLOT.tStoreAddress(address(0));
    // `data` is the abi.encode of the step calls built by startSyncRetargetting and forwarded
    // verbatim by the module; point a calldata array at it in place instead of copying it
    bytes[] calldata calls;
    assembly ("memory-safe") {
      let arrayOffset := add(data.offset, calldataload(data.offset))
      calls.offset := add(arrayOffset, 0x20)
      calls.length := calldataload(arrayOffset)
    }
    _multicall(calls);
    // The module pulls its repayment through this allowance after the callback returns
    LibStorage.assetsStorage().debtAsset.safeApproveWithRetry(module, amount);
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
    LibStorage.configStorage().estimates = estimates_;
    emit EstimatesSet(estimates_);
  }

  /// @inheritdoc IRetargetter
  /// @dev The pair is fixed, so token compatibility is checked once here instead of at every
  ///      operation start.
  function addFund(address fund) external onlyOwner nonReentrant {
    fund.checkContract();
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
    if (IFund(fund).asset() != assets_.debtAsset || IFund(fund).share() != assets_.collateralAsset) {
      revert LibRetargetterErrors.AssetMismatch();
    }
    LibStorage.whitelistsStorage().funds[fund] = true;
    emit FundAdded(fund);
  }

  /// @inheritdoc IRetargetter
  function removeFund(address fund) external onlyOwner nonReentrant {
    if (LibStorage.operationStorage().fund == fund) revert LibRetargetterErrors.OperationActive();
    LibStorage.whitelistsStorage().funds[fund] = false;
    emit FundRemoved(fund);
  }

  /// @inheritdoc IRetargetter
  function addFlashLoanModule(address module) external onlyOwner nonReentrant {
    module.checkContract();
    LibStorage.whitelistsStorage().flashLoanModules[module] = true;
    emit FlashLoanModuleAdded(module);
  }

  /// @inheritdoc IRetargetter
  /// @dev Removable any time: an open window binds its module for the transaction through
  ///      the transient slots, not the whitelist.
  function removeFlashLoanModule(address module) external onlyOwner nonReentrant {
    LibStorage.whitelistsStorage().flashLoanModules[module] = false;
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
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
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
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    return (
      operation_.positionManager,
      operation_.request,
      operation_.fund,
      operation_.startedAt,
      operation_.operationMaxYieldBps,
      operation_.order(),
      operation_.orderLive
    );
  }

  /// @inheritdoc IRetargetter
  function isActive() external view returns (bool) {
    return LibStorage.operationStorage().positionManager != address(0);
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
    RetargetterConfig storage config_ = LibStorage.configStorage();
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
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    operation_.checkRequest();
    return _owed(operation_);
  }

  /// @inheritdoc IRetargetter
  function config() external view returns (RetargetterConfig memory) {
    RetargetterConfig storage stored = LibStorage.configStorage();
    return RetargetterConfig({
      horizon: stored.horizon,
      tickDuration: stored.tickDuration,
      tickThreshold: stored.tickThreshold,
      maxYieldBps: stored.maxYieldBps,
      principalBufferBps: stored.principalBufferBps,
      collateralResidualExponent: stored.collateralResidualExponent,
      debtResidualExponent: stored.debtResidualExponent,
      estimates: stored.estimates
    });
  }

  /// @inheritdoc IRetargetter
  function isFund(address fund) external view returns (bool) {
    return LibStorage.whitelistsStorage().funds[fund];
  }

  /// @inheritdoc IRetargetter
  function isFlashLoanModule(address module) external view returns (bool) {
    return LibStorage.whitelistsStorage().flashLoanModules[module];
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
    RetargetterConfig storage stored = LibStorage.configStorage();
    stored.horizon = config_.horizon;
    stored.tickDuration = config_.tickDuration;
    stored.tickThreshold = config_.tickThreshold;
    stored.maxYieldBps = config_.maxYieldBps;
    stored.principalBufferBps = config_.principalBufferBps;
    stored.collateralResidualExponent = config_.collateralResidualExponent;
    stored.debtResidualExponent = config_.debtResidualExponent;
    stored.estimates = config_.estimates;
    emit ConfigSet(config_);
  }

  /// @dev Reverts unless the position manager's assets equal the bound pair. The fund's
  ///      tokens were validated against the pair at addFund and the Request is created with
  ///      the debt asset, so a matching position manager makes the whole operation match.
  function _checkPair(address positionManager) internal view {
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
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
    RetargetterConfig storage config_ = LibStorage.configStorage();
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

  /// @dev Settlement gate: the balance of each bound asset must stay strictly below two to
  ///      the power of its configured residual exponent, checked with a single shift. The
  ///      zero default keeps the gate exact; a small tolerance (for example 2^20 on a
  ///      6-decimal asset, about one token) stops dust donations from griefing settlement.
  ///      Everything above must have returned to the position manager, to the Request, or
  ///      been rescued by the owner; tolerated dust stays here and folds into the next
  ///      operation through the full-balance sentinels.
  function _checkResidual() internal view {
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
    RetargetterConfig storage config_ = LibStorage.configStorage();
    address collateralAsset = assets_.collateralAsset;
    uint256 balance = collateralAsset.balanceOf(address(this));
    if (balance >> config_.collateralResidualExponent != 0) {
      revert LibRetargetterErrors.ResidualBalance(collateralAsset, balance);
    }
    address debtAsset = assets_.debtAsset;
    balance = debtAsset.balanceOf(address(this));
    if (balance >> config_.debtResidualExponent != 0) {
      revert LibRetargetterErrors.ResidualBalance(debtAsset, balance);
    }
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

  /// @inheritdoc ReentrancyGuardTransient
  /// @dev Returns false to use the transient reentrancy guard on all networks.
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
