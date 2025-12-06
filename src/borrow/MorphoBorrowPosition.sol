// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "lib/morpho-blue/src/interfaces/IOracle.sol";
import {MathLib} from "lib/morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";

import {IBorrowPosition} from "../interfaces/borrow/IBorrowPosition.sol";

/// @title MorphoBorrowPosition
/// @notice Implementation of a borrow position with the Morpho protocol.
contract MorphoBorrowPosition is IBorrowPosition, Initializable, Ownable {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when an address is zero
  error AddressZero();

  /// @notice Thrown when the market ID is invalid (zero)
  error InvalidMarketId();

  /// @notice Thrown when the market does not exist in Morpho
  error MarketNotCreated();

  /// @notice Thrown when the amount is zero
  error AmountZero();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the BorrowPosition contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param morpho The Morpho protocol contract
  /// @param marketId The Morpho market ID for this borrow position
  /// @param marketParams The Morpho market parameters for this borrow position
  struct BorrowPositionStorage {
    IMorpho morpho;
    Id marketId;
    MarketParams marketParams;
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
  /// @param morpho_ The Morpho protocol contract address
  /// @param marketId_ The Morpho market ID for this borrow position
  /// @param positionManager_ The address of the position manager (owner)
  function initialize(IMorpho morpho_, Id marketId_, address positionManager_) public initializer {
    if (address(morpho_) == address(0)) revert AddressZero();
    if (Id.unwrap(marketId_) == bytes32(0)) revert InvalidMarketId();
    if (morpho_.market(marketId_).lastUpdate == 0) revert MarketNotCreated();

    BorrowPositionStorage storage $ = _borrowPositionStorage();
    $.morpho = morpho_;
    $.marketId = marketId_;
    $.marketParams = morpho_.idToMarketParams(marketId_);

    _initializeOwner(positionManager_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OPERATIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  function supplyCollateral(uint256 amount) external override onlyOwner {
    if (amount == 0) revert AmountZero();

    BorrowPositionStorage storage $ = _borrowPositionStorage();

    // Transfer collateral from caller to this contract
    $.marketParams.collateralToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend collateral
    $.marketParams.collateralToken.safeApprove(address($.morpho), amount);

    // Supply collateral to Morpho on behalf of this contract
    $.morpho.supplyCollateral($.marketParams, amount, address(this), "");
  }

  /// @inheritdoc IBorrowPosition
  function withdrawCollateral(uint256 amount) external override onlyOwner {
    if (amount == 0) revert AmountZero();

    BorrowPositionStorage storage $ = _borrowPositionStorage();

    // Withdraw collateral from Morpho to the owner (Position Manager)
    // This will revert if the position would become unhealthy
    $.morpho.withdrawCollateral($.marketParams, amount, address(this), msg.sender);
  }

  /// @inheritdoc IBorrowPosition
  function borrow(uint256 amount) external override onlyOwner {
    if (amount == 0) revert AmountZero();

    BorrowPositionStorage storage $ = _borrowPositionStorage();

    // Borrow from Morpho, sending borrowed assets to the owner (Position Manager)
    // This will revert if the position would become unhealthy or insufficient liquidity
    $.morpho.borrow($.marketParams, amount, 0, address(this), msg.sender);
  }

  /// @inheritdoc IBorrowPosition
  function repay(uint256 amount) external override onlyOwner {
    if (amount == 0) revert AmountZero();

    BorrowPositionStorage storage $ = _borrowPositionStorage();

    // Transfer loan tokens from caller to this contract
    $.marketParams.loanToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend loan tokens
    $.marketParams.loanToken.safeApprove(address($.morpho), amount);

    // Repay debt to Morpho
    $.morpho.repay($.marketParams, amount, 0, address(this), "");
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
    BorrowPositionStorage storage $ = _borrowPositionStorage();

    Position memory _pos = $.morpho.position($.marketId, address(this));
    Market memory _mkt = $.morpho.market($.marketId);

    // Convert borrow shares to assets using market totals
    return uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);
  }

  /// @inheritdoc IBorrowPosition
  function totalCollateral() external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    return $.morpho.position($.marketId, address(this)).collateral;
  }

  /// @inheritdoc IBorrowPosition
  function isHealthy() external view override returns (bool) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();

    Position memory _pos = $.morpho.position($.marketId, address(this));

    // If no borrow, position is always healthy
    if (_pos.borrowShares == 0) return true;

    Market memory _mkt = $.morpho.market($.marketId);
    MarketParams memory _marketParams = $.marketParams;

    // Get collateral price from oracle
    uint256 _collateralPrice = IOracle(_marketParams.oracle).price();

    // Calculate borrowed amount (rounds up to be conservative)
    uint256 _borrowed = uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);

    // Calculate max borrow based on collateral value and LLTV
    uint256 _maxBorrow =
      uint256(_pos.collateral).mulDivDown(_collateralPrice, ORACLE_PRICE_SCALE).wMulDown(_marketParams.lltv);

    return _maxBorrow >= _borrowed;
  }

  /// @inheritdoc IBorrowPosition
  function maxBorrow() external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();

    Position memory _pos = $.morpho.position($.marketId, address(this));
    MarketParams memory _marketParams = $.marketParams;

    // Get collateral price from oracle
    uint256 _collateralPrice = IOracle(_marketParams.oracle).price();

    // Calculate max borrow: collateralValue * LLTV
    return uint256(_pos.collateral).mulDivDown(_collateralPrice, ORACLE_PRICE_SCALE).wMulDown(_marketParams.lltv);
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
