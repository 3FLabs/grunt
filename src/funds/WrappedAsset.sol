// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IWrappedAsset} from "../interfaces/funds/IWrappedAsset.sol";
import {LibChecks} from "../libs/common/LibChecks.sol";

/// @title WrappedAsset
/// @author 3F Protocol
/// @notice ERC20 wrapper token that wraps an underlying asset 1:1.
/// @dev Holds the underlying asset centrally and mints/burns wrapper tokens against it. Multiple
///      issuers (e.g. fund instances) can mint via ISSUER_ROLE. Transfers (not mints/burns) require
///      the sender to have SENDER_ROLE or the receiver to have RECEIVER_ROLE.
contract WrappedAsset is ERC20, IWrappedAsset, OwnableRoles, Initializable {
  using SafeTransferLib for address;
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for asset issuers authorized to mint tokens.
  uint256 internal constant ISSUER_ROLE = _ROLE_0;

  /// @notice Role for addresses authorized to send wrapper tokens.
  /// @dev Restricts transfers to protocol contracts and authorized lending protocols to prevent unauthorized movement.
  ///      Liquidators can still burn tokens to receive underlying and complete liquidations.
  uint256 internal constant SENDER_ROLE = _ROLE_1;

  /// @notice Role for addresses authorized to receive wrapper tokens from anyone.
  /// @dev Addresses with this role can receive tokens even from senders without SENDER_ROLE.
  uint256 internal constant RECEIVER_ROLE = _ROLE_2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the WrappedAsset contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param symbol The symbol of the wrapped asset token.
  /// @param name The name of the wrapped asset token.
  /// @param underlying The address of the underlying asset being wrapped.
  struct WrappedAssetStorage {
    string symbol;
    string name;
    address underlying;
  }

  /// @dev Storage slot for the WrappedAsset contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("wrapped.asset")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _MAIN_STORAGE_SLOT = 0x17335d0a3e97e0293c2bb91805cb7279c336f9ba807e8dbe36cf5097172d3300;

  /// @dev Returns a reference to the contract's storage struct.
  function _wrappedAssetStorage() internal pure returns (WrappedAssetStorage storage wrappedAssetStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      wrappedAssetStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  constructor() {
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the WrappedAsset contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  /// @param owner_ The address that will own this contract (managing roles).
  /// @param initialIssuer_ The address to be granted the ISSUER_ROLE and SENDER_ROLE initially.
  /// @param underlying_ The address of the underlying asset to wrap.
  /// @param symbol_ The symbol of the wrapped asset token.
  /// @param name_ The name of the wrapped asset token.
  function initialize(
    address owner_,
    address initialIssuer_,
    address underlying_,
    string calldata symbol_,
    string calldata name_
  ) public initializer {
    WrappedAssetStorage storage _storage = _wrappedAssetStorage();
    _storage.symbol = symbol_;
    _storage.name = name_;
    _storage.underlying = underlying_;

    _initializeOwner(owner_);
    _setRoles(initialIssuer_, ISSUER_ROLE | SENDER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        WRAP / UNWRAP                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IWrappedAsset
  /// @dev Wraps underlying asset: pulls underlying from caller, mints wrapper to `to`.
  ///      If `to != msg.sender`, the caller must have ISSUER_ROLE.
  function mint(address to, uint256 amount) external override {
    to.checkNotZero();
    if (to != msg.sender) _checkRoles(ISSUER_ROLE);
    WrappedAssetStorage storage _storage = _wrappedAssetStorage();
    _storage.underlying.safeTransferFrom(msg.sender, address(this), amount);
    _mint(to, amount);
  }

  /// @inheritdoc IWrappedAsset
  /// @dev Unwraps to underlying asset: burns wrapper from `from`, sends underlying to `to`.
  ///      If `from != msg.sender`, caller must have sufficient allowance.
  ///      When `to` is set to a redemption-capable underlying token (e.g. USCC),
  ///      this transfer is the on-chain leg of an off-chain redemption flow.
  function burn(address from, address to, uint256 amount) external override {
    to.checkNotZero();
    if (from != msg.sender) {
      _spendAllowance(from, msg.sender, amount);
    }
    _burn(from, amount);
    WrappedAssetStorage storage _storage = _wrappedAssetStorage();
    _storage.underlying.safeTransfer(to, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IWrappedAsset
  function underlying() external view override returns (address) {
    return _wrappedAssetStorage().underlying;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ERC20 OVERRIDES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ERC20
  function name() public view override returns (string memory) {
    return _wrappedAssetStorage().name;
  }

  /// @inheritdoc ERC20
  function symbol() public view override returns (string memory) {
    return _wrappedAssetStorage().symbol;
  }

  /// @inheritdoc ERC20
  function decimals() public view override returns (uint8) {
    return ERC20(_wrappedAssetStorage().underlying).decimals();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     ALLOWLIST HOOK                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IWrappedAsset
  /// @dev Base implementation returns true. Override for compliance checks (e.g., Superstate allowlist).
  function isAllowed(address, uint256) public view virtual returns (bool) {
    return true;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERC20 HOOK                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Enforces transfer restrictions:
  ///      - Transfers (not mints/burns) require sender to have SENDER_ROLE or receiver to have RECEIVER_ROLE
  ///      - Non-null parties must pass isAllowed check (base returns true, override for compliance)
  ///      Solady's ERC20 permits transfers to `address(0)` as a burn-by-transfer (unlike OpenZeppelin's,
  ///      which reverts); the zero-address guards below intentionally let mint/burn paths through
  ///      without role or allowlist checks.
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    if (from != address(0) && to != address(0) && !hasAnyRole(to, RECEIVER_ROLE) && !hasAnyRole(from, SENDER_ROLE)) {
      revert Unauthorized();
    }
    if (from != address(0) && !isAllowed(from, amount)) revert Unauthorized();
    if (to != address(0) && !isAllowed(to, amount)) revert Unauthorized();
    super._beforeTokenTransfer(from, to, amount);
  }
}
