// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {IMidasFund, SettlementMode} from "../../interfaces/funds/midas/IMidasFund.sol";
import {IMidasVault, MidasRequestStatus} from "../../interfaces/integrations/midas/IMidasVault.sol";
import {IMidasDepositVault} from "../../interfaces/integrations/midas/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "../../interfaces/integrations/midas/IMidasRedemptionVault.sol";
import {IMidasDataFeed} from "../../interfaces/integrations/midas/IMidasDataFeed.sol";
import {IMidasAccessControl} from "../../interfaces/integrations/midas/IMidasAccessControl.sol";
import {IWrappedAsset} from "../../interfaces/funds/IWrappedAsset.sol";
import {Order, State, Mode, LibOrder} from "../../libs/funds/Order.sol";
import {LibFundsErrors} from "../../libs/funds/LibFundsErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {BPS} from "../../libs/Constants.sol";

/// @title MidasFund
/// @author 3F Protocol
/// @notice Wrapper of Midas mToken issuance and redemption vaults (e.g. mGLOBAL).
/// @dev - Shares of this fund are represented by WrappedAsset tokens wrapping the mToken.
///      - The order owner and receiver is always msg.sender (the depositor contract).
///      - ACCEPTED / PENDING orders can be canceled back to EMPTY via cancel() before any assets/shares are committed.
///      - This contract uses an "internal state" pattern where the stored state (internalState) may differ
///        from the state returned by the public state() function. The state() function performs dynamic checks
///        on token balances and Midas request statuses to determine state transitions.
///      - Settlement is configurable per direction (INSTANT or REQUEST) and can be changed by the
///        owner/operator while no order is live. INSTANT orders settle synchronously at commit()
///        and are immediately unlockable; REQUEST orders wait for a Midas vault admin approval.
///      - Midas request rejections are NOT refunded on-chain: the committed input is returned
///        off-band by the Midas admin, after which the order is recoverable (the state() function
///        reports RECOVERING once the returned balance covers the effective input).
///      - The Midas vault API is base-18 denominated; this contract converts the payment token
///        amounts from/to native decimals at the boundary.
///      - IMPORTANT (operations): both this fund AND the WrappedAsset must be greenlisted by Midas
///        (e.g. `M_GLOBAL_GREENLISTED_ROLE`) when the vault greenlist is enabled or the mToken is
///        permissioned, otherwise minting/wrapping transfers revert.
contract MidasFund is IMidasFund, OwnableRoles, Initializable {
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

  /// @dev The Midas vault API and data feeds are denominated in base-18.
  uint256 internal constant _BASE18 = 1e18;

  /// @dev mTokens are always 18 decimals.
  uint256 internal constant _MTOKEN_DECIMALS = 18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the MidasFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility.
  /// @param depositVault The Midas DepositVault (issuance vault) address.
  /// @param redemptionVault The Midas RedemptionVault address.
  /// @param mToken The mToken managed by the vaults (e.g. mGLOBAL), 18 decimals.
  /// @param asset The payment token used for deposits and redemptions (e.g. USDC).
  /// @param wrappedShare The WrappedAsset contract that wraps the mToken.
  /// @param assetScale The factor converting asset native decimals to base-18 (10 ** (18 - decimals)).
  /// @param depositSettlementMode The settlement mode used for DEPOSIT orders.
  /// @param redeemSettlementMode The settlement mode used for REDEEM orders.
  /// @param internalState The stored internal state; may differ from the dynamic state returned by `state()`.
  /// @param hasResolvedAmounts Whether the operator has set resolved input/output amounts via resolve().
  /// @param currentOrderId The order ID of the current (or most recent) order.
  /// @param referrerId The Midas referrer id forwarded on deposits.
  /// @param requestId The Midas request id of the current order (REQUEST settlement only).
  /// @param resolvedInput The resolved input amount (if hasResolvedAmounts is true).
  /// @param resolvedOutput The resolved output amount (if hasResolvedAmounts is true).
  /// @param endedOrders Tracks order IDs that have reached ENDED so historical lookups return ENDED.
  struct MidasFundStorage {
    address depositVault;
    address redemptionVault;
    address mToken;
    address asset;
    address wrappedShare;
    uint256 assetScale;
    SettlementMode depositSettlementMode;
    SettlementMode redeemSettlementMode;
    State internalState;
    bool hasResolvedAmounts;
    bytes32 currentOrderId;
    bytes32 referrerId;
    uint256 requestId;
    uint256 resolvedInput;
    uint256 resolvedOutput;
    mapping(bytes32 => bool) endedOrders;
  }

  /// @dev Storage slot for the MidasFund contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("midas.fund")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0xf63eb2852d4e1464e0470aa9625d877f20c1175d59aa4273ea457c0763035400;

  /// @dev Returns a reference to the contract's storage struct.
  function _midasFundStorage() internal pure returns (MidasFundStorage storage midasFundStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      midasFundStorage.slot := _MAIN_STORAGE_SLOT
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

  /// @inheritdoc IMidasFund
  function initialize(
    address owner_,
    address depositor_,
    address depositVault_,
    address redemptionVault_,
    address wrappedShare_,
    address asset_,
    SettlementMode depositSettlementMode_,
    SettlementMode redeemSettlementMode_
  ) public override initializer {
    owner_.checkNotZero();
    depositor_.checkContract();
    depositVault_.checkContract();
    redemptionVault_.checkContract();
    wrappedShare_.checkContract();
    asset_.checkContract();

    // The mToken is derived from the deposit vault; both vaults must manage the same mToken.
    address _mToken = IMidasDepositVault(depositVault_).mToken();
    if (IMidasRedemptionVault(redemptionVault_).mToken() != _mToken) {
      revert LibFundsErrors.InvalidUnderlyingAsset();
    }

    // Verify wrappedShare wraps the mToken
    if (IWrappedAsset(wrappedShare_).underlying() != _mToken) {
      revert LibFundsErrors.InvalidUnderlyingAsset();
    }

    uint256 _mTokenDecimals = IERC20(_mToken).decimals();
    if (_mTokenDecimals != _MTOKEN_DECIMALS) {
      revert LibFundsErrors.DecimalsMismatch(_mTokenDecimals, _MTOKEN_DECIMALS);
    }

    uint256 _assetDecimals = IERC20(asset_).decimals();
    if (_assetDecimals > _MTOKEN_DECIMALS) {
      revert LibFundsErrors.DecimalsMismatch(_assetDecimals, _MTOKEN_DECIMALS);
    }

    // The payment token must be registered on both vaults.
    _checkPaymentToken(depositVault_, asset_);
    _checkPaymentToken(redemptionVault_, asset_);

    MidasFundStorage storage $ = _midasFundStorage();
    $.depositVault = depositVault_;
    $.redemptionVault = redemptionVault_;
    $.mToken = _mToken;
    $.asset = asset_;
    $.wrappedShare = wrappedShare_;
    $.assetScale = 10 ** (_MTOKEN_DECIMALS - _assetDecimals);
    $.depositSettlementMode = depositSettlementMode_;
    $.redeemSettlementMode = redeemSettlementMode_;

    _initializeOwner(owner_);
    _setRoles(depositor_, DEPOSITOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFund
  function create(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    order.input.checkNotZero();
    _validateOutput(order);
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();
    if (order.receiver != msg.sender) revert LibFundsErrors.InvalidReceiver();

    MidasFundStorage storage $ = _midasFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) revert LibFundsErrors.PendingOrder();

    // Fail early if the targeted vault would reject the commit (paused / not greenlisted).
    _checkVaultAccess(order.mode == Mode.DEPOSIT ? $.depositVault : $.redemptionVault, $.wrappedShare);

    if (_internalState == State.ENDED) {
      // Archive ended order
      $.endedOrders[$.currentOrderId] = true;
    }

    // No pending state, always accepted or revert.
    bytes32 _orderId = order.toId(address(this));
    if ($.endedOrders[_orderId]) revert LibFundsErrors.OrderAlreadyExists(_orderId);
    $.currentOrderId = _orderId;
    $.internalState = State.ACCEPTED;
    $.hasResolvedAmounts = false;
    $.resolvedInput = 0;
    $.resolvedOutput = 0;

    emit OrderCreated(_orderId, order.mode, order.owner, order.receiver, order.input, order.output);

    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function cancel(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    MidasFundStorage storage $ = _midasFundStorage();
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
  ///      Under INSTANT settlement the Midas vault settles synchronously, so the order is
  ///      immediately reported as UNLOCKING by state(). Under REQUEST settlement the committed
  ///      input leaves the fund immediately and the output is delivered when a Midas vault admin
  ///      approves the request.
  function commit(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    MidasFundStorage storage $ = _midasFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert LibFundsErrors.InvalidState($.internalState);

    SettlementMode _settlementMode;
    uint256 _requestId;

    if (order.mode == Mode.DEPOSIT) {
      address _asset = $.asset;
      address _depositVault = $.depositVault;
      _checkVaultAccess(_depositVault, $.wrappedShare);
      _settlementMode = $.depositSettlementMode;

      // Pull the payment token from the depositor and let the vault pull it (base-18 amounts).
      _asset.safeTransferFrom(msg.sender, address(this), order.input);
      _asset.safeApproveWithRetry(_depositVault, order.input);

      uint256 _amountBase18 = order.input * $.assetScale;
      if (_settlementMode == SettlementMode.INSTANT) {
        // order.output is the minimum mToken amount (already base-18); mints to this contract.
        IMidasDepositVault(_depositVault).depositInstant(_asset, _amountBase18, order.output, $.referrerId);
      } else {
        _requestId = IMidasDepositVault(_depositVault).depositRequest(_asset, _amountBase18, $.referrerId);
        $.requestId = _requestId;
      }
      _asset.safeApproveWithRetry(_depositVault, 0);
    } else {
      address _mToken = $.mToken;
      address _redemptionVault = $.redemptionVault;
      _checkVaultAccess(_redemptionVault, $.wrappedShare);
      _settlementMode = $.redeemSettlementMode;

      // Burn WrappedAsset from depositor (unwraps mToken to this contract), then let the
      // vault burn/pull it (approval covers both the escrow pull and the fee transfer).
      IWrappedAsset($.wrappedShare).burn(msg.sender, address(this), order.input);
      _mToken.safeApproveWithRetry(_redemptionVault, order.input);

      if (_settlementMode == SettlementMode.INSTANT) {
        // order.output is the minimum asset amount in native decimals; scale it to base-18.
        IMidasRedemptionVault(_redemptionVault).redeemInstant($.asset, order.input, order.output * $.assetScale);
      } else {
        _requestId = IMidasRedemptionVault(_redemptionVault).redeemRequest($.asset, order.input);
        $.requestId = _requestId;
      }
      _mToken.safeApproveWithRetry(_redemptionVault, 0);
    }

    $.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrderId, order.mode, _settlementMode, order.input, _requestId);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev No partial unlocks, always goes to ENDED. The unlocked amount is the fund's full
  ///      output-token balance (which covers the effective output threshold).
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    MidasFundStorage storage $ = _midasFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.UNLOCKING) revert LibFundsErrors.InvalidState(_currentState);

    if (order.mode == Mode.DEPOSIT) {
      // Wrap the received mToken and mint the WrappedAsset to the receiver
      address _mToken = $.mToken;
      address _wrappedShare = $.wrappedShare;
      _mToken.safeApproveWithRetry(_wrappedShare, _amount);
      IWrappedAsset(_wrappedShare).mint(order.receiver, _amount);
    } else {
      $.asset.safeTransfer(order.receiver, _amount);
    }

    $.internalState = State.ENDED;

    emit OrderUnlocked(_currentOrderId, order.mode, _amount, order.receiver);

    return (State.ENDED, _amount);
  }

  /// @inheritdoc IFund
  /// @dev No partial recoveries, always goes to ENDED. Recovery relies on the committed input
  ///      being returned to this contract off-band (Midas request rejections are not refunded
  ///      on-chain; the Midas admin returns funds via `withdrawToken`).
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    MidasFundStorage storage $ = _midasFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.RECOVERING) revert LibFundsErrors.InvalidState(_currentState);

    if (order.mode == Mode.DEPOSIT) {
      $.asset.safeTransfer(order.receiver, _amount);
    } else {
      // Wrap the returned mToken back and mint the WrappedAsset to the receiver
      address _mToken = $.mToken;
      address _wrappedShare = $.wrappedShare;
      _mToken.safeApproveWithRetry(_wrappedShare, _amount);
      IWrappedAsset(_wrappedShare).mint(order.receiver, _amount);
    }

    $.internalState = State.ENDED;

    emit OrderRecovered(_currentOrderId, order.mode, _amount, order.receiver);

    return (State.ENDED, _amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMidasFund
  function recovering(bytes32 orderId) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    MidasFundStorage storage $ = _midasFundStorage();
    if (orderId != $.currentOrderId) revert LibFundsErrors.InvalidOrder(orderId);
    if ($.internalState != State.PROCESSING) revert LibFundsErrors.InvalidState($.internalState);
    $.internalState = State.RECOVERING;

    emit OrderRecovering(orderId);
  }

  /// @inheritdoc IMidasFund
  function cancelRecovering(bytes32 orderId) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    MidasFundStorage storage $ = _midasFundStorage();
    if (orderId != $.currentOrderId) revert LibFundsErrors.InvalidOrder(orderId);
    if ($.internalState != State.RECOVERING) revert LibFundsErrors.InvalidState($.internalState);
    $.internalState = State.PROCESSING;

    emit OrderProcessing(orderId);
  }

  /// @inheritdoc IMidasFund
  function resolve(Order memory order, uint256 input, uint256 output)
    external
    override
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    MidasFundStorage storage $ = _midasFundStorage();
    State _internalState = $.internalState;
    if (_internalState != State.PROCESSING && _internalState != State.RECOVERING) {
      revert LibFundsErrors.InvalidState(_internalState);
    }
    if (order.toId(address(this)) != $.currentOrderId) {
      revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    }

    input.checkNotZero();

    $.hasResolvedAmounts = true;
    $.resolvedInput = input;
    $.resolvedOutput = output;

    emit OrderResolved($.currentOrderId, input, output, msg.sender);
  }

  /// @inheritdoc IMidasFund
  function setSettlementMode(Mode mode, SettlementMode settlementMode_)
    external
    override
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    MidasFundStorage storage $ = _midasFundStorage();
    _checkNoLiveOrder($);

    if (mode == Mode.DEPOSIT) {
      $.depositSettlementMode = settlementMode_;
    } else {
      $.redeemSettlementMode = settlementMode_;
    }

    emit SettlementModeUpdated(mode, settlementMode_, msg.sender);
  }

  /// @inheritdoc IMidasFund
  function setDepositVault(address depositVault_, SettlementMode depositSettlementMode_)
    external
    override
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    depositVault_.checkContract();

    MidasFundStorage storage $ = _midasFundStorage();
    _checkNoLiveOrder($);

    if (IMidasDepositVault(depositVault_).mToken() != $.mToken) revert LibFundsErrors.InvalidUnderlyingAsset();
    _checkPaymentToken(depositVault_, $.asset);
    _checkVaultAccess(depositVault_, $.wrappedShare);

    $.depositVault = depositVault_;
    $.depositSettlementMode = depositSettlementMode_;

    emit DepositVaultUpdated(depositVault_, msg.sender);
    emit SettlementModeUpdated(Mode.DEPOSIT, depositSettlementMode_, msg.sender);
  }

  /// @inheritdoc IMidasFund
  function setRedemptionVault(address redemptionVault_, SettlementMode redeemSettlementMode_)
    external
    override
    onlyOwnerOrRoles(OPERATOR_ROLE)
  {
    redemptionVault_.checkContract();

    MidasFundStorage storage $ = _midasFundStorage();
    _checkNoLiveOrder($);

    if (IMidasRedemptionVault(redemptionVault_).mToken() != $.mToken) revert LibFundsErrors.InvalidUnderlyingAsset();
    _checkPaymentToken(redemptionVault_, $.asset);
    _checkVaultAccess(redemptionVault_, $.wrappedShare);

    $.redemptionVault = redemptionVault_;
    $.redeemSettlementMode = redeemSettlementMode_;

    emit RedemptionVaultUpdated(redemptionVault_, msg.sender);
    emit SettlementModeUpdated(Mode.REDEEM, redeemSettlementMode_, msg.sender);
  }

  /// @inheritdoc IMidasFund
  function setReferrerId(bytes32 referrerId_) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    _midasFundStorage().referrerId = referrerId_;

    emit ReferrerIdUpdated(referrerId_, msg.sender);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMidasFund
  function depositVault() external view override returns (address) {
    return _midasFundStorage().depositVault;
  }

  /// @inheritdoc IMidasFund
  function redemptionVault() external view override returns (address) {
    return _midasFundStorage().redemptionVault;
  }

  /// @inheritdoc IMidasFund
  function mToken() external view override returns (address) {
    return _midasFundStorage().mToken;
  }

  /// @inheritdoc IMidasFund
  function settlementMode(Mode mode) external view override returns (SettlementMode) {
    MidasFundStorage storage $ = _midasFundStorage();
    return mode == Mode.DEPOSIT ? $.depositSettlementMode : $.redeemSettlementMode;
  }

  /// @inheritdoc IMidasFund
  function referrerId() external view override returns (bytes32) {
    return _midasFundStorage().referrerId;
  }

  /// @inheritdoc IMidasFund
  function activeRequestId() external view override returns (uint256) {
    return _midasFundStorage().requestId;
  }

  /// @inheritdoc IFund
  function asset() external view override returns (address) {
    return _midasFundStorage().asset;
  }

  /// @inheritdoc IFund
  function share() external view override returns (address) {
    return _midasFundStorage().wrappedShare;
  }

  /// @inheritdoc IFund
  /// @dev Converts total wrapped share supply to assets using the redemption-side data feeds
  ///      (conservative exit valuation; Midas prices mints and redemptions with separate feeds).
  ///      The returned value is derived from `$.wrappedShare.totalSupply()`, so when a single
  ///      `WrappedAsset` deployment backs multiple `MidasFund` instances, every instance
  ///      reports the same wrapper-wide aggregate AUM rather than AUM scoped to this fund.
  function totalAssets() external view override returns (uint256) {
    MidasFundStorage storage $ = _midasFundStorage();
    uint256 _supply = IERC20($.wrappedShare).totalSupply();
    if (_supply == 0) return 0;

    address _redemptionVault = $.redemptionVault;
    uint256 _mTokenRate = _getMTokenRate(_redemptionVault);
    uint256 _assetRate = _getPaymentTokenRate(_redemptionVault, $.asset);

    // shares (base-18) -> USD (base-18) -> asset (base-18) -> asset (native decimals)
    return _supply.mulDiv(_mTokenRate, _assetRate) / $.assetScale;
  }

  /// @inheritdoc IFund
  function maxDeposit(address account) external view override returns (uint256) {
    if (!hasAllRoles(account, DEPOSITOR_ROLE)) return 0;
    return IERC20(_midasFundStorage().asset).balanceOf(account);
  }

  /// @inheritdoc IFund
  function maxRedeem(address account) external view override returns (uint256) {
    if (!hasAllRoles(account, DEPOSITOR_ROLE)) return 0;
    return IERC20(_midasFundStorage().wrappedShare).balanceOf(account);
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
  ///      This function returns the dynamic state based on token balances and Midas request
  ///      statuses, which may differ from internalState.
  ///
  ///      For PROCESSING state:
  ///      - REQUEST settlement first inspects the Midas request status:
  ///        - PENDING → PROCESSING (awaiting Midas vault admin approval)
  ///        - CANCELED → RECOVERING once the returned input balance covers the effective input
  ///          (rejections are refunded off-band by the Midas admin), PROCESSING otherwise
  ///        - PROCESSED → falls through to the output balance check below
  ///      - The output balance check (also the INSTANT settlement path):
  ///        - Deposit: mToken balance >= effective output → UNLOCKING
  ///        - Redeem: asset balance >= effective output → UNLOCKING
  ///
  ///      For RECOVERING state (set manually via recovering() after an off-band refund):
  ///      - Deposit: asset balance >= effective input → RECOVERING, PROCESSING otherwise
  ///      - Redeem: mToken balance >= effective input → RECOVERING, PROCESSING otherwise
  ///
  ///      For all other states (EMPTY, ACCEPTED, ENDED), returns internalState directly.
  ///
  ///      Returns ENDED for archived orders and EMPTY for any order that is not the current order.
  /// @param order The order to check the state for.
  /// @return The current state based on dynamic checks.
  /// @return The amount available to unlock (if UNLOCKING) or recover (if RECOVERING), 0 otherwise.
  function _state(Order calldata order) internal view returns (State, uint256) {
    MidasFundStorage storage $ = _midasFundStorage();
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

    uint256 _effectiveInput = order.input;
    uint256 _effectiveOutput = order.output;

    // If order resolved, use resolved amounts
    if ($.hasResolvedAmounts) {
      _effectiveInput = $.resolvedInput;
      _effectiveOutput = $.resolvedOutput;
    }

    if (_internalState == State.PROCESSING) {
      SettlementMode _settlementMode = order.mode == Mode.DEPOSIT ? $.depositSettlementMode : $.redeemSettlementMode;

      if (_settlementMode == SettlementMode.REQUEST) {
        MidasRequestStatus _status = _getRequestStatus(order.mode, $);
        if (_status == MidasRequestStatus.PENDING) {
          return (State.PROCESSING, 0);
        }
        if (_status == MidasRequestStatus.CANCELED) {
          // Rejected by Midas; the input is returned off-band by the Midas admin.
          uint256 _recoverable = _inputBalance(order.mode, $);
          return _recoverable >= _effectiveInput ? (State.RECOVERING, _recoverable) : (State.PROCESSING, 0);
        }
        // PROCESSED falls through to the output balance check.
      }

      uint256 _amount = _outputBalance(order.mode, $);
      return _amount >= _effectiveOutput ? (State.UNLOCKING, _amount) : (State.PROCESSING, 0);
    }

    if (_internalState == State.RECOVERING) {
      uint256 _amount = _inputBalance(order.mode, $);
      return _amount >= _effectiveInput ? (State.RECOVERING, _amount) : (State.PROCESSING, 0);
    }

    return (_internalState, 0);
  }

  /// @dev Returns the Midas request status of the current order.
  /// @param _mode The order mode (DEPOSIT or REDEEM).
  /// @param $ The fund storage reference.
  function _getRequestStatus(Mode _mode, MidasFundStorage storage $) internal view returns (MidasRequestStatus) {
    if (_mode == Mode.DEPOSIT) {
      (,, MidasRequestStatus _status,,,) = IMidasDepositVault($.depositVault).mintRequests($.requestId);
      return _status;
    }

    (,, MidasRequestStatus _status,,,) = IMidasRedemptionVault($.redemptionVault).redeemRequests($.requestId);
    return _status;
  }

  /// @dev Returns this contract's balance of the order's output token
  ///      (mToken for DEPOSIT, asset for REDEEM).
  /// @param _mode The order mode (DEPOSIT or REDEEM).
  /// @param $ The fund storage reference.
  function _outputBalance(Mode _mode, MidasFundStorage storage $) internal view returns (uint256) {
    return IERC20(_mode == Mode.DEPOSIT ? $.mToken : $.asset).balanceOf(address(this));
  }

  /// @dev Returns this contract's balance of the order's input token
  ///      (asset for DEPOSIT, mToken for REDEEM).
  /// @param _mode The order mode (DEPOSIT or REDEEM).
  /// @param $ The fund storage reference.
  function _inputBalance(Mode _mode, MidasFundStorage storage $) internal view returns (uint256) {
    return IERC20(_mode == Mode.DEPOSIT ? $.asset : $.mToken).balanceOf(address(this));
  }

  /// @dev Validates that the order output is within acceptable deviation from the feed-derived
  ///      expected output. Reverts if the output deviates negatively by more than
  ///      MAX_OUTPUT_DEVIATION basis points. Uses the direction-specific vault feeds (Midas
  ///      prices mints and redemptions with separate mToken data feeds).
  /// @param order The order to validate.
  function _validateOutput(Order calldata order) internal view {
    MidasFundStorage storage $ = _midasFundStorage();
    uint256 _expectedOutput;

    if (order.mode == Mode.DEPOSIT) {
      // DEPOSIT: asset (native) → mToken (base-18)
      address _depositVault = $.depositVault;
      uint256 _mTokenRate = _getMTokenRate(_depositVault);
      uint256 _assetRate = _getPaymentTokenRate(_depositVault, $.asset);
      _expectedOutput = (order.input * $.assetScale).mulDiv(_assetRate, _mTokenRate);
    } else {
      // REDEEM: mToken (base-18) → asset (native)
      address _redemptionVault = $.redemptionVault;
      uint256 _mTokenRate = _getMTokenRate(_redemptionVault);
      uint256 _assetRate = _getPaymentTokenRate(_redemptionVault, $.asset);
      _expectedOutput = order.input.mulDiv(_mTokenRate, _assetRate) / $.assetScale;
    }

    if (order.output < _expectedOutput) {
      if (_expectedOutput - order.output > _expectedOutput * MAX_OUTPUT_DEVIATION / BPS) {
        revert LibFundsErrors.InvalidOutput();
      }
    }
  }

  /// @dev Returns the base-18 mToken/USD rate from the given vault's data feed.
  /// @param _vault The Midas vault address.
  function _getMTokenRate(address _vault) internal view returns (uint256) {
    return IMidasDataFeed(IMidasVault(_vault).mTokenDataFeed()).getDataInBase18();
  }

  /// @dev Returns the base-18 payment-token/USD rate from the given vault's token config.
  ///      Mirrors the Midas vault pricing: tokens flagged as stable are priced at a constant 1 USD.
  /// @param _vault The Midas vault address.
  /// @param _token The payment token address.
  function _getPaymentTokenRate(address _vault, address _token) internal view returns (uint256) {
    (address _dataFeed,,, bool _stable) = IMidasVault(_vault).tokensConfig(_token);
    if (_dataFeed == address(0)) revert LibFundsErrors.TokenNotSupported(_token);
    if (_stable) return _BASE18;
    return IMidasDataFeed(_dataFeed).getDataInBase18();
  }

  /// @dev Reverts if the vault would reject operations from this fund:
  ///      - the vault is globally paused, or
  ///      - the vault greenlist is enabled and this fund or the wrapped share is not greenlisted.
  ///      The wrapped share is checked because permissioned mTokens (e.g. mGLOBAL) gate every
  ///      transfer on the same greenlist role, including the fund ↔ wrapper wrap/unwrap transfers.
  /// @param _vault The Midas vault address.
  /// @param _wrappedShare The WrappedAsset address.
  function _checkVaultAccess(address _vault, address _wrappedShare) internal view {
    if (IMidasVault(_vault).paused()) revert LibFundsErrors.MidasVaultPaused();

    if (IMidasVault(_vault).greenlistEnabled()) {
      IMidasAccessControl _accessControl = IMidasAccessControl(IMidasVault(_vault).accessControl());
      bytes32 _greenlistedRole = IMidasVault(_vault).greenlistedRole();
      if (!_accessControl.hasRole(_greenlistedRole, address(this))) {
        revert LibFundsErrors.NotAllowedByFund();
      }
      if (!_accessControl.hasRole(_greenlistedRole, _wrappedShare)) {
        revert LibFundsErrors.WrappedShareNotPermissioned();
      }
    }
  }

  /// @dev Reverts if the payment token is not registered on the given vault.
  /// @param _vault The Midas vault address.
  /// @param _token The payment token address.
  function _checkPaymentToken(address _vault, address _token) internal view {
    (address _dataFeed,,,) = IMidasVault(_vault).tokensConfig(_token);
    if (_dataFeed == address(0)) revert LibFundsErrors.TokenNotSupported(_token);
  }

  /// @dev Reverts if an order is live (configuration can only change between orders).
  /// @param $ The fund storage reference.
  function _checkNoLiveOrder(MidasFundStorage storage $) internal view {
    State _internalState = $.internalState;
    if (_internalState != State.EMPTY && _internalState != State.ENDED) {
      revert LibFundsErrors.InvalidState(_internalState);
    }
  }
}
