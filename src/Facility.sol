// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {Multicallable} from "lib/solady/src/utils/Multicallable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

import {IFacility, Intent} from "./interfaces/IFacility.sol";

contract Facility is IFacility, ERC6909, Multicallable, OwnableRoles, Initializable {
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // TODO => Events

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the Facility contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param intents Mapping from intent ID to Intent struct.
  struct FacilityStorage {
    mapping(uint256 => Intent) intents;
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
  function initialize(address owner_, address facilitator_) public initializer {
    _checkNotZero(owner_);
    _checkNotZero(facilitator_);

    _initializeOwner(owner_);
    _setRoles(facilitator_, FACILITATOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTENT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function createIntent() external override returns (uint256 id) {
    // TODO
    return 0;
  }

  /// @inheritdoc IFacility
  function lock(uint256 id) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function resolve(uint256 id) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function setDepositCap(uint256 id, uint256 newDepositCap) external override {
    // TODO
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function create(uint256 id, uint256 amount, uint256 minAmountOut) external override returns (uint256 orderId) {
    // TODO
    return 0;
  }

  /// @inheritdoc IFacility
  function cancel(uint256 id) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function commit(uint256 id) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function unlock(uint256 id) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function recover(uint256 id) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function swap(uint256 id1, address token1, uint256 id2, address token2, uint256 amount1, uint256 amount2)
    external
    override
  {
    // TODO
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function pull(uint256 id, uint256 amount) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function repay(uint256 id, uint256 amount) external override {
    // TODO
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function burnManager(uint256 id, uint256 amount) external override {
    // TODO
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacility
  function deposit(uint256 id, uint256 amount) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function withdraw(uint256 id, uint256 amount) external override {
    // TODO
  }

  /// @inheritdoc IFacility
  function claim(uint256 id) external override {
    // TODO
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERC-6909                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ERC6909
  function name(uint256 id) public view override returns (string memory) {
    return "";
  }

  /// @inheritdoc ERC6909
  function symbol(uint256 id) public view override returns (string memory) {
    return "";
  }

  /// @inheritdoc ERC6909
  function tokenURI(uint256 id) public view override returns (string memory) {
    return "";
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts if the address is the zero address.
  /// @param addr The address to check.
  function _checkNotZero(address addr) internal pure {
    if (addr == address(0)) revert AddressZero();
  }
}
