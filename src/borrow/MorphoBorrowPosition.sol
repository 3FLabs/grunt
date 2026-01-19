// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "lib/morpho-blue/src/interfaces/IOracle.sol";
import {SharesMathLib} from "../libs/borrow/SharesMathLib.sol";
import {LibErrors} from "../libs/borrow/LibErrors.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {IBorrowPosition} from "../interfaces/borrow/IBorrowPosition.sol";
import {UtilsLib} from "lib/morpho-blue/src/libraries/UtilsLib.sol";
import {IMorphoRepayCallback} from "lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IPreLiquidationCallback} from "../interfaces/borrow/IPreliquidationCallback.sol";

/// @title MorphoBorrowPosition
/// @notice Implementation of a borrow position with the Morpho Blue protocol.
/// @dev This contract manages a single collateralized borrow position on Morpho Blue.
///      It acts as the position holder and delegates control to an owner (typically a Position Manager).
///      The contract uses ERC-7201 namespaced storage for proxy compatibility and follows
///      the Checks-Effects-Interactions pattern for security.
/// @author 3F Protocol
contract MorphoBorrowPosition is IBorrowPosition, Initializable, Ownable, IMorphoRepayCallback {
  using SharesMathLib for uint256;
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the BorrowPosition contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param morpho The Morpho protocol contract
  /// @param marketId The Morpho market ID for this borrow position
  /// @param marketParams The Morpho market parameters for this borrow position
  /// @param lltv The custom LLTV for this borrow position (immutable after initialization)
  struct BorrowPositionStorage {
    IMorpho morpho;
    Id marketId;
    MarketParams marketParams;
    uint256 lltv;
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
  /// @param lltv_ The custom LLTV for this borrow position. Must be > 0, <= WAD, and <= market LLTV.
  /// @dev Reverts with {LibErrors.AddressZero} if morpho_ is zero address.
  ///      Reverts with {LibErrors.InvalidMarketId} if marketId_ is zero.
  ///      Reverts with {LibErrors.MarketNotCreated} if the market doesn't exist in Morpho.
  ///      Reverts with {LibErrors.InvalidLltv} if lltv_ is zero or greater than WAD.
  ///      Reverts with {LibErrors.CustomLltvExceedsMarketLltv} if lltv_ exceeds the Morpho market LLTV.
  function initialize(IMorpho morpho_, Id marketId_, address positionManager_, uint256 lltv_) public initializer {
    if (address(morpho_) == address(0)) revert LibErrors.AddressZero();
    if (Id.unwrap(marketId_) == bytes32(0)) revert LibErrors.InvalidMarketId(marketId_);
    if (morpho_.market(marketId_).lastUpdate == 0) revert LibErrors.MarketNotCreated();
    if (lltv_ == 0 || lltv_ > FixedPointMathLib.WAD) revert LibErrors.InvalidLltv();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    _storage.morpho = morpho_;
    _storage.marketId = marketId_;
    _storage.marketParams = morpho_.idToMarketParams(marketId_);

    // Validate custom LLTV does not exceed market LLTV
    // This ensures pre-liquidation triggers before Morpho's native liquidation
    if (lltv_ > _storage.marketParams.lltv) {
      revert LibErrors.CustomLltvExceedsMarketLltv(lltv_, _storage.marketParams.lltv);
    }

    _storage.lltv = lltv_;

    _initializeOwner(positionManager_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OPERATIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers collateral from the caller to this contract, approves Morpho, and supplies it.
  ///      Uses SafeTransferLib for secure token transfers.
  ///      Increases the position's collateral, which increases borrowing capacity.
  ///      Reverts with {LibErrors.AmountZero} if amount is 0.
  function supplyCollateral(uint256 amount) external override onlyOwner {
    if (amount == 0) revert LibErrors.AmountZero();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    MarketParams memory _marketParams = _storage.marketParams;
    IMorpho _morpho = _storage.morpho;

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
  ///      Reverts with {LibErrors.AmountZero} if amount is 0.
  ///      Reverts with {LibErrors.InsufficientCollateral} if withdrawal would make position unhealthy.
  function withdrawCollateral(uint256 amount) external override onlyOwner {
    if (amount == 0) revert LibErrors.AmountZero();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    MarketParams memory _marketParams = _storage.marketParams;

    // Withdraw collateral from Morpho to the owner (Position Manager)
    // This will revert if the position would become unhealthy
    _storage.morpho.withdrawCollateral(_marketParams, amount, address(this), msg.sender);

    if (!_isHealthy(_storage.lltv, _marketParams.oracle)) {
      revert LibErrors.InsufficientCollateral();
    }
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Borrows assets from Morpho and sends them directly to the owner (msg.sender).
  ///      Requires sufficient collateral to maintain a healthy position based on the market's LLTV.
  ///      Morpho enforces health checks and liquidity constraints.
  ///      Reverts with {LibErrors.AmountZero} if amount is 0.
  ///      Reverts with {LibErrors.InsufficientCollateral} if borrowing would exceed LLTV limits.
  function borrow(uint256 amount) external override onlyOwner {
    if (amount == 0) revert LibErrors.AmountZero();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    MarketParams memory _marketParams = _storage.marketParams;

    // Borrow from Morpho, sending borrowed assets to the owner (Position Manager)
    // This will revert if the position would become unhealthy or insufficient liquidity
    _storage.morpho.borrow(_marketParams, amount, 0, address(this), msg.sender);

    if (!_isHealthy(_storage.lltv, _marketParams.oracle)) {
      revert LibErrors.InsufficientCollateral();
    }
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers loan tokens from the caller, approves Morpho, and repays the debt.
  ///      Reduces the borrowed amount, improving the position's health factor.
  ///      Can repay partial or full debt. Uses SafeTransferLib for secure token transfers.
  ///      Reverts with {LibErrors.AmountZero} if amount is 0.
  function repay(uint256 amount) external override onlyOwner {
    if (amount == 0) revert LibErrors.AmountZero();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    MarketParams memory _marketParams = _storage.marketParams;
    IMorpho _morpho = _storage.morpho;

    // Transfer loan tokens from caller to this contract
    _marketParams.loanToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend loan tokens
    _marketParams.loanToken.safeApproveWithRetry(address(_morpho), amount);

    // Repay debt to Morpho
    _morpho.repay(_marketParams, amount, 0, address(this), "");
  }

  /// @notice Pre-liquidates the position when it becomes unhealthy based on the custom LLTV.
  /// @dev This function allows anyone to liquidate an unhealthy position. Unlike Morpho's native liquidation,
  ///      this mechanism gives **proportional collateral** to the liquidator without applying a liquidation
  ///      incentive factor (LIF). This means:
  ///
  ///      **Liquidation Bonus = 1 - LTV (at time of liquidation)**
  ///
  ///      For example, if a position has:
  ///      - 100 collateral tokens (worth $100)
  ///      - 80 debt tokens (worth $80)
  ///      - LTV = 80%
  ///
  ///      A liquidator repaying 50% of the debt ($40) will seize 50% of the collateral (50 tokens worth $50).
  ///      The liquidator's profit is $50 - $40 = $10, which equals (1 - 0.80) × $50 = 20% × $50.
  ///
  ///      This ensures liquidators can always seize their proportional share of collateral, and the liquidation
  ///      bonus scales with how underwater the position is. At the LLTV threshold, the bonus approaches 1 - LLTV.
  ///
  ///      The liquidation uses a callback pattern: Morpho calls `onMorphoRepay` which withdraws collateral
  ///      to the liquidator, optionally calls the liquidator's callback, then pulls loan tokens from the liquidator.
  ///
  ///      **Callback Interface:**
  ///      This function conforms to the same signature and callback interface as Morpho's PreLiquidation contract.
  ///      Liquidators implementing `IPreLiquidationCallback.onPreLiquidate(uint256 repaidAssets, bytes calldata data)`
  ///      will receive the callback if `data` is non-empty.
  ///
  /// @param borrower The address of the position owner (typically this contract's address).
  /// @param seizedAssets The amount of collateral to seize. Pass 0 to calculate based on repaidShares.
  /// @param repaidShares The amount of borrow shares to repay. Pass 0 to calculate based on seizedAssets.
  /// @param data Arbitrary data to pass to the `onPreLiquidate` callback. Pass empty data if not needed.
  /// @return The amount of collateral seized.
  /// @return The amount of debt assets repaid.
  /// @dev Reverts with {LibErrors.InconsistentInput} if both seizedAssets and repaidShares are non-zero or both are zero.
  ///      Reverts with {LibErrors.PositionHealthy} if the position is healthy based on the custom LLTV.
  function preLiquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data)
    external
    returns (uint256, uint256)
  {
    if (!UtilsLib.exactlyOneZero(seizedAssets, repaidShares)) revert LibErrors.InconsistentInput();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    if (_isHealthy(_storage.lltv, _storage.marketParams.oracle)) revert LibErrors.PositionHealthy();

    _storage.morpho.accrueInterest(_storage.marketParams);

    {
      Position memory position = _storage.morpho.position(_storage.marketId, borrower);
      if (seizedAssets > 0) {
        repaidShares = seizedAssets.mulDivUp(position.borrowShares, position.collateral);
      } else {
        seizedAssets = repaidShares.mulDiv(position.collateral, position.borrowShares);
      }
    }

    uint256 repaidAssets;
    {
      bytes memory callbackData = abi.encode(seizedAssets, borrower, msg.sender, data);
      (repaidAssets,) = _storage.morpho.repay(_storage.marketParams, 0, repaidShares, borrower, callbackData);
    }

    return (seizedAssets, repaidAssets);
  }

  /// @notice Morpho callback invoked after a repay operation.
  /// @dev This callback is called by Morpho during the pre-liquidation flow:
  ///      1. preLiquidate() calls morpho.repay() with callback data
  ///      2. Morpho repays the debt and calls this callback
  ///      3. This callback withdraws collateral to the liquidator
  ///      4. Optionally calls the liquidator's onPreLiquidate callback
  ///      5. Pulls loan tokens from the liquidator to complete the repayment
  ///      Reverts with {LibErrors.NotMorpho} if called by any address other than the Morpho contract.
  /// @param repaidAssets The amount of loan tokens that were repaid.
  /// @param callbackData Encoded data containing (seizedAssets, borrower, liquidator, data).
  function onMorphoRepay(uint256 repaidAssets, bytes calldata callbackData) external {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    IMorpho _morpho = _storage.morpho;

    if (msg.sender != address(_morpho)) revert LibErrors.NotMorpho();

    (uint256 seizedAssets, address borrower, address liquidator, bytes memory data) =
      abi.decode(callbackData, (uint256, address, address, bytes));

    MarketParams memory marketParams = _storage.marketParams;

    _morpho.withdrawCollateral(marketParams, seizedAssets, borrower, liquidator);

    if (data.length > 0) {
      IPreLiquidationCallback(liquidator).onPreLiquidate(repaidAssets, data);
    }

    marketParams.loanToken.safeTransferFrom(liquidator, address(this), repaidAssets);
    marketParams.loanToken.safeApproveWithRetry(address(_morpho), repaidAssets);
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
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    IMorpho _morpho = _storage.morpho;
    Id _marketId = _storage.marketId;

    Position memory _pos = _morpho.position(_marketId, address(this));
    Market memory _mkt = _morpho.market(_marketId);

    // Convert borrow shares to assets using market totals
    return uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the raw collateral amount stored in the Morpho position.
  function totalCollateral() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    return uint256(_storage.morpho.position(_storage.marketId, address(this)).collateral);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Takes the raw collateral amount stored in the Morpho position and quotes it
  ///      in borrowed asset units.
  function totalCollateralQuoted() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    return uint256(_storage.morpho.position(_storage.marketId, address(this)).collateral)
      .mulDiv(IOracle(_storage.marketParams.oracle).price(), ORACLE_PRICE_SCALE);
  }

  /// @inheritdoc IBorrowPosition
  function isHealthy(uint256 _lltv) external view override returns (bool) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    return _isHealthy(_lltv, _storage.marketParams.oracle);
  }

  /// @inheritdoc IBorrowPosition
  function maxBorrow(uint256 _lltv) external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    Id _marketId = _storage.marketId;
    IMorpho _morpho = _storage.morpho;

    // Get available liquidity in the market
    Market memory _mkt = _morpho.market(_marketId);
    uint256 _availableLiquidity = _mkt.totalSupplyAssets - _mkt.totalBorrowAssets;

    // Get collateral price from oracle
    Position memory _pos = _morpho.position(_marketId, address(this));
    uint256 _collateralPrice = IOracle(_storage.marketParams.oracle).price();

    uint256 borrowed = uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);

    // Calculate remaining borrow capacity: (collateralValue * LLTV) - alreadyBorrowed
    // Uses zeroFloorSub to return 0 instead of underflowing if already over-utilized
    // Return remaining capacity or available liquidity, whichever is lower
    return uint256(_pos.collateral).mulDiv(_collateralPrice, ORACLE_PRICE_SCALE).mulWad(_lltv).zeroFloorSub(borrowed)
      .min(_availableLiquidity);
  }

  /// @inheritdoc IBorrowPosition
  function availableLiquidity() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Get available liquidity in the market
    Market memory _mkt = _storage.morpho.market(_storage.marketId);
    return _mkt.totalSupplyAssets - _mkt.totalBorrowAssets;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Calculates available collateral as: totalCollateral - (debt * ORACLE_PRICE_SCALE) / (lltv * price)
  ///      If no debt, returns all collateral. Returns 0 if position would be unhealthy.
  function availableCollateral(uint256 _lltv) external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    IMorpho _morpho = _storage.morpho;
    Id _marketId = _storage.marketId;

    Position memory _pos = _morpho.position(_marketId, address(this));

    // If no debt, all collateral is available
    if (_pos.borrowShares == 0) return uint256(_pos.collateral);

    Market memory _mkt = _morpho.market(_marketId);
    uint256 _collateralPrice = IOracle(_storage.marketParams.oracle).price();

    // Calculate borrowed amount (rounds up to be conservative)
    uint256 _borrowed = uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);

    // Required collateral = borrowed * ORACLE_PRICE_SCALE / (lltv * price)
    // This rounds up to be conservative (more collateral required = less available)
    uint256 _requiredCollateral = _borrowed.mulDivUp(ORACLE_PRICE_SCALE, _lltv.mulWad(_collateralPrice));

    // Return available collateral (0 if required > total)
    if (_requiredCollateral >= uint256(_pos.collateral)) return 0;
    return uint256(_pos.collateral) - _requiredCollateral;
  }

  /// @dev Internal helper to determine if the position is healthy based on provided lltv and oracle.
  ///      Health calculation:
  ///      1. If no borrow exists (borrowShares == 0), position is always healthy.
  ///      2. Otherwise, calculates: maxBorrow = (collateral * oraclePrice / ORACLE_PRICE_SCALE) * lltv
  ///      3. Position is healthy if maxBorrow >= borrowed amount (with interest).
  ///      Uses conservative rounding: borrowed amount rounds up, max borrow rounds down.
  /// @param _lltv The LLTV to use for the health calculation.
  /// @param oracle The oracle address to fetch the collateral price.
  /// @return True if the position is healthy, false otherwise.
  function _isHealthy(uint256 _lltv, address oracle) internal view returns (bool) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    IMorpho morpho = _storage.morpho;
    Id _marketId = _storage.marketId;
    Position memory _pos = morpho.position(_marketId, address(this));

    // If no borrow, position is always healthy
    if (_pos.borrowShares == 0) return true;

    Market memory _mkt = morpho.market(_marketId);

    // Get collateral price from oracle
    uint256 _collateralPrice = IOracle(oracle).price();

    // Calculate borrowed amount (rounds up to be conservative)
    uint256 _borrowed = uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);

    // Calculate max borrow based on collateral value and provided LLTV
    return uint256(_pos.collateral).mulDiv(_collateralPrice, ORACLE_PRICE_SCALE).mulWad(_lltv) >= _borrowed;
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

  /// @notice Returns the custom LLTV set for this borrow position.
  /// @dev This LLTV is immutable after initialization and determines when the position
  ///      can be liquidated. It is typically set lower than the Morpho market LLTV.
  /// @return The custom LLTV in WAD format (1e18 = 100%).
  function lltv() external view returns (uint256) {
    return _borrowPositionStorage().lltv;
  }
}
