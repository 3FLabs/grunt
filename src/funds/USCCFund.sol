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
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for operator.
  uint256 public constant OPERATOR_ROLE = _ROLE_0;

  /// @notice Role for depositor.
  uint256 public constant DEPOSITOR_ROLE = _ROLE_1;

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
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the USCCFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param recipient The superstate address receiving USDC to mint USCC.
  /// @param currentOrder The current order being processed. We only handle one at a time.
  /// @param internalState The internal state of the current order.
  /// @param usdc The address of the USDC token contract.
  /// @param uscc The address of the USCC token contract.
  /// @param wuscc The address of the wrapped USCC token contract.
  /// @param oracle The address of Chainlink USCC Oracle.
  /// @param cachedBalance Cached USCC balance before processing to compute received amounts accurately.
  struct UsccFundStorage {
    address recipient;
    Id currentOrder;
    State internalState;
    address usdc;
    address uscc;
    address wuscc;
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
  /// @param usdc_ The address of the USDC token contract.
  /// @param uscc_ The address of the USCC token contract.
  /// @param wuscc_ The address of the wrapped USCC token contract.
  /// @param oracle_ The address of Chainlink USCC Oracle.
  function initialize(
    address owner_,
    address depositor_,
    address recipient_,
    address usdc_,
    address uscc_,
    address wuscc_,
    address oracle_
  ) public initializer {
    if (depositor_.code.length == 0) revert InvalidContract(depositor_);
    if (usdc_.code.length == 0) revert InvalidContract(usdc_);
    if (uscc_.code.length == 0) revert InvalidContract(uscc_);
    if (wuscc_.code.length == 0) revert InvalidContract(wuscc_);
    if (oracle_.code.length == 0) revert InvalidContract(oracle_);
    if (recipient_ == address(0)) revert AddressZero();

    // Ensure oracle decimals match USCC decimals
    uint256 _usccDecimals = IERC20(uscc_).decimals();
    if (AggregatorV3Interface(oracle_).decimals() != _usccDecimals) {
      revert InvalidOracle(oracle_);
    }

    // Ensure wUSCC decimals match USCC decimals
    uint256 _wusccDecimals = IERC20(wuscc_).decimals();
    if (_wusccDecimals != _usccDecimals) {
      revert DecimalsMismatch(_wusccDecimals, _usccDecimals);
    }

    UsccFundStorage storage $ = _usccFundStorage();
    $.recipient = recipient_;
    $.usdc = usdc_;
    $.uscc = uscc_;
    $.wuscc = wuscc_;
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
    if (!IAllowlist(ISuperstateToken($.uscc).allowlistV2()).isAddressAllowedForPrivateInstrument(address(this), "USCC"))
    {
      revert NotAllowedSuperstate();
    }

    // No pending state, always accepted or revert.
    $.currentOrder = order.toId(address(this));
    $.internalState = State.ACCEPTED;
    $.cachedBalance = 0;

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  /// @dev No partial commits, always goes to PROCESSING.
  function commit(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    UsccFundStorage storage $ = _usccFundStorage();
    if (!order.toId(address(this)).eq($.currentOrder)) revert InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert InvalidState($.internalState);

    if (order.mode == Mode.DEPOSIT) {
      // Depositing: transfer USDC to recipient to mint USCC
      $.usdc.safeTransferFrom(msg.sender, $.recipient, order.input);
    } else {
      // Redeeming: burn wUSCC and call offchain redeem on USCC (will burn USCC)
      IWrappedAsset($.wuscc).burn(msg.sender, order.input);
      ISuperstateToken($.uscc).offchainRedeem(order.input);
    }

    // Snapshot balance before receiving minted uscc or recovered uscc
    // We are not caching usdc balance as we don't have (in theory) stationary usdc holdings
    $.cachedBalance = $.uscc.balanceOf(address(this));

    $.internalState = State.PROCESSING;
    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev No partial recoveries, always goes to ENDED.
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    UsccFundStorage storage $ = _usccFundStorage();
    if (!order.toId(address(this)).eq($.currentOrder)) revert InvalidOrder(order.toId(address(this)));
    if (state(order) != State.RECOVERING) revert InvalidState($.internalState);

    if (order.mode == Mode.DEPOSIT) {
      $.usdc.safeTransfer(msg.sender, order.input);
    } else {
      IWrappedAsset($.wuscc).mint(msg.sender, order.input);
    }

    $.internalState = State.ENDED;
    return (State.ENDED, order.input);
  }

  /// @inheritdoc IFund
  /// @dev No partial unlocks, always goes to ENDED.
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    UsccFundStorage storage $ = _usccFundStorage();
    if (!order.toId(address(this)).eq($.currentOrder)) revert InvalidOrder(order.toId(address(this)));
    if (state(order) != State.UNLOCKING) revert InvalidState($.internalState);

    uint256 _amount;
    if (order.mode == Mode.DEPOSIT) {
      // Mint wUSCC to receiver and keep USCC in the contract
      _amount = $.uscc.balanceOf(address(this)).zeroFloorSub($.cachedBalance);
      IWrappedAsset($.wuscc).mint(msg.sender, _amount);
    } else {
      // Transfer USDC to receiver (all the USDC held by the contract)
      _amount = $.usdc.balanceOf(address(this));
      $.usdc.safeTransfer(msg.sender, _amount);
    }

    $.internalState = State.ENDED;
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
  }

  /// @notice Sets the oracle address.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  /// @param oracle The new oracle address.
  function setOracle(address oracle) external onlyOwnerOrRoles(OPERATOR_ROLE) {
    if (oracle.code.length == 0) revert InvalidContract(oracle);

    // Ensure oracle decimals match USCC decimals
    if (AggregatorV3Interface(oracle).decimals() != IERC20(_usccFundStorage().uscc).decimals()) {
      revert InvalidOracle(oracle);
    }
    _usccFundStorage().oracle = oracle;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return _usccFundStorage().usdc;
  }

  /// @inheritdoc IFund
  function share() external view returns (address) {
    return _usccFundStorage().wuscc;
  }

  /// @inheritdoc IFund
  /// @dev We are assuming 1 USDC = 1 USD for totalAssets calculation.
  function totalAssets() external view override returns (uint256) {
    UsccFundStorage storage $ = _usccFundStorage();

    uint256 balance = $.uscc.balanceOf(address(this));
    AggregatorV3Interface _oracle = AggregatorV3Interface($.oracle);

    (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = _oracle.latestRoundData();

    if (answer <= 0) revert ChainlinkInvalidAnswer();
    if (updatedAt == 0) revert ChainlinkIncompleteRound();
    if (answeredInRound < roundId) revert ChainlinkStaleRound();

    return balance.mulDiv(answer.toUint256(), 10 ** _oracle.decimals());
  }

  /// @inheritdoc IFund
  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /// @inheritdoc IFund
  function maxRedeem(address account) external view override returns (uint256) {
    return _usccFundStorage().wuscc.balanceOf(account);
  }

  /// @inheritdoc IFund
  /// @dev This function returns the dynamic state based on balance checks, which may differ from internalState.
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
  function state(Order calldata order) public view override returns (State) {
    UsccFundStorage storage $ = _usccFundStorage();

    if ($.internalState == State.PROCESSING) {
      if (order.mode == Mode.DEPOSIT) {
        // Deposit: check if we received USCC
        return $.uscc.balanceOf(address(this)).zeroFloorSub($.cachedBalance) >= order.output
          ? State.UNLOCKING
          : State.PROCESSING;
      } else {
        // Redeem: check if we received USDC
        return $.usdc.balanceOf(address(this)) >= order.output ? State.UNLOCKING : State.PROCESSING;
      }
    }

    if ($.internalState == State.RECOVERING) {
      if (order.mode == Mode.DEPOSIT) {
        // Deposit: check if we can recover USDC
        return $.usdc.balanceOf(address(this)) >= order.input ? State.RECOVERING : State.PROCESSING;
      } else {
        // Redeem: check if we can recover USCC
        return $.uscc.balanceOf(address(this)).zeroFloorSub($.cachedBalance) >= order.input
          ? State.RECOVERING
          : State.PROCESSING;
      }
    }
    return $.internalState;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc OwnableRoles
  /// @dev Set DEPOSITOR_ROLE as immutable (only set in initialize).
  function _grantRoles(address user, uint256 roles) internal override {
    // Check if DEPOSITOR_ROLE is included in the roles bitmap
    if (roles & DEPOSITOR_ROLE != 0) {
      revert InvalidRoles(roles);
    }
    _updateRoles(user, roles, true);
  }
}
