// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IWrappedAsset} from "../interfaces/funds/IWrappedAsset.sol";

/// @title WrappedAsset
/// @notice ERC20 wrapper token that wraps an underlying asset 1:1.
/// @dev This contract holds the underlying asset and mints/burns wrapper tokens.
///      - mint(): Pulls underlying from `from`, mints wrapper to `to`
///      - burn(): Burns wrapper from `from`, sends underlying to `to`
///      Multiple issuers (e.g., USCCFund instances) can mint via ISSUER_ROLE.
///      Transfers (including burns) require the token `from` address to have SENDER_ROLE.
///      The underlying asset is held centrally in this contract.
contract WrappedAsset is ERC20, IWrappedAsset, OwnableRoles, Initializable {
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for asset issuers authorized to mint tokens.
  uint256 public constant ISSUER_ROLE = _ROLE_0;

  /// @notice Role for addresses authorized to send (transfer/burn) wrapper tokens.
  uint256 public constant SENDER_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when minting to the zero address.
  error MintToZeroAddress();

  /// @notice Thrown when burning to the zero address.
  error BurnToZeroAddress();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the WrappedAsset contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param symbol The symbol of the wrapped asset token.
  /// @param name The name of the wrapped asset token.
  /// @param decimals The number of decimals for the token.
  /// @param underlying The address of the underlying asset being wrapped.
  struct WrappedAssetStorage {
    string symbol;
    string name;
    uint8 decimals;
    address underlying;
  }

  /// @dev Storage slot for the WrappedAsset contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("wrapped.asset")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0x17335d0a3e97e0293c2bb91805cb7279c336f9ba807e8dbe36cf5097172d3300;

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return wrappedAssetStorage A storage pointer to the WrappedAssetStorage struct
  function _wrappedAssetStorage() internal pure returns (WrappedAssetStorage storage wrappedAssetStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      wrappedAssetStorage.slot := _MAIN_STORAGE_SLOT
    }
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
  /// @param decimals_ The number of decimals for the token.
  function initialize(
    address owner_,
    address initialIssuer_,
    address underlying_,
    string calldata symbol_,
    string calldata name_,
    uint8 decimals_
  ) public initializer {
    WrappedAssetStorage storage $ = _wrappedAssetStorage();
    $.symbol = symbol_;
    $.name = name_;
    $.decimals = decimals_;
    $.underlying = underlying_;

    _initializeOwner(owner_);
    _setRoles(initialIssuer_, ISSUER_ROLE | SENDER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        WRAP / UNWRAP                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IWrappedAsset
  /// @dev Wraps underlying asset: pulls underlying from `from`, mints wrapper to `to`.
  ///      Requires ISSUER_ROLE. The caller must ensure `from` has approved this contract.
  function mint(address from, address to, uint256 amount) external override onlyRoles(ISSUER_ROLE) {
    if (to == address(0)) revert MintToZeroAddress();
    WrappedAssetStorage storage $ = _wrappedAssetStorage();
    $.underlying.safeTransferFrom(from, address(this), amount);
    _mint(to, amount);
  }

  /// @inheritdoc IWrappedAsset
  /// @dev Unwraps to underlying asset: burns wrapper from `from`, sends underlying to `to`.
  ///      If `from != msg.sender`, caller must have sufficient allowance.
  function burn(address from, address to, uint256 amount) external override {
    if (to == address(0)) revert BurnToZeroAddress();
    if (from != msg.sender) {
      _spendAllowance(from, msg.sender, amount);
    }
    _burn(from, amount);
    WrappedAssetStorage storage $ = _wrappedAssetStorage();
    $.underlying.safeTransfer(to, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the address of the underlying asset.
  /// @return The underlying asset address.
  function underlying() external view returns (address) {
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
    return _wrappedAssetStorage().decimals;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERC20 HOOK                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Enforces that token transfers (including burns) can only originate from addresses with SENDER_ROLE.
  ///      Minting is excluded (`from == address(0)`).
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
    if (from != address(0) && !hasAllRoles(from, SENDER_ROLE)) revert Unauthorized();
    super._beforeTokenTransfer(from, to, amount);
  }
}
