// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IMorpho, Id, MarketParams, Position} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "lib/morpho-blue/src/interfaces/IOracle.sol";
import {SharesMathLib} from "../libs/borrow/SharesMathLib.sol";
import {MorphoBalancesLib} from "../libs/borrow/MorphoBalancesLib.sol";
import {LibBorrowErrors} from "../libs/borrow/LibBorrowErrors.sol";
import {LibChecks} from "../libs/common/LibChecks.sol";
import {LibCommonErrors} from "../libs/common/LibCommonErrors.sol";
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
  using LibChecks for uint256;
  using MorphoBalancesLib for IMorpho;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Morpho protocol contract address, stored as an immutable in bytecode.
  /// @dev Set once in the constructor and shared across all beacon proxies.
  ///      Saves a warm SLOAD (2100 gas) on every external call compared to storage.
  IMorpho public immutable MORPHO;

  /// @notice Storage struct containing all persistent state for the BorrowPosition contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param marketId The Morpho market ID for this borrow position
  /// @param marketParams The Morpho market parameters for this borrow position
  /// @param safeLtv The safe LTV threshold that must not be reached upon position mutations (immutable after initialization)
  /// @param liquidationLtv The liquidation LTV at which the position can be liquidated (immutable after initialization)
  struct BorrowPositionStorage {
    Id marketId;
    MarketParams marketParams;
    uint128 safeLtv;
    uint128 liquidationLtv;
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

  /// @param morpho_ The Morpho Blue protocol contract address.
  constructor(IMorpho morpho_) {
    MORPHO = morpho_;
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the MorphoBorrowPosition contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      Validates all inputs and fetches market parameters from Morpho.
  ///      The position manager becomes the owner and has exclusive control over the position.
  /// @param marketId_ The Morpho market ID for this borrow position. Must correspond to an existing market.
  /// @param positionManager_ The address of the position manager (owner) that will control this position.
  /// @param safeLtv_ The safe LTV threshold that must not be reached upon position mutations. Must be > 0, < liquidationLtv_.
  /// @param liquidationLtv_ The liquidation LTV at which the position can be liquidated. Must be > safeLtv_, <= WAD, and <= market LLTV.
  /// @dev Reverts with {LibBorrowErrors.InvalidMarketId} if marketId_ is zero.
  ///      Reverts with {LibBorrowErrors.MarketNotCreated} if the market doesn't exist in Morpho.
  ///      Reverts with {LibCommonErrors.InvalidLtv} if liquidationLtv_ is zero or greater than WAD.
  ///      Reverts with {LibBorrowErrors.SafeLtvNotLessThanLiquidationLtv} if safeLtv_ >= liquidationLtv_.
  ///      Reverts with {LibBorrowErrors.LiquidationLtvExceedsMarketLltv} if liquidationLtv_ exceeds the Morpho market LLTV.
  function initialize(Id marketId_, address positionManager_, uint128 safeLtv_, uint128 liquidationLtv_)
    public
    initializer
  {
    if (Id.unwrap(marketId_) == bytes32(0)) revert LibBorrowErrors.InvalidMarketId(marketId_);
    if (MORPHO.market(marketId_).lastUpdate == 0) revert LibBorrowErrors.MarketNotCreated();
    LibChecks.checkValidLtv(liquidationLtv_);
    if (safeLtv_ == 0) revert LibCommonErrors.InvalidLtv();

    // Validate safeLtv < liquidationLtv
    if (safeLtv_ >= liquidationLtv_) {
      revert LibBorrowErrors.SafeLtvNotLessThanLiquidationLtv(safeLtv_, liquidationLtv_);
    }

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    _storage.marketId = marketId_;
    _storage.marketParams = MORPHO.idToMarketParams(marketId_);

    // Validate liquidationLtv does not exceed market LLTV
    // This ensures pre-liquidation triggers before Morpho's native liquidation
    if (liquidationLtv_ > _storage.marketParams.lltv) {
      revert LibBorrowErrors.LiquidationLtvExceedsMarketLltv(liquidationLtv_, _storage.marketParams.lltv);
    }

    _storage.safeLtv = safeLtv_;
    _storage.liquidationLtv = liquidationLtv_;

    _initializeOwner(positionManager_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OPERATIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers collateral from the caller to this contract, approves Morpho, and supplies it.
  ///      Uses SafeTransferLib for secure token transfers.
  ///      Increases the position's collateral, which increases borrowing capacity.
  ///      Reverts with {CommonErrors.AmountZero} if amount is 0.
  function supplyCollateral(uint256 amount) external override onlyOwner {
    amount.checkNotZero();

    MarketParams memory _marketParams = _borrowPositionStorage().marketParams;

    // Transfer collateral from caller to this contract
    _marketParams.collateralToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend collateral
    _marketParams.collateralToken.safeApproveWithRetry(address(MORPHO), amount);

    // Supply collateral to Morpho on behalf of this contract
    MORPHO.supplyCollateral(_marketParams, amount, address(this), "");
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Withdraws collateral directly from Morpho to the owner (msg.sender).
  ///      If there is an active borrow, the remaining collateral must maintain adequate collateralization.
  ///      Reverts with {CommonErrors.AmountZero} if amount is 0.
  ///      Reverts with {LibBorrowErrors.InsufficientCollateral} if withdrawal would exceed safe LTV.
  function withdrawCollateral(uint256 amount) external override onlyOwner {
    amount.checkNotZero();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    MarketParams memory _marketParams = _storage.marketParams;

    // Accrue interest before reading market data for the health check.
    // This ensures the debt calculation uses up-to-date totalBorrowAssets.
    MORPHO.accrueInterest(_marketParams);

    // Withdraw collateral from Morpho to the owner (Position Manager)
    // This will revert if the position would become unhealthy
    MORPHO.withdrawCollateral(_marketParams, amount, address(this), msg.sender);

    if (!_isHealthy(_storage.safeLtv, _marketParams.oracle)) {
      revert LibBorrowErrors.InsufficientCollateral();
    }
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Borrows assets from Morpho and sends them directly to the owner (msg.sender).
  ///      Requires sufficient collateral to maintain a healthy position based on the safe LTV.
  ///      Morpho enforces health checks and liquidity constraints.
  ///      Reverts with {CommonErrors.AmountZero} if amount is 0.
  ///      Reverts with {LibBorrowErrors.InsufficientCollateral} if borrowing would exceed safe LTV.
  function borrow(uint256 amount) external override onlyOwner {
    amount.checkNotZero();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    MarketParams memory _marketParams = _storage.marketParams;

    // Accrue interest before reading market data for the health check.
    // This ensures the debt calculation uses up-to-date totalBorrowAssets.
    MORPHO.accrueInterest(_marketParams);

    // Borrow from Morpho, sending borrowed assets to the owner (Position Manager)
    // This will revert if the position would become unhealthy or insufficient liquidity
    MORPHO.borrow(_marketParams, amount, 0, address(this), msg.sender);

    if (!_isHealthy(_storage.safeLtv, _marketParams.oracle)) {
      revert LibBorrowErrors.InsufficientCollateral();
    }
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Transfers loan tokens from the caller, approves Morpho, and repays the debt.
  ///      Reduces the borrowed amount, improving the position's health factor.
  ///      Can repay partial or full debt. Uses SafeTransferLib for secure token transfers.
  ///      Reverts with {CommonErrors.AmountZero} if amount is 0.
  function repay(uint256 amount) external override onlyOwner {
    amount.checkNotZero();

    MarketParams memory _marketParams = _borrowPositionStorage().marketParams;

    // Transfer loan tokens from caller to this contract
    _marketParams.loanToken.safeTransferFrom(msg.sender, address(this), amount);

    // Approve Morpho to spend loan tokens
    _marketParams.loanToken.safeApproveWithRetry(address(MORPHO), amount);

    // Repay debt to Morpho
    MORPHO.repay(_marketParams, amount, 0, address(this), "");
  }

  /// @notice Pre-liquidates the position when it becomes unhealthy based on the custom liquidation LTV.
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
  ///      bonus scales with how underwater the position is. At the liquidation LTV threshold, the bonus approaches 1 - liquidation LTV.
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
  /// @dev Reverts with {LibBorrowErrors.InvalidBorrower} if borrower is not address(this).
  ///      Reverts with {LibBorrowErrors.InconsistentInput} if both seizedAssets and repaidShares are non-zero or both are zero.
  ///      Reverts with {LibBorrowErrors.PositionHealthy} if the position is healthy based on the custom liquidation LTV.
  function preLiquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data)
    external
    returns (uint256, uint256)
  {
    if (borrower != address(this)) revert LibBorrowErrors.InvalidBorrower();
    if (!UtilsLib.exactlyOneZero(seizedAssets, repaidShares)) revert LibBorrowErrors.InconsistentInput();

    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Accrue interest BEFORE the health check so the debt calculation is up-to-date.
    // Without this, the _isHealthy check uses stale totalBorrowAssets, which could
    // understate debt and incorrectly report a healthy position.
    MORPHO.accrueInterest(_storage.marketParams);

    if (_isHealthy(_storage.liquidationLtv, _storage.marketParams.oracle)) revert LibBorrowErrors.PositionHealthy();

    {
      Position memory position = MORPHO.position(_storage.marketId, borrower);
      if (seizedAssets > 0) {
        repaidShares = seizedAssets.mulDivUp(position.borrowShares, position.collateral);
      } else {
        seizedAssets = repaidShares.mulDiv(position.collateral, position.borrowShares);
      }
    }

    uint256 repaidAssets;
    {
      bytes memory callbackData = abi.encode(seizedAssets, borrower, msg.sender, data);
      (repaidAssets,) = MORPHO.repay(_storage.marketParams, 0, repaidShares, borrower, callbackData);
    }

    return (seizedAssets, repaidAssets);
  }

  /// @notice Morpho callback invoked after a repay operation.
  /// @dev This callback is called by Morpho during the pre-liquidation flow:
  ///      1. preLiquidate() calls MORPHO.repay() with callback data
  ///      2. Morpho repays the debt and calls this callback
  ///      3. This callback withdraws collateral to the liquidator
  ///      4. Optionally calls the liquidator's onPreLiquidate callback
  ///      5. Pulls loan tokens from the liquidator to complete the repayment
  ///      Reverts with {LibBorrowErrors.NotMorpho} if called by any address other than the Morpho contract.
  /// @param repaidAssets The amount of loan tokens that were repaid.
  /// @param callbackData Encoded data containing (seizedAssets, borrower, liquidator, data).
  function onMorphoRepay(uint256 repaidAssets, bytes calldata callbackData) external {
    if (msg.sender != address(MORPHO)) revert LibBorrowErrors.NotMorpho();

    (uint256 seizedAssets, address borrower, address liquidator, bytes memory data) =
      abi.decode(callbackData, (uint256, address, address, bytes));

    MarketParams memory marketParams = _borrowPositionStorage().marketParams;

    MORPHO.withdrawCollateral(marketParams, seizedAssets, borrower, liquidator);

    if (data.length > 0) {
      IPreLiquidationCallback(liquidator).onPreLiquidate(repaidAssets, data);
    }

    marketParams.loanToken.safeTransferFrom(liquidator, address(this), repaidAssets);
    marketParams.loanToken.safeApproveWithRetry(address(MORPHO), repaidAssets);
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
  /// @dev Converts borrow shares to asset amount using SharesMathLib with expected (interest-accrued)
  ///      market totals from MorphoBalancesLib.
  ///      Uses `toAssetsUp` to round up, which is conservative when calculating debt.
  ///      Accounts for accrued interest since the borrow shares represent a proportion
  ///      of the total market debt that grows over time.
  function totalBorrowed() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    Id _marketId = _storage.marketId;

    Position memory _pos = MORPHO.position(_marketId, address(this));

    // Use expected (interest-accrued) market totals to avoid understating debt
    (,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _marketId);

    // Convert borrow shares to assets using expected market totals
    return uint256(_pos.borrowShares).toAssetsUp(_totalBorrowAssets, _totalBorrowShares);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the raw collateral amount stored in the Morpho position.
  function totalCollateral() external view override returns (uint256) {
    return uint256(MORPHO.position(_borrowPositionStorage().marketId, address(this)).collateral);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Takes the raw collateral amount stored in the Morpho position and quotes it
  ///      in borrowed asset units.
  function totalCollateralQuoted() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    return uint256(MORPHO.position(_storage.marketId, address(this)).collateral)
      .mulDiv(IOracle(_storage.marketParams.oracle).price(), ORACLE_PRICE_SCALE);
  }

  /// @inheritdoc IBorrowPosition
  function isHealthy(uint256 _ltv) external view override returns (bool) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    return _isHealthy(_ltv, _storage.marketParams.oracle);
  }

  /// @inheritdoc IBorrowPosition
  function maxBorrow(uint256 _ltv) external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Use expected (interest-accrued) market balances to avoid understating debt
    (uint256 _totalSupplyAssets,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);

    Position memory _pos = MORPHO.position(_storage.marketId, address(this));

    uint256 borrowed = uint256(_pos.borrowShares).toAssetsUp(_totalBorrowAssets, _totalBorrowShares);

    // Calculate remaining borrow capacity: (collateralValue * LTV) - alreadyBorrowed
    // Uses zeroFloorSub to return 0 instead of underflowing if already over-utilized
    // Return remaining capacity or available liquidity, whichever is lower
    return uint256(_pos.collateral).mulDiv(IOracle(_storage.marketParams.oracle).price(), ORACLE_PRICE_SCALE)
      .mulWad(_ltv).zeroFloorSub(borrowed).min(_totalSupplyAssets - _totalBorrowAssets);
  }

  /// @inheritdoc IBorrowPosition
  function availableLiquidity() external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();

    // Use expected (interest-accrued) market balances.
    // Interest accrual increases both supply and borrow by the same amount,
    // so liquidity stays unchanged. However, fee shares redirect a portion of supply,
    // which can subtly affect the calculation. Using expected values is correct.
    (uint256 _totalSupplyAssets,, uint256 _totalBorrowAssets,) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _storage.marketId);
    return _totalSupplyAssets - _totalBorrowAssets;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Calculates available collateral as: totalCollateral - (debt * ORACLE_PRICE_SCALE) / (ltv * price)
  ///      If no debt, returns all collateral. Returns 0 if position would be unhealthy.
  function availableCollateral(uint256 _ltv) external view override returns (uint256) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    Id _marketId = _storage.marketId;

    Position memory _pos = MORPHO.position(_marketId, address(this));

    // If no debt, all collateral is available
    if (_pos.borrowShares == 0) return uint256(_pos.collateral);

    // Use expected (interest-accrued) market totals to avoid understating debt
    (,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _marketId);
    uint256 _collateralPrice = IOracle(_storage.marketParams.oracle).price();

    // Calculate borrowed amount (rounds up to be conservative)
    uint256 _borrowed = uint256(_pos.borrowShares).toAssetsUp(_totalBorrowAssets, _totalBorrowShares);

    // Required collateral = borrowed * ORACLE_PRICE_SCALE / (ltv * price)
    // This rounds up to be conservative (more collateral required = less available)
    uint256 _requiredCollateral = _borrowed.mulDivUp(ORACLE_PRICE_SCALE, _ltv.mulWad(_collateralPrice));

    // Return available collateral (0 if required > total)
    if (_requiredCollateral >= uint256(_pos.collateral)) return 0;
    return uint256(_pos.collateral) - _requiredCollateral;
  }

  /// @dev Internal helper to determine if the position is healthy based on provided ltv and oracle.
  ///      Health calculation:
  ///      1. If no borrow exists (borrowShares == 0), position is always healthy.
  ///      2. Otherwise, calculates: maxBorrow = (collateral * oraclePrice / ORACLE_PRICE_SCALE) * ltv
  ///      3. Position is healthy if maxBorrow >= borrowed amount (with interest).
  ///      Uses conservative rounding: borrowed amount rounds up, max borrow rounds down.
  ///      Uses expected (interest-accrued) market totals from MorphoBalancesLib.
  /// @param _ltv The LTV to use for the health calculation.
  /// @param oracle The oracle address to fetch the collateral price.
  /// @return True if the position is healthy, false otherwise.
  function _isHealthy(uint256 _ltv, address oracle) internal view returns (bool) {
    BorrowPositionStorage storage _storage = _borrowPositionStorage();
    Id _marketId = _storage.marketId;
    Position memory _pos = MORPHO.position(_marketId, address(this));

    // If no borrow, position is always healthy
    if (_pos.borrowShares == 0) return true;

    // Use expected (interest-accrued) market totals to avoid understating debt
    (,, uint256 _totalBorrowAssets, uint256 _totalBorrowShares) =
      MORPHO.expectedMarketBalances(_storage.marketParams, _marketId);

    // Get collateral price from oracle
    uint256 _collateralPrice = IOracle(oracle).price();

    // Calculate borrowed amount (rounds up to be conservative)
    uint256 _borrowed = uint256(_pos.borrowShares).toAssetsUp(_totalBorrowAssets, _totalBorrowShares);

    // Calculate max borrow based on collateral value and provided LTV
    return uint256(_pos.collateral).mulDiv(_collateralPrice, ORACLE_PRICE_SCALE).mulWad(_ltv) >= _borrowed;
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

  /// @inheritdoc IBorrowPosition
  /// @dev The safe LTV is immutable after initialization and determines the threshold
  ///      that must not be reached upon position mutations (borrow, withdrawCollateral).
  function safeLtv() external view override returns (uint128) {
    return _borrowPositionStorage().safeLtv;
  }

  /// @notice Returns the liquidation LTV set for this borrow position.
  /// @dev Immutable after initialization. Determines when the position can be liquidated via preLiquidate.
  /// @return The liquidation LTV in WAD format (1e18 = 100%).
  function liquidationLtv() external view returns (uint128) {
    return _borrowPositionStorage().liquidationLtv;
  }
}
