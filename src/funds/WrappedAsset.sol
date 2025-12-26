// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {IWrappedAsset} from "../interfaces/funds/IWrappedAsset.sol";

contract WrappedAsset is ERC20, IWrappedAsset, OwnableRoles, Initializable {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for asset issuers authorized to mint and burn tokens.
  uint256 public constant ISSUER_ROLE = _ROLE_0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the WrappedAsset contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param symbol The symbol of the wrapped asset token.
  /// @param name The name of the wrapped asset token.
  /// @param decimals The number of decimals for the token.
  struct WrappedAssetStorage {
    string symbol;
    string name;
    uint8 decimals;
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
  /// @param initialIssuer_ The address to be granted the ISSUER_ROLE initially.
  /// @param symbol_ The symbol of the wrapped asset token.
  /// @param name_ The name of the wrapped asset token.
  /// @param decimals_ The number of decimals for the token.
  function initialize(
    address owner_,
    address initialIssuer_,
    string calldata symbol_,
    string calldata name_,
    uint8 decimals_
  ) public initializer {
    WrappedAssetStorage storage $ = _wrappedAssetStorage();
    $.symbol = symbol_;
    $.name = name_;
    $.decimals = decimals_;

    _initializeOwner(owner_);
    _setRoles(initialIssuer_, ISSUER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ISSUANCE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IWrappedAsset
  /// @dev Can only be called by accounts with the ISSUER_ROLE.
  function mint(address to, uint256 amount) external override onlyRoles(ISSUER_ROLE) {
    require(to != address(0), "Mint to zero address");
    _mint(to, amount);
  }

  /// @inheritdoc IWrappedAsset
  /// @dev Can only be called by accounts with the ISSUER_ROLE.
  function burn(address from, uint256 amount) external override onlyRoles(ISSUER_ROLE) {
    _burn(from, amount);
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
}
