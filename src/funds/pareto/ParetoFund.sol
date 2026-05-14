// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {IParetoFund} from "../../interfaces/funds/pareto/IParetoFund.sol";
import {IIdleCDOEpochVariant} from "../../interfaces/integrations/pareto/IIdleCDOEpochVariant.sol";
import {IIdleCreditVault} from "../../interfaces/integrations/pareto/IIdleCreditVault.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {Order, State, Mode, LibOrder} from "../../libs/funds/Order.sol";
import {LibFundsErrors} from "../../libs/funds/LibFundsErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {BPS} from "../../libs/Constants.sol";

/// @title ParetoFund
/// @author 3F Protocol
/// @notice Wrapper of the Pareto (Idle Finance) Credit Vault (IdleCDOEpochVariant).
/// @dev - Shares of this fund are represented by WrappedAsset tokens wrapping the CDO's AA tranche token.
///      - The order owner and receiver is always msg.sender (the depositor contract).
///      - Deposits are synchronous via `depositAA` (between epochs) or `depositDuringEpoch` (during a running epoch).
///        Withdrawals are epoch-gated via `requestWithdraw` + `claimWithdrawRequest`.
///      - No recovery flow: deposits are atomic (succeed or revert), withdrawals always complete after epoch ends.
///      - This contract uses an "internal state" pattern where the stored state (internalState) may differ
///        from the state returned by the public state() function. The state() function queries the CDO
///        to determine state transitions (e.g., PROCESSING → UNLOCKING when withdrawal is claimable).
contract ParetoFund is IParetoFund, OwnableRoles, Initializable {
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

  /// @notice Storage struct containing all persistent state for the ParetoFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility.
  /// @param vault The IdleCDOEpochVariant proxy address.
  /// @param internalState The stored internal state; may differ from the dynamic state returned by `state()`.
  /// @param hasResolvedAmounts Whether the operator has set resolved input/output amounts via resolve().
  /// @param wrappedShare The WrappedAsset contract that wraps the AA tranche token.
  /// @param asset The underlying asset of the vault (e.g. USDC).
  /// @param aaTranche The AA (senior) tranche token address.
  /// @param strategy The IdleCreditVault strategy contract address.
  /// @param currentOrderId The order ID of the current (or most recent) order.
  /// @param resolvedOutput The resolved output amount (if hasResolvedAmounts is true).
  /// @param depositReceived The actual AA tranche tokens received during commit() for a DEPOSIT order.
  /// @param endedOrders Tracks order IDs that have reached ENDED so historical lookups return ENDED.
  struct ParetoFundStorage {
    address vault;
    State internalState;
    bool hasResolvedAmounts;
    address wrappedShare;
    address asset;
    address aaTranche;
    address strategy;
    bytes32 currentOrderId;
    uint256 resolvedOutput;
    uint256 depositReceived;
    mapping(bytes32 => bool) endedOrders;
  }

  /// @dev Storage slot for the ParetoFund contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("pareto.fund")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0x25d550f5e3213f45c3910fd288fb480ffdef8072a13543bd1cf85ff3f7be5900;

  /// @dev Returns a reference to the contract's storage struct.
  function _paretoFundStorage() internal pure returns (ParetoFundStorage storage paretoFundStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      paretoFundStorage.slot := _MAIN_STORAGE_SLOT
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

  /// @inheritdoc IParetoFund
  function initialize(address owner_, address depositor_, address vault_, address wrappedShare_)
    public
    override
    initializer
  {
    owner_.checkNotZero();
    depositor_.checkContract();
    vault_.checkContract();
    wrappedShare_.checkContract();

    // Read derived addresses from the vault
    address _aaTranche = IIdleCDOEpochVariant(vault_).AATranche();
    if (IWrappedAsset(wrappedShare_).underlying() != _aaTranche) {
      revert LibFundsErrors.InvalidUnderlyingAsset();
    }

    ParetoFundStorage storage $ = _paretoFundStorage();
    $.vault = vault_;
    $.wrappedShare = wrappedShare_;
    $.asset = IIdleCDOEpochVariant(vault_).token();
    $.aaTranche = _aaTranche;
    $.strategy = IIdleCDOEpochVariant(vault_).strategy();

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

    ParetoFundStorage storage $ = _paretoFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) revert LibFundsErrors.PendingOrder();

    IIdleCDOEpochVariant _vault = IIdleCDOEpochVariant($.vault);
    _checkVaultAllowed(address(_vault), order.mode);

    // Refuse orders that would always revert at commit() time.
    // Deposits during a running epoch use `depositDuringEpoch`, which reverts when
    // `isDepositDuringEpochDisabled` is true. Redeems use `requestWithdraw`, which reverts
    // when `allowAAWithdrawRequest` is false (set by `startEpoch`).
    if (order.mode == Mode.DEPOSIT) {
      if (_vault.isEpochRunning() && _vault.isDepositDuringEpochDisabled()) {
        revert LibFundsErrors.DepositDuringEpochDisabled();
      }
    } else {
      if (!_vault.allowAAWithdrawRequest()) {
        revert LibFundsErrors.WithdrawRequestDisabled();
      }
    }

    if (_internalState == State.ENDED) {
      $.endedOrders[$.currentOrderId] = true;
    }

    // Slippage guard: reject if expected output deviates too far below the current rate.
    uint256 _virtualPrice = _vault.virtualPrice($.aaTranche);
    uint256 _expectedOutput =
      order.mode == Mode.DEPOSIT ? order.input.mulDiv(1e18, _virtualPrice) : order.input.mulDiv(_virtualPrice, 1e18);

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

    emit OrderCreated(_orderId, order.mode, order.owner, order.receiver, order.input, order.output);

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function cancel(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    _checkOrderOwner(order);

    ParetoFundStorage storage $ = _paretoFundStorage();
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

    ParetoFundStorage storage $ = _paretoFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert LibFundsErrors.InvalidState($.internalState);

    address _vault = $.vault;

    _checkVaultAllowed(_vault, order.mode);
    address _aaTranche = $.aaTranche;
    if (order.mode == Mode.DEPOSIT) {
      // Pull underlying asset from depositor, approve to vault, deposit into AA tranche
      address _asset = $.asset;
      _asset.safeTransferFrom(msg.sender, address(this), order.input);
      _asset.safeApproveWithRetry(_vault, order.input);
      uint256 _before = IERC20(_aaTranche).balanceOf(address(this));
      if (IIdleCDOEpochVariant(_vault).isEpochRunning()) {
        IIdleCDOEpochVariant(_vault).depositDuringEpoch(order.input, _aaTranche);
      } else {
        IIdleCDOEpochVariant(_vault).depositAA(order.input);
      }
      $.depositReceived = IERC20(_aaTranche).balanceOf(address(this)) - _before;
      _asset.safeApproveWithRetry(_vault, 0);
    } else {
      // Burn wrapped AA from depositor (unwraps to AA tranche tokens held by this contract)
      IWrappedAsset($.wrappedShare).burn(msg.sender, address(this), order.input);
      // Request epoch-gated withdrawal: CDO burns AA tokens directly (no approval needed)
      uint256 _lwrBefore = IIdleCreditVault($.strategy).lastWithdrawRequest(address(this));
      IIdleCDOEpochVariant(_vault).requestWithdraw(order.input, _aaTranche);
      // Block instant withdrawals: if the CDO routed to the instant path,
      // lastWithdrawRequest won't change and the order would be stuck in PROCESSING.
      if (IIdleCreditVault($.strategy).lastWithdrawRequest(address(this)) <= _lwrBefore) {
        revert LibFundsErrors.InstantWithdrawDetected();
      }
    }

    $.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrderId, order.mode, order.input);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);

    ParetoFundStorage storage $ = _paretoFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.UNLOCKING) revert LibFundsErrors.InvalidState(_currentState);

    if (order.mode == Mode.DEPOSIT) {
      // Wrap AA tranche tokens into WrappedAsset and send to receiver
      address _aaTranche = $.aaTranche;
      address _wrappedShare = $.wrappedShare;
      uint256 _received = $.depositReceived;
      _aaTranche.safeApproveWithRetry(_wrappedShare, _received);
      IWrappedAsset(_wrappedShare).mint(order.receiver, _received);
      _aaTranche.safeApproveWithRetry(_wrappedShare, 0);
      _amount = _received;
    } else {
      // Claim withdrawal from CDO (underlying asset arrives in this contract) and send to receiver
      address _asset = $.asset;
      uint256 _before = IERC20(_asset).balanceOf(address(this));
      IIdleCDOEpochVariant($.vault).claimWithdrawRequest();
      _amount = IERC20(_asset).balanceOf(address(this)) - _before;
      _asset.safeTransfer(order.receiver, _amount);
    }

    $.internalState = State.ENDED;

    emit OrderUnlocked(_currentOrderId, order.mode, _amount, order.receiver);

    return (State.ENDED, _amount);
  }

  /// @inheritdoc IFund
  /// @dev No recovery flow: deposits are atomic (depositAA/depositDuringEpoch succeed or revert in the same tx),
  ///      and withdrawals always complete after the epoch ends (no cancel mechanism in the CDO).
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    _checkOrderOwner(order);
    // Always revert: recovery is not applicable for Pareto CDO
    revert LibFundsErrors.RecoverNotSupported();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IParetoFund
  function resolve(Order memory order, uint256 input, uint256 output)
    external
    override
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    ParetoFundStorage storage $ = _paretoFundStorage();
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IParetoFund
  function vault() external view override returns (address) {
    return _paretoFundStorage().vault;
  }

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return _paretoFundStorage().asset;
  }

  /// @inheritdoc IFund
  function share() external view override returns (address) {
    return _paretoFundStorage().wrappedShare;
  }

  /// @inheritdoc IFund
  /// @dev Converts total wrapped share supply to assets using the CDO's virtual price.
  ///      virtualPrice is WAD-scaled (1e18) and wrappedShare totalSupply has the AA tranche's decimals (18).
  ///      Result is in underlying-asset decimals: totalSupply * virtualPrice / 1e18.
  ///      The returned value is derived from `$.wrappedShare.totalSupply()`, so when a single
  ///      `WrappedAsset` deployment backs multiple `ParetoFund` instances, every instance reports
  ///      the same wrapper-wide aggregate AUM rather than AUM scoped to this fund.
  function totalAssets() external view override returns (uint256) {
    ParetoFundStorage storage $ = _paretoFundStorage();
    return IERC20($.wrappedShare).totalSupply().mulDiv(IIdleCDOEpochVariant($.vault).virtualPrice($.aaTranche), 1e18);
  }

  /// @inheritdoc IFund
  function maxDeposit(address account) external view override returns (uint256) {
    return hasAllRoles(account, DEPOSITOR_ROLE) ? type(uint256).max : 0;
  }

  /// @inheritdoc IFund
  function maxRedeem(address account) external view override returns (uint256) {
    return hasAllRoles(account, DEPOSITOR_ROLE) ? IERC20(_paretoFundStorage().wrappedShare).balanceOf(account) : 0;
  }

  /// @inheritdoc IFund
  function state(Order calldata order) public view override returns (State) {
    ParetoFundStorage storage $ = _paretoFundStorage();
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
  ///      Queries the CDO and strategy to determine state transitions.
  ///
  ///      For PROCESSING + DEPOSIT:
  ///      - Checks `depositReceived >= order.output` → UNLOCKING with depositReceived
  ///
  ///      For PROCESSING + REDEEM:
  ///      - Checks strategy has pending withdrawal (lastWithdrawRequest > 0) AND epoch has ended → UNLOCKING
  ///      - Epoch ended = epochEndDate == 0 OR epochNumber > lastWithdrawRequest(this)
  ///      - Uses lastWithdrawRequest instead of withdrawsRequests because the latter is not set
  ///        on the apr0 path in IdleCreditVault (see _requestWithdrawApr0).
  ///
  ///      For all other states, returns internalState directly.
  function _state(Order calldata order) internal view returns (State, uint256) {
    ParetoFundStorage storage $ = _paretoFundStorage();

    State _internalState = $.internalState;

    if (_internalState == State.PROCESSING) {
      if (order.mode == Mode.DEPOSIT) {
        uint256 _expectedOutput = $.hasResolvedAmounts ? $.resolvedOutput : order.output;
        uint256 _received = $.depositReceived;
        return _received >= _expectedOutput ? (State.UNLOCKING, _received) : (State.PROCESSING, 0);
      } else {
        address _strategy = $.strategy;
        uint256 _lastRequest = IIdleCreditVault(_strategy).lastWithdrawRequest(address(this));
        if (_lastRequest > 0) {
          if (
            IIdleCDOEpochVariant($.vault).epochEndDate() == 0
              || IIdleCreditVault(_strategy).epochNumber() > _lastRequest
          ) {
            return (State.UNLOCKING, 0);
          }
        }
        return (State.PROCESSING, 0);
      }
    }

    return (_internalState, 0);
  }

  /// @dev Reverts if the order owner is not the caller.
  /// @param order The given order.
  function _checkOrderOwner(Order calldata order) internal view {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();
  }

  /// @dev Reverts if the fund wallet is not authorized to perform `mode` against the vault.
  ///      DEPOSIT requires `isWalletAllowed`. REDEEM also accepts `keyringAllowWithdraw`,
  ///      mirroring upstream IdleCDOEpochVariant.requestWithdraw which bypasses the wallet
  ///      allowlist when the vault is in open-withdraw / liquidation mode.
  function _checkVaultAllowed(address vault_, Mode mode) internal view {
    if (IIdleCDOEpochVariant(vault_).isWalletAllowed(address(this))) return;
    if (mode == Mode.REDEEM && IIdleCDOEpochVariant(vault_).keyringAllowWithdraw()) return;
    revert LibFundsErrors.NotAllowedByFund();
  }
}
