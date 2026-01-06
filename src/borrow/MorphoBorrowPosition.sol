// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "lib/morpho-blue/src/interfaces/IOracle.sol";
import {MathLib} from "lib/morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {IPreLiquidation} from "lib/pre-liquidation/src/interfaces/IPreLiquidation.sol";
import {IPreLiquidationFactory} from "lib/pre-liquidation/src/interfaces/IPreLiquidationFactory.sol";
import "lib/pre-liquidation/src/interfaces/IPreLiquidation.sol" as PreLiquidation;

import {IBorrowPosition} from "../interfaces/borrow/IBorrowPosition.sol";

/// @title MorphoBorrowPosition
/// @notice Implementation of a borrow position with the Morpho Blue protocol.
/// @dev This contract manages a single collateralized borrow position on Morpho Blue.
///      It acts as the position holder and delegates control to an owner (typically a Position Manager).
///      The contract uses ERC-7201 namespaced storage for proxy compatibility and follows
///      the Checks-Effects-Interactions pattern for security.
/// @author 3F Protocol
contract MorphoBorrowPosition is IBorrowPosition, Initializable, Ownable {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a required address parameter is the zero address.
  error AddressZero();

  /// @notice Thrown when the market ID is invalid (zero bytes32).
  /// @dev Market IDs in Morpho are derived from market parameters and must be non-zero.
  /// @param marketId The invalid market ID.
  error InvalidMarketId(Id marketId);

  /// @notice Thrown when attempting to initialize with a market that doesn't exist in Morpho.
  /// @dev Markets must be created in Morpho before a borrow position can be initialized for them.
  error MarketNotCreated();

  /// @notice Thrown when an operation is called with a zero amount.
  error AmountZero();

  /// @notice Thrown when the position has insufficient collateral after an operation.
  error InsufficientCollateral();

  /// @notice Thrown when the provided pre-liquidation contract is not valid (not known from the factory).
  /// @param preLiquidation The invalid pre-liquidation contract address.
  error InvalidPreLiquidation(address preLiquidation);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The preLiquidation Factory contract address.
  IPreLiquidationFactory internal immutable _PRE_LIQUIDATION_FACTORY;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Constructs the MorphoBorrowPosition contract with the PreLiquidation factory address.
  /// @param preLiquidationFactory_ The PreLiquidation factory contract address.
  constructor(IPreLiquidationFactory preLiquidationFactory_) {
    _PRE_LIQUIDATION_FACTORY = preLiquidationFactory_;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the BorrowPosition contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param morpho The Morpho protocol contract
  /// @param marketId The Morpho market ID for this borrow position
  /// @param marketParams The Morpho market parameters for this borrow position
  /// @param preLiquidation The pre-liquidation contract for this borrow position
  /// @param preLltv The pre-liquidation maximum LLTV for this borrow position
  struct BorrowPositionStorage {
    IMorpho morpho;
    Id marketId;
    MarketParams marketParams;
    IPreLiquidation preLiquidation;
    uint256 preLltv;
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
    assembly ("memory-safe") {
      borrowPositionStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the MorphoBorrowPosition contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      Validates all inputs and fetches market parameters from Morpho.
  ///      The position manager becomes the owner and has exclusive control over the position.
  /// @param morpho_ The Morpho Blue protocol contract address.
  /// @param marketId_ The Morpho market ID for this borrow position. Must correspond to an existing market.
  /// @param positionManager_ The address of the position manager (owner) that will control this position.
  /// @param preLiquidation_ The pre-liquidation contract for this borrow position.
  /// @custom:reverts InvalidMarketId if marketId_ is zero.
  /// @custom:reverts MarketNotCreated if the market doesn't exist in Morpho (lastUpdate == 0).
  function initialize(IMorpho morpho_, Id marketId_, address positionManager_, IPreLiquidation preLiquidation_)
    public
    initializer
  {
    if (address(morpho_) == address(0)) revert AddressZero();
    if (address(preLiquidation_) == address(0)) revert AddressZero();
    if (Id.unwrap(marketId_) == bytes32(0)) revert InvalidMarketId(marketId_);
    if (morpho_.market(marketId_).lastUpdate == 0) revert MarketNotCreated();
    if (PreLiquidation.Id.unwrap(preLiquidation_.ID()) != Id.unwrap(marketId_)) {
      revert InvalidMarketId(marketId_);
    }
    if (!_PRE_LIQUIDATION_FACTORY.isPreLiquidation(address(preLiquidation_))) {
      revert InvalidPreLiquidation(address(preLiquidation_));
    }

    BorrowPositionStorage storage $ = _borrowPositionStorage();
    $.morpho = morpho_;
    $.marketId = marketId_;
    $.marketParams = morpho_.idToMarketParams(marketId_);
    $.preLltv = preLiquidation_.preLiquidationParams().preLltv;

    $.preLiquidation = preLiquidation_;
    morpho_.setAuthorization(address(preLiquidation_), true);

    _initializeOwner(positionManager_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OPERATIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers collateral from the caller to this contract, approves Morpho, and supplies it.
  ///      Uses SafeTransferLib for secure token transfers.
  ///      Increases the position's collateral, which increases borrowing capacity.
  /// @custom:reverts AmountZero if amount is 0.
  /// @custom:reverts Unauthorized if caller is not the owner.
  /// @custom:reverts TransferFromFailed if the caller has insufficient balance or allowance.
  function supplyCollateral(uint256 amount) external override onlyOwner {
    if (amount == 0) revert AmountZero();

    BorrowPositionStorage storage $ = _borrowPositionStorage();
    MarketParams memory _marketParams = $.marketParams;
    IMorpho _morpho = $.morpho;

    // Transfer collateral from caller to this contract
    _marketParams.collateralToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend collateral
    _marketParams.collateralToken.safeApproveWithRetry(address(_morpho), amount);

    // Supply collateral to Morpho on behalf of this contract
    _morpho.supplyCollateral(_marketParams, amount, address(this), "");
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Withdraws collateral directly from Morpho to the owner (msg.sender).
  ///      Morpho enforces health checks and will revert if the withdrawal would make the position unhealthy.
  ///      If there is an active borrow, the remaining collateral must maintain adequate collateralization.
  /// @custom:reverts AmountZero if amount is 0.
  /// @custom:reverts Unauthorized if caller is not the owner.
  /// @custom:reverts ArithmeticError (underflow) if amount exceeds available collateral.
  /// @custom:reverts "insufficient collateral" from Morpho if withdrawal would make position unhealthy.
  function withdrawCollateral(uint256 amount) external override onlyOwner {
    if (amount == 0) revert AmountZero();

    BorrowPositionStorage storage $ = _borrowPositionStorage();
    MarketParams memory _marketParams = $.marketParams;

    // Withdraw collateral from Morpho to the owner (Position Manager)
    // This will revert if the position would become unhealthy
    $.morpho.withdrawCollateral(_marketParams, amount, address(this), msg.sender);

    if (!_isHealthy($.preLltv, _marketParams.oracle)) {
      revert InsufficientCollateral();
    }
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Borrows assets from Morpho and sends them directly to the owner (msg.sender).
  ///      Requires sufficient collateral to maintain a healthy position based on the market's LLTV.
  ///      Morpho enforces health checks and liquidity constraints.
  /// @custom:reverts AmountZero if amount is 0.
  /// @custom:reverts Unauthorized if caller is not the owner.
  /// @custom:reverts "insufficient collateral" from Morpho if borrowing would exceed LLTV limits.
  /// @custom:reverts "insufficient liquidity" from Morpho if the market doesn't have enough liquidity.
  function borrow(uint256 amount) external override onlyOwner {
    if (amount == 0) revert AmountZero();

    BorrowPositionStorage storage $ = _borrowPositionStorage();
    MarketParams memory _marketParams = $.marketParams;

    // Borrow from Morpho, sending borrowed assets to the owner (Position Manager)
    // This will revert if the position would become unhealthy or insufficient liquidity
    $.morpho.borrow(_marketParams, amount, 0, address(this), msg.sender);

    if (!_isHealthy($.preLltv, _marketParams.oracle)) {
      revert InsufficientCollateral();
    }
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers loan tokens from the caller, approves Morpho, and repays the debt.
  ///      Reduces the borrowed amount, improving the position's health factor.
  ///      Can repay partial or full debt. Uses SafeTransferLib for secure token transfers.
  /// @custom:reverts AmountZero if amount is 0.
  /// @custom:reverts Unauthorized if caller is not the owner.
  /// @custom:reverts TransferFromFailed if the caller has insufficient balance or allowance.
  function repay(uint256 amount) external override onlyOwner {
    if (amount == 0) revert AmountZero();

    BorrowPositionStorage storage $ = _borrowPositionStorage();
    MarketParams memory _marketParams = $.marketParams;
    IMorpho _morpho = $.morpho;

    // Transfer loan tokens from caller to this contract
    _marketParams.loanToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend loan tokens
    _marketParams.loanToken.safeApproveWithRetry(address(_morpho), amount);

    // Repay debt to Morpho
    _morpho.repay(_marketParams, amount, 0, address(this), "");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ASSETS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the loan token address from the cached market parameters.
  function borrowAsset() external view override returns (address) {
    return _borrowPositionStorage().marketParams.loanToken;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the collateral token address from the cached market parameters.
  function collateralAsset() external view override returns (address) {
    return _borrowPositionStorage().marketParams.collateralToken;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          POSITION                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Converts borrow shares to asset amount using Morpho's SharesMathLib.
  ///      Uses `toAssetsUp` to round up, which is conservative when calculating debt.
  ///      Accounts for accrued interest since the borrow shares represent a proportion
  ///      of the total market debt that grows over time.
  function totalBorrowed() external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    IMorpho _morpho = $.morpho;
    Id _marketId = $.marketId;

    Position memory _pos = _morpho.position(_marketId, address(this));
    Market memory _mkt = _morpho.market(_marketId);

    // Convert borrow shares to assets using market totals
    return uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the raw collateral amount stored in the Morpho position.
  function totalCollateral() external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    return uint256($.morpho.position($.marketId, address(this)).collateral);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Takes the raw collateral amount stored in the Morpho position and quotes it
  ///      in borrowed asset units.
  function totalCollateralQuoted() external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    return uint256($.morpho.position($.marketId, address(this)).collateral)
      .mulDivDown(IOracle($.marketParams.oracle).price(), ORACLE_PRICE_SCALE);
  }

  /// @inheritdoc IBorrowPosition
  function isHealthy(uint256 lltv) external view override returns (bool) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    return _isHealthy(lltv, $.marketParams.oracle);
  }

  /// @inheritdoc IBorrowPosition
  function maxBorrow(uint256 lltv) external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    Id _marketId = $.marketId;
    IMorpho _morpho = $.morpho;

    // Get available liquidity in the market
    Market memory _mkt = _morpho.market(_marketId);
    uint256 _availableLiquidity = _mkt.totalSupplyAssets - _mkt.totalBorrowAssets;

    // Get collateral price from oracle
    Position memory _pos = _morpho.position(_marketId, address(this));
    uint256 _collateralPrice = IOracle($.marketParams.oracle).price();

    // Calculate max borrow: collateralValue * LLTV
    // Return computed max borrow or available liquidity, whichever is lower
    return
      uint256(_pos.collateral).mulDivDown(_collateralPrice, ORACLE_PRICE_SCALE).wMulDown(lltv).min(_availableLiquidity);
  }

  /// @inheritdoc IBorrowPosition
  function availableLiquidity() external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();

    // Get available liquidity in the market
    Market memory _mkt = $.morpho.market($.marketId);
    return _mkt.totalSupplyAssets - _mkt.totalBorrowAssets;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Calculates free collateral as: totalCollateral - (debt * ORACLE_PRICE_SCALE) / (lltv * price)
  ///      If no debt, returns all collateral. Returns 0 if position would be unhealthy.
  function freeCollateral(uint256 lltv) external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    IMorpho _morpho = $.morpho;
    Id _marketId = $.marketId;

    Position memory _pos = _morpho.position(_marketId, address(this));

    // If no debt, all collateral is free
    if (_pos.borrowShares == 0) return uint256(_pos.collateral);

    Market memory _mkt = _morpho.market(_marketId);
    uint256 _collateralPrice = IOracle($.marketParams.oracle).price();

    // Calculate borrowed amount (rounds up to be conservative)
    uint256 _borrowed = uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);

    // Required collateral = borrowed * ORACLE_PRICE_SCALE / (lltv * price)
    // This rounds up to be conservative (more collateral required = less free)
    uint256 _requiredCollateral = MathLib.mulDivUp(_borrowed, ORACLE_PRICE_SCALE, lltv.wMulDown(_collateralPrice));

    // Return free collateral (0 if required > total)
    if (_requiredCollateral >= uint256(_pos.collateral)) return 0;
    return uint256(_pos.collateral) - _requiredCollateral;
  }

  /// @dev Internal helper to determine if the position is healthy based on provided lltv and oracle.
  ///      Health calculation:
  ///      1. If no borrow exists (borrowShares == 0), position is always healthy.
  ///      2. Otherwise, calculates: maxBorrow = (collateral * oraclePrice / ORACLE_PRICE_SCALE) * lltv
  ///      3. Position is healthy if maxBorrow >= borrowed amount (with interest).
  ///      Uses conservative rounding: borrowed amount rounds up, max borrow rounds down.
  /// @param lltv The LLTV to use for the health calculation.
  /// @param oracle The oracle address to fetch the collateral price.
  /// @return True if the position is healthy, false otherwise.
  function _isHealthy(uint256 lltv, address oracle) internal view returns (bool) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    IMorpho morpho = $.morpho;
    Id _marketId = $.marketId;
    Position memory _pos = morpho.position(_marketId, address(this));

    // If no borrow, position is always healthy
    if (_pos.borrowShares == 0) return true;

    Market memory _mkt = morpho.market(_marketId);

    // Get collateral price from oracle
    uint256 _collateralPrice = IOracle(oracle).price();

    // Calculate borrowed amount (rounds up to be conservative)
    uint256 _borrowed = uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);

    // Calculate max borrow based on collateral value and provided LLTV
    return uint256(_pos.collateral).mulDivDown(_collateralPrice, ORACLE_PRICE_SCALE).wMulDown(lltv) >= _borrowed;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           GETTERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the Morpho market ID associated with this borrow position.
  /// @dev The market ID is set during initialization and uniquely identifies the Morpho market
  ///      (loan token, collateral token, oracle, LLTV, and IRM combination).
  /// @return The Morpho market ID (bytes32 encoded).
  function marketId() external view returns (Id) {
    return _borrowPositionStorage().marketId;
  }
}
