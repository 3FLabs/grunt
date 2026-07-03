// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {IWildcatFund} from "../../interfaces/funds/wildcat/IWildcatFund.sol";
import {IWildcatMarket, WithdrawalBatch} from "../../interfaces/integrations/wildcat/IWildcatMarket.sol";
import {IWildcat4626Wrapper} from "../../interfaces/integrations/wildcat/IWildcat4626Wrapper.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {Order, State, Mode, LibOrder} from "../../libs/funds/Order.sol";
import {LibFundsErrors} from "../../libs/funds/LibFundsErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {BPS, RAY} from "../../libs/Constants.sol";

/// @title WildcatFund
/// @author 3F Protocol
/// @notice Wrapper of a Wildcat V2 private-credit market (e.g. Wintermute Trading USD Coin, wmtUSDC).
/// @dev - The Wildcat market token is rebasing (balances grow with a ray-scaled `scaleFactor`), so it
///        cannot back the strictly 1:1 WrappedAsset directly. Instead, shares of this fund are
///        represented by WrappedAsset tokens wrapping the market's official ERC-4626 wrapper
///        (Wildcat4626Wrapper), whose shares mirror the market's scaled balances and are therefore
///        non-rebasing and price-appreciating (1 share = scaleFactor / 1e27 underlying).
///      - The order owner and receiver is always msg.sender (the depositor contract).
///      - Deposits are synchronous: `market.deposit()` then wrap into the ERC-4626 wrapper.
///        Redemptions are queued: unwrap to market tokens, `queueWithdrawal()` into a batch keyed
///        by an expiry timestamp, then claim via `executeWithdrawal()` once expired. Batches are
///        paid pro-rata from market liquidity and may be paid across multiple partial payments if
///        the borrower is delinquent, so REDEEM orders support partial unlocks
///        (UNLOCKING -> PROCESSING -> UNLOCKING -> ... -> ENDED).
///      - No recovery flow: deposits are atomic (succeed or revert), and queued withdrawals cannot
///        be canceled upstream. Orders stuck in PROCESSING can be force-ended by an operator.
///      - This contract uses an "internal state" pattern where the stored state (internalState) may
///        differ from the state returned by the public state() function. The state() function
///        queries the market to determine state transitions (e.g., PROCESSING -> UNLOCKING when a
///        withdrawal batch becomes claimable).
///      - Access: the market's hooks contract may require a deposit credential. Markets with an
///        open-access pull provider (like wmtUSDC) credential any non-sanctioned account
///        automatically; others need the borrower to grant one to this fund (one-time onboarding
///        per deployment) before the first commit. After a first deposit the fund is a "known
///        lender" and can always queue withdrawals.
///      - The same implementation supports any Wildcat V2 market: deploy one fund (and one
///        WrappedAsset) per market via the factory. When a single WrappedAsset backs multiple
///        WildcatFund instances on the same market, total assets are shared across them (see
///        `totalAssets()`).
contract WildcatFund is IWildcatFund, OwnableRoles, Initializable {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using LibChecks for address;
  using LibChecks for uint256;
  using LibOrder for Order;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for operator.
  uint256 internal constant OPERATOR_ROLE = _ROLE_0;

  /// @notice Role for depositor.
  uint256 internal constant DEPOSITOR_ROLE = _ROLE_1;

  /// @notice Maximum allowed deviation between order output and current rate (in basis points).
  /// @dev 10_000 = 100%. E.g., 500 = 5% max deviation below current rate.
  uint256 public constant MAX_OUTPUT_DEVIATION = 500; // 5%

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the WildcatFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility.
  /// @param market The Wildcat V2 market address (the rebasing market token).
  /// @param internalState The stored internal state; may differ from the dynamic state returned by `state()`.
  /// @param batchExpiry The withdrawal batch expiry of the current REDEEM order (0 for DEPOSIT orders).
  /// @param hasResolvedAmounts Whether the operator has set resolved input/output amounts via resolve().
  /// @param wrapper The official Wildcat ERC-4626 wrapper over the market token.
  /// @param wrappedShare The WrappedAsset contract that wraps the ERC-4626 wrapper shares.
  /// @param asset The underlying asset of the market (e.g. USDC).
  /// @param currentOrderId The order ID of the current (or most recent) order.
  /// @param resolvedOutput The resolved output amount (if hasResolvedAmounts is true).
  /// @param depositReceived The ERC-4626 wrapper shares received during commit() for a DEPOSIT order.
  /// @param batchPaidOut The batch proceeds already forwarded to the receiver for the current
  ///        REDEEM order (mirrors the market's per-batch `normalizedAmountWithdrawn` counter).
  /// @param endedOrders Tracks order IDs that have reached ENDED so historical lookups return ENDED.
  struct WildcatFundStorage {
    address market;
    State internalState;
    uint32 batchExpiry;
    bool hasResolvedAmounts;
    address wrapper;
    address wrappedShare;
    address asset;
    bytes32 currentOrderId;
    uint256 resolvedOutput;
    uint256 depositReceived;
    uint256 batchPaidOut;
    mapping(bytes32 => bool) endedOrders;
  }

  /// @dev Storage slot for the WildcatFund contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("wildcat.fund")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0x094560e47f6cda980a0b9be91ad9b6256e8b62ff4107294c9fab4e6c012c6c00;

  /// @dev Returns a reference to the contract's storage struct.
  function _wildcatFundStorage() internal pure returns (WildcatFundStorage storage wildcatFundStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      wildcatFundStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Disables initializers on the implementation contract to prevent misuse.
  constructor() {
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IWildcatFund
  function initialize(address owner_, address depositor_, address wrapper_, address wrappedShare_)
    public
    override
    initializer
  {
    owner_.checkNotZero();
    depositor_.checkContract();
    wrapper_.checkContract();
    wrappedShare_.checkContract();

    // Verify wrappedShare wraps the ERC-4626 wrapper's shares
    if (IWrappedAsset(wrappedShare_).underlying() != wrapper_) {
      revert LibFundsErrors.InvalidUnderlyingAsset();
    }

    address _market = IWildcat4626Wrapper(wrapper_).market();
    _market.checkContract();

    WildcatFundStorage storage $ = _wildcatFundStorage();
    $.market = _market;
    $.wrapper = wrapper_;
    $.wrappedShare = wrappedShare_;
    $.asset = IWildcatMarket(_market).asset();

    _initializeOwner(owner_);
    _setRoles(depositor_, DEPOSITOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  /// @dev Hook-level policies (deposit credential, minimum deposit) are market-specific and are
  ///      not pre-checked here; a commit violating them reverts and the order can be canceled.
  ///      For DEPOSIT orders, `order.output` should be set slightly below the shares expected at
  ///      the current rate: the scaleFactor accrues interest every second, so a commit landing in
  ///      a later block always receives marginally fewer shares than quoted at create time.
  function create(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    order.input.checkNotZero();
    _checkOrderOwner(order);
    if (order.receiver != msg.sender) revert LibFundsErrors.InvalidReceiver();

    WildcatFundStorage storage $ = _wildcatFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) revert LibFundsErrors.PendingOrder();

    IWildcatMarket _market = IWildcatMarket($.market);

    // Refuse orders that would always revert at commit() time.
    if (order.mode == Mode.DEPOSIT) {
      if (_market.isClosed()) revert LibFundsErrors.MarketClosed();
      if (order.input > _market.maximumDeposit()) revert LibFundsErrors.DepositCapExceeded();
    }

    if (_internalState == State.ENDED) {
      // Archive ended order
      $.endedOrders[$.currentOrderId] = true;
    }

    // Slippage guard: reject if expected output deviates too far below the current rate.
    // DEPOSIT: input is underlying, output is wrapper shares (scaled units).
    // REDEEM: input is wrapper shares, output is underlying.
    uint256 _scaleFactor = _market.scaleFactor();
    uint256 _expectedOutput =
      order.mode == Mode.DEPOSIT ? order.input.mulDiv(RAY, _scaleFactor) : order.input.mulDiv(_scaleFactor, RAY);

    if (order.output < _expectedOutput) {
      if (_expectedOutput - order.output > _expectedOutput * MAX_OUTPUT_DEVIATION / BPS) {
        revert LibFundsErrors.InvalidOutput();
      }
    }

    bytes32 _orderId = order.toId(address(this));
    if ($.endedOrders[_orderId]) revert LibFundsErrors.OrderAlreadyExists(_orderId);
    $.currentOrderId = _orderId;
    $.internalState = State.ACCEPTED;
    $.hasResolvedAmounts = false;
    $.resolvedOutput = 0;
    $.depositReceived = 0;
    $.batchExpiry = 0;
    $.batchPaidOut = 0;

    emit OrderCreated(_orderId, order.mode, order.owner, order.receiver, order.input, order.output);

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function cancel(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    _checkOrderOwner(order);

    WildcatFundStorage storage $ = _wildcatFundStorage();
    bytes32 _orderId = order.toId(address(this));
    if (_orderId != $.currentOrderId) revert LibFundsErrors.InvalidOrder(_orderId);

    State _internalState = $.internalState;
    if (_internalState != State.ACCEPTED && _internalState != State.PENDING) {
      revert LibFundsErrors.InvalidState(_internalState);
    }

    $.currentOrderId = bytes32(0);
    $.internalState = State.EMPTY;

    emit OrderCanceled(_orderId, order.mode, order.owner);

    return State.EMPTY;
  }

  /// @inheritdoc IFund
  function commit(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    WildcatFundStorage storage $ = _wildcatFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert LibFundsErrors.InvalidState($.internalState);

    address _market = $.market;
    address _wrapper = $.wrapper;

    if (order.mode == Mode.DEPOSIT) {
      // Pull underlying asset from depositor and deposit into the market (exact amount:
      // market.deposit reverts if the full input cannot be minted).
      address _asset = $.asset;
      _asset.safeTransferFrom(msg.sender, address(this), order.input);
      _asset.safeApproveWithRetry(_market, order.input);
      uint256 _before = IERC20(_market).balanceOf(address(this));
      IWildcatMarket(_market).deposit(order.input);
      uint256 _received = IERC20(_market).balanceOf(address(this)) - _before;
      _asset.safeApproveWithRetry(_market, 0);

      // Wrap the rebasing market tokens into non-rebasing ERC-4626 wrapper shares.
      _market.safeApproveWithRetry(_wrapper, _received);
      $.depositReceived = IWildcat4626Wrapper(_wrapper).deposit(_received, address(this));
      _market.safeApproveWithRetry(_wrapper, 0);
    } else {
      // Burn WrappedAsset from depositor (unwraps to ERC-4626 wrapper shares held by this contract)
      IWrappedAsset($.wrappedShare).burn(msg.sender, address(this), order.input);
      // Unwrap to market tokens and queue the withdrawal into the current batch
      uint256 _assets = IWildcat4626Wrapper(_wrapper).redeem(order.input, address(this), address(this));
      $.batchExpiry = IWildcatMarket(_market).queueWithdrawal(_assets);
    }

    $.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrderId, order.mode, order.input);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev REDEEM orders support partial unlocks: withdrawal batches are paid pro-rata from market
  ///      liquidity and may take multiple payments (borrower repayments) to be fully paid.
  ///      Proceeds are credited from the market's per-batch `normalizedAmountWithdrawn` counter,
  ///      which also captures amounts pushed here by third parties calling the permissionless
  ///      `market.executeWithdrawal()` directly, while never crediting funds belonging to other
  ///      batches (e.g. a force-ended order's late payments) or plain donations.
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    WildcatFundStorage storage $ = _wildcatFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.UNLOCKING) revert LibFundsErrors.InvalidState(_currentState);

    State _newState;
    if (order.mode == Mode.DEPOSIT) {
      // Wrap ERC-4626 wrapper shares into WrappedAsset and send to receiver
      // (_amount already holds $.depositReceived, returned by _state above)
      address _wrapper = $.wrapper;
      address _wrappedShare = $.wrappedShare;
      _wrapper.safeApproveWithRetry(_wrappedShare, _amount);
      IWrappedAsset(_wrappedShare).mint(order.receiver, _amount);
      _wrapper.safeApproveWithRetry(_wrappedShare, 0);
      _newState = State.ENDED;
    } else {
      IWildcatMarket _market = IWildcatMarket($.market);
      uint32 _expiry = $.batchExpiry;
      // Claim whatever the batch can currently pay us (if anything). Claims may also have
      // been pushed here by third parties via the permissionless executeWithdrawal.
      if (_market.getAvailableWithdrawalAmount(address(this), _expiry) > 0) {
        _market.executeWithdrawal(address(this), _expiry);
      }
      // Credit exactly this order's batch proceeds: the market's per-batch counter tracks
      // everything ever paid to this contract for the batch, regardless of who executed.
      uint256 _withdrawn = _market.getAccountWithdrawalStatus(address(this), _expiry).normalizedAmountWithdrawn;
      _amount = _withdrawn - $.batchPaidOut;
      $.batchPaidOut = _withdrawn;
      $.asset.safeTransfer(order.receiver, _amount);

      // The order ends once the batch is fully paid; otherwise it returns to PROCESSING
      // and unlocks again as the borrower repays.
      WithdrawalBatch memory _batch = _market.getWithdrawalBatch(_expiry);
      _newState = _batch.scaledAmountBurned == _batch.scaledTotalAmount ? State.ENDED : State.PROCESSING;
    }

    $.internalState = _newState;

    emit OrderUnlocked(_currentOrderId, order.mode, _amount, order.receiver);

    return (_newState, _amount);
  }

  /// @inheritdoc IFund
  /// @dev No recovery flow: deposits are atomic (market.deposit succeeds or reverts in the same tx),
  ///      and queued withdrawals cannot be canceled in the Wildcat market.
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);
    // Always revert: recovery is not applicable for Wildcat markets
    revert LibFundsErrors.RecoverNotSupported();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IWildcatFund
  function resolve(Order memory order, uint256 input, uint256 output)
    external
    override
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    // Only DEPOSIT orders use resolved amounts: REDEEM progression is driven purely by the
    // withdrawal batch's expiry and payments, so resolving one would be a misleading no-op.
    if (order.mode != Mode.DEPOSIT) revert LibFundsErrors.ResolveNotSupported();

    WildcatFundStorage storage $ = _wildcatFundStorage();
    if ($.internalState != State.PROCESSING) {
      revert LibFundsErrors.InvalidState($.internalState);
    }
    if (order.toId(address(this)) != $.currentOrderId) {
      revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    }

    $.hasResolvedAmounts = true;
    $.resolvedOutput = output;

    emit OrderResolved($.currentOrderId, input, output, msg.sender);
  }

  /// @inheritdoc IWildcatFund
  function forceEnd(Order calldata order) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    WildcatFundStorage storage $ = _wildcatFundStorage();
    bytes32 _orderId = order.toId(address(this));
    if (_orderId != $.currentOrderId) {
      revert LibFundsErrors.InvalidOrder(_orderId);
    }

    // Deposits are atomic: a stuck DEPOSIT always holds its wrapper shares and must be
    // completed via resolve() + unlock(), never abandoned.
    if (order.mode == Mode.DEPOSIT) revert LibFundsErrors.ForceEndNotSupported();

    // A batch that has not expired yet is not stuck: it always pays (at least partially)
    // at expiry. Force-ending it early would strand a redemption that was on track.
    if (block.timestamp <= $.batchExpiry) revert LibFundsErrors.BatchNotExpired();

    // Only orders stuck in PROCESSING (expired batch, nothing currently retrievable) can be
    // force-ended: retrievable amounts must be drained via unlock() first.
    (State _currentState,) = _state(order);
    if (_currentState != State.PROCESSING) {
      revert LibFundsErrors.InvalidState(_currentState);
    }

    $.internalState = State.ENDED;

    emit OrderForceEnded(_orderId, msg.sender);
  }

  /// @inheritdoc IWildcatFund
  function rescueTokens(address token, address to) external override onlyOwner {
    to.checkNotZero();

    WildcatFundStorage storage $ = _wildcatFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) {
      revert LibFundsErrors.InvalidState(_internalState);
    }

    uint256 _amount = IERC20(token).balanceOf(address(this));
    token.safeTransfer(to, _amount);

    emit TokensRescued(token, to, _amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IWildcatFund
  function market() external view override returns (address) {
    return _wildcatFundStorage().market;
  }

  /// @inheritdoc IWildcatFund
  function wrapper() external view override returns (address) {
    return _wildcatFundStorage().wrapper;
  }

  /// @inheritdoc IWildcatFund
  function currentBatchExpiry() external view override returns (uint32) {
    return _wildcatFundStorage().batchExpiry;
  }

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return _wildcatFundStorage().asset;
  }

  /// @inheritdoc IFund
  function share() external view override returns (address) {
    return _wildcatFundStorage().wrappedShare;
  }

  /// @inheritdoc IFund
  /// @dev Converts total wrapped share supply to underlying using the ERC-4626 wrapper rate
  ///      (the market's scaleFactor). Market tokens are normalized 1:1 with the underlying asset.
  ///      The returned value is derived from `$.wrappedShare.totalSupply()`, so when a single
  ///      `WrappedAsset` deployment backs multiple `WildcatFund` instances, every instance
  ///      reports the same wrapper-wide aggregate AUM rather than AUM scoped to this fund.
  function totalAssets() external view override returns (uint256) {
    WildcatFundStorage storage $ = _wildcatFundStorage();
    return IWildcat4626Wrapper($.wrapper).convertToAssets(IERC20($.wrappedShare).totalSupply());
  }

  /// @inheritdoc IFund
  /// @dev Bounded by the market's remaining capacity (maxTotalSupply). Hook-level minimum
  ///      deposit requirements are market-specific and not reflected here.
  function maxDeposit(address account) external view override returns (uint256) {
    if (!hasAllRoles(account, DEPOSITOR_ROLE)) return 0;
    WildcatFundStorage storage $ = _wildcatFundStorage();
    IWildcatMarket _market = IWildcatMarket($.market);
    if (_market.isClosed()) return 0;
    return IERC20($.asset).balanceOf(account).min(_market.maximumDeposit());
  }

  /// @inheritdoc IFund
  function maxRedeem(address account) external view override returns (uint256) {
    return hasAllRoles(account, DEPOSITOR_ROLE) ? IERC20(_wildcatFundStorage().wrappedShare).balanceOf(account) : 0;
  }

  /// @inheritdoc IFund
  function state(Order calldata order) public view override returns (State) {
    WildcatFundStorage storage $ = _wildcatFundStorage();
    bytes32 _orderId = order.toId(address(this));

    // Return ENDED for archived orders
    if ($.endedOrders[_orderId]) {
      return State.ENDED;
    }

    // Return EMPTY to indicate this order doesn't exist
    if (_orderId != $.currentOrderId) {
      return State.EMPTY;
    }

    (State _currentState,) = _state(order);
    return _currentState;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Internal function that returns both the dynamic state and the associated amount.
  ///      Queries the market to determine state transitions.
  ///
  ///      For PROCESSING + DEPOSIT:
  ///      - Checks `depositReceived >= order.output` (or the resolved output) -> UNLOCKING
  ///
  ///      For PROCESSING + REDEEM:
  ///      - Before the batch expiry: PROCESSING (funds not claimable yet).
  ///      - After expiry: UNLOCKING when something is retrievable, i.e. the batch can pay us
  ///        (`getAvailableWithdrawalAmount > 0`) or proceeds were already pushed here by a
  ///        third-party `executeWithdrawal` call (permissionless) but not yet forwarded
  ///        (per-batch `normalizedAmountWithdrawn` exceeds `batchPaidOut`).
  ///      - Otherwise stays PROCESSING (batch unpaid, waiting on borrower repayment).
  ///
  ///      For all other states, returns internalState directly.
  function _state(Order calldata order) internal view returns (State, uint256) {
    WildcatFundStorage storage $ = _wildcatFundStorage();

    State _internalState = $.internalState;

    if (_internalState == State.PROCESSING) {
      if (order.mode == Mode.DEPOSIT) {
        uint256 _expectedOutput = $.hasResolvedAmounts ? $.resolvedOutput : order.output;
        uint256 _received = $.depositReceived;
        return _received >= _expectedOutput ? (State.UNLOCKING, _received) : (State.PROCESSING, 0);
      } else {
        uint32 _expiry = $.batchExpiry;
        // getAvailableWithdrawalAmount reverts while the batch has not expired
        if (block.timestamp <= _expiry) return (State.PROCESSING, 0);

        // Retrievable = what the batch can pay us now + what was already pushed here by
        // third-party executeWithdrawal calls but not yet forwarded to the receiver.
        IWildcatMarket _market = IWildcatMarket($.market);
        uint256 _retrievable = _market.getAvailableWithdrawalAmount(address(this), _expiry)
          + _market.getAccountWithdrawalStatus(address(this), _expiry).normalizedAmountWithdrawn - $.batchPaidOut;
        return _retrievable > 0 ? (State.UNLOCKING, _retrievable) : (State.PROCESSING, 0);
      }
    }

    return (_internalState, 0);
  }

  /// @dev Reverts if the order owner is not the caller.
  /// @param order The given order.
  function _checkOrderOwner(Order calldata order) internal view {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();
  }
}
