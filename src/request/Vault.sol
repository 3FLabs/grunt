// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ControlledVault} from "./abstract/vault/ControlledVault.sol";
import {ControlledToken} from "./abstract/tokens/ControlledToken.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

/// @title Vault
/// @author 3F Protocol
/// @notice Concrete implementation of an ERC4626-compliant vault for PT or YT tokens.
/// @dev The vault type is fixed at deployment via the immutable `_IS_YT` flag, so the same bytecode
///      serves both PT and YT instances, both managed by a single VaultController. Direct deposits
///      revert; all minting is delegated to the controller.
contract Vault is ControlledVault, Initializable {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Immutable flag determining whether this vault represents YT (true) or PT (false).
  ///      Set at construction and cannot be changed. This allows the same contract bytecode
  ///      to serve both vault types while maintaining type-specific behavior.
  bool internal immutable _IS_YT;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice ERC-7201 namespaced storage struct for the Vault contract.
  /// @param controller The address of the VaultController managing this vault
  struct VaultStorage {
    address controller;
  }

  /// @dev ERC-7201 storage slot for VaultStorage.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("vault.main")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _VAULT_STORAGE_SLOT = 0xbfbfcd6df78e796c7f6a4ffb712d0537d34f4debe7adeafdef6a66872f365f00;

  /// @dev Returns the VaultStorage struct at `_VAULT_STORAGE_SLOT`.
  function _vaultStorage() internal pure returns (VaultStorage storage vaultStorage) {
    assembly ("memory-safe") {
      vaultStorage.slot := _VAULT_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Constructs a new Vault instance with the specified token type.
  /// @dev Sets the immutable `_IS_YT` flag which determines whether this vault
  ///      handles Principal Tokens (PT) or Yield Tokens (YT). This cannot be changed after deployment.
  /// @param isYt True to create a Yield Token vault, false for a Principal Token vault
  constructor(bool isYt) {
    _IS_YT = isYt;
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the Vault contract with the controller address.
  /// @dev Can only be called once due to the `initializer` modifier. Links this vault
  ///      to its managing VaultController which handles minting, burning, and access control.
  /// @param controller The address of the VaultController managing this vault
  function initialize(address controller) public initializer {
    _vaultStorage().controller = controller;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL OVERRIDES                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ControlledToken
  /// @dev Returns the immutable token type flag set during construction.
  function _isYtToken() internal view override returns (bool) {
    return _IS_YT;
  }

  /// @inheritdoc ControlledToken
  /// @dev Returns the controller address stored in ERC-7201 namespaced storage.
  function _controller() internal view override returns (address) {
    return _vaultStorage().controller;
  }
}
