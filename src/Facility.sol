// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {Multicallable} from "lib/solady/src/utils/Multicallable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

import {IFacility, Intent} from "./interfaces/IFacility.sol";
import {IIntentDescriptor} from "./interfaces/IIntentDescriptor.sol";
import {IFund} from "./interfaces/funds/IFund.sol";
import {Order, Mode} from "./libs/Order.sol";

import {TokenBalancesLib} from "./libs/facility/TokenBalancesLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract Facility is IFacility, ERC6909, Multicallable, OwnableRoles, Initializable {
  using TokenBalancesLib for EnumerableMapLib.AddressToUint256Map;
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for operator.
  uint256 public constant FACILITATOR_ROLE = _ROLE_0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a required address parameter is the zero address.
  error AddressZero();

  /// @notice Thrown when the intent is already resolving.
  error AlreadyResolving(uint256 id);

  /// @notice Thrown when the intent is already resolved.
  error AlreadyResolved(uint256 id);

  /// @notice Thrown when the intent is not resolving.
  error NotResolving(uint256 id);

  /// @notice Thrown when the intent is not resolved.
  error NotResolved(uint256 id);

  /// @notice Thrown when the intent is not depositing.
  error NotDepositing(uint256 id);

  /// @notice Thrown when the deposit cap is exceeded.
  error DepositCapExceeded(uint256 id);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the intent descriptor is updated.
  /// @param descriptor The new descriptor address.
  event DescriptorSet(address indexed descriptor);

  // TODO => Events

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
  function createIntent() external override onlyRoles(FACILITATOR_ROLE) returns (uint256 id) {
    // TODO
    return 0;
  }

  /// @inheritdoc IFacility
  function lock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (_isResolving(_intent)) revert AlreadyResolving(id);

    _intent.resolveStart = uint40(block.timestamp);

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function resolve(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (_intent.resolved) revert AlreadyResolved(id);

    _intent.resolved = true;
    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function setDepositCap(uint256 id, uint256 newDepositCap) external override onlyRoles(FACILITATOR_ROLE) {
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
    returns (Order memory order)
  {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // TODO - Validations
    if (!_isResolving(_intent)) revert NotResolving(id);

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
  function cancel(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // TODO - Validations
    if (!_isResolving(_intent)) revert NotResolving(id);

    IFund(_intent.fund).cancel(_intent.order);

    // TODO - Updates
    delete _intent.order;

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function commit(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // TODO - Validations
    if (!_isResolving(_intent)) revert NotResolving(id);
    // TODO - check order exists

    // TODO - change the way we handle the asset
    address asset = _intent.order.mode == Mode.DEPOSIT ? IFund(_intent.fund).asset() : IFund(_intent.fund).share();
    if (asset != _intent.depositAsset) revert InvalidAsset(id);

    // TODO - Updates
    Order memory order = _intent.order;
    _intent.amounts.sub(asset, order.input);
    asset.safeApproveWithRetry(_intent.fund, order.input);
    (, committedAmount) = IFund(_intent.fund).commit(order);

    if (committedAmount != order.input) revert InvalidAmount(id);

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function unlock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // TODO - Validations
    if (!_isResolving(_intent)) revert NotResolving(id);

    // TODO - change the way we handle the asset
    Order memory order = _intent.order;
    address asset = order.mode == Mode.DEPOSIT ? IFund(_intent.fund).share() : IFund(_intent.fund).asset();

    (, uint256 unlockedAmount) = IFund(_intent.fund).unlock(order);
    _intent.amounts.add(asset, unlockedAmount);

    // TODO - Updates

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function recover(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // TODO - Validations
    if (!_isResolving(_intent)) revert NotResolving(id);
    
    // TODO - Updates
    Order memory order = _intent.order;
    address asset = order.mode == Mode.DEPOSIT ? IFund(_intent.fund).asset() : IFund(_intent.fund).share();

    (_, uint recoveredAmount) = IFund(_intent.fund).recover(order);
    
    _intent.amounts.add(asset, recoveredAmount);

    // TODO - Emits event

  }

  /// @inheritdoc IFacility
  function swap(uint256 id1, address token1, uint256 id2, address token2, uint256 amount1, uint256 amount2) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent1 = $.intents[id1];
    Intent storage _intent2 = $.intents[id2];
    _intent1.amounts.sub(token1, amount1);
    _intent1.amounts.add(token2, amount2);
    _intent2.amounts.sub(token2, amount2);
    _intent2.amounts.add(token1, amount1);

    // TODO - Emits event
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function pull(uint256 id, uint256 amount) external override onlyRoles(FACILITATOR_ROLE) {
    // TODO

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);

    // TODO - Updates
  }

  /// @inheritdoc IFacility
  function repay(uint256 id, uint256 amount) external override onlyRoles(FACILITATOR_ROLE) {
    // TODO

    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);

    // TODO - Updates
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
  {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);

    // TODO - Updates
  }

  /// @inheritdoc IFacility
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
  {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);

    // TODO - Updates
  }

  /// @inheritdoc IFacility
  function burnManager(uint256 id, uint256 amount) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isResolving(_intent)) revert NotResolving(id);

    // TODO - Updates
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function deposit(uint256 id, uint256 amount) external override {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    // IScreener.check(msg.sender, id, data, amount);

    if (!_isDepositing(_intent)) revert NotDepositing(id);
    if (_intent.totalSupply + amount > _intent.depositCap) revert DepositCapExceeded(id);

    // TODO - Updates
    address depositAsset = _intent.depositAsset;
    depositAsset.safeTransferFrom(msg.sender, address(this), amount);
    _intent.amounts.add(depositAsset, amount);
    _mint(msg.sender, id, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function withdraw(uint256 id, uint256 amount) external override {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_isDepositing(_intent)) revert NotDepositing(id);

    // TODO - Updates
    address depositAsset = _intent.depositAsset;
    _intent.amounts.sub(depositAsset, amount);
    depositAsset.safeTransfer(msg.sender, amount);
    _burn(msg.sender, id, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacility
  function claim(uint256 id) external override {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (!_intent.resolved) revert NotResolved(id);

    uint256 balance = balanceOf(msg.sender, id);
    uint256 totalSupply = totalSupply(id);

    // TODO - Updates
    address[] memory tokens = _intent.amounts.keys();
    for (uint256 i = 0; i < tokens.length; i++) {
      address token = tokens[i];
      uint256 userBalance = _intent.amounts.get(token).mulDiv(balance, totalSupply);
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

  function totalSupply(uint256 id) public view override returns (uint256) {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];
    return _intent.totalSupply;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts if the address is the zero address.
  /// @param addr The address to check.
  function _checkNotZero(address addr) internal pure {
    if (addr == address(0)) revert AddressZero();
  }

  function _isResolving(Intent storage _intent) internal view returns (bool) {
    return _intent.resolveStart <= block.timestamp && !_intent.resolved;
  }

  function _isDepositing(Intent storage _intent) internal view returns (bool) {
    return !_intent.resolved && _intent.resolveStart > block.timestamp;
  }

  function _beforeTokenTransfer(address from, address to, uint256 id, uint256 amount) internal override {
    FacilityStorage storage $ = _facilityStorage();
    Intent storage _intent = $.intents[id];

    if (from == address(0) && to != address(0)) {
      _intent.totalSupply += amount;
    } else if (from != address(0) && to == address(0)) {
      _intent.totalSupply -= amount;
    }
  }
}
