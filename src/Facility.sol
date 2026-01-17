// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {Multicallable} from "lib/solady/src/utils/Multicallable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {EIP712} from "lib/solady/src/utils/EIP712.sol";
import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";

import {IFacility} from "./interfaces/facility/IFacility.sol";
import {IFacilityIntents} from "./interfaces/facility/base/IFacilityIntents.sol";
import {IFacilityFunds} from "./interfaces/facility/base/IFacilityFunds.sol";
import {IFacilityRequests} from "./interfaces/facility/base/IFacilityRequests.sol";
import {IFacilityPositionManager} from "./interfaces/facility/base/IFacilityPositionManager.sol";
import {IFacilityLP} from "./interfaces/facility/base/IFacilityLP.sol";
import {IFacilitySwap, SwapParams} from "./interfaces/facility/base/IFacilitySwap.sol";
import {IIntentDescriptor} from "./interfaces/facility/IIntentDescriptor.sol";
import {Intent, IntentProperties, Asset} from "./libs/facility/LibIntent.sol";
import {IFund} from "./interfaces/funds/IFund.sol";
import {IPositionManager} from "./interfaces/manager/IPositionManager.sol";
import {ITransferGuard} from "./interfaces/guard/ITransferGuard.sol";
import {IVaultController} from "./interfaces/request/IVaultController.sol";
import {IRequestInteractions} from "./interfaces/request/IRequestInteractions.sol";
import {IERC20} from "./interfaces/integrations/IERC20.sol";
import {Order, Mode, State, Id} from "./libs/Order.sol";

import {TokenBalancesLib} from "./libs/facility/TokenBalancesLib.sol";
import {LibStorage, FacilityStorageData} from "./libs/facility/LibStorage.sol";
import {LibErrors} from "./libs/facility/LibErrors.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

contract Facility is IFacility, ERC6909, Multicallable, OwnableRoles, Initializable, EIP712, ReentrancyGuardTransient {
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

  /// @notice EIP-712 typehash for SwapParams struct.
  bytes32 constant SWAP_PARAMS_TYPEHASH = keccak256(
    "SwapParams(uint256 id1,address token1,uint256 id2,address token2,uint256 amount1,uint256 amount2,uint256 deadline)"
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the Facility contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the depositor can execute orders.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param facilitator_ The address to be granted the FACILITATOR_ROLE (initial facilitator).
  /// @param descriptor_ The initial intent descriptor contract.
  function initialize(address owner_, address facilitator_, address descriptor_) public initializer {
    _checkNotZero(owner_);
    _initializeOwner(owner_);
    _setDescriptor(descriptor_);
    _setRoles(facilitator_, FACILITATOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         DESCRIPTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function setDescriptor(address descriptor_) external onlyOwner {
    _setDescriptor(descriptor_);
  }

  /// @dev Internal function to set the intent descriptor contract.
  /// @param descriptor_ The new descriptor contract address.
  function _setDescriptor(address descriptor_) internal {
    _checkContract(descriptor_);
    LibStorage.facilityStorage().descriptor = IIntentDescriptor(descriptor_);
    emit DescriptorSet(descriptor_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTENT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityIntents
  function createIntent(IntentProperties calldata params)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    returns (uint256 id)
  {
    FacilityStorageData storage $ = LibStorage.facilityStorage();

    id = $.lastIntentId + 1;

    if (params.resolveStart <= block.timestamp) {
      revert LibErrors.InvalidResolveStart(params.resolveStart, uint40(block.timestamp));
    }
    _checkContract(params.depositAsset.asset);
    _checkContract(params.targetAsset.asset);
    _checkContract(params.guardKey);

    $.lastIntentId = id;

    Intent storage intent = $.intents[id];

    // Sets the intent immutable properties.
    intent.properties.depositAsset = params.depositAsset;
    intent.properties.quorum = params.quorum;
    emit IntentCreated(id, params.depositAsset, params.quorum);

    // Checks and updates the target asset and guard key based on the deposit asset.
    _updateTargetAsset(id, intent, params.depositAsset, params.targetAsset, params.guardKey);

    // Updates the deposit cap.
    _updateDepositCap(id, intent, params.depositCap);

    // Updates the resolve start.
    _updateResolveStart(id, intent, params.resolveStart);
  }

  /// @inheritdoc IFacilityIntents
  function updateTarget(uint256 id, Asset calldata newTargetAsset, address newGuardKey) external override onlyOwner {
    _requireIntentExists(id);
    _checkContract(newTargetAsset.asset);
    _checkContract(newGuardKey);
    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    _updateTargetAsset(id, _intent, _intent.properties.depositAsset, newTargetAsset, newGuardKey);
  }

  /// @inheritdoc IFacilityIntents
  function lock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (_intent.resolved) revert LibErrors.AlreadyResolved(id);
    if (_isResolving(_intent)) revert LibErrors.AlreadyResolving(id);

    _updateResolveStart(id, _intent, uint40(block.timestamp));
  }

  /// @inheritdoc IFacilityIntents
  function resolve(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (_intent.resolved) revert LibErrors.AlreadyResolved(id);
    if (!_isResolving(_intent)) revert LibErrors.NotResolving(id);

    address _request = _intent.request;
    if (_request != address(0) && !IVaultController(_request).canWithdraw()) {
      revert LibErrors.RequestNotRepaid(_request);
    }

    // TODO - Check if needed or not...
    // It's possible to resolve multiple times if needed, always overriding the previous resolution.
    if (_hasActiveOrder(_intent)) revert LibErrors.NoActiveOrder(id);

    _intent.resolved = true;
    emit IntentResolved(id);
  }

  /// @inheritdoc IFacilitySwap
  function swap(SwapParams calldata params, address[] calldata signers, bytes[] calldata signatures)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
  {
    if (params.id1 == params.id2) revert LibErrors.SameIntent();
    if (block.timestamp > params.deadline) revert LibErrors.SwapExpired();
    if (params.amount1 == 0 || params.amount2 == 0) revert LibErrors.InvalidSwapAmount();

    {
      _requireIntentExists(params.id1);
      _requireIntentExists(params.id2);

      FacilityStorageData storage $ = LibStorage.facilityStorage();
      Intent storage intent1 = $.intents[params.id1];
      Intent storage intent2 = $.intents[params.id2];

      if (!_isResolving(intent1)) revert LibErrors.NotResolving(params.id1);
      if (!_isResolving(intent2)) revert LibErrors.NotResolving(params.id2);

      // take the higher quorum
      uint256 _required =
        intent1.properties.quorum >= intent2.properties.quorum ? intent1.properties.quorum : intent2.properties.quorum;

      bytes32 _digest = _swapDigest(params);

      if ($.usedSwapDigests[_digest]) revert LibErrors.SwapDigestUsed(_digest);
      $.usedSwapDigests[_digest] = true;

      _verifySwapSignatures(_digest, signers, signatures, _required);

      intent1.amounts.sub(params.token1, params.amount1);
      intent1.amounts.add(params.token2, params.amount2);
      intent2.amounts.sub(params.token2, params.amount2);
      intent2.amounts.add(params.token1, params.amount1);
    }

    emit Swap(params.id1, params.id2, params.token1, params.amount1, params.token2, params.amount2);
  }

  /// @inheritdoc IFacilityIntents
  function setDepositCap(uint256 id, uint256 newDepositCap) external override onlyRoles(FACILITATOR_ROLE) {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    _updateDepositCap(id, _intent, newDepositCap);
  }

  /// @inheritdoc IFacilityIntents
  function setFund(uint256 id, address newFund) external onlyRoles(FACILITATOR_ROLE) {
    _checkContract(newFund);
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (_hasActiveOrder(_intent)) revert LibErrors.ActiveOrder(id);

    (address _pmCollateral, address _pmDebt) = IPositionManager(_intent.properties.guardKey).assets();

    address _fundAsset = IFund(newFund).asset();
    if (_fundAsset != _pmDebt) revert LibErrors.AssetMismatch(_pmDebt, _fundAsset);

    address _fundShare = IFund(newFund).share();
    if (_fundShare != _pmCollateral) revert LibErrors.AssetMismatch(_pmCollateral, _fundShare);

    $.intents[id].fund = newFund;
    emit FundUpdated(id, newFund);
  }

  /// @inheritdoc IFacilityIntents
  function setRequest(uint256 id, address newRequest) external onlyRoles(FACILITATOR_ROLE) {
    _checkContract(newRequest);
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();

    Intent storage _intent = $.intents[id];
    address _request = _intent.request;

    if (_request != address(0) && !IVaultController(_request).canWithdraw()) {
      // TODO canWithdraw is not enough (need intermediary state like `repaid()`)
      // TODO do the same change for resolve()
      // TODO OR Check that the request is not used yet.
      revert LibErrors.RequestNotRepaid(_request);
    }

    (, address _pmDebt) = IPositionManager(_intent.properties.guardKey).assets();
    address _requestAsset = IVaultController(newRequest).asset();
    if (_requestAsset != _pmDebt) revert LibErrors.AssetMismatch(_pmDebt, _requestAsset);

    $.intents[id].request = newRequest;
    emit RequestUpdated(id, newRequest);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityFunds
  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
    returns (Order memory order)
  {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert LibErrors.NotResolving(id);
    if (_hasActiveOrder(_intent)) revert LibErrors.ActiveOrder(id);

    order = Order({
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: minAmountOut,
      mode: mode,
      salt: keccak256(abi.encode(address(this), block.timestamp, id))
    });

    address _fund = _intent.fund;
    emit CreatingOrder(id, order.toId(_fund));
    IFund(_fund).create(order);

    _intent.order = order;
  }

  /// @inheritdoc IFacilityFunds
  function cancel(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_hasActiveOrder(_intent)) revert LibErrors.NoActiveOrder(id);

    IFund(_intent.fund).cancel(_intent.order);
    delete _intent.order;
  }

  /// @inheritdoc IFacilityFunds
  function commit(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_hasActiveOrder(_intent)) revert LibErrors.NoActiveOrder(id);

    Order memory _order = _intent.order;
    address _tokenIn = _order.mode == Mode.DEPOSIT ? IFund(_intent.fund).asset() : IFund(_intent.fund).share();

    // TODO event for sub
    _intent.amounts.sub(_tokenIn, _order.input);

    _tokenIn.safeApproveWithRetry(_intent.fund, _order.input);

    // Revert in commit() if wrong state
    (, uint256 committedAmount) = IFund(_intent.fund).commit(_order);
  }

  /// @inheritdoc IFacilityFunds
  function unlock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_hasActiveOrder(_intent)) revert LibErrors.NoActiveOrder(id);

    Order memory order = _intent.order;

    (State _state, uint256 _unlockedAmount) = IFund(_intent.fund).unlock(order);
    address _tokenOut = order.mode == Mode.DEPOSIT ? IFund(_intent.fund).share() : IFund(_intent.fund).asset();

    // TODO event for add
    _intent.amounts.add(_tokenOut, _unlockedAmount);

    // if not, partial unlock
    if (_state == State.ENDED) {
      delete _intent.order;
    }
  }

  /// @inheritdoc IFacilityFunds
  function recover(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_hasActiveOrder(_intent)) revert LibErrors.NoActiveOrder(id);

    Order memory order = _intent.order;

    (State _state, uint256 _recoveredAmount) = IFund(_intent.fund).recover(order);
    address _tokenIn = order.mode == Mode.DEPOSIT ? IFund(_intent.fund).asset() : IFund(_intent.fund).share();

    // TODO event for add
    _intent.amounts.add(_tokenIn, _recoveredAmount);

    // if not, partial recover
    if (_state == State.ENDED) {
      delete _intent.order;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityRequests
  function pull(uint256 id, uint256 amount) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert LibErrors.NotResolving(id);
    if (_intent.request == address(0)) revert LibErrors.MissingRequest(id);

    address asset = IVaultController(_intent.request).asset();

    IRequestInteractions(_intent.request).pullFunds(amount, bytes(""));
    _intent.amounts.add(asset, amount);
  }

  /// @inheritdoc IFacilityRequests
  function repay(uint256 id, uint256 amount) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert LibErrors.NotResolving(id);
    if (_intent.request == address(0)) revert LibErrors.MissingRequest(id);

    address asset = IVaultController(_intent.request).asset();

    _intent.amounts.sub(asset, amount);
    asset.safeApproveWithRetry(_intent.request, amount);
    IRequestInteractions(_intent.request).repay(amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityPositionManager
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
  {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert LibErrors.NotResolving(id);

    Asset storage selected = useTarget ? _intent.properties.targetAsset : _intent.properties.depositAsset;
    if (!selected.isPositionManager) revert LibErrors.AssetNotPositionManager(selected.asset);

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

  /// @inheritdoc IFacilityPositionManager
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount, bool useTarget)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
  {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert LibErrors.NotResolving(id);

    Asset storage selected = useTarget ? _intent.properties.targetAsset : _intent.properties.depositAsset;
    if (!selected.isPositionManager) revert LibErrors.AssetNotPositionManager(selected.asset);

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

  /// @inheritdoc IFacilityPositionManager
  function burnManager(uint256 id, uint256 shares, bool useTarget)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
  {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert LibErrors.NotResolving(id);

    Asset storage selected = useTarget ? _intent.properties.targetAsset : _intent.properties.depositAsset;
    if (!selected.isPositionManager) revert LibErrors.AssetNotPositionManager(selected.asset);

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

    if (debt != debtNeeded) revert LibErrors.AmountMismatch(debtNeeded, debt);
    if (collateral > 0) {
      _intent.amounts.add(collateralAsset, collateral);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityLP
  function deposit(uint256 id, uint256 amount) external override {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    // IScreener.check(msg.sender, id, data, amount);

    if (!_isDepositing(_intent)) revert LibErrors.NotDepositing(id);
    uint256 attemptedTotal = _intent.totalSupply + amount;
    if (attemptedTotal > _intent.properties.depositCap) {
      revert LibErrors.DepositCapExceeded(id, _intent.properties.depositCap, attemptedTotal);
    }

    // TODO - Updates
    address depositAsset = _intent.properties.depositAsset.asset;
    depositAsset.safeTransferFrom(msg.sender, address(this), amount);
    _intent.amounts.add(depositAsset, amount);
    _mint(msg.sender, id, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacilityLP
  function withdraw(uint256 id, uint256 amount) external override {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isDepositing(_intent)) revert LibErrors.NotDepositing(id);

    // TODO - Updates
    address depositAsset = _intent.properties.depositAsset.asset;
    _intent.amounts.sub(depositAsset, amount);
    depositAsset.safeTransfer(msg.sender, amount);
    _burn(msg.sender, id, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacilityLP
  function claim(uint256 id) external override {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_intent.resolved) revert LibErrors.NotResolved(id);
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
    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage intent = $.intents[id];
    return IERC20(intent.properties.depositAsset.asset).decimals();
  }

  /// @inheritdoc ERC6909
  function name(uint256 id) public view override returns (string memory) {
    return LibStorage.facilityStorage().descriptor.name(IFacility(address(this)), id);
  }

  /// @inheritdoc ERC6909
  function symbol(uint256 id) public view override returns (string memory) {
    return LibStorage.facilityStorage().descriptor.symbol(IFacility(address(this)), id);
  }

  /// @inheritdoc ERC6909
  function tokenURI(uint256 id) public view override returns (string memory) {
    return LibStorage.facilityStorage().descriptor.tokenURI(IFacility(address(this)), id);
  }

  /// @notice Returns total supply for a given intent.
  /// @param id The intent ID.
  /// @return The total supply.
  function totalSupply(uint256 id) public view returns (uint256) {
    _requireIntentExists(id);
    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];
    return _intent.totalSupply;
  }

  /// @inheritdoc ERC6909
  function _beforeTokenTransfer(address from, address to, uint256 id, uint256 amount) internal override {
    _requireIntentExists(id);

    FacilityStorageData storage $ = LibStorage.facilityStorage();
    Intent storage _intent = $.intents[id];

    (,, address guard) = IPositionManager(_intent.properties.guardKey).config();
    if (guard != address(0)) {
      if (!ITransferGuard(guard).canTransfer(_intent.properties.guardKey, from, to, amount)) {
        revert LibErrors.TransferBlocked(guard, from, to, amount);
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

  /// @inheritdoc EIP712
  function _domainNameAndVersionMayChange() internal pure override returns (bool) {
    return true;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   REENTRANCY GUARD TRANSIENT               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ReentrancyGuardTransient
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts if the intent ID does not exist.
  /// @param id The intent ID to check.
  function _requireIntentExists(uint256 id) internal view {
    uint256 lastId = LibStorage.facilityStorage().lastIntentId;
    if (id == 0 || id > lastId) revert LibErrors.IntentNotFound(id);
  }

  /// @dev Reverts if the address is the zero address.
  /// @param addr The address to check.
  function _checkNotZero(address addr) internal pure {
    if (addr == address(0)) revert LibErrors.AddressZero();
  }

  /// @dev Reverts if the address is not a contract.
  /// @param addr The address to check.
  function _checkContract(address addr) internal view {
    if (addr.code.length == 0) revert LibErrors.InvalidContract(addr);
  }

  /// @dev TODO Natspec + Refactor
  function _checkAssetsAndGuardKey(Asset memory depositAsset, Asset memory targetAsset, address guardKey)
    internal
    view
  {
    address _pmCollateral;
    address _pmDebt;
    bool depositIsPm = depositAsset.isPositionManager;
    bool targetIsPm = targetAsset.isPositionManager;

    if (!depositIsPm && !targetIsPm) revert LibErrors.MissingPositionManager();

    if (depositIsPm && !targetIsPm) {
      if (guardKey != depositAsset.asset) revert LibErrors.InvalidGuardKey(guardKey);
    }

    if (!depositIsPm && targetIsPm) {
      if (guardKey != targetAsset.asset) revert LibErrors.InvalidGuardKey(guardKey);
      (_pmCollateral, _pmDebt) = IPositionManager(guardKey).assets();
      if (depositAsset.asset != _pmDebt) revert LibErrors.AssetMismatch(_pmDebt, depositAsset.asset);
    }

    if (guardKey != depositAsset.asset && guardKey != targetAsset.asset) {
      revert LibErrors.InvalidGuardKey(guardKey);
    }

    (_pmCollateral, _pmDebt) = IPositionManager(guardKey).assets();

    if (depositIsPm && targetIsPm) {
      address otherPm = guardKey == depositAsset.asset ? targetAsset.asset : depositAsset.asset;
      (address otherCollateral, address otherDebt) = IPositionManager(otherPm).assets();
      if (otherCollateral != _pmCollateral) revert LibErrors.AssetMismatch(_pmCollateral, otherCollateral);
      if (otherDebt != _pmDebt) revert LibErrors.AssetMismatch(_pmDebt, otherDebt);
    }
  }

  /// @dev TODO Natspec
  function _verifySwapSignatures(
    bytes32 digest,
    address[] calldata signers,
    bytes[] calldata signatures,
    uint256 required
  ) internal view {
    if (required == 0) return;
    if (signers.length != signatures.length) revert LibErrors.InvalidSignatureLength();
    if (signers.length < required) revert LibErrors.InvalidSignatureCount(required, signers.length);

    address lastSigner = address(0);
    for (uint256 i = 0; i < signers.length; i++) {
      address signer = signers[i];
      if (signer <= lastSigner) revert LibErrors.InvalidSignerOrder();
      if (!hasAnyRole(signer, GUARDIAN_ROLE)) revert LibErrors.NotGuardian(signer);
      if (!SignatureCheckerLib.isValidSignatureNowCalldata(signer, digest, signatures[i])) {
        revert LibErrors.InvalidSignature(signer);
      }
      lastSigner = signer;
    }
  }

  function _isResolving(Intent storage _intent) internal view returns (bool) {
    return _intent.properties.resolveStart <= block.timestamp && !_intent.resolved;
  }

  function _isDepositing(Intent storage _intent) internal view returns (bool) {
    return !_intent.resolved && _intent.properties.resolveStart > block.timestamp;
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

  function _updateTargetAsset(
    uint256 id,
    Intent storage intent,
    Asset memory depositAsset,
    Asset memory newTargetAsset,
    address newGuardKey
  ) internal {
    // Checks that the new target asset and guard key are compatible with the deposit asset.
    _checkAssetsAndGuardKey(depositAsset, newTargetAsset, newGuardKey);

    intent.properties.targetAsset = newTargetAsset;
    intent.properties.guardKey = newGuardKey;
    emit IntentTargetUpdated(id, newTargetAsset, newGuardKey);
  }

  function _updateDepositCap(uint256 id, Intent storage intent, uint256 newDepositCap) internal {
    intent.properties.depositCap = newDepositCap;
    emit DepositCapUpdated(id, newDepositCap);
  }

  function _updateResolveStart(uint256 id, Intent storage intent, uint40 newResolveStart) internal {
    intent.properties.resolveStart = newResolveStart;
    emit ResolveStartUpdated(id, newResolveStart);
  }
}
