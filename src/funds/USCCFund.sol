// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {IERC20} from "../interfaces/integrations/IERC20.sol";
import {ISuperstateToken} from "../interfaces/integrations/superstate/ISuperstateToken.sol";
import {IAllowlist} from "../interfaces/integrations/superstate/IAllowlist.sol";
import {IFund} from "../interfaces/funds/IFund.sol";
import {IWrappedAsset} from "../interfaces/funds/IWrappedAsset.sol";
import {AggregatorV3Interface} from "../interfaces/integrations/AggregatorV3Interface.sol";
import {Order, State, Id, Mode} from "../libs/Order.sol";

/// @notice Wrapper of Superstate USCC fund.
/// @dev - Shares of this fund are represented by wUSCC tokens (external ERC20). Since multiple USCCFund can mint wUSCC.
///        The USCC tokens are held by this contract. Only wUSCC are sent to users.
///      - The order owner and receiver is always msg.sender (the depositor contract).
///      - This contract uses an "internal state" pattern where the stored state (internalState) may differ
///        from the state returned by the public state() function. The state() function performs dynamic checks
///        on asset balances to determine state transitions.
contract USCCFund is IFund, OwnableRoles, Initializable {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using SafeCastLib for int256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for operator.
  uint256 public constant OPERATOR_ROLE = _ROLE_0;

  /// @notice Role for depositor.
  uint256 public constant DEPOSITOR_ROLE = _ROLE_1;

  /// @dev USCC/USDC/wUSCC all have 6 decimals (same for the oracle).
  uint256 private constant _DECIMALS = 6;

  /// @dev Scaled unit for 6 decimals.
  uint256 private constant _SCALED_UNIT = 10 ** _DECIMALS;

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
    _checkContract(usdc);
    _checkContract(uscc);
    _checkContract(wuscc);
    _checkDecimals(usdc);
    _checkDecimals(uscc);
    _checkDecimals(wuscc);

    USDC = usdc;
    USCC = uscc;
    WUSCC = wuscc;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a required address parameter is the zero address.
  error AddressZero();

  /// @notice Thrown when an operation is called with a zero amount.
  error AmountZero();

  /// @notice Thrown when an address parameter is not a contract (code.length == 0).
  /// @param addr The invalid address.
  error InvalidContract(address addr);

  /// @notice Thrown when the order owner does not match the caller (the owner).
  error InvalidOwner();

  /// @notice Thrown when the order receiver does not match the caller (the owner).
  error InvalidReceiver();

  /// @notice Thrown when trying to create an order while another is still pending.
  error PendingOrder();

  /// @notice Thrown when the current state does not match the expected one.
  /// @param actual The actual state.
  error InvalidState(State actual);

  /// @notice Thrown when the order Id does not match the current one.
  /// @param orderId The invalid order Id.
  error InvalidOrder(Id orderId);

  /// @notice Thrown when address(this) is not allowed by Superstate to deposit in USCC.
  error NotAllowedSuperstate();

  /// @notice Thrown when attempting to grant invalid roles (e.g., immutable roles).
  error InvalidRoles(uint256 roles);

  /// @notice Thrown when the Chainlink oracle returns a non-positive price.
  /// @dev Indicates an invalid or paused oracle feed, or corrupted round data.
  ///      Triggered if `answer <= 0` from `latestRoundData()`.
  error ChainlinkInvalidAnswer();

  /// @notice Thrown when the latest Chainlink round is not yet complete.
  /// @dev Indicates the oracle round has not been finalized.
  ///      Triggered if `updatedAt == 0` from `latestRoundData()`.
  error ChainlinkIncompleteRound();

  /// @notice Thrown when the Chainlink oracle response is stale.
  /// @dev Indicates the answer comes from an earlier round than the latest one.
  ///      Triggered if `answeredInRound < roundId` from `latestRoundData()`.
  error ChainlinkStaleRound();

  /// @notice Thrown when the provided oracle address is invalid (e.g., decimals mismatch).
  /// @param oracle The invalid oracle address.
  error InvalidOracle(address oracle);

  /// @notice Thrown when there is a decimals mismatch between two tokens.
  /// @param decimalsA The decimals of the first token.
  /// @param decimalsB The decimals of the second token.
  error DecimalsMismatch(uint256 decimalsA, uint256 decimalsB);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new order is created and accepted.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param owner The owner of the order.
  /// @param receiver The receiver of the order output.
  /// @param input The input amount for the order.
  /// @param output The expected output amount for the order.
  event OrderCreated(
    Id indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );

  /// @notice Emitted when an order is committed and assets are transferred.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount committed.
  event OrderCommitted(Id indexed orderId, Mode mode, uint256 amount);

  /// @notice Emitted when an order is recovered and funds are returned.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount recovered.
  /// @param receiver The address receiving the recovered funds.
  event OrderRecovered(Id indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  /// @notice Emitted when an order is unlocked and completed successfully.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount unlocked.
  /// @param receiver The address receiving the unlocked funds.
  event OrderUnlocked(Id indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  /// @notice Emitted when the internal state is manually set to RECOVERING.
  /// @param orderId The unique identifier of the order being recovered.
  event OrderRecovering(Id indexed orderId);

  /// @notice Emitted when the oracle address is updated.
  /// @param newOracle The new oracle address.
  /// @param operator The address that updated the oracle.
  event OracleUpdated(address indexed newOracle, address indexed operator);

  /// @notice Emitted when an order is manually resolved by an operator.
  /// @param orderId The unique identifier of the resolved order.
  /// @param newInput The new input amount set by the operator.
  /// @param newOutput The new output amount set by the operator.
  /// @param operator The address that resolved the order.
  event OrderResolved(Id indexed orderId, uint256 newInput, uint256 newOutput, address indexed operator);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the USCCFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param recipient The superstate address receiving USDC to mint USCC.
  /// @param currentOrder The current order being processed. We only handle one at a time.
  /// @param internalState The internal state of the current order.
  /// @param oracle The address of Chainlink USCC Oracle.
  /// @param cachedBalance Cached USCC balance before processing to compute received amounts accurately.
  struct UsccFundStorage {
    address recipient;
    Id currentOrder;
    State internalState;
    address oracle;
    uint256 cachedBalance;
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

  /// @notice Initializes the USCCFund contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the depositor can execute orders.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param depositor_ The address that will execute orders (must be a contract, receives DEPOSITOR_ROLE).
  /// @param recipient_ The superstate address receiving USDC to mint USCC.
  /// @param oracle_ The address of Chainlink USCC Oracle.
  function initialize(address owner_, address depositor_, address recipient_, address oracle_) public initializer {
    _checkNotZero(owner_);
    _checkNotZero(recipient_);
    _checkContract(depositor_);
    _checkContract(oracle_);

    // Ensure oracle has 6 decimals
    if (AggregatorV3Interface(oracle_).decimals() != _DECIMALS) {
      revert InvalidOracle(oracle_);
    }

    UsccFundStorage storage $ = _usccFundStorage();
    $.recipient = recipient_;
    $.oracle = oracle_;

    _initializeOwner(owner_);
    _setRoles(depositor_, DEPOSITOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function create(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    if (order.input == 0) revert AmountZero(); // no restrictions on output
    if (order.owner != msg.sender) revert InvalidOwner();
    if (order.receiver != msg.sender) revert InvalidReceiver();

    UsccFundStorage storage $ = _usccFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) revert PendingOrder();

    // Check allowlist permissions for this contract to deposit in USCC
    if (!IAllowlist(ISuperstateToken(USCC).allowlistV2()).isAddressAllowedForPrivateInstrument(address(this), "USCC")) {
      revert NotAllowedSuperstate();
    }

    // No pending state, always accepted or revert.
    Id _orderId = order.toId(address(this));
    $.currentOrder = _orderId;
    $.internalState = State.ACCEPTED;
    $.cachedBalance = 0;

    emit OrderCreated(_orderId, order.mode, order.owner, order.receiver, order.input, order.output);

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  /// @dev No partial commits, always goes to PROCESSING.
  function commit(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    UsccFundStorage storage $ = _usccFundStorage();
    Id _currentOrder = $.currentOrder;
    if (!order.toId(address(this)).eq(_currentOrder)) revert InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert InvalidState($.internalState);

    if (order.mode == Mode.DEPOSIT) {
      // Depositing: transfer USDC to recipient to mint USCC
      USDC.safeTransferFrom(msg.sender, $.recipient, order.input);
    } else {
      // Redeeming: burn wUSCC and call offchain redeem on USCC (will burn USCC)
      IWrappedAsset(WUSCC).burn(msg.sender, order.input);
      ISuperstateToken(USCC).offchainRedeem(order.input);
    }

    // Snapshot balance before receiving minted uscc or recovered uscc
    // We are not caching usdc balance as we don't have (in theory) stationary usdc holdings
    $.cachedBalance = USCC.balanceOf(address(this));

    $.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrder, order.mode, order.input);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev No partial recoveries, always goes to ENDED.
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    UsccFundStorage storage $ = _usccFundStorage();
    Id _currentOrder = $.currentOrder;
    if (!order.toId(address(this)).eq(_currentOrder)) revert InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.RECOVERING) revert InvalidState($.internalState);

    if (order.mode == Mode.DEPOSIT) {
      USDC.safeTransfer(msg.sender, _amount);
    } else {
      IWrappedAsset(WUSCC).mint(msg.sender, _amount);
    }

    $.internalState = State.ENDED;

    emit OrderRecovered(_currentOrder, order.mode, _amount, msg.sender);

    return (State.ENDED, _amount);
  }

  /// @inheritdoc IFund
  /// @dev No partial unlocks, always goes to ENDED.
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    UsccFundStorage storage $ = _usccFundStorage();
    Id _currentOrder = $.currentOrder;
    if (!order.toId(address(this)).eq(_currentOrder)) revert InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.UNLOCKING) revert InvalidState($.internalState);

    if (order.mode == Mode.DEPOSIT) {
      // Mint wUSCC to receiver and keep USCC in the contract
      IWrappedAsset(WUSCC).mint(msg.sender, _amount);
    } else {
      // Transfer USDC to receiver (all the USDC held by the contract)
      USDC.safeTransfer(msg.sender, _amount);
    }

    $.internalState = State.ENDED;

    emit OrderUnlocked(_currentOrder, order.mode, _amount, msg.sender);

    return (State.ENDED, _amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the fund internal state to RECOVERING (if issues arise with Superstate).
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      This is an emergency function to signal that Superstate failed to process the order.
  ///      Once set to RECOVERING, the state() function will check if recovery funds (original input)
  ///      have been returned. If yes, it shows RECOVERING. If no, it falls back to PROCESSING.
  function recovering() external onlyOwnerOrRoles(OPERATOR_ROLE) {
    UsccFundStorage storage $ = _usccFundStorage();
    if ($.internalState != State.PROCESSING) revert InvalidState($.internalState);
    $.internalState = State.RECOVERING;

    emit OrderRecovering($.currentOrder);
  }

  /// @notice Sets the oracle address.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  /// @param oracle The new oracle address.
  function setOracle(address oracle) external onlyOwnerOrRoles(OPERATOR_ROLE) {
    _checkContract(oracle);

    // Ensure oracle decimals match USCC decimals
    if (AggregatorV3Interface(oracle).decimals() != _DECIMALS) {
      revert InvalidOracle(oracle);
    }

    UsccFundStorage storage $ = _usccFundStorage();
    $.oracle = oracle;

    emit OracleUpdated(oracle, msg.sender);
  }

  /// @notice Resolves the current order by setting its input and output amounts.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      This function is used to resolve stuck orders in PROCESSING or RECOVERING state if received amounts
  ///      differ from expected ones (e.g., due to unexpected conditions).
  ///
  ///      IMPORTANT: Modifying the input/output amounts generates a NEW order ID, since the order ID is
  ///      a hash of all order parameters. After calling resolve(), the original order ID becomes invalid.
  ///      Subsequent unlock() or recover() calls MUST use the resolved order with the updated input/output
  ///      amounts, not the original order. The new order ID is emitted in the OrderResolved event.
  ///
  /// @param order The order to resolve (must match current order ID before resolution).
  /// @param input The new input amount.
  /// @param output The new output amount.
  function resolve(Order memory order, uint256 input, uint256 output) external onlyOwnerOrRoles(OPERATOR_ROLE) {
    UsccFundStorage storage $ = _usccFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.PROCESSING && _internalState != State.RECOVERING) revert InvalidState($.internalState);
    if (!order.toId(address(this)).eq($.currentOrder)) revert InvalidOrder(order.toId(address(this)));

    order.input = input;
    order.output = output;

    Id newOrderId = order.toId(address(this));
    $.currentOrder = newOrderId;

    emit OrderResolved(newOrderId, input, output, msg.sender);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return USDC;
  }

  /// @inheritdoc IFund
  function share() external view returns (address) {
    return WUSCC;
  }

  /// @inheritdoc IFund
  /// @dev We are assuming 1 USDC = 1 USD for totalAssets calculation.
  ///      Validates the oracle round data is consistent and complete.
  function totalAssets() external view override returns (uint256) {
    UsccFundStorage storage $ = _usccFundStorage();

    AggregatorV3Interface _oracle = AggregatorV3Interface($.oracle);

    // Fetch latest round data
    (uint80 _roundId, int256 _answer,, uint256 _updatedAt, uint80 _answeredInRound) = _oracle.latestRoundData();

    // Validate latest round
    if (_answer <= 0) revert ChainlinkInvalidAnswer();
    if (_updatedAt == 0) revert ChainlinkIncompleteRound();
    if (_answeredInRound < _roundId) revert ChainlinkStaleRound();

    uint256 _latestPrice = _answer.toUint256();

    return USCC.balanceOf(address(this)).mulDiv(_latestPrice, _SCALED_UNIT);
  }

  /// @inheritdoc IFund
  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /// @inheritdoc IFund
  function maxRedeem(address account) external view override returns (uint256) {
    return WUSCC.balanceOf(account);
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
    UsccFundStorage storage $ = _usccFundStorage();

    // Return EMPTY to indicate this order doesn't exist
    if (!order.toId(address(this)).eq($.currentOrder)) {
      return (State.EMPTY, 0);
    }

    State _internalState = $.internalState;

    if (_internalState == State.PROCESSING) {
      uint256 _amount;
      if (order.mode == Mode.DEPOSIT) {
        // Deposit: check if we received USCC
        _amount = USCC.balanceOf(address(this)).zeroFloorSub($.cachedBalance);
        return _amount >= order.output ? (State.UNLOCKING, _amount) : (State.PROCESSING, 0);
      } else {
        // Redeem: check if we received USDC
        _amount = USDC.balanceOf(address(this));
        return _amount >= order.output ? (State.UNLOCKING, _amount) : (State.PROCESSING, 0);
      }
    }

    if (_internalState == State.RECOVERING) {
      uint256 _amount;
      if (order.mode == Mode.DEPOSIT) {
        // Deposit: check if we can recover USDC
        _amount = USDC.balanceOf(address(this));
        return _amount >= order.input ? (State.RECOVERING, _amount) : (State.PROCESSING, 0);
      } else {
        // Redeem: check if we can recover USCC
        _amount = USCC.balanceOf(address(this)).zeroFloorSub($.cachedBalance);
        return _amount >= order.input ? (State.RECOVERING, _amount) : (State.PROCESSING, 0);
      }
    }

    return (_internalState, 0);
  }

  /// @inheritdoc OwnableRoles
  /// @dev Set DEPOSITOR_ROLE as immutable (only set in initialize).
  function _grantRoles(address user, uint256 roles) internal override {
    // Check if DEPOSITOR_ROLE is included in the roles bitmap
    if ((roles & DEPOSITOR_ROLE) != 0) {
      revert InvalidRoles(roles);
    }
    _updateRoles(user, roles, true);
  }

  /// @inheritdoc OwnableRoles
  /// @dev Prevent DEPOSITOR_ROLE from being removed after initialization.
  function _removeRoles(address user, uint256 roles) internal override {
    // Check if DEPOSITOR_ROLE is included in the roles bitmap
    if ((roles & DEPOSITOR_ROLE) != 0) {
      revert InvalidRoles(roles);
    }
    _updateRoles(user, roles, false);
  }

  /// @dev Reverts if the address is the zero address.
  /// @param addr The address to check.
  function _checkNotZero(address addr) internal pure {
    if (addr == address(0)) revert AddressZero();
  }

  /// @dev Reverts if the address is not a contract.
  /// @param addr The address to check.
  function _checkContract(address addr) internal view {
    if (addr.code.length == 0) revert InvalidContract(addr);
  }

  /// @dev Internal function to check that a token has the expected decimals (6).
  /// @param token The token address to check.
  function _checkDecimals(address token) internal view {
    uint256 _decimals = IERC20(token).decimals();
    if (_decimals != _DECIMALS) {
      revert DecimalsMismatch(_decimals, _DECIMALS);
    }
  }
}
