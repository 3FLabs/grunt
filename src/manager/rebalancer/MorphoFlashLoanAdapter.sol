// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IFlashLoanModule, IFlashLoanReceiver} from "../../interfaces/manager/rebalancer/IFlashLoanModule.sol";
import {IMorphoFlashLoanCallback} from "lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IMorpho} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {LibRetargetterErrors} from "../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title MorphoFlashLoanAdapter
/// @author 3F Protocol
/// @notice Stateless {IFlashLoanModule} adapter over Morpho Blue's zero-fee flash loans.
/// @dev Deployed once per chain as permissionless infrastructure: anyone may call it, and all
///      borrower-side security lives with the borrower (for the Retargetter, its module
///      whitelist and window authentication). The initiator and token of the in-flight loan
///      live in transient storage, so the adapter holds no persistent state.
///
///      Call chain:
///      1. Initiator calls `flashLoan(token, amount, data)`
///      2. Adapter forwards to `MORPHO.flashLoan`, which transfers the funds to the adapter
///      3. Morpho calls back `onMorphoFlashLoan`; the adapter forwards the funds and the
///         payload verbatim to `IFlashLoanReceiver(initiator).onFlashLoan(amount, data)`
///      4. The adapter pulls repayment from the initiator via allowance and approves Morpho,
///         which reclaims the funds after the callback returns
contract MorphoFlashLoanAdapter is IFlashLoanModule, IMorphoFlashLoanCallback {
  using SafeTransferLib for address;
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Morpho Blue contract providing the flash loans.
  IMorpho public immutable MORPHO;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     TRANSIENT STORAGE                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Transient slot for the in-flight loan's initiator.
  ///      Computed as: uint256(keccak256("morphoFlashLoanAdapter.transient.initiator")) - 1
  uint256 private constant _INITIATOR_TSLOT = 0xfa5f7b46217f272988f4af45bb58816b2efa985aea1afa7e65663eb8c2b28654;

  /// @dev Transient slot for the in-flight loan's token.
  ///      Computed as: uint256(keccak256("morphoFlashLoanAdapter.transient.token")) - 1
  uint256 private constant _TOKEN_TSLOT = 0x575d37d8424ca69d89964ff6ba8caa9111551c931b64140c534be5fd977cac8b;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the adapter.
  /// @param morpho_ The Morpho Blue contract address
  constructor(address morpho_) {
    morpho_.checkContract();
    MORPHO = IMorpho(morpho_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         FLASH LOAN                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFlashLoanModule
  /// @dev The payload travels through Morpho verbatim; nothing is wrapped or decoded anywhere
  ///      in the chain. Reverts with {LibRetargetterErrors.OperationActive} when a loan is
  ///      already in flight (no nesting).
  function flashLoan(address token, uint256 amount, bytes calldata data) external {
    if (_loadAddress(_INITIATOR_TSLOT) != address(0)) revert LibRetargetterErrors.OperationActive();
    _store(_INITIATOR_TSLOT, msg.sender);
    _store(_TOKEN_TSLOT, token);
    MORPHO.flashLoan(token, amount, data);
    _store(_INITIATOR_TSLOT, address(0));
    _store(_TOKEN_TSLOT, address(0));
  }

  /// @notice Callback called by Morpho during a flash loan.
  /// @dev Forwards the funds and payload to the initiator, then pulls repayment from it via
  ///      the allowance the initiator granted inside its own callback, and approves Morpho to
  ///      reclaim. Only callable by Morpho while a loan is in flight.
  /// @param assets The amount of assets that was flash loaned
  /// @param data The payload passed to {flashLoan}, forwarded verbatim
  function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
    address initiator = _loadAddress(_INITIATOR_TSLOT);
    if (msg.sender != address(MORPHO) || initiator == address(0)) {
      revert LibRetargetterErrors.UnauthorizedCaller();
    }
    address token = _loadAddress(_TOKEN_TSLOT);
    token.safeTransfer(initiator, assets);
    IFlashLoanReceiver(initiator).onFlashLoan(assets, data);
    token.safeTransferFrom(initiator, address(this), assets);
    token.safeApproveWithRetry(address(MORPHO), assets);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reads an address from a transient slot.
  function _loadAddress(uint256 slot) private view returns (address value) {
    assembly ("memory-safe") {
      value := tload(slot)
    }
  }

  /// @dev Writes an address to a transient slot.
  function _store(uint256 slot, address value) private {
    assembly ("memory-safe") {
      tstore(slot, value)
    }
  }
}
