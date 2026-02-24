// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {ICentrifugeFund} from "../../interfaces/funds/centrifuge/ICentrifugeFund.sol";
import {ICentrifugeVault} from "../../interfaces/integrations/centrifuge/ICentrifugeVault.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {Order, State, Mode, LibOrder} from "../../libs/funds/Order.sol";
import {LibFundsErrors} from "../../libs/funds/LibFundsErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";

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
contract CentrifugeFund is ICentrifugeFund, OwnableRoles, Initializable {
  using SafeTransferLib for address;
  using LibChecks for address;
  using LibChecks for uint256;
  using LibOrder for Order;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for operator.
  uint256 public constant OPERATOR_ROLE = _ROLE_0;

  /// @notice Role for depositor.
  uint256 public constant DEPOSITOR_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the CentrifugeFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility.
  struct CentrifugeFundStorage {
    address vault;
    address wrappedShare;
    address asset;
    address shareToken;
    bytes32 currentOrderId;
    State internalState;
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
      revert LibFundsErrors.InvalidReceiver();
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
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();
    if (order.receiver != msg.sender) revert LibFundsErrors.InvalidReceiver();

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) revert LibFundsErrors.PendingOrder();

    if (!ICentrifugeVault($.vault).isPermissioned(address(this))) {
      revert LibFundsErrors.NotAllowedToOperateWithVault();
    }

    if (_internalState == State.ENDED) {
      // Archive ended order
      $.endedOrders[$.currentOrderId] = true;
    }

    if (order.mode == Mode.DEPOSIT) {
      if (order.output > ICentrifugeVault($.vault).convertToShares(order.input)) {
        revert LibFundsErrors.InvalidOutput();
      }
    } else {
      if (order.output > ICentrifugeVault($.vault).convertToAssets(order.input)) {
        revert LibFundsErrors.InvalidOutput();
      }
    }

    bytes32 _orderId = order.toId(address(this));
    $.currentOrderId = _orderId;
    $.internalState = State.ACCEPTED;

    emit OrderCreated(_orderId, order.mode, order.owner, order.receiver, order.input, order.output);

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function cancel(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    bytes32 _orderId = order.toId(address(this));
    if (_orderId != _currentOrderId) revert LibFundsErrors.InvalidOrder(_orderId);

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
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert LibFundsErrors.InvalidState($.internalState);

    address _vault = $.vault;
    if (order.mode == Mode.DEPOSIT) {
      // Pull asset from depositor, approve vault, request deposit
      $.asset.safeTransferFrom(msg.sender, address(this), order.input);
      $.asset.safeApproveWithRetry(_vault, order.input);
      ICentrifugeVault(_vault).requestDeposit(order.input, address(this), address(this));
    } else {
      // Burn WrappedAsset from depositor (unwraps to share tokens held by this contract)
      IWrappedAsset($.wrappedShare).burn(msg.sender, address(this), order.input);
      // Approve share tokens to vault and request redeem
      $.shareToken.safeApproveWithRetry(_vault, order.input);
      ICentrifugeVault(_vault).requestRedeem(order.input, address(this), address(this));
    }

    $.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrderId, order.mode, order.input);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev Supports partial unlocks when requests remain pending.
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState,) = _state(order);
    if (_currentState != State.UNLOCKING) revert LibFundsErrors.InvalidState($.internalState);

    address _vault = $.vault;
    uint256 _amount;

    if (order.mode == Mode.DEPOSIT) {
      // Claim deposited share tokens from vault
      ICentrifugeVault(_vault).mint(ICentrifugeVault(_vault).maxMint(address(this)), address(this), address(this));
      // Wrap share tokens into WrappedAsset and send to receiver
      _amount = IERC20($.shareToken).balanceOf(address(this));
      $.shareToken.safeApproveWithRetry($.wrappedShare, _amount);
      IWrappedAsset($.wrappedShare).mint(order.receiver, _amount);
    } else {
      // Claim redeemed assets from vault
      ICentrifugeVault(_vault).withdraw(ICentrifugeVault(_vault).maxWithdraw(address(this)), address(this), address(this));
      // Transfer assets to receiver
      _amount = IERC20($.asset).balanceOf(address(this));
      $.asset.safeTransfer(order.receiver, _amount);
    }
  
    bool _hasPendingRequest = _stateHasPendingRequest(_vault, order.mode);
    $.internalState = _hasPendingRequest ? State.PROCESSING : State.ENDED;

    emit OrderUnlocked(_currentOrderId, order.mode, _amount, order.receiver);

    return ($.internalState, _amount);
  }

  /// @inheritdoc IFund
  /// @dev Supports partial recoveries while cancellation requests are still pending.
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState,) = _state(order);
    if (_currentState != State.RECOVERING) revert LibFundsErrors.InvalidState($.internalState);

    address _vault = $.vault;
    uint256 _amount;

    if (order.mode == Mode.DEPOSIT) {
      // Claim cancelled deposit (returns assets)
      ICentrifugeVault(_vault).claimCancelDepositRequest(0, address(this), address(this));
      _amount = IERC20($.asset).balanceOf(address(this));
      $.asset.safeTransfer(order.receiver, _amount);
    } else {
      // Claim cancelled redeem (returns share tokens)
      ICentrifugeVault(_vault).claimCancelRedeemRequest(0, address(this), address(this));
      // Wrap share tokens and send to receiver
      _amount = IERC20($.shareToken).balanceOf(address(this));
      $.shareToken.safeApproveWithRetry($.wrappedShare, _amount);
      IWrappedAsset($.wrappedShare).mint(order.receiver, _amount);
    }

    bool _hasPendingRecover = _stateHasPendingRecover(order.mode, _vault);
    $.internalState = _hasPendingRecover ? State.RECOVERING : State.ENDED;

    emit OrderRecovered(_currentOrderId, order.mode, _amount, order.receiver);

    return ($.internalState, _amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ICentrifugeFund
  function cancelRequest(Order calldata order) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    if ($.internalState != State.PROCESSING) revert LibFundsErrors.InvalidState($.internalState);
    if (order.toId(address(this)) != $.currentOrderId) {
      revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    }

    $.internalState = State.RECOVERING;

    address _vault = $.vault;

    if (order.mode == Mode.DEPOSIT) {
      ICentrifugeVault(_vault).cancelDepositRequest(0, address(this));
    } else {
      ICentrifugeVault(_vault).cancelRedeemRequest(0, address(this));
    }

    emit CancelRequestSubmitted($.currentOrderId);
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
  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /// @inheritdoc IFund
  function maxRedeem(address account) external view override returns (uint256) {
    return IERC20(_centrifugeFundStorage().wrappedShare).balanceOf(account);
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
  ///      Queries the Centrifuge vault for claimable amounts to determine state transitions.
  ///
  ///      For PROCESSING state:
  ///      - Deposit: checks vault.maxMint(this) > 0 → UNLOCKING
  ///      - Redeem: checks vault.maxWithdraw(this) > 0 → UNLOCKING
  ///
  ///      For RECOVERING state (after cancelRequest submitted):
  ///      - Deposit: checks vault.claimableCancelDepositRequest(0, this) > 0 → RECOVERING
  ///      - Redeem: checks vault.claimableCancelRedeemRequest(0, this) > 0 → RECOVERING
  ///      - If not yet claimable, falls back to PROCESSING
  ///
  ///      For all other states, returns internalState directly.
  function _state(Order calldata order) internal view returns (State, uint256) {
    CentrifugeFundStorage storage $ = _centrifugeFundStorage();
    bytes32 _orderId = order.toId(address(this));

    // Return ENDED for archived orders
    if ($.endedOrders[_orderId]) {
      return (State.ENDED, 0);
    }

    // Return EMPTY to indicate this order doesn't exist
    if (_orderId != $.currentOrderId) {
      return (State.EMPTY, 0);
    }

    State _internalState = $.internalState;
    address _vault = $.vault;

    if (_internalState == State.PROCESSING) {
      if (order.mode == Mode.DEPOSIT) {
        uint256 _claimable = ICentrifugeVault(_vault).maxMint(address(this));
        return _claimable > 0 ? (State.UNLOCKING, _claimable) : (State.PROCESSING, 0);
      } else {
        uint256 _claimable = ICentrifugeVault(_vault).maxWithdraw(address(this));
        return _claimable > 0 ? (State.UNLOCKING, _claimable) : (State.PROCESSING, 0);
      }
    }

    if (_internalState == State.RECOVERING) {
      uint256 _claimable;
      bool _hasPending;

      if (order.mode == Mode.DEPOSIT) {
        _claimable = ICentrifugeVault(_vault).claimableCancelDepositRequest(0, address(this));
        _hasPending = _claimable > 0 || ICentrifugeVault(_vault).pendingCancelDepositRequest(0, address(this));
      } else {
        _claimable = ICentrifugeVault(_vault).claimableCancelRedeemRequest(0, address(this));
        _hasPending = _claimable > 0 || ICentrifugeVault(_vault).pendingCancelRedeemRequest(0, address(this));
      }

      return _hasPending ? (State.RECOVERING, _claimable) : (State.PROCESSING, 0);
    }

    return (_internalState, 0);
  }

  /// @dev Returns whether the deposit/redeem request is still pending for this controller.
  function _stateHasPendingRequest(address _vault, Mode _mode) internal view returns (bool) {
    if (_mode == Mode.DEPOSIT) {
      return ICentrifugeVault(_vault).pendingDepositRequest(0, address(this)) > 0;
    }

    return ICentrifugeVault(_vault).pendingRedeemRequest(0, address(this)) > 0;
  }

  /// @dev Returns whether a cancellation request is still pending or claimable.
  function _stateHasPendingRecover(Mode _mode, address _vault) internal view returns (bool) {
    if (_mode == Mode.DEPOSIT) {
      return ICentrifugeVault(_vault).pendingCancelDepositRequest(0, address(this))
        || ICentrifugeVault(_vault).claimableCancelDepositRequest(0, address(this)) > 0;
    }

    return ICentrifugeVault(_vault).pendingCancelRedeemRequest(0, address(this))
      || ICentrifugeVault(_vault).claimableCancelRedeemRequest(0, address(this)) > 0;
  }
}
