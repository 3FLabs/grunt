// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {RebalancingData} from "../../interfaces/manager/base/IPositionManagerRebalancing.sol";
import {IMorphoFlashLoanCallback} from "lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IMorpho} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {LibManagerErrors} from "../../libs/manager/LibManagerErrors.sol";

/// @title MorphoRebalancer
/// @notice A rebalancer contract that uses Morpho flash loans to rebalance PositionManager positions.
/// @dev Designed to be granted the REBALANCER role on PositionManagers and reusable across
///      several of them by passing the target as a parameter; the rebalance runs inside a
///      Morpho flash-loan callback and the loan is repaid in the same transaction.
/// @author 3F Protocol
contract MorphoRebalancer is IMorphoFlashLoanCallback, Ownable, ReentrancyGuardTransient {
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a rebalance operation is executed via Morpho flash loan.
  /// @param positionManager The PositionManager that was rebalanced
  /// @param flashLoanAmount The amount of debt tokens flash loaned
  /// @param collateralExcess The excess collateral returned to the receiver
  /// @param debtExcess The excess debt returned to the receiver
  event MorphoRebalanced(
    address indexed positionManager, uint256 flashLoanAmount, uint256 collateralExcess, uint256 debtExcess
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Morpho protocol contract used for flash loans.
  IMorpho public immutable MORPHO;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the MorphoRebalancer contract.
  /// @param owner_ The owner of the contract who can call rebalance
  /// @param morpho_ The Morpho protocol contract address
  constructor(address owner_, address morpho_) {
    _initializeOwner(owner_);
    MORPHO = IMorpho(morpho_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        REBALANCE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Executes a rebalance operation using a Morpho flash loan.
  /// @dev Only callable by the owner. The flash loan amount is taken from data.debt.
  ///      Collateral must be zero in the rebalancing data. Any excess tokens from the
  ///      rebalance operation are sent to the receiver after flash loan repayment.
  /// @param positionManager The PositionManager contract to rebalance
  /// @param data The rebalancing data to pass to the PositionManager (data.debt is used as flash loan amount)
  /// @param receiver The address to receive any excess collateral and debt tokens
  function rebalance(IPositionManager positionManager, RebalancingData calldata data, address receiver)
    external
    onlyOwner
    nonReentrant
  {
    // Collateral cannot be provided through this rebalancer
    if (data.collateral != 0) revert LibManagerErrors.CollateralNotAllowed();

    (address collateralAsset, address debtAsset) = positionManager.assets();

    bytes memory callbackData = abi.encode(positionManager, data, receiver);

    MORPHO.flashLoan(debtAsset, data.debt, callbackData);

    uint256 collateralExcess = collateralAsset.safeTransferAll(receiver);
    uint256 debtExcess = debtAsset.safeTransferAll(receiver);

    emit MorphoRebalanced(address(positionManager), data.debt, collateralExcess, debtExcess);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FLASH LOAN CALLBACK                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Callback called by Morpho during a flash loan.
  /// @dev This function executes the rebalancing operation and approves Morpho
  ///      to pull back the flash loaned amount. Only callable by Morpho.
  ///      Excess tokens must come back to this contract to repay the flash loan,
  ///      then any remaining excess is transferred to receiver after the callback.
  /// @param assets The amount of assets that was flash loaned
  /// @param data The encoded PositionManager, RebalancingData, and receiver
  function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
    if (msg.sender != address(MORPHO)) revert LibManagerErrors.UnauthorizedCaller();

    (IPositionManager positionManager, RebalancingData memory rebalancingData,) =
      abi.decode(data, (IPositionManager, RebalancingData, address));

    (, address debtAsset) = positionManager.assets();

    debtAsset.safeApproveWithRetry(address(positionManager), rebalancingData.debt);

    // Excess tokens must come back here (address(this)) to repay the flash loan
    positionManager.rebalance(rebalancingData, address(this));

    debtAsset.safeApprove(address(positionManager), 0);

    debtAsset.safeApproveWithRetry(address(MORPHO), assets);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         RESCUE                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Rescues tokens stuck in the contract.
  /// @dev Only callable by the owner. Useful for recovering tokens sent by mistake.
  /// @param token The token address to rescue
  /// @param to The address to send the tokens to
  /// @return amount The amount of tokens rescued
  function rescue(address token, address to) external onlyOwner returns (uint256 amount) {
    amount = token.safeTransferAll(to);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OVERRIDES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Always use transient storage for reentrancy guard (not just on mainnet).
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
