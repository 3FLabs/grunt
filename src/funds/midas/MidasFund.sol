// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {IMidasFund, BondConfig} from "../../interfaces/funds/midas/IMidasFund.sol";
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
///        on the Midas mint request status and token balances to determine state transitions.
///      - Deposits settle asynchronously: commit() transfers the payment token to Midas via
///        `depositRequest` and the order stays PROCESSING until a Midas vault admin approves the
///        request (which mints the full mToken amount directly to this fund).
///        A rejected request is not refunded on-chain; the Midas admin returns the payment token
///        off-band and the order becomes recoverable.
///      - Redeems always follow the Repay-and-Redeem bond flow and commit in two legs. The bond
///        leg (first commit()) burns `input * bondConfig.amount / BPS` wrapped shares from the
///        depositor and forwards the unwrapped mTokens to `bondConfig.recipient` (nothing moves
///        when the bond config is empty or the bond floors to zero); the order then waits in
///        PROCESSING (asset balances are ignored) until an account with the PAYMENT_ROLE
///        confirms the bond receipt via unlockInstantRedeem() — also callable before any
///        commit to skip the bond leg when nothing is required for a specific redemption —
///        returning the order to ACCEPTED. The redeem leg (second commit()) burns the
///        remaining `input - bondPaid` shares and settles synchronously via `redeemInstant`
///        with the minimum output scaled proportionally; the full proceeds are then claimable
///        via a single terminal unlock() (possibly zero-amount) that ends the order. A settled
///        redeem cannot be recovered (the instant settlement is irreversible): recovery covers
///        deposits and unsettled bonded redeems only.
///      - Each redemption settles through a dedicated redemption vault deployed by Midas once
///        the bond is received: create() resets the stored redemption vault to address(0), and
///        setRedemptionVault() — not gated on a live order (the redemption vault carries no
///        per-order state) — must point the fund at the fresh vault before the redeem leg
///        commits. Consequently redeem orders are not feed-validated at create (their minimum
///        output is enforced on-chain by `redeemInstant` at commit) and totalAssets() uses
///        the deposit vault's data feeds, the only ones always available.
///      - Once the bond is paid the order cannot be canceled (the bond is forfeited on
///        abandonment): it either completes forward, or — while the redemption has not
///        executed — is aborted via recovering() + recover(), which ends the order (the
///        remainder shares never left the depositor; a bond returned off-band in mTokens is
///        re-wrapped into shares minted to the receiver, possibly zero).
///      - The Midas vault API is base-18 denominated; this contract converts the payment token
///        amounts from/to native decimals at the boundary.
///      - IMPORTANT (operations): both this fund AND the WrappedAsset must be greenlisted by Midas
///        (e.g. `M_GLOBAL_GREENLISTED_ROLE`) when the vault greenlist is enabled or the mToken is
///        permissioned, otherwise minting/wrapping transfers revert. The bond recipient must
///        also be greenlisted when the mToken is permissioned (mGLOBAL gates every transfer on
///        both parties), otherwise the bond leg reverts.
contract MidasFund is IMidasFund, OwnableRoles, Initializable {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using LibChecks for address;
  using LibChecks for uint256;
  using LibOrder for Order;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Maximum allowed deviation between a deposit order output and the current rate
  ///         (in basis points). Redeem outputs are not feed-validated (see _validateOutput).
  /// @dev 10_000 = 100%. E.g., 500 = 5% max deviation below current rate.
  uint256 public constant MAX_OUTPUT_DEVIATION = 500; // 5%

  /// @notice Maximum bond fraction of a redeem order input (in basis points).
  uint256 public constant MAX_BOND_AMOUNT = 500; // 5%

  /// @notice Role for operator.
  uint256 internal constant OPERATOR_ROLE = _ROLE_0;

  /// @notice Role for depositor.
  uint256 internal constant DEPOSITOR_ROLE = _ROLE_1;

  /// @notice Role for confirming bond receipts (or skipping the bond leg) via
  ///         unlockInstantRedeem() (can be held by an EOA distinct from the operator).
  uint256 internal constant PAYMENT_ROLE = _ROLE_2;

  /// @notice Role for managing the Midas vaults (can be held by an EOA distinct from the operator).
  uint256 internal constant VAULT_MANAGER_ROLE = _ROLE_3;

  /// @dev The Midas vault API and data feeds are denominated in base-18.
  uint256 internal constant _BASE18 = 1e18;

  /// @dev mTokens are always 18 decimals.
  uint256 internal constant _MTOKEN_DECIMALS = 18;

  /// @dev Midas function selectors this fund calls at commit time.
  bytes4 internal constant _DEPOSIT_REQUEST_SELECTOR = bytes4(keccak256("depositRequest(address,uint256,bytes32)"));
  bytes4 internal constant _REDEEM_INSTANT_SELECTOR = bytes4(keccak256("redeemInstant(address,uint256,uint256)"));

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the MidasFund contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility.
  /// @param depositVault The Midas DepositVault (issuance vault) address.
  /// @param redemptionVault The Midas RedemptionVault address. Reset to address(0) on every
  ///        create() (each redemption settles through a dedicated one-shot vault) and set
  ///        per-redemption via setRedemptionVault().
  /// @param mToken The mToken managed by the vaults (e.g. mGLOBAL), 18 decimals.
  /// @param asset The payment token used for deposits and redemptions (e.g. USDC).
  /// @param wrappedShare The WrappedAsset contract that wraps the mToken.
  /// @param assetScale The factor converting asset native decimals to base-18 (10 ** (18 - decimals)).
  /// @param internalState The stored internal state; may differ from the dynamic state returned by `state()`.
  /// @param hasResolvedAmounts Whether the operator has set resolved input/output amounts via resolve().
  /// @param currentOrderId The order ID of the current (or most recent) order.
  /// @param referrerId The Midas referrer id forwarded on deposits.
  /// @param requestId The Midas mint request id of the current deposit order (set at commit).
  /// @param resolvedInput The resolved input amount (if hasResolvedAmounts is true).
  /// @param resolvedOutput The resolved output amount (if hasResolvedAmounts is true).
  /// @param endedOrders Tracks order IDs that have reached ENDED so historical lookups return ENDED.
  /// @param bondConfig The Repay-and-Redeem bond configuration (amount in basis points of the
  ///        redeem input, recipient of the mToken bond). A zero amount means no bond payment is
  ///        required: the bond leg moves nothing, but redeems still wait for unlockInstantRedeem().
  /// @param instantRedeemUnlocked Whether the current order may execute `redeemInstant` at
  ///        commit. Snapshot taken at create(): true for deposits, false for redeems until
  ///        unlockInstantRedeem().
  /// @param bondPaid The bond amount (in mTokens) paid for the current order; reset on create().
  struct MidasFundStorage {
    address depositVault;
    address redemptionVault;
    address mToken;
    address asset;
    address wrappedShare;
    uint256 assetScale;
    State internalState;
    bool hasResolvedAmounts;
    bytes32 currentOrderId;
    bytes32 referrerId;
    uint256 requestId;
    uint256 resolvedInput;
    uint256 resolvedOutput;
    mapping(bytes32 => bool) endedOrders;
    BondConfig bondConfig;
    bool instantRedeemUnlocked;
    uint256 bondPaid;
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
  function initialize(address owner_, address depositor_, address depositVault_, address wrappedShare_, address asset_)
    external
    override
    initializer
  {
    owner_.checkNotZero();
    depositor_.checkContract();
    depositVault_.checkContract();
    wrappedShare_.checkContract();
    asset_.checkContract();

    // The mToken is derived from the deposit vault. No redemption vault is configured here:
    // Midas deploys a dedicated one per redemption, set via setRedemptionVault() mid-order.
    address _mToken = IMidasDepositVault(depositVault_).mToken();

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

    _checkPaymentToken(depositVault_, asset_);

    MidasFundStorage storage $ = _midasFundStorage();
    $.depositVault = depositVault_;
    $.mToken = _mToken;
    $.asset = asset_;
    $.wrappedShare = wrappedShare_;
    $.assetScale = 10 ** (_MTOKEN_DECIMALS - _assetDecimals);

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

    // Fail early if the deposit vault would reject the commit (paused / fn-paused / not
    // greenlisted). Redeems cannot be pre-checked: their dedicated redemption vault does not
    // exist yet (Midas deploys it once the bond is received).
    if (order.mode == Mode.DEPOSIT) {
      _checkVaultAccess($.depositVault, $.wrappedShare, _DEPOSIT_REQUEST_SELECTOR);
    }

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

    // Each redemption settles through a fresh one-shot vault: drop the previous order's vault
    // so a redeem can never settle through a stale one. setRedemptionVault() re-points the
    // fund once Midas deploys the vault for this redemption.
    if ($.redemptionVault != address(0)) {
      $.redemptionVault = address(0);
      emit RedemptionVaultUpdated(address(0), msg.sender);
    }

    // Redeems always follow the bond flow: the instant redemption stays locked until the bond
    // receipt is confirmed (or the bond leg is skipped) via unlockInstantRedeem(). Deposits
    // are unlocked from creation (the flag is only meaningful for redeems).
    $.instantRedeemUnlocked = order.mode == Mode.DEPOSIT;

    $.bondPaid = 0;
    $.requestId = 0;
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
    // A paid bond is forfeited on abandonment: the order completes forward or is aborted via
    // recovering() + recover() (reachable only in the re-ACCEPTED window after
    // unlockInstantRedeem(); the bond-phase PROCESSING state is already rejected above).
    if ($.bondPaid > 0) revert LibFundsErrors.BondAlreadyPaid();

    $.currentOrderId = bytes32(0);
    $.internalState = State.EMPTY;

    emit OrderCanceled(_orderId, order.mode, order.owner);

    return State.EMPTY;
  }

  /// @inheritdoc IFund
  /// @dev Always goes to PROCESSING.
  ///      - Deposit: transfers the payment token to Midas via `depositRequest` and records the
  ///        mint request id; the order stays PROCESSING until the Midas admin approves the
  ///        request (minting the mToken to this fund).
  ///      - Redeem, bond leg (instant redemption locked): pays the Repay-and-Redeem bond —
  ///        burns `input * bondConfig.amount / BPS` wrapped shares and forwards the unwrapped
  ///        mTokens to the bond recipient — without touching the redemption vault; the order
  ///        waits in PROCESSING until unlockInstantRedeem() returns it to ACCEPTED for the
  ///        redeem leg.
  ///      - Redeem, redeem leg (instant redemption unlocked): settles the remaining
  ///        `input - bondPaid` synchronously via `redeemInstant` through the per-redemption
  ///        vault configured via setRedemptionVault(); the proceeds are then claimable via a
  ///        single terminal unlock() that ends the order.
  ///      Both redeem legs return `order.input` as the committed amount (not the per-leg
  ///      amount): the depositor requires the full input to be reported on every commit and
  ///      accounts with balance deltas, so the two legs' share burns net to the order input.
  function commit(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    MidasFundStorage storage $ = _midasFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));
    if ($.internalState != State.ACCEPTED) revert LibFundsErrors.InvalidState($.internalState);

    uint256 _requestId;
    uint256 _legAmount = order.input;

    if (order.mode == Mode.DEPOSIT) {
      address _asset = $.asset;
      address _depositVault = $.depositVault;
      _checkVaultAccess(_depositVault, $.wrappedShare, _DEPOSIT_REQUEST_SELECTOR);

      // Pull the payment token from the depositor and let the vault pull it (base-18 amounts).
      _asset.safeTransferFrom(msg.sender, address(this), order.input);
      _asset.safeApproveWithRetry(_depositVault, order.input);

      // Async settlement: the mToken is minted to this fund when the Midas admin approves.
      _requestId = IMidasDepositVault(_depositVault).depositRequest(_asset, order.input * $.assetScale, $.referrerId);
      $.requestId = _requestId;
      _asset.safeApproveWithRetry(_depositVault, 0);
    } else if (!$.instantRedeemUnlocked) {
      _legAmount = _commitBondLeg($, _currentOrderId, order.input);
    } else {
      _legAmount = _commitRedeemLeg($, order);
    }

    $.internalState = State.PROCESSING;

    emit OrderCommitted(_currentOrderId, order.mode, _legAmount, _requestId);

    return (State.PROCESSING, order.input);
  }

  /// @inheritdoc IFund
  /// @dev The unlocked amount is the fund's full output-token balance (for deposits the mToken
  ///      minted on request approval, for redeems the payment token received from
  ///      `redeemInstant`). Single-shot for both modes: unlock() always ends the order. For a
  ///      redeem it may be a zero-amount finalization call (no transfer, only ends the order)
  ///      when the settlement proceeds floored to zero.
  function unlock(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    MidasFundStorage storage $ = _midasFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.UNLOCKING) revert LibFundsErrors.InvalidState(_currentState);

    if (order.mode == Mode.DEPOSIT) {
      // Wrap the received mToken and mint the WrappedAsset to the receiver
      _wrapTo($, order.receiver, _amount);
    } else if (_amount > 0) {
      // Skipped at zero amount: the terminal unlock of a zero-proceeds redeem only ends the order.
      $.asset.safeTransfer(order.receiver, _amount);
    }

    $.internalState = State.ENDED;

    emit OrderUnlocked(_currentOrderId, order.mode, _amount, order.receiver);

    return (State.ENDED, _amount);
  }

  /// @inheritdoc IFund
  /// @dev No partial recoveries, always goes to ENDED.
  ///      - Deposit: recovery relies on the committed input being returned to this contract
  ///        off-band by the Midas admin (e.g. via `withdrawToken`), which is also the refund
  ///        path for a rejected deposit request.
  ///      - Redeem: only an aborted UNSETTLED bonded redeem reaches RECOVERING (a settled
  ///        redeem completes forward via the terminal unlock()). The remainder shares never
  ///        left the depositor; the only amount possibly owed back is the bond, which Midas
  ///        returns off-band in mTokens (the token it was paid in), never in the payment
  ///        token. This sweeps the mToken balance re-wrapped 1:1 into shares minted to the
  ///        receiver, and may be a zero-amount finalization call when the bond stays
  ///        forfeited (no transfer, only ends the order; OrderRecovered fires with amount
  ///        0). Payment tokens sitting in the fund are ignored here — they are picked up by
  ///        a later order's asset-balance sweep like any donation.
  function recover(Order calldata order) external override onlyRoles(DEPOSITOR_ROLE) returns (State, uint256) {
    if (order.owner != msg.sender) revert LibFundsErrors.InvalidOwner();

    MidasFundStorage storage $ = _midasFundStorage();
    bytes32 _currentOrderId = $.currentOrderId;
    if (order.toId(address(this)) != _currentOrderId) revert LibFundsErrors.InvalidOrder(order.toId(address(this)));

    (State _currentState, uint256 _amount) = _state(order);
    if (_currentState != State.RECOVERING) revert LibFundsErrors.InvalidState(_currentState);

    // Skipped at zero amount: the terminal recover of an aborted bonded redeem with no
    // off-band bond return only ends the order.
    if (_amount > 0) {
      // The redeem refund arrives in mTokens: re-wrap it into shares for the receiver
      // (raw mTokens may not be transferable to a non-greenlisted receiver).
      if (order.mode == Mode.REDEEM) _wrapTo($, order.receiver, _amount);
      else $.asset.safeTransfer(order.receiver, _amount);
    }

    $.internalState = State.ENDED;

    emit OrderRecovered(_currentOrderId, order.mode, _amount, order.receiver);

    return (State.ENDED, _amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMidasFund
  function recovering(Order calldata order) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    MidasFundStorage storage $ = _midasFundStorage();
    bytes32 _orderId = order.toId(address(this));
    if (_orderId != $.currentOrderId) revert LibFundsErrors.InvalidOrder(_orderId);

    State _internalState = $.internalState;
    if (order.mode == Mode.REDEEM) {
      // A settled redeem (redeemInstant executed ⟺ PROCESSING with the instant redemption
      // unlocked) has irreversibly received its payout and can only complete forward via
      // the terminal unlock(). An UNSETTLED bonded redeem can be aborted: in the
      // bond phase, or re-ACCEPTED after unlockInstantRedeem() with the bond already paid.
      // The remainder shares never left the depositor, so the recovery only has to end the
      // order, re-wrapping any bond returned off-band in mTokens (possibly zero — the bond
      // may stay forfeited).
      // An uncommitted redeem (no bond paid) is rejected: cancel() is the tool there.
      if (
        (_internalState != State.PROCESSING || $.instantRedeemUnlocked)
          && (_internalState != State.ACCEPTED || $.bondPaid == 0)
      ) {
        revert LibFundsErrors.RecoverNotSupported();
      }
      // Re-lock the instant redemption so cancelRecovering() (which restores PROCESSING)
      // always lands in the consistent bond phase, never in a fake "settled" state.
      $.instantRedeemUnlocked = false;
    } else if (_internalState != State.PROCESSING) {
      revert LibFundsErrors.InvalidState(_internalState);
    }
    $.internalState = State.RECOVERING;

    emit OrderRecovering(_orderId);
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
  function unlockInstantRedeem(bytes32 orderId) external override onlyOwnerOrRoles(PAYMENT_ROLE) {
    MidasFundStorage storage $ = _midasFundStorage();
    if (orderId != $.currentOrderId) revert LibFundsErrors.InvalidOrder(orderId);
    // Rejects deposit orders (unlocked at creation), double calls, and any call after the
    // redemption executed.
    if ($.instantRedeemUnlocked) revert LibFundsErrors.InstantRedeemAlreadyUnlocked();
    State _internalState = $.internalState;
    // ACCEPTED: skip-bond path (the bond is waived before any commit); PROCESSING: bond leg done.
    if (_internalState != State.ACCEPTED && _internalState != State.PROCESSING) {
      revert LibFundsErrors.InvalidState(_internalState);
    }
    $.instantRedeemUnlocked = true;
    $.internalState = State.ACCEPTED;

    emit InstantRedeemUnlocked(orderId, msg.sender);
  }

  /// @inheritdoc IMidasFund
  function setDepositVault(address depositVault_) external override onlyOwnerOrRoles(VAULT_MANAGER_ROLE) {
    depositVault_.checkContract();

    MidasFundStorage storage $ = _midasFundStorage();
    _checkNoLiveOrder($);

    if (IMidasDepositVault(depositVault_).mToken() != $.mToken) revert LibFundsErrors.InvalidUnderlyingAsset();
    _checkPaymentToken(depositVault_, $.asset);
    _checkVaultAccess(depositVault_, $.wrappedShare, _DEPOSIT_REQUEST_SELECTOR);

    $.depositVault = depositVault_;

    emit DepositVaultUpdated(depositVault_, msg.sender);
  }

  /// @inheritdoc IMidasFund
  function setRedemptionVault(address redemptionVault_) external override onlyOwnerOrRoles(VAULT_MANAGER_ROLE) {
    redemptionVault_.checkContract();

    MidasFundStorage storage $ = _midasFundStorage();

    if (IMidasRedemptionVault(redemptionVault_).mToken() != $.mToken) revert LibFundsErrors.InvalidUnderlyingAsset();
    _checkPaymentToken(redemptionVault_, $.asset);
    _checkVaultAccess(redemptionVault_, $.wrappedShare, _REDEEM_INSTANT_SELECTOR);

    $.redemptionVault = redemptionVault_;

    emit RedemptionVaultUpdated(redemptionVault_, msg.sender);
  }

  /// @inheritdoc IMidasFund
  function setBondConfig(BondConfig calldata bondConfig_) external override onlyOwnerOrRoles(VAULT_MANAGER_ROLE) {
    if (bondConfig_.amount == 0 || bondConfig_.amount > MAX_BOND_AMOUNT || bondConfig_.recipient == address(0)) {
      revert LibFundsErrors.InvalidBondConfig();
    }

    MidasFundStorage storage $ = _midasFundStorage();
    _checkNoLiveOrder($);

    $.bondConfig = bondConfig_;

    emit BondConfigUpdated(bondConfig_.amount, bondConfig_.recipient, msg.sender);
  }

  /// @inheritdoc IMidasFund
  function removeBondConfig() external override onlyOwnerOrRoles(VAULT_MANAGER_ROLE) {
    MidasFundStorage storage $ = _midasFundStorage();
    _checkNoLiveOrder($);

    delete $.bondConfig;

    emit BondConfigUpdated(0, address(0), msg.sender);
  }

  /// @inheritdoc IMidasFund
  function setReferrerId(bytes32 referrerId_) external override onlyOwnerOrRoles(OPERATOR_ROLE) {
    // This is intentionally not gated by _checkNoLiveOrder(): the referrer id is metadata only,
    // and Midas reads it once when a deposit request is committed.
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
  function bondConfig() external view override returns (BondConfig memory) {
    return _midasFundStorage().bondConfig;
  }

  /// @inheritdoc IMidasFund
  function bondPaid() external view override returns (uint256) {
    return _midasFundStorage().bondPaid;
  }

  /// @inheritdoc IMidasFund
  function instantRedeemUnlocked() external view override returns (bool) {
    return _midasFundStorage().instantRedeemUnlocked;
  }

  /// @inheritdoc IMidasFund
  function activeRequestId() external view override returns (uint256) {
    return _midasFundStorage().requestId;
  }

  /// @inheritdoc IMidasFund
  function referrerId() external view override returns (bytes32) {
    return _midasFundStorage().referrerId;
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
  /// @dev Converts total wrapped share supply to assets using the deposit vault's data feeds:
  ///      the redemption vault is transient (reset to address(0) on every create and only set
  ///      while a redemption is settling), so the issuance-side feeds are the only ones always
  ///      available.
  ///      The returned value is derived from `$.wrappedShare.totalSupply()`, so when a single
  ///      `WrappedAsset` deployment backs multiple `MidasFund` instances, every instance
  ///      reports the same wrapper-wide aggregate AUM rather than AUM scoped to this fund.
  function totalAssets() external view override returns (uint256) {
    MidasFundStorage storage $ = _midasFundStorage();
    uint256 _supply = IERC20($.wrappedShare).totalSupply();
    if (_supply == 0) return 0;

    address _depositVault = $.depositVault;
    uint256 _mTokenRate = _getMTokenRate(_depositVault);
    uint256 _assetRate = _getPaymentTokenRate(_depositVault, $.asset);

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
  ///      This function returns the dynamic state based on the Midas request status and token
  ///      balances, which may differ from internalState.
  ///
  ///      For PROCESSING state:
  ///      - Deposit (async request settlement): while the mint request is PENDING → PROCESSING.
  ///        If the request was CANCELED (rejected by Midas), the input is refunded off-band:
  ///        asset balance >= effective input → RECOVERING, PROCESSING otherwise. Once PROCESSED,
  ///        mToken balance >= effective output → UNLOCKING.
  ///      - Redeem, bond phase (instant redemption locked): always PROCESSING with no
  ///        claimable amount — asset balances (donations) are ignored until the redemption
  ///        executes; the order is waiting for unlockInstantRedeem().
  ///      - Redeem, settled (instant redemption unlocked): always UNLOCKING with the full
  ///        asset balance — `redeemInstant` paid synchronously at commit, so the proceeds are
  ///        claimable in one shot; the balance may be zero (proceeds floored to zero),
  ///        allowing a zero-amount terminal unlock. The minimum output was already enforced
  ///        on-chain by `redeemInstant` at commit, so resolved amounts do not affect redeem
  ///        state.
  ///
  ///      For RECOVERING state (set manually via recovering()):
  ///      - Deposit (off-band refund expected): asset balance >= effective input → RECOVERING,
  ///        PROCESSING otherwise.
  ///      - Redeem (aborted unsettled bonded redeem): always RECOVERING with the full mToken
  ///        balance — the remainder shares never left the depositor and the only amount
  ///        possibly owed back is the bond, returned off-band in mTokens, so recover() may
  ///        finalize with a zero amount when the bond stays forfeited.
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
      if (order.mode == Mode.DEPOSIT) {
        // Deposits settle asynchronously: wait for the Midas admin decision on the mint request.
        MidasRequestStatus _status = _mintRequestStatus($);
        if (_status == MidasRequestStatus.PENDING) return (State.PROCESSING, 0);
        if (_status == MidasRequestStatus.CANCELED) {
          // Rejected by Midas; the input is returned off-band by the Midas admin.
          uint256 _recoverable = IERC20($.asset).balanceOf(address(this));
          return _recoverable >= _effectiveInput ? (State.RECOVERING, _recoverable) : (State.PROCESSING, 0);
        }
        // PROCESSED: the full mToken amount is minted in one shot on request approval.
        uint256 _minted = _outputBalance(Mode.DEPOSIT, $);
        return _minted < _effectiveOutput ? (State.PROCESSING, 0) : (State.UNLOCKING, _minted);
      }

      // Bond phase: the redemption has not executed; ignore asset balances (donations cannot
      // fake UNLOCKING); the order is waiting for unlockInstantRedeem().
      if (!$.instantRedeemUnlocked) return (State.PROCESSING, 0);

      // Settled: `redeemInstant` paid the proceeds synchronously at commit, so the full asset
      // balance is claimable in one shot. UNLOCKING even at zero balance, so a zero-proceeds
      // redeem can still be finalized without a transfer.
      return (State.UNLOCKING, _outputBalance(Mode.REDEEM, $));
    }

    if (_internalState == State.RECOVERING) {
      // An aborted redeem is always recoverable: the remainder shares never left the
      // depositor and the only amount possibly owed back is the bond, returned off-band in
      // mTokens (maybe never — recover() may finalize with a zero amount).
      if (order.mode == Mode.REDEEM) return (State.RECOVERING, IERC20($.mToken).balanceOf(address(this)));
      uint256 _amount = IERC20($.asset).balanceOf(address(this));
      return _amount >= _effectiveInput ? (State.RECOVERING, _amount) : (State.PROCESSING, 0);
    }

    return (_internalState, 0);
  }

  /// @dev Bond leg of a bonded redeem commit: pays the Repay-and-Redeem bond in mTokens to the
  ///      Midas-specified wallet by burning the bond fraction of the depositor's wrapped shares
  ///      (unwrapping to this contract) and forwarding the mTokens to the bond recipient.
  ///      The redemption vault is not touched; the order waits in PROCESSING until the bond
  ///      receipt is confirmed via unlockInstantRedeem(). No vault access check: the mToken
  ///      transfer itself enforces the greenlist for permissioned tokens. If the bond floors
  ///      to zero, no tokens move but the order still waits for unlockInstantRedeem().
  /// @param $ The fund storage reference.
  /// @param _orderId The current order id (for the BondPaid event).
  /// @param _input The order input amount (wrapped shares).
  /// @return The bond amount paid.
  function _commitBondLeg(MidasFundStorage storage $, bytes32 _orderId, uint256 _input) internal returns (uint256) {
    uint256 _bondAmount = _input * $.bondConfig.amount / BPS;
    if (_bondAmount > 0) {
      address _recipient = $.bondConfig.recipient;
      IWrappedAsset($.wrappedShare).burn(msg.sender, address(this), _bondAmount);
      $.mToken.safeTransfer(_recipient, _bondAmount);
      $.bondPaid = _bondAmount;

      emit BondPaid(_orderId, _bondAmount, _recipient);
    }
    return _bondAmount;
  }

  /// @dev Redeem leg of a redeem commit: burns the WrappedAsset from the depositor (unwraps
  ///      mToken to this contract), then lets the vault burn/pull it (approval covers both the
  ///      escrow pull and the fee transfer). Only settles the remainder: the bond fraction (if
  ///      any) was already burned by the bond leg. The redemption vault is reset on create()
  ///      and set per-redemption, so it must have been configured via setRedemptionVault()
  ///      before this leg commits (reverts with InvalidContract otherwise).
  /// @param $ The fund storage reference.
  /// @param order The order being committed.
  /// @return The mToken amount redeemed (order input minus the bond paid).
  function _commitRedeemLeg(MidasFundStorage storage $, Order calldata order) internal returns (uint256) {
    address _mToken = $.mToken;
    address _redemptionVault = $.redemptionVault;
    _redemptionVault.checkContract();
    _checkVaultAccess(_redemptionVault, $.wrappedShare, _REDEEM_INSTANT_SELECTOR);

    uint256 _redeemAmount = order.input - $.bondPaid;
    IWrappedAsset($.wrappedShare).burn(msg.sender, address(this), _redeemAmount);
    _mToken.safeApproveWithRetry(_redemptionVault, _redeemAmount);

    // order.output is the minimum asset amount in native decimals for the full input; scale it
    // proportionally to the non-bond remainder (floor), then to base-18.
    IMidasRedemptionVault(_redemptionVault)
      .redeemInstant($.asset, _redeemAmount, order.output.mulDiv(_redeemAmount, order.input) * $.assetScale);
    _mToken.safeApproveWithRetry(_redemptionVault, 0);
    return _redeemAmount;
  }

  /// @dev Returns the Midas mint request status of the current deposit order.
  /// @param $ The fund storage reference.
  function _mintRequestStatus(MidasFundStorage storage $) internal view returns (MidasRequestStatus) {
    (,, MidasRequestStatus _status,,,) = IMidasDepositVault($.depositVault).mintRequests($.requestId);
    return _status;
  }

  /// @dev Returns this contract's balance of the order's output token
  ///      (mToken for DEPOSIT, asset for REDEEM).
  /// @param _mode The order mode (DEPOSIT or REDEEM).
  /// @param $ The fund storage reference.
  function _outputBalance(Mode _mode, MidasFundStorage storage $) internal view returns (uint256) {
    return IERC20(_mode == Mode.DEPOSIT ? $.mToken : $.asset).balanceOf(address(this));
  }

  /// @dev Wraps `_amount` of the mToken held by this contract into the WrappedAsset, minting
  ///      the shares 1:1 to `_receiver` (the exact-amount approval is fully consumed by the
  ///      wrapper's pull).
  /// @param $ The fund storage reference.
  /// @param _receiver The recipient of the minted shares.
  /// @param _amount The mToken amount to wrap.
  function _wrapTo(MidasFundStorage storage $, address _receiver, uint256 _amount) internal {
    address _wrappedShare = $.wrappedShare;
    $.mToken.safeApproveWithRetry(_wrappedShare, _amount);
    IWrappedAsset(_wrappedShare).mint(_receiver, _amount);
  }

  /// @dev Validates that a deposit order's output is within acceptable deviation from the
  ///      feed-derived expected output (asset native → mToken base-18, priced by the deposit
  ///      vault's feeds). Reverts if the output deviates negatively by more than
  ///      MAX_OUTPUT_DEVIATION basis points. This is a create-time sanity bound only: the
  ///      actual mint amount is set by the NAV rate at which the Midas admin approves the
  ///      request. Redeem orders are not feed-validated: their dedicated vault (and its
  ///      redemption-side pricing, which may deviate from the issuance-side feeds by more
  ///      than the allowed bound) does not exist at create time — the order output is the
  ///      minimum payout enforced on-chain by `redeemInstant` when the redeem leg commits.
  /// @param order The order to validate.
  function _validateOutput(Order calldata order) internal view {
    if (order.mode != Mode.DEPOSIT) return;

    MidasFundStorage storage $ = _midasFundStorage();
    address _depositVault = $.depositVault;
    uint256 _mTokenRate = _getMTokenRate(_depositVault);
    uint256 _assetRate = _getPaymentTokenRate(_depositVault, $.asset);
    uint256 _expectedOutput = (order.input * $.assetScale).mulDiv(_assetRate, _mTokenRate);

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
  ///      - the targeted vault function is paused, or
  ///      - the vault greenlist is enabled and this fund or the wrapped share is not greenlisted.
  ///      The wrapped share is checked because permissioned mTokens (e.g. mGLOBAL) gate every
  ///      transfer on the same greenlist role, including the fund ↔ wrapper wrap/unwrap transfers.
  /// @param _vault The Midas vault address.
  /// @param _wrappedShare The WrappedAsset address.
  /// @param _selector The Midas vault function selector called by the order.
  function _checkVaultAccess(address _vault, address _wrappedShare, bytes4 _selector) internal view {
    if (IMidasVault(_vault).paused()) revert LibFundsErrors.MidasVaultPaused();
    if (IMidasVault(_vault).fnPaused(_selector)) revert LibFundsErrors.MidasVaultFunctionPaused(_selector);

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
