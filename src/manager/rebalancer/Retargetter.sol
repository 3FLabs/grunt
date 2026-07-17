// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IRetargetter, RetargetterConfig, YieldEstimates} from "../../interfaces/manager/rebalancer/IRetargetter.sol";
import {IRetargetterQuoter} from "../../interfaces/manager/rebalancer/IRetargetterQuoter.sol";
import {IFlashLoanModule} from "../../interfaces/manager/rebalancer/IFlashLoanModule.sol";
import {IFlashLoanReceiver} from "../../interfaces/manager/rebalancer/IFlashLoanReceiver.sol";
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
import {LibStorage, RetargetterAssets, RetargetterOperation} from "../../libs/manager/rebalancer/LibStorage.sol";
import {
  REBALANCER_ROLE,
  CONSUMER_ROLE,
  MIN_HORIZON,
  MAX_HORIZON,
  MAX_TICK_DURATION,
  MAX_YIELD_CAP_BPS,
  MAX_PRINCIPAL_BUFFER_BPS,
  MAX_AUTHORIZED_ACCOUNTS,
  REPAYMENT_DEADLINE_OFFSET,
  FULL_BALANCE_SENTINEL,
  WINDOW_TSLOT,
  MODULE_TSLOT,
  AMOUNT_TSLOT,
  REENTRANCY_TSLOT
} from "../../libs/manager/rebalancer/LibRetargetterConstants.sol";
import {BPS} from "../../libs/Constants.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {LibTransientSlot} from "../../libs/common/LibTransientSlot.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Multicallable} from "lib/solady/src/utils/Multicallable.sol";
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
contract Retargetter is IRetargetter, IFlashLoanReceiver, OwnableRoles, Initializable, Multicallable {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using LibChecks for address;
  using LibStorage for RetargetterOperation;
  using LibTransientSlot for bytes32;
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The stateless quoter holding the sizing and repayment math; private because the
  ///      {quoter} interface view already exposes it (a public immutable would duplicate the
  ///      getter).
  address private immutable _QUOTER;

  /// @dev The factory deploying the operation Requests; private because the {requestFactory}
  ///      interface view already exposes it.
  address private immutable _REQUEST_FACTORY;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         MODIFIERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Passes when the caller is the module driving an open flash-loan window (the
  ///      payload steps are delegatecalled from the callback, so `msg.sender` there is the
  ///      module), when the caller is the owner, or when the caller holds the rebalancer
  ///      role. Outside a window the slot reads the zero address, which never matches a
  ///      caller, and a third party gaining execution control inside a window stays an
  ///      ordinary unauthorized caller. The body lives in a function so the modifier costs
  ///      a jump at each of its many use sites instead of an inlined copy (contract size).
  modifier onlyOwnerOrRebalancer() {
    _checkOwnerOrRebalancer();
    _;
  }

  /// @dev See {onlyOwnerOrRebalancer}.
  function _checkOwnerOrRebalancer() internal view {
    if (msg.sender != WINDOW_TSLOT.tLoadAddress() && msg.sender != owner() && !hasAnyRole(msg.sender, REBALANCER_ROLE))
    {
      revert Unauthorized();
    }
  }

  /// @dev Transient reentrancy guard, with the body behind function calls: the guard sits on
  ///      nearly every entry point, and inlining it at each one costs contract size. The
  ///      error signature matches Solady's ReentrancyGuardTransient, keeping the selector
  ///      tooling knows.
  modifier nonReentrant() {
    _nonReentrantBefore();
    _;
    _nonReentrantAfter();
  }

  /// @dev Reverts when a guarded call is already on the stack, then flags the guard slot.
  function _nonReentrantBefore() private {
    if (REENTRANCY_TSLOT.tLoadUint() != 0) revert LibRetargetterErrors.Reentrancy();
    REENTRANCY_TSLOT.tStoreUint(1);
  }

  /// @dev Clears the guard slot.
  function _nonReentrantAfter() private {
    REENTRANCY_TSLOT.tStoreUint(0);
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
    _QUOTER = quoter_;
    _REQUEST_FACTORY = requestFactory_;
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
  ///      zero mint-to-repaid delay. That delay exists to keep a Request consumer from minting
  ///      disproportionate yield tokens right before repayment; here the minting paths are
  ///      boxed in instead: the yield gates cap yield proportional to principal, the principal
  ///      gates cap principal at the live quoter cap (so every pulled asset is capital the
  ///      operation actually uses), the minimum-one-tick rule guarantees lenders a full tick
  ///      of yield, and the consumption window closes capital entry at the tick threshold or
  ///      the first pull of funds, whichever comes first. A nonzero delay would instead let a
  ///      late authorized mint push settlement back. The deadline is mirrored into the
  ///      operation storage (the Request does not expose it) so the loan clock can only
  ///      start while at least MIN_DEADLINE_BUFFER remains before it; see
  ///      {LibStorage.checkConsumptionWindow}. The Retargetter becomes the Request's owner,
  ///      puller and consumer.
  function startRetargetting(
    address positionManager,
    uint256 principal,
    uint16 maxYieldBps_,
    address fund,
    string calldata requestName,
    string calldata requestSymbol
  ) external onlyOwnerOrRebalancer nonReentrant returns (address request) {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    _checkStart(operation_, positionManager, fund, principal);

    uint16 configCap = LibStorage.configStorage().maxYieldBps;
    uint16 effectiveYieldCap = maxYieldBps_ < configCap ? maxYieldBps_ : configCap;

    // Safe: block.timestamp + 90 days fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    uint40 repaymentDeadline = uint40(block.timestamp + REPAYMENT_DEADLINE_OFFSET);

    (request,,) = IRequestFactory(_REQUEST_FACTORY)
      .createRequest(
        address(this),
        address(this),
        address(this),
        LibStorage.assetsStorage().debtAsset,
        requestName,
        requestSymbol,
        repaymentDeadline,
        0
      );

    operation_.positionManager = positionManager;
    operation_.operationMaxYieldBps = effectiveYieldCap;
    operation_.request = request;
    operation_.repaymentDeadline = repaymentDeadline;
    operation_.fund = fund;

    emit RetargettingStarted(positionManager, request, fund, principal, effectiveYieldCap);
  }

  /// @inheritdoc IRetargetter
  /// @dev The yield gate compares the offer's ratio (partial fills keep it), division-free:
  ///      `expectedReturn * BPS <= amount * operationMaxYieldBps`. The gate is flat because
  ///      repayment itself is duration-prorated by the tick formula. The principal gate is
  ///      cumulative through the Request's PT supply plus the outstanding mint authorizations,
  ///      which together are the complete capital accounting for the Request.
  function consume(Offer calldata offer, bytes calldata signature, uint256 ptAmount)
    external
    onlyOwnerOrRoles(CONSUMER_ROLE)
    nonReentrant
    returns (uint256 ytAmount)
  {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    address request = operation_.checkRequest();
    operation_.checkOffer(
      request, offer.amount, offer.expectedReturn, ptAmount, maxPrincipal(operation_.positionManager)
    );
    ytAmount = IRequest(request).consume(offer, signature, ptAmount);
    emit OfferConsumed(request, offer.maker, ptAmount, ytAmount);
  }

  /// @inheritdoc IRetargetter
  /// @dev Shares consume's gates: the flat yield-ratio gate on the authorized amounts and the
  ///      principal gate counting the PT supply plus every outstanding authorization (the
  ///      account's current one is replaced, not added to). A nonzero authorization starts the
  ///      loan clock, must land inside the consumption window and is capped in count by
  ///      MAX_AUTHORIZED_ACCOUNTS; the zero-amount revocation skips every gate because it
  ///      only shrinks exposure and must stay available after the window closes.
  function authorizeMinting(address to, uint128 ptAmount, uint128 ytAmount)
    external
    onlyOwnerOrRoles(CONSUMER_ROLE)
    nonReentrant
  {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    address request = operation_.checkRequest();
    // Replace semantics: drop the account from the set so the principal gate sizes the new
    // amounts as fresh capital; a full revocation (both amounts zero) skips every gate, since
    // it only shrinks exposure and must stay available once the window has closed
    EnumerableSetLib.AddressSet storage accounts = operation_.authorizedAccounts;
    accounts.remove(to);
    if (ptAmount != 0 || ytAmount != 0) {
      operation_.checkOffer(request, ptAmount, ytAmount, ptAmount, maxPrincipal(operation_.positionManager));
      // The capacity bound keeps every loop over the set within gas reach; see the constant
      accounts.add(to, MAX_AUTHORIZED_ACCOUNTS);
    }
    IRequest(request).authorizeMinting(to, ptAmount, ytAmount);
    emit MintingAuthorized(request, to, ptAmount, ytAmount);
  }

  /// @inheritdoc IRetargetter
  /// @dev Naturally bounded by the Request's balance, which the principal cap already bounded.
  function pullRequestFunds(uint256 amount) external onlyOwnerOrRebalancer nonReentrant {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    address request = operation_.checkRequest();
    // Pulling is the point of no return for the funding round: capital entry shuts and every
    // pending authorization is revoked, so funds being deployed can no longer be diluted
    operation_.closeConsumption(request);
    if (amount == FULL_BALANCE_SENTINEL) amount = LibStorage.assetsStorage().debtAsset.balanceOf(request);
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
  ///      settling after that point cannot be delivered to lenders locally. The expiry
  ///      bypassing the local repayment flow is an acknowledged limitation and, like the
  ///      expiry itself, delivery of late proceeds runs through the governed upgrade path;
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
  ///      cannot grief settlement; anything above is folded into the position with a
  ///      full-balance rebalance leg, except a debt-asset donation beyond the outstanding
  ///      module debt, which the owner instead tolerates by raising the asset's residual
  ///      exponent so it folds into the next operation).
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
    (, address fund, Order memory order_) = _liveOrder();
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
    (RetargetterOperation storage operation_, address fund, Order memory order_) = _liveOrder();
    State state_;
    (state_, amountOut) = IFund(fund).unlock(order_);
    if (state_ == State.ENDED) operation_.clearOrder();
    emit OrderUnlocked(fund, order_);
  }

  /// @inheritdoc IRetargetter
  function cancelOrder() external onlyOwnerOrRebalancer nonReentrant {
    (RetargetterOperation storage operation_, address fund, Order memory order_) = _liveOrder();
    IFund(fund).cancel(order_);
    operation_.clearOrder();
    emit OrderCanceled(fund, order_);
  }

  /// @inheritdoc IRetargetter
  /// @dev Partial recoveries leave the order live for a later call; the order is cleared once
  ///      the fund reports ENDED.
  function recoverOrder() external onlyOwnerOrRebalancer nonReentrant returns (uint256 amountIn) {
    (RetargetterOperation storage operation_, address fund, Order memory order_) = _liveOrder();
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
  ///      A sentinel resolving to zero (an empty balance, or a REPAY leg on a debt-free
  ///      module) produces a zero-amount leg, which the borrow modules reject; the whole
  ///      call reverts atomically.
  function rebalance(RebalancingData calldata data) external onlyOwnerOrRebalancer nonReentrant {
    address positionManager = LibStorage.operationStorage().checkActive();
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
    address collateralAsset = assets_.collateralAsset;
    address debtAsset = assets_.debtAsset;

    // Resolve the full-balance sentinels in memory before calling the position manager.
    // Input legs resolve to the current balance of the corresponding asset; a REPAY leg is
    // further capped at its module's live debt, because the borrow modules forward the
    // amount to the venue verbatim and venues reject repayments above the outstanding debt,
    // so an uncapped balance could never be folded once it exceeds what the module owes.
    // The module reports that debt rounded down, so a capped repayment can leave one or
    // more wei of debt behind rather than clearing the module exactly. The sentinel is
    // rejected on output legs (BORROW, WITHDRAW). Resolution is one snapshot taken before
    // any leg executes: sentinels do not compose, so every leg resolves against the same
    // pre-call balances, never the state left by earlier legs, and REPAY sentinels across
    // several modules can together commit more than the shared balance.
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
        resolved.operations[i].amount =
          debtBalance.min(IBorrowPosition(resolved.operations[i].position).totalBorrowed());
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
    _checkStart(operation_, positionManager, fund, flashLoanAmount);
    if (!LibStorage.whitelistsStorage().flashLoanModules[flashLoanModule]) {
      revert LibRetargetterErrors.ModuleNotWhitelisted();
    }

    // Open the window: the operation storage carries the addresses the steps read (and locks
    // out nested starts); the window slot hands step authority to the module alone for the
    // whole window, while the module slot authenticates the callback and is zeroed on its
    // entry (single-shot), which is why the module address lives in both
    operation_.positionManager = positionManager;
    operation_.fund = fund;
    WINDOW_TSLOT.tStoreAddress(flashLoanModule);
    MODULE_TSLOT.tStoreAddress(flashLoanModule);
    AMOUNT_TSLOT.tStoreUint(flashLoanAmount);

    address debtAsset = LibStorage.assetsStorage().debtAsset;
    IFlashLoanModule(flashLoanModule).flashLoan(debtAsset, flashLoanAmount, abi.encode(data));

    // The module has pulled its repayment; close the window and scrub any leftover approval
    WINDOW_TSLOT.tStoreAddress(address(0));
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
  ///      flows through the window slot holding the module address.
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
  ///      operation start. Removal is blocked while the fund is bound to the active operation.
  function setFund(address fund, bool whitelisted) external onlyOwner nonReentrant {
    if (whitelisted) {
      fund.checkContract();
      RetargetterAssets storage assets_ = LibStorage.assetsStorage();
      if (IFund(fund).asset() != assets_.debtAsset || IFund(fund).share() != assets_.collateralAsset) {
        revert LibRetargetterErrors.AssetMismatch();
      }
    } else if (LibStorage.operationStorage().fund == fund) {
      revert LibRetargetterErrors.OperationActive();
    }
    LibStorage.whitelistsStorage().funds[fund] = whitelisted;
    emit FundSet(fund, whitelisted);
  }

  /// @inheritdoc IRetargetter
  /// @dev Removable any time: an open window binds its module for the transaction through
  ///      the transient slots, not the whitelist.
  function setFlashLoanModule(address module, bool whitelisted) external onlyOwner nonReentrant {
    if (whitelisted) module.checkContract();
    LibStorage.whitelistsStorage().flashLoanModules[module] = whitelisted;
    emit FlashLoanModuleSet(module, whitelisted);
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
      uint40 repaymentDeadline,
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
      operation_.repaymentDeadline,
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
    RetargetterConfig storage config_ = LibStorage.configStorage();
    // The estimates pack into a single slot, so one copy into memory beats a storage
    // pointer re-reading the slot for every field passed to the quoter
    YieldEstimates memory estimates = config_.estimates;
    uint256 principal = IRetargetterQuoter(_QUOTER)
      .retargetPrincipal(
        collateralQuoted,
        debt,
        target,
        estimates.requestYieldRate,
        estimates.borrowRate,
        estimates.collateralYieldRate,
        estimates.subscriptionDuration,
        estimates.redemptionDuration
      );
    return principal * (BPS + config_.principalBufferBps) / BPS;
  }

  /// @inheritdoc IRetargetter
  function owed() external view returns (uint256) {
    RetargetterOperation storage operation_ = LibStorage.operationStorage();
    operation_.checkRequest();
    return _owed(operation_);
  }

  /// @inheritdoc IRetargetter
  function authorizedAccounts() external view returns (address[] memory accounts) {
    return LibStorage.operationStorage().authorizedAccounts.values();
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
    return _QUOTER;
  }

  /// @inheritdoc IRetargetter
  function requestFactory() external view returns (address) {
    return _REQUEST_FACTORY;
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

  /// @dev Shared start gate of both entry points. One operation at a time: the position
  ///      manager doubles as the active flag, and a SYNC window keeps it populated, so this
  ///      also locks out starts smuggled into a window payload. No leftover order, matching
  ///      asset pair, whitelisted fund, and the requested amount within the live principal
  ///      cap (fail-fast for ASYNC, where the binding check re-runs at every consume).
  function _checkStart(RetargetterOperation storage operation_, address positionManager, address fund, uint256 amount)
    internal
    view
  {
    if (operation_.positionManager != address(0)) revert LibRetargetterErrors.OperationActive();
    if (operation_.orderLive) revert LibRetargetterErrors.OrderActive();
    _checkPair(positionManager);
    if (!LibStorage.whitelistsStorage().funds[fund]) revert LibRetargetterErrors.FundNotWhitelisted();
    if (amount > maxPrincipal(positionManager)) revert LibRetargetterErrors.PrincipalCapExceeded();
  }

  /// @dev Shared preamble of the wrappers acting on the live order: requires an active
  ///      operation and a stored order, returning the operation, its fund and the rebuilt
  ///      order.
  function _liveOrder()
    internal
    view
    returns (RetargetterOperation storage operation_, address fund, Order memory order_)
  {
    operation_ = LibStorage.operationStorage();
    operation_.checkActive();
    fund = operation_.fund;
    if (!operation_.orderLive) revert LibRetargetterErrors.NoOrder();
    order_ = operation_.order();
  }

  /// @dev Reverts unless the position manager's assets equal the bound pair. The fund's
  ///      tokens were validated against the pair at setFund and the Request is created with
  ///      the debt asset, so a matching position manager makes the whole operation match.
  function _checkPair(address positionManager) internal view {
    RetargetterAssets storage assets_ = LibStorage.assetsStorage();
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();
    if (collateralAsset != assets_.collateralAsset || debtAsset != assets_.debtAsset) {
      revert LibRetargetterErrors.AssetMismatch();
    }
  }

  /// @dev Current owed amount on the operation's Request. The supplies only grow through
  ///      consume and authorized mints, both reachable only once the loan clock has started,
  ///      so with startedAt still zero both supplies are zero and the owed amount is zero
  ///      regardless of the elapsed time.
  function _owed(RetargetterOperation storage operation_) internal view returns (uint256) {
    (uint128 ptSupply, uint128 ytSupply) = ITokenController(operation_.request).totalSupplies();
    RetargetterConfig storage config_ = LibStorage.configStorage();
    return IRetargetterQuoter(_QUOTER)
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
  ///      Everything above must have returned to the position manager or the Request, or be
  ///      folded into the position through the full-balance rebalance legs; a debt-asset
  ///      donation beyond what those legs can repay is tolerated by the owner raising the
  ///      asset's residual exponent instead. Tolerated dust stays here and folds into the
  ///      next operation through the full-balance sentinels.
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
}
