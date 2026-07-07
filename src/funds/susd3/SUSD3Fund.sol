// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {ISUSD3Fund} from "../../interfaces/funds/susd3/ISUSD3Fund.sol";
import {ISUSD3} from "../../interfaces/integrations/susd3/ISUSD3.sol";
import {IUSD3} from "../../interfaces/integrations/susd3/IUSD3.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {Order, State, Mode, LibOrder} from "../../libs/funds/Order.sol";
import {LibFundsErrors} from "../../libs/funds/LibFundsErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {BPS} from "../../libs/Constants.sol";

/// @title SUSD3Fund
/// @author 3F Protocol
/// @notice Wrapper of the sUSD3 (staked USD3) subordinate tranche strategy.
/// @dev - The fund's accounting asset is USDC, but sUSD3 stakes USD3, which itself wraps USDC.
///        Deposits therefore convert USDC -> USD3 -> sUSD3, and redemptions sUSD3 -> USD3 -> USDC,
///        via two chained ERC-4626 conversions.
///      - Shares of this fund are represented by WrappedAsset tokens wrapping the sUSD3 share token.
///      - The order owner and receiver is always msg.sender (the depositor contract).
///      - Deposit commits stake synchronously (USDC -> USD3 -> sUSD3). Delivery of the wrapped shares
///        is immediate when sUSD3 applies no deposit lock, or deferred until the lock elapses when one
///        is active (the fund holds the staked sUSD3 meanwhile, gated by the per-account
///        `sUSD3.lockedUntil`). Redemptions are async: commit starts the sUSD3 cooldown, and unlock
///        claims once the cooldown has matured (`sUSD3.maxRedeem(this) > 0`).
///      - Recovery is operator-driven: cancelRedeem() cancels the cooldown (PROCESSING -> RECOVERING),
///        then recover() re-wraps the still-held sUSD3 back to the receiver. Only REDEEM orders recover.
///        Deposit commits are atomic, but delivery may stay in PROCESSING while a lock or output
///        shortfall is outstanding. A DEPOSIT that yields fewer sUSD3 shares than `order.output` stays
///        in PROCESSING until an operator lowers the threshold via resolve().
///      - This contract uses an "internal state" pattern where the stored state (internalState) may
///        differ from the state returned by the public state() function, which queries sUSD3 to detect
///        the PROCESSING -> UNLOCKING transition.
contract SUSD3Fund is ISUSD3Fund, OwnableRoles, Initializable {
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

  /// @notice Storage struct containing all persistent state for the SUSD3Fund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility.
  /// @param susd3 The sUSD3 (staked USD3) strategy address (the "vault").
  /// @param internalState The stored internal state; may differ from the dynamic state returned by `state()`.
  /// @param usd3 The intermediate USD3 strategy address (sUSD3's underlying asset).
  /// @param asset The base accounting asset (USDC), USD3's underlying.
  /// @param wrappedShare The WrappedAsset contract that wraps the sUSD3 share token.
  /// @param hasResolvedAmounts Whether the operator has overridden the DEPOSIT output threshold via resolve().
  /// @param currentOrderId The order ID of the current (or most recent) order.
  /// @param depositReceived The sUSD3 shares received during commit() for a DEPOSIT order.
  /// @param pendingRedeemShares The sUSD3 shares the fund holds for the live REDEEM order (source of
  ///        truth for the redeem remainder across partial unlocks and recovery).
  /// @param resolvedOutput The output threshold set by resolve() (used when hasResolvedAmounts is true).
  /// @param endedOrders Tracks order IDs that have reached ENDED so historical lookups return ENDED.
  struct SUSD3FundStorage {
    address susd3;
    State internalState;
    bool hasResolvedAmounts;
    address usd3;
    address asset;
    address wrappedShare;
    bytes32 currentOrderId;
    uint256 depositReceived;
    uint256 pendingRedeemShares;
    uint256 resolvedOutput;
    mapping(bytes32 => bool) endedOrders;
  }

  /// @dev Storage slot for the SUSD3Fund contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("susd3.fund")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0xd63cc11a02da632fb5b68467564e500e196a1d31a6574f58f51073894e8f0b00;

  /// @dev Returns a reference to the contract's storage struct.
  function _susd3FundStorage() internal pure returns (SUSD3FundStorage storage susd3FundStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      susd3FundStorage.slot := _MAIN_STORAGE_SLOT
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

  /// @inheritdoc ISUSD3Fund
  function initialize(address owner_, address depositor_, address susd3_, address wrappedShare_)
    public
    override
    initializer
  {
    owner_.checkNotZero();
    depositor_.checkContract();
    susd3_.checkContract();
    wrappedShare_.checkContract();

    // Verify the wrapped share wraps the sUSD3 share token.
    if (IWrappedAsset(wrappedShare_).underlying() != susd3_) {
      revert LibFundsErrors.InvalidUnderlyingAsset();
    }

    // Derive the token stack: sUSD3.asset() == USD3, USD3.asset() == USDC.
    address _usd3 = ISUSD3(susd3_).asset();
    address _usdc = IUSD3(_usd3).asset();

    // Defensive: this integration targets the all-6-decimals USDC/USD3/sUSD3 stack. The conversion
    // math is decimals-agnostic, but equal decimals documents intent and catches misconfiguration.
    _checkSameDecimals(_usdc, _usd3);
    _checkSameDecimals(_usd3, susd3_);

    SUSD3FundStorage storage $ = _susd3FundStorage();
    $.susd3 = susd3_;
    $.usd3 = _usd3;
    $.asset = _usdc;
    $.wrappedShare = wrappedShare_;

    _initializeOwner(owner_);
    _setRoles(depositor_, DEPOSITOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function create(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    order.input.checkNotZero();
    _checkOrderOwner(order);
    if (order.receiver != msg.sender) revert LibFundsErrors.InvalidReceiver();

    SUSD3FundStorage storage $ = _susd3FundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) revert LibFundsErrors.PendingOrder();

    address _susd3 = $.susd3;
    address _usd3 = $.usd3;

    // Refuse deposits below USD3's minimum deposit. The fund never holds USD3 between orders, so it
    // is always a first-time depositor and USD3 enforces `minDeposit` on every deposit.
    if (order.mode == Mode.DEPOSIT) {
      if (order.input < IUSD3(_usd3).minDeposit()) revert LibFundsErrors.BelowMinDeposit();
    }

    if (_internalState == State.ENDED) {
      // Archive ended order.
      $.endedOrders[$.currentOrderId] = true;
    }

    // Slippage guard: reject if expected output deviates too far below the current rate. Both modes
    // chain two ERC-4626 conversions across USD3 and sUSD3.
    uint256 _expectedOutput = _convertOrder(order.mode, order.input, _usd3, _susd3);
    if (order.output < _expectedOutput) {
      if (_expectedOutput - order.output > _expectedOutput * MAX_OUTPUT_DEVIATION / BPS) {
        revert LibFundsErrors.InvalidOutput();
      }
    }

    bytes32 _orderId = order.toId(address(this));
    if ($.endedOrders[_orderId]) revert LibFundsErrors.OrderAlreadyExists(_orderId);
    $.currentOrderId = _orderId;
    $.internalState = State.ACCEPTED;
    $.depositReceived = 0;
    $.pendingRedeemShares = 0;
    $.hasResolvedAmounts = false;
    $.resolvedOutput = 0;

    emit OrderCreated(_orderId, order.mode, order.owner, order.receiver, order.input, order.output);

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function cancel(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    _checkOrderOwner(order);

    SUSD3FundStorage storage $ = _susd3FundStorage();
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
  /// @dev DEPOSIT stakes synchronously (USDC -> USD3 -> sUSD3); REDEEM starts the sUSD3 cooldown.
  ///      Always goes to PROCESSING.
  function commit(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    SUSD3FundStorage storage $ = _susd3FundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert LibFundsErrors.InvalidState($.internalState);

    address _susd3 = $.susd3;
    if (order.mode == Mode.DEPOSIT) {
      // The USDC -> USD3 leg is always synchronous: USD3 (an ERC-4626 TokenizedStrategy) mints on
      // deposit, has no lock, and its commitment-period transfer guard exempts transfers into sUSD3
      // (staking), so the received USD3 can always be staked immediately. The only async element is
      // sUSD3's deposit lock: when active, the received shares are held here and delivered by
      // unlock() once the per-account lock elapses (see _state) — no lock rejection needed.
      address _asset = $.asset;
      address _usd3 = $.usd3;

      // USDC -> USD3
      _asset.safeTransferFrom(msg.sender, address(this), order.input);
      _asset.safeApproveWithRetry(_usd3, order.input);
      uint256 _usd3Before = IERC20(_usd3).balanceOf(address(this));
      IUSD3(_usd3).deposit(order.input, address(this));
      uint256 _usd3Out = IERC20(_usd3).balanceOf(address(this)) - _usd3Before;
      _asset.safeApproveWithRetry(_usd3, 0);

      // USD3 -> sUSD3
      _usd3.safeApproveWithRetry(_susd3, _usd3Out);
      uint256 _susd3Before = IERC20(_susd3).balanceOf(address(this));
      ISUSD3(_susd3).deposit(_usd3Out, address(this));
      $.depositReceived = IERC20(_susd3).balanceOf(address(this)) - _susd3Before;
      _usd3.safeApproveWithRetry(_susd3, 0);
    } else {
      // Burn wrapped sUSD3 from depositor (unwraps to sUSD3 held by this contract), then start the
      // cooldown on the held shares (no approval/movement needed, owner == this contract).
      IWrappedAsset($.wrappedShare).burn(msg.sender, address(this), order.input);
      ISUSD3(_susd3).startCooldown(order.input);
      $.pendingRedeemShares = order.input;
    }

    $.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrderId, order.mode, order.input);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev DEPOSIT delivers the wrapped shares; REDEEM claims the matured cooldown, supporting partial
  ///      fills when sUSD3/USD3 can only satisfy part of the request.
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    SUSD3FundStorage storage $ = _susd3FundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState,) = _state(order);
    if (_currentState != State.UNLOCKING) revert LibFundsErrors.InvalidState(_currentState);

    (State _newState, uint256 _amount) =
      order.mode == Mode.DEPOSIT ? _unlockDeposit($, order.receiver) : _unlockRedeem($, order.receiver);

    $.internalState = _newState;

    emit OrderUnlocked(_currentOrderId, order.mode, _amount, order.receiver);

    return (_newState, _amount);
  }

  /// @inheritdoc IFund
  /// @dev Returns the input of a recovering REDEEM order: re-wraps the still-held sUSD3 (the tracked
  ///      remainder) back to the receiver. Deposits never enter RECOVERING.
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    SUSD3FundStorage storage $ = _susd3FundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.RECOVERING) revert LibFundsErrors.InvalidState($.internalState);

    uint256 _shares = $.pendingRedeemShares;
    address _susd3 = $.susd3;
    address _wrappedShare = $.wrappedShare;

    _susd3.safeApproveWithRetry(_wrappedShare, _shares);
    IWrappedAsset(_wrappedShare).mint(order.receiver, _shares);
    _susd3.safeApproveWithRetry(_wrappedShare, 0);

    $.pendingRedeemShares = 0;
    $.internalState = State.ENDED;

    emit OrderRecovered(_currentOrderId, order.mode, _shares, order.receiver);

    return (State.ENDED, _shares);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ISUSD3Fund
  function cancelRedeem(Order calldata order) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    SUSD3FundStorage storage $ = _susd3FundStorage();
    if ($.internalState != State.PROCESSING) revert LibFundsErrors.InvalidState($.internalState);
    if (order.mode != Mode.REDEEM) revert LibFundsErrors.InvalidMode(order.mode);

    bytes32 _orderId = order.toId(address(this));
    if (_orderId != $.currentOrderId) revert LibFundsErrors.InvalidOrder(_orderId);

    // Cancel the sUSD3 cooldown; the fund keeps the shares for recover() to re-wrap.
    ISUSD3($.susd3).cancelCooldown();
    $.internalState = State.RECOVERING;

    emit RedeemCanceled(_orderId);
  }

  /// @inheritdoc ISUSD3Fund
  /// @dev Overrides the DEPOSIT output threshold for a stuck order. Only affects the DEPOSIT branch of
  ///      state() (redeem uses `sUSD3.maxRedeem`, not a threshold). Does not change the order identity.
  function resolve(Order calldata order, uint256 input, uint256 output)
    external
    override
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    SUSD3FundStorage storage $ = _susd3FundStorage();
    if ($.internalState != State.PROCESSING) revert LibFundsErrors.InvalidState($.internalState);
    if (order.toId(address(this)) != $.currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if (order.mode != Mode.DEPOSIT) revert LibFundsErrors.InvalidMode(order.mode);

    $.hasResolvedAmounts = true;
    $.resolvedOutput = output;

    emit OrderResolved($.currentOrderId, input, output, msg.sender);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ISUSD3Fund
  function susd3() external view override returns (address) {
    return _susd3FundStorage().susd3;
  }

  /// @inheritdoc ISUSD3Fund
  function usd3() external view override returns (address) {
    return _susd3FundStorage().usd3;
  }

  /// @inheritdoc ISUSD3Fund
  function vault() external view override returns (address) {
    return _susd3FundStorage().susd3;
  }

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return _susd3FundStorage().asset;
  }

  /// @inheritdoc IFund
  function share() external view override returns (address) {
    return _susd3FundStorage().wrappedShare;
  }

  /// @inheritdoc IFund
  /// @dev Converts the total wrapped share supply (sUSD3) back through USD3 to USDC. Because the
  ///      wrapped share is shared across all SUSD3Fund instances, this reports the wrapper-wide
  ///      aggregate AUM rather than AUM scoped to this fund.
  function totalAssets() external view override returns (uint256) {
    SUSD3FundStorage storage $ = _susd3FundStorage();
    return IUSD3($.usd3).convertToAssets(ISUSD3($.susd3).convertToAssets(IERC20($.wrappedShare).totalSupply()));
  }

  /// @inheritdoc IFund
  /// @dev The binding USDC deposit capacity: the account's USDC balance, the USD3 supply-cap headroom
  ///      (USDC-denominated), and the sUSD3 subordination-cap headroom (USD3-denominated, converted to
  ///      USDC). Clamps values below USD3's minimum deposit to 0. Returns 0 for accounts without
  ///      DEPOSITOR_ROLE.
  function maxDeposit(address account) external view override returns (uint256) {
    if (!hasAllRoles(account, DEPOSITOR_ROLE)) return 0;
    SUSD3FundStorage storage $ = _susd3FundStorage();
    address _usd3 = $.usd3;
    uint256 _usd3Cap = IUSD3(_usd3).maxDeposit(address(this));
    uint256 _susd3CapUsdc = IUSD3(_usd3).convertToAssets(ISUSD3($.susd3).maxDeposit(address(this)));
    uint256 _max = IERC20($.asset).balanceOf(account).min(_usd3Cap).min(_susd3CapUsdc);
    return _max < IUSD3(_usd3).minDeposit() ? 0 : _max;
  }

  /// @inheritdoc IFund
  /// @dev The redeemable wrapped-share balance. Cooldown constraints apply only after commit(), so
  ///      they are not reflected here. Returns 0 for accounts without DEPOSITOR_ROLE.
  function maxRedeem(address account) external view override returns (uint256) {
    if (!hasAllRoles(account, DEPOSITOR_ROLE)) return 0;
    return IERC20(_susd3FundStorage().wrappedShare).balanceOf(account);
  }

  /// @inheritdoc IFund
  function state(Order calldata order) public view override returns (State) {
    SUSD3FundStorage storage $ = _susd3FundStorage();
    bytes32 _orderId = order.toId(address(this));

    // Return ENDED for archived orders.
    if ($.endedOrders[_orderId]) {
      return State.ENDED;
    }

    // Return EMPTY to indicate this order doesn't exist.
    if (_orderId != $.currentOrderId) {
      return State.EMPTY;
    }

    (State _currentState,) = _state(order);
    return _currentState;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Delivers a synchronous DEPOSIT: wraps the sUSD3 received at commit and mints it to `receiver`.
  /// @param $ The fund storage pointer.
  /// @param receiver The order receiver.
  /// @return The new state (ENDED) and the wrapped-share amount minted.
  function _unlockDeposit(SUSD3FundStorage storage $, address receiver) internal returns (State, uint256) {
    address _susd3 = $.susd3;
    address _wrappedShare = $.wrappedShare;
    uint256 _received = $.depositReceived;

    _susd3.safeApproveWithRetry(_wrappedShare, _received);
    IWrappedAsset(_wrappedShare).mint(receiver, _received);
    _susd3.safeApproveWithRetry(_wrappedShare, 0);

    return (State.ENDED, _received);
  }

  /// @dev Claims a matured REDEEM: redeems as much of the cooldown as sUSD3 currently allows, unwraps
  ///      USD3 -> USDC, and sends USDC to `receiver`. Returns to PROCESSING when a remainder is left.
  /// @param $ The fund storage pointer.
  /// @param receiver The order receiver.
  /// @return The new state (ENDED if fully drained, else PROCESSING) and the USDC amount delivered.
  function _unlockRedeem(SUSD3FundStorage storage $, address receiver) internal returns (State, uint256) {
    address _susd3 = $.susd3;
    address _usd3 = $.usd3;
    address _asset = $.asset;

    uint256 _remaining = $.pendingRedeemShares;
    uint256 _toRedeem = _remaining.min(ISUSD3(_susd3).maxRedeem(address(this)));

    // sUSD3 -> USD3
    uint256 _usd3Out;
    {
      uint256 _usd3Before = IERC20(_usd3).balanceOf(address(this));
      ISUSD3(_susd3).redeem(_toRedeem, address(this), address(this));
      _usd3Out = IERC20(_usd3).balanceOf(address(this)) - _usd3Before;
    }

    // USD3 -> USDC (atomic second leg: reverts the whole unlock if USD3 lacks liquidity)
    uint256 _amount;
    {
      uint256 _assetBefore = IERC20(_asset).balanceOf(address(this));
      IUSD3(_usd3).redeem(_usd3Out, address(this), address(this));
      _amount = IERC20(_asset).balanceOf(address(this)) - _assetBefore;
    }
    _asset.safeTransfer(receiver, _amount);

    uint256 _left = _remaining - _toRedeem;
    $.pendingRedeemShares = _left;

    return (_left == 0 ? State.ENDED : State.PROCESSING, _amount);
  }

  /// @dev Internal function that returns both the dynamic state and the associated amount.
  ///      Queries sUSD3 to determine the PROCESSING -> UNLOCKING transition.
  ///
  ///      For PROCESSING + DEPOSIT:
  ///      - UNLOCKING once the received sUSD3 meets the output threshold
  ///        (`depositReceived >= hasResolvedAmounts ? resolvedOutput : order.output`) AND any sUSD3
  ///        deposit lock has elapsed (`block.timestamp >= sUSD3.lockedUntil(this)`). A shortfall below
  ///        the threshold (e.g. an adverse rate move between create and commit) keeps the order in
  ///        PROCESSING until an operator lowers the threshold via resolve().
  ///
  ///      For PROCESSING + REDEEM:
  ///      - UNLOCKING once `sUSD3.maxRedeem(this) > 0`, which is true only after the cooldown has
  ///        matured and while the withdrawal is not blocked by unrealized losses / the backing floor.
  ///
  ///      For all other states (including RECOVERING), returns internalState directly.
  function _state(Order calldata order) internal view returns (State, uint256) {
    SUSD3FundStorage storage $ = _susd3FundStorage();

    State _internalState = $.internalState;

    if (_internalState == State.PROCESSING) {
      if (order.mode == Mode.DEPOSIT) {
        uint256 _expectedOutput = $.hasResolvedAmounts ? $.resolvedOutput : order.output;
        uint256 _received = $.depositReceived;
        bool _ready = _received >= _expectedOutput && block.timestamp >= ISUSD3($.susd3).lockedUntil(address(this));
        return _ready ? (State.UNLOCKING, _received) : (State.PROCESSING, 0);
      } else {
        // order.mode == Mode.REDEEM
        return ISUSD3($.susd3).maxRedeem(address(this)) > 0 ? (State.UNLOCKING, 0) : (State.PROCESSING, 0);
      }
    }

    return (_internalState, 0);
  }

  /// @dev Chained ERC-4626 conversion for the slippage guard.
  ///      DEPOSIT: USDC input -> USD3 shares -> sUSD3 shares. REDEEM: sUSD3 input -> USD3 -> USDC.
  /// @param mode The order mode.
  /// @param input The order input amount.
  /// @param _usd3 The USD3 strategy address.
  /// @param _susd3 The sUSD3 strategy address.
  function _convertOrder(Mode mode, uint256 input, address _usd3, address _susd3) internal view returns (uint256) {
    if (mode == Mode.DEPOSIT) {
      return ISUSD3(_susd3).convertToShares(IUSD3(_usd3).convertToShares(input));
    }
    return IUSD3(_usd3).convertToAssets(ISUSD3(_susd3).convertToAssets(input));
  }

  /// @dev Reverts if two tokens report different decimals.
  /// @param a The first token.
  /// @param b The second token.
  function _checkSameDecimals(address a, address b) internal view {
    uint8 _decA = IERC20(a).decimals();
    uint8 _decB = IERC20(b).decimals();
    if (_decA != _decB) revert LibFundsErrors.DecimalsMismatch(_decA, _decB);
  }

  /// @dev Reverts if the order owner is not the caller.
  /// @param order The given order.
  function _checkOrderOwner(Order calldata order) internal view {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();
  }
}
