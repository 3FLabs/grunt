// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

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
/// @notice Implementation of a borrow position with the Morpho Blue protocol.
/// @dev This contract manages a single collateralized borrow position on Morpho Blue.
///      It acts as the position holder and delegates control to an owner (typically a Position Manager).
///      The contract uses ERC-7201 namespaced storage for proxy compatibility and follows
///      the Checks-Effects-Interactions pattern for security.
/// @author 3F Protocol
contract MorphoBorrowPosition is IBorrowPosition, Initializable, Ownable {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a required address parameter is the zero address.
  error AddressZero();

  /// @notice Thrown when the market ID is invalid (zero bytes32).
  /// @dev Market IDs in Morpho are derived from market parameters and must be non-zero.
  error InvalidMarketId();

  /// @notice Thrown when attempting to initialize with a market that doesn't exist in Morpho.
  /// @dev Markets must be created in Morpho before a borrow position can be initialized for them.
  error MarketNotCreated();

  /// @notice Thrown when an operation is called with a zero amount.
  /// @dev Zero amounts are not allowed for supply, withdraw, borrow, or repay operations.
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
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      Validates all inputs and fetches market parameters from Morpho.
  ///      The position manager becomes the owner and has exclusive control over the position.
  /// @param morpho_ The Morpho Blue protocol contract address.
  /// @param marketId_ The Morpho market ID for this borrow position. Must correspond to an existing market.
  /// @param positionManager_ The address of the position manager (owner) that will control this position.
  /// @custom:reverts AddressZero if morpho_ is the zero address.
  /// @custom:reverts InvalidMarketId if marketId_ is zero.
  /// @custom:reverts MarketNotCreated if the market doesn't exist in Morpho (lastUpdate == 0).
  /// @custom:reverts InvalidInitialization if called more than once.
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
  /// @dev Transfers collateral from the caller to this contract, approves Morpho, and supplies it.
  ///      Uses SafeTransferLib for secure token transfers.
  ///      Increases the position's collateral, which increases borrowing capacity.
  /// @custom:reverts AmountZero if amount is 0.
  /// @custom:reverts Unauthorized if caller is not the owner.
  /// @custom:reverts TransferFromFailed if the caller has insufficient balance or allowance.
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

    // Withdraw collateral from Morpho to the owner (Position Manager)
    // This will revert if the position would become unhealthy
    $.morpho.withdrawCollateral($.marketParams, amount, address(this), msg.sender);
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

    // Borrow from Morpho, sending borrowed assets to the owner (Position Manager)
    // This will revert if the position would become unhealthy or insufficient liquidity
    $.morpho.borrow($.marketParams, amount, 0, address(this), msg.sender);
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
  /// @dev Returns the loan token address from the cached market parameters.
  /// @return The address of the ERC20 token that is borrowed in this position.
  function borrowAsset() external view override returns (address) {
    return _borrowPositionStorage().marketParams.loanToken;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the collateral token address from the cached market parameters.
  /// @return The address of the ERC20 token used as collateral in this position.
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
  /// @return The total amount of loan tokens borrowed, including accrued interest.
  function totalBorrowed() external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();

    Position memory _pos = $.morpho.position($.marketId, address(this));
    Market memory _mkt = $.morpho.market($.marketId);

    // Convert borrow shares to assets using market totals
    return uint256(_pos.borrowShares).toAssetsUp(_mkt.totalBorrowAssets, _mkt.totalBorrowShares);
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Returns the raw collateral amount stored in the Morpho position.
  ///      This is denominated in the collateral token's native units.
  /// @return The total amount of collateral tokens supplied to this position.
  function totalCollateral() external view override returns (uint256) {
    BorrowPositionStorage storage $ = _borrowPositionStorage();
    return $.morpho.position($.marketId, address(this)).collateral;
  }

  /// @inheritdoc IBorrowPosition
  /// @dev Determines position health by comparing borrowed amount against max borrow capacity.
  ///      Health calculation:
  ///      1. If no borrow exists (borrowShares == 0), position is always healthy.
  ///      2. Otherwise, calculates: maxBorrow = (collateral * oraclePrice / ORACLE_PRICE_SCALE) * LLTV
  ///      3. Position is healthy if maxBorrow >= borrowed amount (with interest).
  ///      Uses conservative rounding: borrowed amount rounds up, max borrow rounds down.
  /// @return True if the position is healthy (not liquidatable), false otherwise.
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
  /// @dev Calculates the maximum borrowable amount based on current collateral and market parameters.
  ///      Formula: maxBorrow = (collateral * oraclePrice / ORACLE_PRICE_SCALE) * LLTV
  ///      Where LLTV (Loan-to-Liquidation-Threshold Value) is the market's maximum allowed
  ///      loan-to-collateral ratio. Uses conservative rounding (down) to prevent borrowing
  ///      more than allowed. Does not account for existing borrows; returns absolute max capacity.
  /// @return The maximum amount of loan tokens that can be borrowed given current collateral.
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
  /// @dev The market ID is set during initialization and uniquely identifies the Morpho market
  ///      (loan token, collateral token, oracle, LLTV, and IRM combination).
  /// @return The Morpho market ID (bytes32 encoded).
  function marketId() external view returns (Id) {
    return _borrowPositionStorage().marketId;
  }
}
