// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";

import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {ISuperstateToken} from "../../interfaces/integrations/superstate/ISuperstateToken.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {IUSCCFund} from "../../interfaces/funds/USCC/IUSCCFund.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {AggregatorV3Interface} from "../../interfaces/integrations/AggregatorV3Interface.sol";
import {Order, State, Mode, LibOrder} from "../../libs/funds/Order.sol";
import {LibFundsErrors} from "../../libs/funds/LibFundsErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {BPS} from "../../libs/Constants.sol";

/// @title USCCFund
/// @author 3F Protocol
/// @notice Wrapper of Superstate USCC fund.
/// @dev - Shares of this fund are represented by wUSCC tokens (external ERC20). Multiple USCCFund instances can mint wUSCC.
///        The underlying USCC tokens are held centrally by the wUSCC contract (not by individual funds).
///        This enables shared state across all funds via wUSCC.totalSupply().
///      - The order owner and receiver is always msg.sender (the depositor contract).
///      - ACCEPTED / PENDING orders can be canceled back to EMPTY via cancel() before any assets/shares are committed.
///      - This contract uses an "internal state" pattern where the stored state (internalState) may differ
///        from the state returned by the public state() function. The state() function performs dynamic checks
///        on asset balances to determine state transitions.
contract USCCFund is IUSCCFund, OwnableRoles, Initializable {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using SafeCastLib for int256;
  using LibChecks for address;
  using LibChecks for uint256;
  using LibOrder for Order;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for operator.
  uint256 internal constant _OPERATOR_ROLE = _ROLE_0;

  /// @notice Role for depositor.
  uint256 internal constant _DEPOSITOR_ROLE = _ROLE_1;

  /// @dev USCC/USDC/wUSCC all have 6 decimals (same for the oracle).
  uint256 private constant _DECIMALS = 6;

  /// @dev Scaled unit for 6 decimals.
  uint256 private constant _SCALED_UNIT = 10 ** _DECIMALS;

  /// @notice Maximum allowed negative deviation (in basis points) between the order output
  ///         and the oracle-derived expected output. Orders with output below this threshold revert.
  uint256 public constant MAX_OUTPUT_DEVIATION = 500; // 5%

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The USDC token contract address.
  address public immutable USDC;

  /// @notice The USCC token contract address.
  address public immutable USCC;

  /// @notice The wUSCC wrapped token contract address.
  address public immutable WUSCC;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the USCCFund contract with the required token addresses.
  /// @param usdc The USDC token address.
  /// @param uscc The USCC token address.
  /// @param wuscc The wUSCC token address.
  constructor(address usdc, address uscc, address wuscc) {
    usdc.checkContract();
    uscc.checkContract();
    wuscc.checkContract();
    _checkDecimals(usdc);
    _checkDecimals(uscc);
    _checkDecimals(wuscc);

    // Mirror the wrapped-share invariant enforced by ParetoFund/CentrifugeFund:
    // wUSCC must wrap USCC, otherwise mint/burn flows would silently move the wrong asset.
    if (IWrappedAsset(wuscc).underlying() != uscc) {
      revert LibFundsErrors.InvalidUnderlyingAsset();
    }

    USDC = usdc;
    USCC = uscc;
    WUSCC = wuscc;

    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the USCCFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param recipient The superstate address receiving USDC to mint USCC.
  /// @param currentOrderId The unique identifier of the current order.
  /// @param internalState The internal state of the current order.
  /// @param hasResolvedAmounts Whether the operator has set resolved input/output amounts via resolve().
  /// @param oracle The address of Chainlink USCC Oracle.
  /// @param resolvedInput The resolved input amount (if hasResolvedAmounts is true).
  /// @param resolvedOutput The resolved output amount (if hasResolvedAmounts is true).
  /// @param endedOrders Mapping of ended order Ids to boolean (true if ended). To archive ended orders
  ///                    (since we only handle one at a time).
  struct UsccFundStorage {
    address recipient;
    bytes32 currentOrderId;
    State internalState;
    bool hasResolvedAmounts;
    address oracle;
    uint256 resolvedInput;
    uint256 resolvedOutput;
    mapping(bytes32 => bool) endedOrders;
  }

  /// @dev Storage slot for the USCCFund contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("uscc.fund")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0x22af3a319200d6ffd5a884897090be53ffe5ca9dd773cf69926581248771a500;

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return usccFundStorage A storage pointer to the UsccFundStorage struct
  function _usccFundStorage() internal pure returns (UsccFundStorage storage usccFundStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      usccFundStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IUSCCFund
  function initialize(address owner_, address depositor_, address recipient_, address oracle_)
    public
    override
    initializer
  {
    owner_.checkNotZero();
    recipient_.checkNotZero();
    depositor_.checkContract();

    _usccFundStorage().recipient = recipient_;

    _setOracle(oracle_);

    _initializeOwner(owner_);
    _setRoles(depositor_, _DEPOSITOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function create(Order calldata order) external override onlyRoles(_DEPOSITOR_ROLE) returns (State) {
    order.input.checkNotZero();
    _validateOutput(order);
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();
    if (order.receiver != msg.sender) revert LibFundsErrors.InvalidReceiver();

    UsccFundStorage storage _storage = _usccFundStorage();
    State _internalState = _storage.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) revert LibFundsErrors.PendingOrder();

    // Check allowlist permissions for this contract to deposit in USCC
    if (!ISuperstateToken(USCC).isAllowed(address(this))) {
      revert LibFundsErrors.NotAllowedSuperstate();
    }
    // Check allowlist permissions for the eventual wUSCC receiver
    if (!ISuperstateToken(USCC).isAllowed(order.receiver)) {
      revert LibFundsErrors.NotAllowedSuperstate();
    }

    // offchainRedeem() is a burn path; reject redeems while Superstate accounting is paused
    // so the order does not get stuck in ACCEPTED with a guaranteed-revert commit.
    if (order.mode == Mode.REDEEM && ISuperstateToken(USCC).accountingPaused()) {
      revert LibFundsErrors.SuperstateAccountingPaused();
    }

    if (_internalState == State.ENDED) {
      // Archive ended order
      _storage.endedOrders[_storage.currentOrderId] = true;
    }

    // No pending state, always accepted or revert.
    bytes32 _orderId = order.toId(address(this));
    if (_storage.endedOrders[_orderId]) revert LibFundsErrors.OrderAlreadyExists(_orderId);
    _storage.currentOrderId = _orderId;
    _storage.internalState = State.ACCEPTED;
    _storage.hasResolvedAmounts = false;
    _storage.resolvedInput = 0;
    _storage.resolvedOutput = 0;

    emit OrderCreated(_orderId, order.mode, order.owner, order.receiver, order.input, order.output);

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function cancel(Order calldata order) external override onlyRoles(_DEPOSITOR_ROLE) returns (State) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    UsccFundStorage storage _storage = _usccFundStorage();
    bytes32 _currentOrderId = _storage.currentOrderId;
    bytes32 _orderId = order.toId(address(this));
    if (_orderId != _currentOrderId) revert LibFundsErrors.InvalidOrder(_orderId);

    State _internalState = _storage.internalState;
    if (_internalState != State.ACCEPTED && _internalState != State.PENDING) {
      revert LibFundsErrors.InvalidState(_internalState);
    }

    _storage.currentOrderId = bytes32(0);
    _storage.internalState = State.EMPTY;

    emit OrderCanceled(_orderId, order.mode, order.owner);

    return State.EMPTY;
  }

  /// @inheritdoc IFund
  /// @dev No partial commits, always goes to PROCESSING.
  function commit(Order calldata order) external override onlyRoles(_DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    UsccFundStorage storage _storage = _usccFundStorage();
    bytes32 _currentOrderId = _storage.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if (_storage.internalState != State.ACCEPTED) revert LibFundsErrors.InvalidState(_storage.internalState);

    // Check allowlist permissions for this contract to deposit in USCC
    if (!ISuperstateToken(USCC).isAllowed(address(this))) {
      revert LibFundsErrors.NotAllowedSuperstate();
    }
    // Re-check allowlist permissions for the eventual wUSCC receiver
    if (!ISuperstateToken(USCC).isAllowed(order.receiver)) {
      revert LibFundsErrors.NotAllowedSuperstate();
    }

    if (order.mode == Mode.DEPOSIT) {
      // Depositing: transfer USDC to recipient to mint USCC
      USDC.safeTransferFrom(msg.sender, _storage.recipient, order.input);
    } else {
      // Redeeming: burn wUSCC (sends USCC to this contract), then call offchain redeem on USCC
      IWrappedAsset(WUSCC).burn(msg.sender, address(this), order.input);
      ISuperstateToken(USCC).offchainRedeem(order.input);
    }

    _storage.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrderId, order.mode, order.input);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev No partial recoveries, always goes to ENDED.
  function recover(Order calldata order) external override onlyRoles(_DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    UsccFundStorage storage _storage = _usccFundStorage();
    bytes32 _currentOrderId = _storage.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.RECOVERING) revert LibFundsErrors.InvalidState(_currentState);

    if (order.mode == Mode.DEPOSIT) {
      USDC.safeTransfer(order.receiver, _amount);
    } else {
      // Mint wUSCC back to depositor (pulls USCC from this contract)
      USCC.safeApproveWithRetry(WUSCC, _amount);
      IWrappedAsset(WUSCC).mint(order.receiver, _amount);
    }

    _storage.internalState = State.ENDED;

    emit OrderRecovered(_currentOrderId, order.mode, _amount, order.receiver);

    return (State.ENDED, _amount);
  }

  /// @inheritdoc IFund
  /// @dev No partial unlocks, always goes to ENDED.
  function unlock(Order calldata order) external override onlyRoles(_DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    UsccFundStorage storage _storage = _usccFundStorage();
    bytes32 _currentOrderId = _storage.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.UNLOCKING) revert LibFundsErrors.InvalidState(_currentState);

    if (order.mode == Mode.DEPOSIT) {
      // Mint wUSCC to receiver (pulls USCC from this contract into wUSCC)
      USCC.safeApproveWithRetry(WUSCC, _amount);
      IWrappedAsset(WUSCC).mint(order.receiver, _amount);
    } else {
      // Transfer USDC to receiver (all the USDC held by the contract)
      USDC.safeTransfer(order.receiver, _amount);
    }

    _storage.internalState = State.ENDED;

    emit OrderUnlocked(_currentOrderId, order.mode, _amount, order.receiver);

    return (State.ENDED, _amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IUSCCFund
  function recovering(bytes32 orderId) external override onlyOwnerOrRoles(_OPERATOR_ROLE) {
    UsccFundStorage storage _storage = _usccFundStorage();
    if (orderId != _storage.currentOrderId) revert LibFundsErrors.InvalidOrder(orderId);
    if (_storage.internalState != State.PROCESSING) revert LibFundsErrors.InvalidState(_storage.internalState);
    _storage.internalState = State.RECOVERING;

    emit OrderRecovering(_storage.currentOrderId);
  }

  /// @inheritdoc IUSCCFund
  function cancelRecovering(bytes32 orderId) external override onlyOwnerOrRoles(_OPERATOR_ROLE) {
    UsccFundStorage storage _storage = _usccFundStorage();
    if (orderId != _storage.currentOrderId) revert LibFundsErrors.InvalidOrder(orderId);
    if (_storage.internalState != State.RECOVERING) revert LibFundsErrors.InvalidState(_storage.internalState);
    _storage.internalState = State.PROCESSING;

    emit OrderProcessing(_storage.currentOrderId);
  }

  /// @notice Sets the oracle address.
  /// @dev Can only be called by an account with the _OPERATOR_ROLE or the owner.
  /// @param oracle The new oracle address.
  function setOracle(address oracle) external onlyOwnerOrRoles(_OPERATOR_ROLE) {
    _setOracle(oracle);
  }

  /// @inheritdoc IUSCCFund
  function resolve(Order memory order, uint256 input, uint256 output)
    external
    override
    onlyOwnerOrRoles(_OPERATOR_ROLE)
  {
    UsccFundStorage storage _storage = _usccFundStorage();
    State _internalState = _storage.internalState;
    if (_internalState != State.PROCESSING && _internalState != State.RECOVERING) {
      revert LibFundsErrors.InvalidState(_storage.internalState);
    }
    if (order.toId(address(this)) != _storage.currentOrderId) {
      revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    }

    input.checkNotZero();

    _storage.hasResolvedAmounts = true;
    _storage.resolvedInput = input;
    _storage.resolvedOutput = output;

    emit OrderResolved(_storage.currentOrderId, input, output, msg.sender);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return USDC;
  }

  /// @inheritdoc IFund
  function share() external view override returns (address) {
    return WUSCC;
  }

  /// @inheritdoc IFund
  /// @dev We are assuming 1 USDC = 1 USD for totalAssets calculation.
  ///      Validates the oracle round data is consistent and complete.
  ///      The returned value is derived from `WUSCC.totalSupply()`, so when a single `WUSCC`
  ///      deployment backs multiple `USCCFund` instances, every instance reports the same
  ///      wrapper-wide aggregate AUM rather than AUM scoped to this fund.
  function totalAssets() external view override returns (uint256) {
    return WUSCC.totalSupply().mulDiv(_getOraclePrice(), _SCALED_UNIT);
  }

  /// @inheritdoc IFund
  function maxDeposit(address account) external view override returns (uint256) {
    return hasAllRoles(account, _DEPOSITOR_ROLE) ? IERC20(USDC).balanceOf(account) : 0;
  }

  /// @inheritdoc IFund
  function maxRedeem(address account) external view override returns (uint256) {
    return hasAllRoles(account, _DEPOSITOR_ROLE) ? IERC20(WUSCC).balanceOf(account) : 0;
  }

  /// @inheritdoc IFund
  function state(Order calldata order) public view override returns (State) {
    (State _currentState,) = _state(order);
    return _currentState;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Internal function that returns both the dynamic state and the associated amount.
  ///      This function returns the dynamic state based on balance checks, which may differ from internalState.
  ///
  ///      For PROCESSING state (waiting for Superstate to process the order):
  ///      - Deposit: checks if USCC output was received → UNLOCKING if yes, PROCESSING if no
  ///      - Redeem: checks if USDC output was received → UNLOCKING if yes, PROCESSING if no
  ///
  ///      For RECOVERING state (Superstate failed, attempting recovery):
  ///      - Deposit: checks if USDC input was returned → RECOVERING if yes, PROCESSING if no
  ///      - Redeem: checks if USCC input was returned → RECOVERING if yes, PROCESSING if no
  ///
  ///      For all other states (EMPTY, ACCEPTED, ENDED), returns internalState directly.
  ///
  ///      Returns EMPTY for any order that is not the current order (except when internalState is EMPTY or ENDED).
  /// @param order The order to check the state for.
  /// @return The current state based on balance checks.
  /// @return The amount available to unlock (if UNLOCKING) or recover (if RECOVERING), 0 otherwise.
  function _state(Order calldata order) internal view returns (State, uint256) {
    UsccFundStorage storage _storage = _usccFundStorage();
    bytes32 _orderId = order.toId(address(this));

    // Return ENDED for archived orders
    if (_storage.endedOrders[_orderId]) {
      return (State.ENDED, 0);
    }

    // Return EMPTY to indicate this order doesn't exist
    if (_orderId != _storage.currentOrderId) {
      return (State.EMPTY, 0);
    }

    State _internalState = _storage.internalState;

    uint256 _effectiveInput = order.input;
    uint256 _effectiveOutput = order.output;

    // If order resolved, use resolved amounts
    if (_storage.hasResolvedAmounts) {
      _effectiveInput = _storage.resolvedInput;
      _effectiveOutput = _storage.resolvedOutput;
    }

    if (_internalState == State.PROCESSING) {
      uint256 _amount;
      if (order.mode == Mode.DEPOSIT) {
        // Deposit: check if we received USCC
        _amount = IERC20(USCC).balanceOf(address(this));
        return _amount >= _effectiveOutput ? (State.UNLOCKING, _amount) : (State.PROCESSING, 0);
      } else {
        // Redeem: check if we received USDC
        _amount = IERC20(USDC).balanceOf(address(this));
        return _amount >= _effectiveOutput ? (State.UNLOCKING, _amount) : (State.PROCESSING, 0);
      }
    }

    if (_internalState == State.RECOVERING) {
      uint256 _amount;
      if (order.mode == Mode.DEPOSIT) {
        // Deposit: check if we can recover USDC
        _amount = IERC20(USDC).balanceOf(address(this));
        return _amount >= _effectiveInput ? (State.RECOVERING, _amount) : (State.PROCESSING, 0);
      } else {
        // Redeem: check if we can recover USCC
        _amount = IERC20(USCC).balanceOf(address(this));
        return _amount >= _effectiveInput ? (State.RECOVERING, _amount) : (State.PROCESSING, 0);
      }
    }

    return (_internalState, 0);
  }

  /// @dev Returns the validated oracle price for USCC/USD.
  /// @return The latest oracle price as a uint256.
  function _getOraclePrice() internal view returns (uint256) {
    AggregatorV3Interface _oracle = AggregatorV3Interface(_usccFundStorage().oracle);

    (uint80 _roundId, int256 _answer,, uint256 _updatedAt, uint80 _answeredInRound) = _oracle.latestRoundData();

    if (_answer <= 0) revert LibFundsErrors.ChainlinkInvalidAnswer();
    if (_updatedAt == 0) revert LibFundsErrors.ChainlinkIncompleteRound();
    if (_answeredInRound < _roundId) revert LibFundsErrors.ChainlinkStaleRound();

    return _answer.toUint256();
  }

  /// @dev Validates that the order output is within acceptable deviation from the oracle-derived expected output.
  ///      Reverts if the output deviates negatively by more than MAX_OUTPUT_DEVIATION basis points.
  /// @param order The order to validate.
  function _validateOutput(Order calldata order) internal view {
    uint256 _price = _getOraclePrice();
    uint256 _expectedOutput;

    if (order.mode == Mode.DEPOSIT) {
      // DEPOSIT: USDC → USCC, expected USCC = input * _SCALED_UNIT / price
      _expectedOutput = order.input.mulDiv(_SCALED_UNIT, _price);
    } else {
      // REDEEM: wUSCC → USDC, expected USDC = input * price / _SCALED_UNIT
      _expectedOutput = order.input.mulDiv(_price, _SCALED_UNIT);
    }

    if (order.output < _expectedOutput) {
      if (_expectedOutput - order.output > _expectedOutput * MAX_OUTPUT_DEVIATION / BPS) {
        revert LibFundsErrors.InvalidOutput();
      }
    }
  }

  /// @dev Internal function to validate and set the oracle address.
  /// @param oracle The oracle address to set.
  function _setOracle(address oracle) private {
    oracle.checkContract();

    // Ensure oracle decimals match USCC decimals
    if (AggregatorV3Interface(oracle).decimals() != _DECIMALS) {
      revert LibFundsErrors.InvalidOracle(oracle);
    }

    _usccFundStorage().oracle = oracle;
    emit OracleUpdated(oracle, msg.sender);
  }

  /// @dev Internal function to check that a token has the expected decimals (6).
  /// @param token The token address to check.
  function _checkDecimals(address token) internal view {
    uint256 _decimals = IERC20(token).decimals();
    if (_decimals != _DECIMALS) {
      revert LibFundsErrors.DecimalsMismatch(_decimals, _DECIMALS);
    }
  }
}
