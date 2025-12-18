// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IERC20} from "../interfaces/integrations/IERC20.sol";
import {ISuperstateToken} from "../interfaces/integrations/superstate/ISuperstateToken.sol";
import {IAllowlist} from "../interfaces/integrations/superstate/IAllowlist.sol";
import {IFund} from "../interfaces/funds/IFund.sol";
import {Order, State, Id} from "../libs/Order.sol";

/// @notice Wrapper of Superstate USCC fund.
/// @dev Shares of this fund are represented by wUSCC tokens (external ERC20). Since multiple USCCFund can mint wUSCC.
contract USCCFund is IFund, Ownable, Initializable {
  using SafeTransferLib for address;

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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the USCCFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param recipient The superstate address receiving USDC to mint USCC.
  /// @param currentOrder The current order being processed. We only handle one at a time.
  /// @param currentState The current state of the (current) order.
  /// @param usdc The address of the USDC token contract.
  /// @param uscc The address of the USCC token contract.
  /// @param wuscc The address of the wrapped USCC token contract.
  struct UsccFundStorage {
    address recipient;
    Id currentOrder;
    State currentState;
    address usdc;
    address uscc;
    address wuscc;
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
  ///      The position manager becomes the owner and has exclusive control over the position.
  /// @param positionManager_ The address of the position manager (owner) that will control this position.
  /// @param recipient_ The superstate address receiving USDC to mint USCC.
  /// @param usdc_ The address of the USDC token contract.
  /// @param uscc_ The address of the USCC token contract.
  /// @param wuscc_ The address of the wrapped USCC token contract.
  function initialize(address positionManager_, address recipient_, address usdc_, address uscc_, address wuscc_)
    public
    initializer
  {
    if (usdc_.code.length == 0) revert InvalidContract(usdc_);
    if (uscc_.code.length == 0) revert InvalidContract(uscc_);
    if (wuscc_.code.length == 0) revert InvalidContract(wuscc_);
    if (recipient_ == address(0)) revert AddressZero();

    UsccFundStorage storage $ = _usccFundStorage();
    $.recipient = recipient_;
    $.usdc = usdc_;
    $.uscc = uscc_;
    $.wuscc = wuscc_;

    _initializeOwner(positionManager_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function create(Order calldata order) external override onlyOwner returns (State) {
    if (order.input == 0) revert AmountZero(); // no restrictions on output
    if (order.owner != msg.sender) revert InvalidOwner();
    if (order.receiver != msg.sender) revert InvalidReceiver();

    UsccFundStorage storage $ = _usccFundStorage();
    if ($.currentState != State.EMPTY) revert PendingOrder();
    if (!$.currentOrder.eq(Id.wrap(0))) revert PendingOrder();

    // Check allowlist permissions for this contract to deposit in USCC
    if (!IAllowlist(ISuperstateToken($.uscc).allowlistV2()).isAddressAllowedForPrivateInstrument(address(this), "USCC"))
    {
      revert NotAllowedSuperstate();
    }

    // No pending state, always accepted or revert.
    $.currentOrder = order.toId(address(this));
    $.currentState = State.ACCEPTED;

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function commit(Order calldata order) external override onlyOwner returns (State, uint256) {
    UsccFundStorage storage $ = _usccFundStorage();
    if (!order.toId(address(this)).eq($.currentOrder)) revert InvalidOrder(order.toId(address(this)));
    if ($.currentState != State.ACCEPTED) revert InvalidState($.currentState);

    $.uscc.safeTransferFrom(msg.sender, $.recipient, order.input);

    $.currentState = State.PROCESSING;
    return (State.UNLOCKING, 0);
  }

  /// @inheritdoc IFund
  function recover(Order calldata) external view override onlyOwner returns (State, uint256) {
    // TODO
    return (State.ENDED, 0);
  }

  /// @inheritdoc IFund
  function unlock(Order calldata) external view override onlyOwner returns (State, uint256) {
    // TODO
    return (State.ENDED, 0);
  }

  function recovering() external {
    // TODO only operator

    UsccFundStorage storage $ = _usccFundStorage();

    if ($.currentState != State.PROCESSING) revert InvalidState($.currentState);
    $.currentState = State.RECOVERING;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function estimate(Order calldata) external pure override returns (uint256) {
    // TODO
    return 0;
  }

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return _usccFundStorage().usdc;
  }

  /// @inheritdoc IFund
  function totalAssets() external pure override returns (uint256) {
    // TODO convert with oracle (base on balance of uscc)
    return 0;
  }

  /// @inheritdoc IFund
  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /// @inheritdoc IFund
  function maxRedeem(address account) external view override returns (uint256) {
    return IERC20(_usccFundStorage().wuscc).balanceOf(account);
  }

  /// @inheritdoc IFund
  function state(Order calldata) external view override returns (State) {
    UsccFundStorage storage $ = _usccFundStorage();

    // TODO if processing (only) => check usdc balance
    return $.currentState;
  }
}
