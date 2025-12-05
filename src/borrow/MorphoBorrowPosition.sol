// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "../interfaces/borrow/IBorrowPosition.sol";
import {IMorpho, Id, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

/// @title MorphoBorrowPosition
/// @notice Implementation of a borrow position with the Morpho protocol.
contract MorphoBorrowPosition is IBorrowPosition, Initializable {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the BorrowPosition contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param morpho The Morpho protocol contract
  /// @param marketId The Morpho market ID for this borrow position
  /// @param marketParams The Morpho market parameters for this borrow position
  /// @param positionManager The grunt position manager address
  struct BorrowPositionStorage {
    IMorpho morpho;
    Id marketId;
    MarketParams marketParams;
    address positionManager;
  }

  /// @dev Storage slot for the MorphoBorrowPosition contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("morpho.borrow.position")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0xe3d52ac7b6434dd627426ef8fa2ba1a2f9cb96afe079ac59af28727292403c00;

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return borrowPositionStorage A storage pointer to the BorrowPositionStorage struct
  function _borrowPositionStorage() internal pure returns (BorrowPositionStorage storage borrowPositionStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      borrowPositionStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the MorphoBorrowPosition contract with all required parameters.
  function initialize(IMorpho morpho_, Id marketId_, address positionManager_) public initializer {
    // TODO missing validation checks

    BorrowPositionStorage storage $ = _borrowPositionStorage();
    $.morpho = morpho_;
    $.marketId = marketId_;
    $.positionManager = positionManager_;
    $.marketParams = morpho_.idToMarketParams(marketId_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OPERATIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  function supplyCollateral(uint256 amount) external override {
    // Implementation goes here
  }

  /// @inheritdoc IBorrowPosition
  function withdrawCollateral(uint256 amount) external override {
    // Implementation goes here
  }

  /// @inheritdoc IBorrowPosition
  function borrow(uint256 amount) external override {
    // Implementation goes here
  }

  /// @inheritdoc IBorrowPosition
  function repay(uint256 amount) external override {
    // Implementation goes here
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ASSETS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  function borrowAsset() external view override returns (address) {
    return _borrowPositionStorage().marketParams.loanToken;
  }

  /// @inheritdoc IBorrowPosition
  function collateralAsset() external view override returns (address) {
    return _borrowPositionStorage().marketParams.collateralToken;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          POSITION                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  function totalBorrowed() external view override returns (uint256) {
    // Implementation goes here
    return 0;
  }

  /// @inheritdoc IBorrowPosition
  function totalCollateral() external view override returns (uint256) {
    return 0;
  }

  /// @inheritdoc IBorrowPosition
  function isHealthy() external view override returns (bool) {
    // Implementation goes here
    // re-write the private isHealthy functions from Morpho.sol
    return true;
  }

  /// @inheritdoc IBorrowPosition
  function maxBorrow() external view override returns (uint256) {
    // Implementation goes here
    return 0;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         MORPHO VIEWS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the Morpho market ID associated with this borrow position.
  /// @return The Morpho market ID
  function marketId() external view returns (Id) {
    return _borrowPositionStorage().marketId;
  }
}
