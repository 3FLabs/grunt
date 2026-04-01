// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {ICentrifugeFund} from "../../interfaces/funds/centrifuge/ICentrifugeFund.sol";
import {ICentrifugeVault} from "../../interfaces/integrations/centrifuge/ICentrifugeVault.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {Order, State, Mode, LibOrder} from "../../libs/funds/Order.sol";
import {LibFundsErrors} from "../../libs/funds/LibFundsErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {BPS} from "../../libs/Constants.sol";

/// @title CentrifugeFund
/// @author 3F Protocol
/// @notice Wrapper of Centrifuge ERC-7540 vaults.
/// @dev - Shares of this fund are represented by WrappedAsset tokens wrapping the vault's share token.
///      - The order owner and receiver is always msg.sender (the depositor contract).
///      - ACCEPTED / PENDING orders can be canceled back to EMPTY via cancel() before any assets/shares are committed.
///      - This contract uses an "internal state" pattern where the stored state (internalState) may differ
///        from the state returned by the public state() function. The state() function queries the Centrifuge
///        vault to determine state transitions (e.g., PROCESSING → UNLOCKING when claimable).
///      - Recovery is async: cancelRequest() → wait for Centrifuge → recover().
///      - All vault calls use requestId = 0, which is the Centrifuge convention for
///        "the current request for this controller" (each controller has at most one active request).
contract CentrifugeFund is ICentrifugeFund, OwnableRoles, Initializable {
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

  /// @dev Centrifuge convention: requestId = 0 means "the current request for this controller".
  uint256 internal constant _PENDING_REQUEST = 0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the CentrifugeFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility.
  /// @param vault The Centrifuge ERC-7540 vault address.
  /// @param internalState The stored internal state; may differ from the dynamic state returned by `state()`.
  /// @param wrappedShare The WrappedAsset contract that wraps the vault's share token.
  /// @param asset The underlying asset of the vault (e.g. USDC).
  /// @param shareToken The vault's raw share token (unwrapped).
  /// @param currentOrderId The order ID of the current (or most recent) order.
  /// @param endedOrders Tracks order IDs that have reached ENDED so historical lookups return ENDED.
  struct CentrifugeFundStorage {
    address vault;
    State internalState;
    address wrappedShare;
    address asset;
    address shareToken;
    bytes32 currentOrderId;
    mapping(bytes32 => bool) endedOrders;
  }

  /// @dev Storage slot for the CentrifugeFund contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("centrifuge.fund")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0x28ef1884921bced10c88ede8544b3b6c142d3b6f429022b5bec0411945718000;

  /// @dev Returns a reference to the contract's storage struct.
  function _centrifugeFundStorage() internal pure returns (CentrifugeFundStorage storage centrifugeFundStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      centrifugeFundStorage.slot := _MAIN_STORAGE_SLOT
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

  /// @inheritdoc ICentrifugeFund
  function initialize(address owner_, address depositor_, address vault_, address wrappedShare_)
    public
    override
    initializer
  {
    owner_.checkNotZero();
    depositor_.checkContract();
    vault_.checkContract();
    wrappedShare_.checkContract();

    // Verify wrappedShare wraps the vault's share token
    address _shareToken = ICentrifugeVault(vault_).share();
    if (IWrappedAsset(wrappedShare_).underlying() != _shareToken) {
      revert LibFundsErrors.InvalidUnderlyingAsset();
    }

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    $.vault = vault_;
    $.wrappedShare = wrappedShare_;
    $.asset = ICentrifugeVault(vault_).asset();
    $.shareToken = _shareToken;

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

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) revert LibFundsErrors.PendingOrder();

    address _vault = $.vault;
    if (!ICentrifugeVault(_vault).isPermissioned(address(this))) {
      revert LibFundsErrors.NotAllowedByFund();
    }
    if (!ICentrifugeVault(_vault).isPermissioned($.wrappedShare)) {
      revert LibFundsErrors.WrappedShareNotPermissioned();
    }

    if (_internalState == State.ENDED) {
      // Archive ended order
      $.endedOrders[$.currentOrderId] = true;
    }

    // Slippage guard: reject if expected output deviates too far below the current rate.
    uint256 _expectedOutput = order.mode == Mode.DEPOSIT
      ? ICentrifugeVault(_vault).convertToShares(order.input)
      : ICentrifugeVault(_vault).convertToAssets(order.input);

    if (order.output < _expectedOutput) {
      if (_expectedOutput - order.output > _expectedOutput * MAX_OUTPUT_DEVIATION / BPS) {
        revert LibFundsErrors.InvalidOutput();
      }
    }

    bytes32 _orderId = order.toId(address(this));
    if ($.endedOrders[_orderId]) revert LibFundsErrors.OrderAlreadyExists(_orderId);
    $.currentOrderId = _orderId;
    $.internalState = State.ACCEPTED;

    emit OrderCreated(_orderId, order.mode, order.owner, order.receiver, order.input, order.output);

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function cancel(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    _checkOrderOwner(order);

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
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
  /// @dev No partial commits, always goes to PROCESSING.
  function commit(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert LibFundsErrors.InvalidState($.internalState);

    address _vault = $.vault;
    if (!ICentrifugeVault(_vault).isPermissioned(address(this))) {
      revert LibFundsErrors.NotAllowedByFund();
    }
    if (!ICentrifugeVault(_vault).isPermissioned($.wrappedShare)) {
      revert LibFundsErrors.WrappedShareNotPermissioned();
    }

    if (order.mode == Mode.DEPOSIT) {
      // Pull asset from depositor, approve vault, request deposit
      address _asset = $.asset;
      _asset.safeTransferFrom(msg.sender, address(this), order.input);
      _asset.safeApproveWithRetry(_vault, order.input);
      ICentrifugeVault(_vault).requestDeposit(order.input, address(this), address(this));
      _asset.safeApproveWithRetry(_vault, 0);
    } else {
      // Burn WrappedAsset from depositor (unwraps to share tokens held by this contract)
      IWrappedAsset($.wrappedShare).burn(msg.sender, address(this), order.input);
      // Approve share tokens to vault and request redeem
      address _shareToken = $.shareToken;
      _shareToken.safeApproveWithRetry(_vault, order.input);
      ICentrifugeVault(_vault).requestRedeem(order.input, address(this), address(this));
      _shareToken.safeApproveWithRetry(_vault, 0);
    }

    $.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrderId, order.mode, order.input);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev Supports partial unlocks when requests remain pending.
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState,) = _state(order);
    if (_currentState != State.UNLOCKING) revert LibFundsErrors.InvalidState(_currentState);

    address _vault = $.vault;
    uint256 _amount;

    if (order.mode == Mode.DEPOSIT) {
      address _shareToken = $.shareToken;
      address _wrappedShare = $.wrappedShare;
      uint256 _before = IERC20(_shareToken).balanceOf(address(this));
      ICentrifugeVault(_vault).mint(ICentrifugeVault(_vault).maxMint(address(this)), address(this), address(this));
      _amount = IERC20(_shareToken).balanceOf(address(this)) - _before;
      _shareToken.safeApproveWithRetry(_wrappedShare, _amount);
      IWrappedAsset(_wrappedShare).mint(order.receiver, _amount);
      _shareToken.safeApproveWithRetry(_wrappedShare, 0);
    } else {
      address _asset = $.asset;
      uint256 _before = IERC20(_asset).balanceOf(address(this));
      ICentrifugeVault(_vault)
        .withdraw(ICentrifugeVault(_vault).maxWithdraw(address(this)), address(this), address(this));
      _amount = IERC20(_asset).balanceOf(address(this)) - _before;
      _asset.safeTransfer(order.receiver, _amount);
    }

    bool _hasPendingRequest = _stateHasPendingRequest(_vault, order.mode);

    State _newState;
    if ($.internalState == State.RECOVERING) {
      bool _hasPendingRecover = _stateHasPendingRecover(order.mode, _vault);
      bool _hasPending = _hasPendingRecover || _hasPendingRequest;
      $.internalState = _hasPending ? State.RECOVERING : State.ENDED;
      _newState = _hasPending ? State.PROCESSING : State.ENDED;
    } else {
      _newState = _hasPendingRequest ? State.PROCESSING : State.ENDED;
      $.internalState = _newState;
    }

    emit OrderUnlocked(_currentOrderId, order.mode, _amount, order.receiver);

    return (_newState, _amount);
  }

  /// @inheritdoc IFund
  /// @dev Supports partial recoveries while cancellation requests are still pending.
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState,) = _state(order);
    if (_currentState != State.RECOVERING) revert LibFundsErrors.InvalidState(_currentState);

    address _vault = $.vault;
    uint256 _amount;

    if (order.mode == Mode.DEPOSIT) {
      // Claim cancelled deposit (returns assets)
      address _asset = $.asset;
      uint256 _before = IERC20(_asset).balanceOf(address(this));
      ICentrifugeVault(_vault).claimCancelDepositRequest(_PENDING_REQUEST, address(this), address(this));
      _amount = IERC20(_asset).balanceOf(address(this)) - _before;
      _asset.safeTransfer(order.receiver, _amount);
    } else {
      // Claim cancelled redeem (returns share tokens)
      address _shareToken = $.shareToken;
      address _wrappedShare = $.wrappedShare;
      uint256 _before = IERC20(_shareToken).balanceOf(address(this));
      ICentrifugeVault(_vault).claimCancelRedeemRequest(_PENDING_REQUEST, address(this), address(this));
      // Wrap share tokens and send to receiver
      _amount = IERC20(_shareToken).balanceOf(address(this)) - _before;
      _shareToken.safeApproveWithRetry(_wrappedShare, _amount);
      IWrappedAsset(_wrappedShare).mint(order.receiver, _amount);
      _shareToken.safeApproveWithRetry(_wrappedShare, 0);
    }

    bool _hasPendingRecover = _stateHasPendingRecover(order.mode, _vault);
    $.internalState = _hasPendingRecover ? State.RECOVERING : State.ENDED;

    emit OrderRecovered(_currentOrderId, order.mode, _amount, order.receiver);

    return (_hasPendingRecover ? State.PROCESSING : State.ENDED, _amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ICentrifugeFund
  function cancelRequest(Order calldata order) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    if ($.internalState != State.PROCESSING) revert LibFundsErrors.InvalidState($.internalState);
    bytes32 orderId = order.toId(address(this));
    if (orderId != $.currentOrderId) {
      revert LibFundsErrors.InvalidOrder(orderId);
    }

    address _vault = $.vault;
    _revertIfUnclaimedFills(_vault, order.mode);

    $.internalState = State.RECOVERING;

    if (order.mode == Mode.DEPOSIT) {
      ICentrifugeVault(_vault).cancelDepositRequest(_PENDING_REQUEST, address(this));
    } else {
      ICentrifugeVault(_vault).cancelRedeemRequest(_PENDING_REQUEST, address(this));
    }

    emit CancelRequestSubmitted(orderId);
  }

  /// @inheritdoc ICentrifugeFund
  function forceEnd(Order calldata order) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.PROCESSING && _internalState != State.RECOVERING) {
      revert LibFundsErrors.InvalidState(_internalState);
    }

    bytes32 _orderId = order.toId(address(this));
    if (_orderId != $.currentOrderId) {
      revert LibFundsErrors.InvalidOrder(_orderId);
    }

    address _vault = $.vault;

    // Revert if claimable fills exist (must be drained via unlock() first).
    if (order.mode == Mode.DEPOSIT) {
      if (ICentrifugeVault(_vault).maxMint(address(this)) > 0) {
        revert LibFundsErrors.PendingClaimableAssets();
      }
    } else {
      if (ICentrifugeVault(_vault).maxWithdraw(address(this)) > 0) {
        revert LibFundsErrors.PendingClaimableAssets();
      }
    }

    // Revert if recoverable cancel assets exist (must be drained via recover() first)
    if (_internalState == State.RECOVERING) {
      if (order.mode == Mode.DEPOSIT) {
        if (ICentrifugeVault(_vault).claimableCancelDepositRequest(_PENDING_REQUEST, address(this)) > 0) {
          revert LibFundsErrors.PendingClaimableAssets();
        }
      } else {
        if (ICentrifugeVault(_vault).claimableCancelRedeemRequest(_PENDING_REQUEST, address(this)) > 0) {
          revert LibFundsErrors.PendingClaimableAssets();
        }
      }
    }

    $.internalState = State.ENDED;

    emit OrderForceEnded(_orderId, msg.sender);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ICentrifugeFund
  function vault() external view override returns (address) {
    return _centrifugeFundStorage().vault;
  }

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return _centrifugeFundStorage().asset;
  }

  /// @inheritdoc IFund
  function share() external view override returns (address) {
    return _centrifugeFundStorage().wrappedShare;
  }

  /// @inheritdoc IFund
  /// @dev Converts total wrapped share supply to assets using the vault's conversion rate.
  function totalAssets() external view override returns (uint256) {
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    return ICentrifugeVault($.vault).convertToAssets(IERC20($.wrappedShare).totalSupply());
  }

  /// @inheritdoc IFund
  /// @dev The Centrifuge vault requires `account` to be permissioned at the vault level.
  /// In practice, only the fund contract is permissioned, so this will return 0 for
  /// accounts that are not also permissioned on the Centrifuge vault.
  function maxDeposit(address account) external view override returns (uint256) {
    if (!hasAllRoles(account, DEPOSITOR_ROLE)) return 0;
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    return IERC20($.asset).balanceOf(account).min(ICentrifugeVault($.vault).maxDeposit(account));
  }

  /// @inheritdoc IFund
  /// @dev The Centrifuge vault requires `account` to be permissioned at the vault level.
  /// In practice, only the fund contract is permissioned, so this will return 0 for
  /// accounts that are not also permissioned on the Centrifuge vault.
  function maxRedeem(address account) external view override returns (uint256) {
    if (!hasAllRoles(account, DEPOSITOR_ROLE)) return 0;
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    return IERC20($.wrappedShare).balanceOf(account).min(ICentrifugeVault($.vault).maxRedeem(account));
  }

  /// @inheritdoc IFund
  function state(Order calldata order) public view override returns (State) {
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
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
  ///      Queries the Centrifuge vault for claimable amounts to determine state transitions.
  ///
  ///      For PROCESSING state:
  ///      - Deposit: checks vault.maxMint(this) > 0 → UNLOCKING
  ///      - Redeem: checks vault.maxWithdraw(this) > 0 → UNLOCKING
  ///
  ///      For RECOVERING state (after cancelRequest submitted):
  ///      - First checks for fulfilled shares/assets (race condition: the Centrifuge pool can
  ///        approve a deposit/redeem even after cancelRequest, since fulfillment is multi-step):
  ///        - Deposit: checks vault.maxMint(this) > 0 → UNLOCKING
  ///        - Redeem: checks vault.maxWithdraw(this) > 0 → UNLOCKING
  ///      - Then checks for claimable cancel assets:
  ///        - Deposit: checks vault.claimableCancelDepositRequest(_PENDING_REQUEST, this) > 0 → RECOVERING
  ///        - Redeem: checks vault.claimableCancelRedeemRequest(_PENDING_REQUEST, this) > 0 → RECOVERING
  ///      - If neither is claimable (cancel still pending), returns PROCESSING
  ///
  ///      For all other states, returns internalState directly.
  function _state(Order calldata order) internal view returns (State, uint256) {
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();

    State _internalState = $.internalState;
    address _vault = $.vault;

    if (_internalState == State.PROCESSING) {
      uint256 _claimable = order.mode == Mode.DEPOSIT
        ? ICentrifugeVault(_vault).maxMint(address(this))
        : ICentrifugeVault(_vault).maxWithdraw(address(this));

      return _claimable > 0 ? (State.UNLOCKING, _claimable) : (State.PROCESSING, 0);
    }

    if (_internalState == State.RECOVERING) {
      // Check for fulfilled shares/assets first (race condition: deposit approved despite cancel)
      uint256 _claimable = order.mode == Mode.DEPOSIT
        ? ICentrifugeVault(_vault).maxMint(address(this))
        : ICentrifugeVault(_vault).maxWithdraw(address(this));

      if (_claimable > 0) return (State.UNLOCKING, _claimable);

      _claimable = order.mode == Mode.DEPOSIT
        ? ICentrifugeVault(_vault).claimableCancelDepositRequest(_PENDING_REQUEST, address(this))
        : ICentrifugeVault(_vault).claimableCancelRedeemRequest(_PENDING_REQUEST, address(this));

      // Report PROCESSING while the Centrifuge pool hasn't fulfilled the cancel yet,
      // so callers don't attempt to claim before there's anything to recover.
      return _claimable > 0 ? (State.RECOVERING, _claimable) : (State.PROCESSING, 0);
    }

    return (_internalState, 0);
  }

  /// @dev Returns whether the original deposit/redeem request still has assets pending in the vault.
  ///      Used by `unlock()` to decide whether the order returns to PROCESSING (partial fill)
  ///      or transitions to ENDED (fully filled).
  /// @param _vault The Centrifuge vault address.
  /// @param _mode  The order mode (DEPOSIT or REDEEM).
  function _stateHasPendingRequest(address _vault, Mode _mode) internal view returns (bool) {
    if (_mode == Mode.DEPOSIT) {
      return ICentrifugeVault(_vault).pendingDepositRequest(_PENDING_REQUEST, address(this)) > 0;
    }

    return ICentrifugeVault(_vault).pendingRedeemRequest(_PENDING_REQUEST, address(this)) > 0;
  }

  /// @dev Reverts if claimable fills exist and no pending request is active.
  ///      When a pending request exists, claimable amounts may be polluted
  ///      by attacker deposits and should not block fund operations.
  /// @param _vault The Centrifuge vault address.
  /// @param _mode  The order mode (DEPOSIT or REDEEM).
  function _revertIfUnclaimedFills(address _vault, Mode _mode) internal view {
    if (_stateHasPendingRequest(_vault, _mode)) return;

    if (_mode == Mode.DEPOSIT) {
      if (ICentrifugeVault(_vault).maxMint(address(this)) > 0) {
        revert LibFundsErrors.PendingClaimableAssets();
      }
    } else {
      if (ICentrifugeVault(_vault).maxWithdraw(address(this)) > 0) {
        revert LibFundsErrors.PendingClaimableAssets();
      }
    }
  }

  /// @dev Returns whether a cancellation request is still pending or has claimable assets.
  ///      Used by `recover()` and `unlock()` to decide between returning PROCESSING (partial)
  ///      and ENDED (fully claimed). Internally the order stays in RECOVERING until complete.
  ///      Checks both pending (not yet processed by pool) AND claimable (processed but not yet
  ///      claimed by us), because the pool may partially process a cancellation across epochs.
  /// @param _mode  The order mode (DEPOSIT or REDEEM).
  /// @param _vault The Centrifuge vault address.
  function _stateHasPendingRecover(Mode _mode, address _vault) internal view returns (bool) {
    if (_mode == Mode.DEPOSIT) {
      return ICentrifugeVault(_vault).pendingCancelDepositRequest(_PENDING_REQUEST, address(this))
        || ICentrifugeVault(_vault).claimableCancelDepositRequest(_PENDING_REQUEST, address(this)) > 0;
    }

    return ICentrifugeVault(_vault).pendingCancelRedeemRequest(_PENDING_REQUEST, address(this))
      || ICentrifugeVault(_vault).claimableCancelRedeemRequest(_PENDING_REQUEST, address(this)) > 0;
  }

  /// @dev Reverts if the order owner is not the caller.
  /// @param order The given order.
  function _checkOrderOwner(Order calldata order) internal view {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();
  }
}
