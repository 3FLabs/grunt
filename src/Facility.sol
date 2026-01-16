// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {Multicallable} from "lib/solady/src/utils/Multicallable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {EIP712} from "lib/solady/src/utils/EIP712.sol";
import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";
import {ReentrancyGuard} from "lib/solady/src/utils/ReentrancyGuard.sol";

import {IFacility, Asset, Intent, SwapParams, CreateIntentParams} from "./interfaces/IFacility.sol";
import {IIntentDescriptor} from "./interfaces/IIntentDescriptor.sol";
import {IFund} from "./interfaces/funds/IFund.sol";
import {IPositionManager} from "./interfaces/manager/IPositionManager.sol";
import {ITransferGuard} from "./interfaces/guard/ITransferGuard.sol";
import {IVaultController} from "./interfaces/request/IVaultController.sol";
import {IPositionManagerRequest} from "./interfaces/request/IPositionManagerRequest.sol";
import {IERC20} from "./interfaces/integrations/IERC20.sol";
import {Order, Mode, State} from "./libs/Order.sol";

import {TokenBalancesLib} from "./libs/facility/TokenBalancesLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

contract Facility is IFacility, ERC6909, Multicallable, OwnableRoles, Initializable, EIP712, ReentrancyGuard {
  using TokenBalancesLib for EnumerableMapLib.AddressToUint256Map;
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for operator.
  uint256 public constant FACILITATOR_ROLE = _ROLE_0;

  /// @notice Role for global swap guardians.
  uint256 public constant GUARDIAN_ROLE = _ROLE_1;

  bytes32 constant SWAP_PARAMS_TYPEHASH = keccak256(
    "SwapParams(uint256 id1,address token1,uint256 id2,address token2,uint256 amount1,uint256 amount2,uint256 deadline)"
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a required address parameter is the zero address.
  error AddressZero();

  /// @notice Thrown when the intent is already resolving.
  /// @param id The intent ID.
  error AlreadyResolving(uint256 id);

  /// @notice Thrown when the intent is already resolved.
  /// @param id The intent ID.
  error AlreadyResolved(uint256 id);

  /// @notice Thrown when the intent is not resolving.
  /// @param id The intent ID.
  error NotResolving(uint256 id);

  /// @notice Thrown when the intent is not resolved.
  /// @param id The intent ID.
  error NotResolved(uint256 id);

  /// @notice Thrown when the intent is not depositing.
  /// @param id The intent ID.
  error NotDepositing(uint256 id);

  /// @notice Thrown when the deposit cap is exceeded.
  /// @param id The intent ID.
  /// @param depositCap The configured deposit cap.
  /// @param attemptedTotal The attempted total supply after deposit.
  error DepositCapExceeded(uint256 id, uint256 depositCap, uint256 attemptedTotal);

  /// @notice Thrown when an expected asset does not match the actual asset.
  /// @param expected The expected asset address.
  /// @param actual The actual asset address.
  error AssetMismatch(address expected, address actual);

  /// @notice Thrown when no position manager is provided on either side of the intent.
  error MissingPositionManager();

  /// @notice Thrown when the guard key does not match the required position manager.
  /// @param guardKey The provided guard key.
  error InvalidGuardKey(address guardKey);

  /// @notice Thrown when an asset is expected to be a position manager but is not.
  /// @param asset The asset address that is not a position manager.
  error AssetNotPositionManager(address asset);

  /// @notice Thrown when the request has not reached a withdrawable state.
  /// @param request The request address.
  error RequestNotRepaid(address request);

  /// @notice Thrown when an amount differs from the expected value.
  /// @param expected The expected amount.
  /// @param actual The actual amount.
  error AmountMismatch(uint256 expected, uint256 actual);

  /// @notice Thrown when resolveStart is not in the future.
  /// @param resolveStart The provided resolve start timestamp.
  /// @param currentTime The current block timestamp.
  error InvalidResolveStart(uint40 resolveStart, uint40 currentTime);

  /// @notice Thrown when an intent ID does not exist.
  /// @param id The intent ID.
  error IntentNotFound(uint256 id);

  /// @notice Thrown when a TransferGuard blocks a transfer.
  /// @param guard The TransferGuard address.
  /// @param from The token sender.
  /// @param to The token receiver.
  /// @param amount The token amount.
  error TransferBlocked(address guard, address from, address to, uint256 amount);

  /// @notice Thrown when a fund order already exists.
  /// @param id The intent ID.
  error ActiveOrder(uint256 id);

  /// @notice Thrown when no fund order exists.
  /// @param id The intent ID.
  error NoActiveOrder(uint256 id);

  /// @notice Thrown when a fund order is not yet ended.
  /// @param id The intent ID.
  error OrderNotEnded(uint256 id);

  /// @notice Thrown when a fund is required but not configured.
  /// @param id The intent ID.
  error MissingFund(uint256 id);

  /// @notice Thrown when a request is required but not configured.
  /// @param id The intent ID.
  error MissingRequest(uint256 id);

  /// @notice Thrown when swap params reference the same intent.
  error SameIntent();

  /// @notice Thrown when the swap deadline has passed.
  error SwapExpired();

  /// @notice Thrown when swap amounts are zero.
  error InvalidSwapAmount();

  /// @notice Thrown when a swap digest has already been used.
  /// @param digest The used swap digest.
  error SwapDigestUsed(bytes32 digest);

  /// @notice Thrown when signatures length mismatches.
  error InvalidSignatureLength();

  /// @notice Thrown when not enough guardian signatures are provided.
  /// @param required The required number of signatures.
  /// @param provided The number of signatures provided.
  error InvalidSignatureCount(uint256 required, uint256 provided);

  /// @notice Thrown when signers are not strictly increasing.
  error InvalidSignerOrder();

  /// @notice Thrown when a signer is not a guardian.
  /// @param signer The address of the signer.
  error NotGuardian(address signer);

  /// @notice Thrown when a signature is invalid.
  /// @param signer The address of the signer.
  error InvalidSignature(address signer);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the intent descriptor is updated.
  /// @param descriptor The new descriptor address.
  event DescriptorSet(address indexed descriptor);

  event IntentCreated(
    uint256 indexed id,
    address depositAsset,
    bool depositIsPositionManager,
    address targetAsset,
    bool targetIsPositionManager,
    address indexed guardKey,
    address fund,
    address request,
    uint256 depositCap,
    uint40 resolveStart,
    uint8 quorum
  );

  event IntentTargetUpdated(
    uint256 indexed id,
    address oldTargetAsset,
    bool oldTargetIsPositionManager,
    address newTargetAsset,
    bool newTargetIsPositionManager,
    address indexed oldGuardKey,
    address indexed newGuardKey
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the Facility contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param intents Mapping from intent ID to Intent struct.
  /// @param descriptor The intent descriptor contract for generating token metadata.
  struct FacilityStorage {
    mapping(uint256 => Intent) intents;
    IIntentDescriptor descriptor;

    uint256 nextIntentId;
    mapping(bytes32 => bool) usedSwapDigests;
  }

  /// @dev Storage slot for the Facility contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("facility")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0x17225e1ce54a2d38eb42db16fff6bda9e819f9fc11384a092e92905d7c79a900;

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return facilityStorage A storage pointer to the FacilityStorage struct
  function _facilityStorage() internal pure returns (FacilityStorage storage facilityStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      facilityStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the Facility contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the depositor can execute orders.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param facilitator_ The address to be granted the FACILITATOR_ROLE (initial facilitator).
  /// @param descriptor_ The initial intent descriptor contract (can be address(0) to disable).
  function initialize(address owner_, address facilitator_, IIntentDescriptor descriptor_) public initializer {
    _checkNotZero(owner_);
    _checkNotZero(facilitator_);

    _initializeOwner(owner_);
    _setRoles(facilitator_, FACILITATOR_ROLE);

    _facilityStorage().nextIntentId = 1;

    if (address(descriptor_) != address(0)) {
      _facilityStorage().descriptor = descriptor_;
      emit DescriptorSet(address(descriptor_));
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         DESCRIPTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the current intent descriptor contract.
  /// @return The intent descriptor address.
  function descriptor() external view returns (IIntentDescriptor) {
    return _facilityStorage().descriptor;
  }

  /// @notice Sets the intent descriptor contract for generating token metadata.
  /// @dev Only callable by the owner. Can be set to address(0) to disable.
  /// @param descriptor_ The new descriptor contract address.
  function setDescriptor(IIntentDescriptor descriptor_) external onlyOwner {
    _facilityStorage().descriptor = descriptor_;
    emit DescriptorSet(address(descriptor_));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTENT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function createIntent(CreateIntentParams calldata params)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    returns (uint256 id)
  {
    FacilityStorage storage $ = _facilityStorage();

    uint256 nextId = $.nextIntentId;
    if (nextId == 0) nextId = 1;
    id = nextId;

    if (params.resolveStart <= block.timestamp) {
      revert InvalidResolveStart(params.resolveStart, uint40(block.timestamp));
    }

    _checkNotZero(params.depositAsset.asset);
    _checkNotZero(params.targetAsset.asset);
    _checkNotZero(params.guardKey);

    (address pmCollateral, address pmDebt) =
      _getPositionManagerAssets(params.depositAsset, params.targetAsset, params.guardKey);

    if (params.request != address(0)) {
      address requestAsset = IVaultController(params.request).asset();
      if (requestAsset != pmDebt) revert AssetMismatch(pmDebt, requestAsset);
    }

    if (params.fund != address(0)) {
      address fundAsset = IFund(params.fund).asset();
      if (fundAsset != pmDebt) revert AssetMismatch(pmDebt, fundAsset);
      address fundShare = IFund(params.fund).share();
      if (fundShare != pmCollateral) revert AssetMismatch(pmCollateral, fundShare);
    }

    $.nextIntentId = nextId + 1;

    Intent storage intent = $.intents[id];
    intent.depositAsset = params.depositAsset;
    intent.targetAsset = params.targetAsset;
    intent.guardKey = params.guardKey;
    intent.fund = params.fund;
    intent.request = params.request;
    intent.depositCap = params.depositCap;
    intent.resolveStart = params.resolveStart;
    intent.quorum = params.quorum;

    emit IntentCreated(
      id,
      intent.depositAsset.asset,
      intent.depositAsset.isPositionManager,
      intent.targetAsset.asset,
      intent.targetAsset.isPositionManager,
      intent.guardKey,
      intent.fund,
      intent.request,
      intent.depositCap,
      intent.resolveStart,
      intent.quorum
    );
  }

  /// @inheritdoc IFacility
  function updateTarget(uint256 id, Asset calldata newTargetAsset, address newGuardKey) external override onlyOwner {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage intent = $.intents[id];

    address oldTarget = intent.targetAsset.asset;
    bool oldTargetIsPm = intent.targetAsset.isPositionManager;
    address oldGuardKey = intent.guardKey;

    _validateUpdateTarget(intent.depositAsset, newTargetAsset, newGuardKey, intent.fund, intent.request);

    intent.targetAsset = newTargetAsset;
    intent.guardKey = newGuardKey;

    emit IntentTargetUpdated(
      id,
      oldTarget,
      oldTargetIsPm,
      intent.targetAsset.asset,
      intent.targetAsset.isPositionManager,
      oldGuardKey,
      newGuardKey
    );
  }

  /// @inheritdoc IFacility
  function lock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (_intent.resolved) revert AlreadyResolved(id);
    if (_isResolving(_intent)) revert AlreadyResolving(id);

    _intent.resolveStart = uint40(block.timestamp);

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function resolve(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (_intent.resolved) revert AlreadyResolved(id);
    if (!_isResolving(_intent)) revert NotResolving(id);

    if (_intent.request != address(0)) {
      if (!IVaultController(_intent.request).canWithdraw()) {
        revert RequestNotRepaid(_intent.request);
      }
    }

    if (_intent.fund != address(0) && _hasActiveOrder(_intent)) {
      if (IFund(_intent.fund).state(_intent.order) != State.ENDED) revert OrderNotEnded(id);
    }

    _intent.resolved = true;
    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function setDepositCap(uint256 id, uint256 newDepositCap) external override onlyRoles(FACILITATOR_ROLE) {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    _intent.depositCap = newDepositCap;
    // TODO - Emits event
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
    returns (Order memory order)
  {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // TODO - Validations
    if (!_isResolving(_intent)) revert NotResolving(id);
    if (_intent.fund == address(0)) revert MissingFund(id);
    if (_hasActiveOrder(_intent)) revert ActiveOrder(id);

    order = Order({
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: minAmountOut,
      mode: mode,
      salt: keccak256(abi.encode(address(this), block.timestamp, id))
    });

    IFund(_intent.fund).create(order);

    // TODO - Updates
    _intent.order = order;

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function cancel(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // TODO - Validations
    if (!_isResolving(_intent)) revert NotResolving(id);
    if (!_hasActiveOrder(_intent)) revert NoActiveOrder(id);

    IFund(_intent.fund).cancel(_intent.order);

    // TODO - Updates
    delete _intent.order;

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function commit(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);
    if (!_hasActiveOrder(_intent)) revert NoActiveOrder(id);

    Order memory order = _intent.order;
    address asset = IFund(_intent.fund).asset();
    address share = IFund(_intent.fund).share();
    address tokenIn = order.mode == Mode.DEPOSIT ? asset : share;

    _intent.amounts.sub(tokenIn, order.input);
    tokenIn.safeApproveWithRetry(_intent.fund, order.input);
    (, uint256 committedAmount) = IFund(_intent.fund).commit(order);

    if (committedAmount != order.input) revert AmountMismatch(order.input, committedAmount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function unlock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);
    if (!_hasActiveOrder(_intent)) revert NoActiveOrder(id);

    Order memory order = _intent.order;
    address asset = IFund(_intent.fund).asset();
    address share = IFund(_intent.fund).share();
    address tokenOut = order.mode == Mode.DEPOSIT ? share : asset;

    (State state, uint256 unlockedAmount) = IFund(_intent.fund).unlock(order);
    _intent.amounts.add(tokenOut, unlockedAmount);

    if (state == State.ENDED) {
      delete _intent.order;
    }

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function recover(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);
    if (!_hasActiveOrder(_intent)) revert NoActiveOrder(id);

    Order memory order = _intent.order;
    address asset = IFund(_intent.fund).asset();
    address share = IFund(_intent.fund).share();
    address tokenIn = order.mode == Mode.DEPOSIT ? asset : share;

    (State state, uint256 recoveredAmount) = IFund(_intent.fund).recover(order);
    _intent.amounts.add(tokenIn, recoveredAmount);

    if (state == State.ENDED) {
      delete _intent.order;
    }

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function swap(SwapParams calldata params, address[] calldata signers, bytes[] calldata signatures)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
  {
    if (params.id1 == params.id2) revert SameIntent();
    if (block.timestamp > params.deadline) revert SwapExpired();
    if (params.amount1 == 0 || params.amount2 == 0) revert InvalidSwapAmount();

    _checkNotZero(params.token1);
    _checkNotZero(params.token2);

    _requireIntentExists(params.id1);
    _requireIntentExists(params.id2);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent1 = $.intents[params.id1];
    Intent storage _intent2 = $.intents[params.id2];

    if (!_isResolving(_intent1)) revert NotResolving(params.id1);
    if (!_isResolving(_intent2)) revert NotResolving(params.id2);

    uint256 required = _intent1.quorum >= _intent2.quorum ? _intent1.quorum : _intent2.quorum;
    bytes32 digest = _swapDigest(params);

    if ($.usedSwapDigests[digest]) revert SwapDigestUsed(digest);
    $.usedSwapDigests[digest] = true;

    if (required != 0) {
      if (signers.length != signatures.length) revert InvalidSignatureLength();
      if (signers.length < required) revert InvalidSignatureCount(required, signers.length);

      address lastSigner = address(0);
      for (uint256 i = 0; i < signers.length; i++) {
        address signer = signers[i];
        if (signer <= lastSigner) revert InvalidSignerOrder();
        if (!hasAllRoles(signer, GUARDIAN_ROLE)) revert NotGuardian(signer);
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(signer, digest, signatures[i])) {
          revert InvalidSignature(signer);
        }
        lastSigner = signer;
      }
    }

    _intent1.amounts.sub(params.token1, params.amount1);
    _intent1.amounts.add(params.token2, params.amount2);
    _intent2.amounts.sub(params.token2, params.amount2);
    _intent2.amounts.add(params.token1, params.amount1);

    // TODO - Emits event
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function pull(uint256 id, uint256 amount) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);
    if (_intent.request == address(0)) revert MissingRequest(id);

    address asset = IVaultController(_intent.request).asset();

    IPositionManagerRequest(_intent.request).pullFunds(amount, bytes(""));
    _intent.amounts.add(asset, amount);
  }

  /// @inheritdoc IFacility
  function repay(uint256 id, uint256 amount) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);
    if (_intent.request == address(0)) revert MissingRequest(id);

    address asset = IVaultController(_intent.request).asset();

    _intent.amounts.sub(asset, amount);
    asset.safeApproveWithRetry(_intent.request, amount);
    IPositionManagerRequest(_intent.request).repay(amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
  {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);

    Asset storage selected = useTarget ? _intent.targetAsset : _intent.depositAsset;
    if (!selected.isPositionManager) revert AssetNotPositionManager(selected.asset);

    address positionManager = selected.asset;
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();

    if (depositAmount > 0) {
      _intent.amounts.sub(collateralAsset, depositAmount);
      collateralAsset.safeApproveWithRetry(positionManager, depositAmount);
    }

    int256 shares = IPositionManager(positionManager).deposit(depositAmount, borrowAmount);

    if (borrowAmount > 0) {
      _intent.amounts.add(debtAsset, borrowAmount);
    }

    if (shares > 0) {
      _intent.amounts.add(positionManager, uint256(shares));
    } else if (shares < 0) {
      _intent.amounts.sub(positionManager, uint256(-shares));
    }
  }

  /// @inheritdoc IFacility
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount, bool useTarget)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
  {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);

    Asset storage selected = useTarget ? _intent.targetAsset : _intent.depositAsset;
    if (!selected.isPositionManager) revert AssetNotPositionManager(selected.asset);

    address positionManager = selected.asset;
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();

    if (repayAmount > 0) {
      _intent.amounts.sub(debtAsset, repayAmount);
      debtAsset.safeApproveWithRetry(positionManager, repayAmount);
    }

    int256 shares = IPositionManager(positionManager).withdraw(withdrawAmount, repayAmount);

    if (withdrawAmount > 0) {
      _intent.amounts.add(collateralAsset, withdrawAmount);
    }

    if (shares > 0) {
      _intent.amounts.add(positionManager, uint256(shares));
    } else if (shares < 0) {
      _intent.amounts.sub(positionManager, uint256(-shares));
    }
  }

  /// @inheritdoc IFacility
  function burnManager(uint256 id, uint256 shares, bool useTarget)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
  {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);

    Asset storage selected = useTarget ? _intent.targetAsset : _intent.depositAsset;
    if (!selected.isPositionManager) revert AssetNotPositionManager(selected.asset);

    address positionManager = selected.asset;
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();

    uint256 debtAmount = IPositionManager(positionManager).debtAmount();
    uint256 totalSupply_ = IERC20(positionManager).totalSupply();
    uint256 debtNeeded = debtAmount.mulDivUp(shares, totalSupply_);

    _intent.amounts.sub(positionManager, shares);
    if (debtNeeded > 0) {
      _intent.amounts.sub(debtAsset, debtNeeded);
      debtAsset.safeApproveWithRetry(positionManager, debtNeeded);
    }

    (uint256 collateral, uint256 debt) = IPositionManager(positionManager).burn(shares);

    if (debt != debtNeeded) revert AmountMismatch(debtNeeded, debt);
    if (collateral > 0) {
      _intent.amounts.add(collateralAsset, collateral);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function deposit(uint256 id, uint256 amount) external override {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // IScreener.check(msg.sender, id, data, amount);

    if (!_isDepositing(_intent)) revert NotDepositing(id);
    uint256 attemptedTotal = _intent.totalSupply + amount;
    if (attemptedTotal > _intent.depositCap) {
      revert DepositCapExceeded(id, _intent.depositCap, attemptedTotal);
    }

    // TODO - Updates
    address depositAsset = _intent.depositAsset.asset;
    depositAsset.safeTransferFrom(msg.sender, address(this), amount);
    _intent.amounts.add(depositAsset, amount);
    _mint(msg.sender, id, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function withdraw(uint256 id, uint256 amount) external override {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isDepositing(_intent)) revert NotDepositing(id);

    // TODO - Updates
    address depositAsset = _intent.depositAsset.asset;
    _intent.amounts.sub(depositAsset, amount);
    depositAsset.safeTransfer(msg.sender, amount);
    _burn(msg.sender, id, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function claim(uint256 id) external override {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_intent.resolved) revert NotResolved(id);
    uint256 balance = balanceOf(msg.sender, id);
    if (balance == 0) return;

    uint256 supply = totalSupply(id);
    if (supply == 0) return;

    // TODO - Updates
    address[] memory tokens = _intent.amounts.keys();
    for (uint256 i = 0; i < tokens.length; i++) {
      address token = tokens[i];
      uint256 userBalance = _intent.amounts.get(token).mulDiv(balance, supply);
      _intent.amounts.sub(token, userBalance);
      token.safeTransfer(msg.sender, userBalance);
    }

    _burn(msg.sender, id, balance);

    // TODO - Emits event
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERC-6909                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ERC6909
  function decimals(uint256 id) public view override returns (uint8) {
    _requireIntentExists(id);
    FacilityStorage storage $ = _facilityStorage();
    Intent storage intent = $.intents[id];
    return IERC20(intent.depositAsset.asset).decimals();
  }

  /// @inheritdoc ERC6909
  function name(uint256 id) public view override returns (string memory) {
    IIntentDescriptor descriptor_ = _facilityStorage().descriptor;
    if (address(descriptor_) == address(0)) return "";
    return descriptor_.name(IFacility(address(this)), id);
  }

  /// @inheritdoc ERC6909
  function symbol(uint256 id) public view override returns (string memory) {
    IIntentDescriptor descriptor_ = _facilityStorage().descriptor;
    if (address(descriptor_) == address(0)) return "";
    return descriptor_.symbol(IFacility(address(this)), id);
  }

  /// @inheritdoc ERC6909
  function tokenURI(uint256 id) public view override returns (string memory) {
    IIntentDescriptor descriptor_ = _facilityStorage().descriptor;
    if (address(descriptor_) == address(0)) return "";
    return descriptor_.tokenURI(IFacility(address(this)), id);
  }

  /// @notice Returns total supply for a given intent.
  /// @param id The intent ID.
  /// @return The total supply.
  function totalSupply(uint256 id) public view returns (uint256) {
    _requireIntentExists(id);
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];
    return _intent.totalSupply;
  }

  /// @inheritdoc ERC6909
  function _beforeTokenTransfer(address from, address to, uint256 id, uint256 amount) internal override {
    _requireIntentExists(id);

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    (,, address guard) = IPositionManager(_intent.guardKey).config();
    if (guard != address(0)) {
      if (!ITransferGuard(guard).canTransfer(_intent.guardKey, from, to, amount)) {
        revert TransferBlocked(guard, from, to, amount);
      }
    }

    if (from == address(0) && to != address(0)) {
      _intent.totalSupply += amount;
    } else if (from != address(0) && to == address(0)) {
      _intent.totalSupply -= amount;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EIP-712                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc EIP712
  function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
    name = "3Facility";
    version = "1.0.0";
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts if the intent ID does not exist.
  /// @param id The intent ID to check.
  function _requireIntentExists(uint256 id) internal view {
    uint256 nextId = _facilityStorage().nextIntentId;
    if (id == 0 || id >= nextId) revert IntentNotFound(id);
  }

  /// @dev Reverts if the address is the zero address.
  /// @param addr The address to check.
  function _checkNotZero(address addr) internal pure {
    if (addr == address(0)) revert AddressZero();
  }

  function _validateUpdateTarget(
    Asset memory depositAsset,
    Asset calldata newTargetAsset,
    address newGuardKey,
    address fund,
    address request
  ) internal view {
    _checkNotZero(newTargetAsset.asset);
    _checkNotZero(newGuardKey);

    (address pmCollateral, address pmDebt) = _getPositionManagerAssets(depositAsset, newTargetAsset, newGuardKey);

    if (request != address(0)) {
      address requestAsset = IVaultController(request).asset();
      if (requestAsset != pmDebt) revert AssetMismatch(pmDebt, requestAsset);
    }

    if (fund != address(0)) {
      address fundAsset = IFund(fund).asset();
      if (fundAsset != pmDebt) revert AssetMismatch(pmDebt, fundAsset);
      address fundShare = IFund(fund).share();
      if (fundShare != pmCollateral) revert AssetMismatch(pmCollateral, fundShare);
    }
  }

  function _getPositionManagerAssets(Asset memory depositAsset, Asset memory targetAsset, address guardKey)
    internal
    view
    returns (address pmCollateral, address pmDebt)
  {
    bool depositIsPm = depositAsset.isPositionManager;
    bool targetIsPm = targetAsset.isPositionManager;

    if (!depositIsPm && !targetIsPm) revert MissingPositionManager();

    if (depositIsPm && !targetIsPm) {
      if (guardKey != depositAsset.asset) revert InvalidGuardKey(guardKey);
      return IPositionManager(guardKey).assets();
    }

    if (!depositIsPm && targetIsPm) {
      if (guardKey != targetAsset.asset) revert InvalidGuardKey(guardKey);
      (pmCollateral, pmDebt) = IPositionManager(guardKey).assets();
      if (depositAsset.asset != pmDebt) revert AssetMismatch(pmDebt, depositAsset.asset);
      return (pmCollateral, pmDebt);
    }

    if (guardKey != depositAsset.asset && guardKey != targetAsset.asset) {
      revert InvalidGuardKey(guardKey);
    }

    (pmCollateral, pmDebt) = IPositionManager(guardKey).assets();

    address otherPm = guardKey == depositAsset.asset ? targetAsset.asset : depositAsset.asset;
    (address otherCollateral, address otherDebt) = IPositionManager(otherPm).assets();
    if (otherCollateral != pmCollateral) revert AssetMismatch(pmCollateral, otherCollateral);
    if (otherDebt != pmDebt) revert AssetMismatch(pmDebt, otherDebt);
  }

  function _isResolving(Intent storage _intent) internal view returns (bool) {
    return _intent.resolveStart <= block.timestamp && !_intent.resolved;
  }

  function _isDepositing(Intent storage _intent) internal view returns (bool) {
    return !_intent.resolved && _intent.resolveStart > block.timestamp;
  }

  function _hasActiveOrder(Intent storage _intent) internal view returns (bool) {
    return _intent.order.owner != address(0);
  }

  function _swapDigest(SwapParams calldata params) internal view returns (bytes32) {
    return _hashTypedData(
      keccak256(
        abi.encode(
          SWAP_PARAMS_TYPEHASH,
          params.id1,
          params.token1,
          params.id2,
          params.token2,
          params.amount1,
          params.amount2,
          params.deadline
        )
      )
    );
  }
}
