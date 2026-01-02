// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "../interfaces/borrow/IBorrowPosition.sol";
import {
  IPositionManager,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType,
  SupplyQueueEntry
} from "../interfaces/manager/IPositionManager.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PositionManager
/// @notice Aggregates multiple borrow positions into a single vault with share-based accounting.
/// @dev Uses supply/withdrawal queues for deposit/withdraw operations, implements fee accrual,
///      and uses virtual share offset for inflation attack protection.
contract PositionManager is IPositionManager, OwnableRoles, ERC20, Initializable {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 internal constant _ROLE_MINTER = _ROLE_0;

  /// @dev Virtual offset for share calculation to prevent inflation attacks.
  ///      Using 1e6 as offset (similar to MetaMorpho's approach with decimalsOffset).
  uint256 internal constant VIRTUAL_SHARES = 1e6;

  /// @dev Virtual assets offset for share calculation.
  uint256 internal constant VIRTUAL_ASSETS = 1;

  /// @dev WAD precision (1e18 = 100%).
  uint256 internal constant WAD = 1e18;

  /// @dev Basis points precision (10000 = 100%).
  uint256 internal constant BPS = 10_000;

  /// @dev Seconds in a year for management fee calculation.
  uint256 internal constant SECONDS_PER_YEAR = 365 days;

  /// @dev Maximum management fee: 50% per year (5000 basis points).
  uint256 internal constant MAX_MANAGEMENT_FEE = 5000;

  /// @dev Maximum performance fee: 50% (5000 basis points).
  uint256 internal constant MAX_PERFORMANCE_FEE = 5000;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Fee configuration data.
  struct FeeData {
    address feeRecipient;
    uint24 managementFee; // In basis points per year (e.g., 200 = 2%)
    uint24 performanceFee; // In basis points (e.g., 2000 = 20%)
  }

  /// @notice Storage struct containing all persistent state for the PositionManager contract.
  struct PositionManagerStorage {
    FeeData feeData;
    SupplyQueueEntry[] supplyQueue;
    address[] withdrawalQueue;
    string name;
    string symbol;
    uint8 decimals;
    address collateralAsset;
    address debtAsset;
    uint256 lltv; // LLTV for free collateral calculation (WAD precision)
    uint256 lastTotalAssets; // Snapshot for performance fee calculation
    uint256 lastFeeAccrualTimestamp; // Timestamp of last fee accrual
  }

  /// @dev Storage slot for the PositionManager contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("positionmanager.main")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _POSITION_MANAGER_STORAGE_SLOT =
    0x5214b8a11a99e3fe330cebe436fd1668609fe97b04b87c673ddbf614b1920c00;

  /// @dev Returns a reference to the contract's storage struct.
  function _positionManagerStorage() internal pure returns (PositionManagerStorage storage positionManagerStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      positionManagerStorage.slot := _POSITION_MANAGER_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the PositionManager.
  /// @param owner_ The owner of the contract
  /// @param name_ The name of the share token
  /// @param symbol_ The symbol of the share token
  /// @param decimals_ The decimals of the share token
  /// @param collateralAsset_ The collateral asset address
  /// @param debtAsset_ The debt asset address
  /// @param lltv_ The LLTV for free collateral calculation (WAD precision)
  function initialize(
    address owner_,
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    address collateralAsset_,
    address debtAsset_,
    uint256 lltv_
  ) external initializer {
    _initializeOwner(owner_);
    PositionManagerStorage storage ps = _positionManagerStorage();
    ps.name = name_;
    ps.symbol = symbol_;
    ps.decimals = decimals_;
    ps.collateralAsset = collateralAsset_;
    ps.debtAsset = debtAsset_;
    ps.lltv = lltv_;
    ps.lastFeeAccrualTimestamp = block.timestamp;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEW                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function name() public view override returns (string memory) {
    return _positionManagerStorage().name;
  }

  function symbol() public view override returns (string memory) {
    return _positionManagerStorage().symbol;
  }

  function decimals() public view override returns (uint8) {
    return _positionManagerStorage().decimals;
  }

  /// @inheritdoc IPositionManager
  function supplyQueue() public view returns (SupplyQueueEntry[] memory) {
    return _positionManagerStorage().supplyQueue;
  }

  /// @inheritdoc IPositionManager
  function withdrawalQueue() public view returns (address[] memory) {
    return _positionManagerStorage().withdrawalQueue;
  }

  /// @inheritdoc IPositionManager
  function lltv() public view returns (uint256) {
    return _positionManagerStorage().lltv;
  }

  /// @inheritdoc IPositionManager
  function collateralAmount() public view returns (uint256 amount) {
    SupplyQueueEntry[] memory queue = _positionManagerStorage().supplyQueue;
    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength;) {
      amount += IBorrowPosition(queue[i].position).totalCollateral();
      unchecked {
        ++i;
      }
    }
  }

  /// @inheritdoc IPositionManager
  function collateralAmountQuoted() public view returns (uint256 amount) {
    SupplyQueueEntry[] memory queue = _positionManagerStorage().supplyQueue;
    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength;) {
      amount += IBorrowPosition(queue[i].position).totalCollateralQuoted();
      unchecked {
        ++i;
      }
    }
  }

  /// @inheritdoc IPositionManager
  function debtAmount() public view returns (uint256 amount) {
    SupplyQueueEntry[] memory queue = _positionManagerStorage().supplyQueue;
    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength;) {
      amount += IBorrowPosition(queue[i].position).totalBorrowed();
      unchecked {
        ++i;
      }
    }
  }

  /// @inheritdoc IPositionManager
  function totalAssets() public view returns (uint256) {
    return collateralAmountQuoted().zeroFloorSub(debtAmount());
  }

  /// @inheritdoc IPositionManager
  function feeData() public view returns (address feeRecipient, uint24 managementFee, uint24 performanceFee) {
    FeeData memory fd = _positionManagerStorage().feeData;
    return (fd.feeRecipient, fd.managementFee, fd.performanceFee);
  }

  /// @inheritdoc IPositionManager
  function collateralAsset() public view returns (address) {
    return _positionManagerStorage().collateralAsset;
  }

  /// @inheritdoc IPositionManager
  function debtAsset() public view returns (address) {
    return _positionManagerStorage().debtAsset;
  }

  /// @inheritdoc IPositionManager
  function lastTotalAssets() public view returns (uint256) {
    return _positionManagerStorage().lastTotalAssets;
  }

  /// @inheritdoc IPositionManager
  function lastFeeAccrualTimestamp() public view returns (uint256) {
    return _positionManagerStorage().lastFeeAccrualTimestamp;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FEE ACCRUAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Accrues fees (management + performance) and mints shares to the fee recipient.
  ///      Returns the current total assets after fee accrual for use in share calculations.
  /// @return currentTotalAssets The total assets after fee accrual
  function _accrueFees() internal returns (uint256 currentTotalAssets) {
    PositionManagerStorage storage ps = _positionManagerStorage();
    FeeData memory fd = ps.feeData;

    currentTotalAssets = totalAssets();

    if (fd.feeRecipient == address(0)) {
      ps.lastTotalAssets = currentTotalAssets;
      ps.lastFeeAccrualTimestamp = block.timestamp;
      return currentTotalAssets;
    }

    uint256 feeShares = 0;
    uint256 _totalSupply = totalSupply();

    // Management fee: based on time elapsed and total assets
    if (fd.managementFee > 0 && _totalSupply > 0) {
      uint256 elapsed = block.timestamp - ps.lastFeeAccrualTimestamp;
      // Fee = totalAssets * managementFee * elapsed / (BPS * SECONDS_PER_YEAR)
      uint256 managementFeeAssets = currentTotalAssets.mulDiv(fd.managementFee * elapsed, BPS * SECONDS_PER_YEAR);
      if (managementFeeAssets > 0) {
        // Convert assets to shares
        feeShares += _convertToShares(managementFeeAssets, _totalSupply, currentTotalAssets);
      }
    }

    // Performance fee: based on gains since last snapshot
    if (fd.performanceFee > 0 && currentTotalAssets > ps.lastTotalAssets && _totalSupply > 0) {
      uint256 gains = currentTotalAssets - ps.lastTotalAssets;
      uint256 performanceFeeAssets = gains.mulDiv(fd.performanceFee, BPS);
      if (performanceFeeAssets > 0) {
        feeShares += _convertToShares(performanceFeeAssets, _totalSupply, currentTotalAssets);
      }
    }

    // Mint fee shares
    if (feeShares > 0) {
      _mint(fd.feeRecipient, feeShares);
      emit FeesAccrued(fd.feeRecipient, feeShares);
    }

    ps.lastFeeAccrualTimestamp = block.timestamp;

    return currentTotalAssets;
  }

  /// @dev Updates the lastTotalAssets snapshot after an operation.
  function _updateSnapshot() internal {
    _positionManagerStorage().lastTotalAssets = totalAssets();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    SHARE CALCULATIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Converts assets to shares using virtual offset for inflation attack protection.
  /// @param assets The amount of assets to convert
  /// @param _totalSupply The current total supply of shares
  /// @param _totalAssets The current total assets
  /// @return shares The equivalent amount of shares
  function _convertToShares(uint256 assets, uint256 _totalSupply, uint256 _totalAssets)
    internal
    pure
    returns (uint256 shares)
  {
    return assets.mulDiv(_totalSupply + VIRTUAL_SHARES, _totalAssets + VIRTUAL_ASSETS);
  }

  /// @dev Converts shares to assets using virtual offset for inflation attack protection.
  /// @param shares The amount of shares to convert
  /// @param _totalSupply The current total supply of shares
  /// @param _totalAssets The current total assets
  /// @return assets The equivalent amount of assets
  function _convertToAssets(uint256 shares, uint256 _totalSupply, uint256 _totalAssets)
    internal
    pure
    returns (uint256 assets)
  {
    return shares.mulDiv(_totalAssets + VIRTUAL_ASSETS, _totalSupply + VIRTUAL_SHARES);
  }

  /// @dev Settles share changes based on total assets delta.
  ///      Mints shares if assets increased, burns shares if assets decreased.
  /// @param totalAssetsBefore The total assets before the operation
  /// @param _totalSupply The total supply before the operation
  /// @return sharesDelta Positive if shares minted, negative if shares burned
  function _settleShares(uint256 totalAssetsBefore, uint256 _totalSupply) internal returns (int256 sharesDelta) {
    uint256 totalAssetsAfter = totalAssets();

    if (totalAssetsAfter > totalAssetsBefore) {
      // Assets increased: mint shares to caller
      uint256 assetsAdded = totalAssetsAfter - totalAssetsBefore;
      uint256 sharesToMint = _convertToShares(assetsAdded, _totalSupply, totalAssetsBefore);
      if (sharesToMint == 0) revert ZeroShares();
      _mint(msg.sender, sharesToMint);
      sharesDelta = int256(sharesToMint);
    } else if (totalAssetsAfter < totalAssetsBefore) {
      // Assets decreased: burn shares from caller
      uint256 assetsRemoved = totalAssetsBefore - totalAssetsAfter;
      uint256 sharesToBurn = _convertToShares(assetsRemoved, _totalSupply, totalAssetsBefore);
      if (sharesToBurn == 0) revert ZeroShares();
      _burn(msg.sender, sharesToBurn);
      sharesDelta = -int256(sharesToBurn);
    }
    // If equal, sharesDelta remains 0

    // Update snapshot for performance fees
    _updateSnapshot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManager
  function deposit(uint256 collateral, uint256 debt) external onlyRoles(_ROLE_MINTER) returns (int256 shares) {
    if (collateral == 0 && debt == 0) revert ZeroAmount();

    PositionManagerStorage storage ps = _positionManagerStorage();

    // Accrue fees and get current total assets
    uint256 totalAssetsBefore = _accrueFees();
    uint256 _totalSupply = totalSupply();

    // Pull collateral from caller
    if (collateral > 0) {
      ps.collateralAsset.safeTransferFrom(msg.sender, address(this), collateral);
    }

    // Process deposits through supply queue
    if (debt == 0) {
      // No debt: deposit all collateral to first position
      if (ps.supplyQueue.length > 0 && collateral > 0) {
        _supply(ps.supplyQueue[0].position, ps.collateralAsset, collateral);
      }
    } else {
      // With debt: iterate through queue
      _processDeposit(collateral, debt, ps);
    }

    // Send borrowed debt to caller
    if (debt > 0) {
      ps.debtAsset.safeTransfer(msg.sender, debt);
    }

    // Settle shares based on assets delta
    shares = _settleShares(totalAssetsBefore, _totalSupply);

    emit Deposit(msg.sender, collateral, debt, shares);
  }

  /// @dev Processes deposit through the supply queue.
  function _processDeposit(uint256 collateral, uint256 debt, PositionManagerStorage storage ps) internal {
    uint256 remainingCollateral = collateral;
    uint256 remainingDebt = debt;
    uint256 queueLength = ps.supplyQueue.length;

    for (uint256 i = 0; i < queueLength && remainingDebt > 0;) {
      SupplyQueueEntry memory entry = ps.supplyQueue[i];
      address position = entry.position;

      // Calculate how much we can borrow from this position
      uint256 availableLiquidity = IBorrowPosition(position).availableLiquidity();
      uint256 toBorrow = availableLiquidity.min(uint256(entry.maxBorrow)).min(remainingDebt);

      if (toBorrow == 0) {
        unchecked {
          ++i;
        }
        continue;
      }

      // Calculate proportional collateral
      // If we're borrowing X% of remaining debt, we supply X% of remaining collateral
      uint256 collateralToSupply = remainingCollateral.mulDiv(toBorrow, remainingDebt);

      // Supply collateral first (if any)
      if (collateralToSupply > 0) {
        _supply(position, ps.collateralAsset, collateralToSupply);
        remainingCollateral -= collateralToSupply;
      }

      // Then borrow
      _borrow(position, toBorrow);
      remainingDebt -= toBorrow;

      unchecked {
        ++i;
      }
    }

    // If we couldn't borrow all the requested debt, revert
    if (remainingDebt > 0) revert InsufficientBorrowCapacity();
  }

  /// @inheritdoc IPositionManager
  function withdraw(uint256 collateral, uint256 debt) external onlyRoles(_ROLE_MINTER) returns (int256 shares) {
    if (collateral == 0 && debt == 0) revert ZeroAmount();

    PositionManagerStorage storage ps = _positionManagerStorage();

    // Accrue fees and get current total assets
    uint256 totalAssetsBefore = _accrueFees();
    uint256 _totalSupply = totalSupply();

    // Pull debt from caller for repayment
    if (debt > 0) {
      ps.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    }

    // Process withdrawals through withdrawal queue
    _processWithdrawal(collateral, debt, ps);

    // Send collateral to caller
    if (collateral > 0) {
      ps.collateralAsset.safeTransfer(msg.sender, collateral);
    }

    // Settle shares based on assets delta
    shares = _settleShares(totalAssetsBefore, _totalSupply);

    emit Withdraw(msg.sender, collateral, debt, shares);
  }

  /// @dev Processes withdrawal through the withdrawal queue.
  function _processWithdrawal(uint256 collateral, uint256 debt, PositionManagerStorage storage ps) internal {
    uint256 remainingDebt = debt;
    uint256 remainingCollateral = collateral;
    uint256 queueLength = ps.withdrawalQueue.length;

    // First pass: repay debt
    for (uint256 i = 0; i < queueLength && remainingDebt > 0;) {
      address position = ps.withdrawalQueue[i];
      uint256 positionDebt = IBorrowPosition(position).totalBorrowed();

      if (positionDebt == 0) {
        unchecked {
          ++i;
        }
        continue;
      }

      uint256 toRepay = positionDebt.min(remainingDebt);
      _repay(position, ps.debtAsset, toRepay);
      remainingDebt -= toRepay;

      unchecked {
        ++i;
      }
    }

    // Second pass: withdraw collateral
    for (uint256 i = 0; i < queueLength && remainingCollateral > 0;) {
      address position = ps.withdrawalQueue[i];

      // Get free collateral for this position
      uint256 freeCollat = IBorrowPosition(position).freeCollateral(ps.lltv);
      uint256 positionCollateral = IBorrowPosition(position).totalCollateral();

      // We can withdraw up to the free collateral
      uint256 toWithdraw = freeCollat.min(positionCollateral).min(remainingCollateral);

      if (toWithdraw == 0) {
        unchecked {
          ++i;
        }
        continue;
      }

      _withdraw(position, toWithdraw);
      remainingCollateral -= toWithdraw;

      unchecked {
        ++i;
      }
    }

    // If we couldn't withdraw all requested collateral, revert
    if (remainingCollateral > 0) revert InsufficientFreeCollateral();
  }

  /// @inheritdoc IPositionManager
  function burn(uint256 shares) external onlyRoles(_ROLE_MINTER) returns (uint256 collateral, uint256 debt) {
    if (shares == 0) revert ZeroAmount();

    PositionManagerStorage storage ps = _positionManagerStorage();

    // Accrue fees first
    _accrueFees();

    uint256 _totalSupply = totalSupply();
    uint256 _totalCollateral = collateralAmount();
    uint256 _totalDebt = debtAmount();

    // Calculate proportional amounts to maintain average LTV
    // Round down collateral (user gets less), round up debt (user repays more)
    collateral = _totalCollateral.mulDiv(shares, _totalSupply);
    debt = _totalDebt.mulDivUp(shares, _totalSupply);

    // Burn shares first
    _burn(msg.sender, shares);

    // Pull debt from caller for repayment
    if (debt > 0) {
      ps.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    }

    // Process burn through withdrawal queue - withdraws/repays proportionally on each position
    _processBurn(collateral, debt, _totalCollateral, _totalDebt, ps);

    // Send collateral to caller
    if (collateral > 0) {
      ps.collateralAsset.safeTransfer(msg.sender, collateral);
    }

    // Update snapshot for performance fees
    _updateSnapshot();

    emit Burn(msg.sender, shares, collateral, debt);
  }

  /// @dev Processes burn by repaying debt and withdrawing collateral proportionally from each position.
  ///      This maintains the average LTV across all positions.
  /// @param collateralToWithdraw Total collateral to withdraw
  /// @param debtToRepay Total debt to repay
  /// @param _totalCollateral Total collateral across all positions
  /// @param _totalDebt Total debt across all positions
  /// @param ps Storage pointer
  function _processBurn(
    uint256 collateralToWithdraw,
    uint256 debtToRepay,
    uint256 _totalCollateral,
    uint256 _totalDebt,
    PositionManagerStorage storage ps
  ) internal {
    uint256 remainingCollateral = collateralToWithdraw;
    uint256 remainingDebt = debtToRepay;
    uint256 queueLength = ps.withdrawalQueue.length;

    for (uint256 i = 0; i < queueLength;) {
      address position = ps.withdrawalQueue[i];
      uint256 positionDebt = IBorrowPosition(position).totalBorrowed();
      uint256 positionCollateral = IBorrowPosition(position).totalCollateral();

      // Repay proportionally
      if (remainingDebt > 0 && positionDebt > 0 && _totalDebt > 0) {
        uint256 toRepay = debtToRepay.mulDiv(positionDebt, _totalDebt);
        if (toRepay > remainingDebt) toRepay = remainingDebt;
        if (toRepay > 0) {
          _repay(position, ps.debtAsset, toRepay);
          remainingDebt -= toRepay;
        }
      }

      // Withdraw proportionally
      if (remainingCollateral > 0 && positionCollateral > 0 && _totalCollateral > 0) {
        uint256 toWithdraw = collateralToWithdraw.mulDiv(positionCollateral, _totalCollateral);
        if (toWithdraw > remainingCollateral) toWithdraw = remainingCollateral;
        if (toWithdraw > 0) {
          _withdraw(position, toWithdraw);
          remainingCollateral -= toWithdraw;
        }
      }

      unchecked {
        ++i;
      }
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _supply(address position, address token, uint256 amount) internal {
    token.safeApprove(position, amount);
    IBorrowPosition(position).supplyCollateral(amount);
    token.safeApprove(position, 0);
  }

  function _withdraw(address position, uint256 amount) internal {
    IBorrowPosition(position).withdrawCollateral(amount);
  }

  function _borrow(address position, uint256 amount) internal {
    IBorrowPosition(position).borrow(amount);
  }

  function _repay(address position, address token, uint256 amount) internal {
    token.safeApprove(position, amount);
    IBorrowPosition(position).repay(amount);
    token.safeApprove(position, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManager
  function setSupplyQueue(SupplyQueueEntry[] calldata queue) external onlyOwner {
    PositionManagerStorage storage ps = _positionManagerStorage();
    delete ps.supplyQueue;
    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength;) {
      ps.supplyQueue.push(queue[i]);
      unchecked {
        ++i;
      }
    }
    emit SupplyQueueSet(queue);
  }

  /// @inheritdoc IPositionManager
  function setWithdrawalQueue(address[] calldata queue) external onlyOwner {
    _positionManagerStorage().withdrawalQueue = queue;
    emit WithdrawalQueueSet(queue);
  }

  /// @inheritdoc IPositionManager
  function setLLTV(uint256 lltv_) external onlyOwner {
    _positionManagerStorage().lltv = lltv_;
    emit LLTVSet(lltv_);
  }

  /// @inheritdoc IPositionManager
  function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external onlyOwner {
    if (managementFee > MAX_MANAGEMENT_FEE || performanceFee > MAX_PERFORMANCE_FEE) {
      revert FeeExceedsMax();
    }

    // Accrue fees to current recipient first
    _accrueFees();

    FeeData memory fd;
    fd.feeRecipient = feeRecipient;
    fd.managementFee = managementFee;
    fd.performanceFee = performanceFee;
    _positionManagerStorage().feeData = fd;

    emit FeeDataSet(feeRecipient, managementFee, performanceFee);
  }

  /// @inheritdoc IPositionManager
  function rebalance(RebalancingData calldata data)
    external
    onlyOwner
    returns (uint256 collateralExcess, uint256 debtExcess)
  {
    // Accrue fees based on pre-rebalance state
    _accrueFees();

    PositionManagerStorage storage ps = _positionManagerStorage();
    address _collateralAsset = ps.collateralAsset;
    address _debtAsset = ps.debtAsset;

    if (data.collateral > 0) {
      _collateralAsset.safeTransferFrom(msg.sender, address(this), data.collateral);
    }
    if (data.debt > 0) {
      _debtAsset.safeTransferFrom(msg.sender, address(this), data.debt);
    }

    uint256 opsLength = data.operations.length;
    for (uint256 i = 0; i < opsLength;) {
      _dispatchRebalancingOperation(data.operations[i], _collateralAsset, _debtAsset);
      unchecked {
        ++i;
      }
    }

    collateralExcess = _collateralAsset.safeTransferAll(msg.sender);
    debtExcess = _debtAsset.safeTransferAll(msg.sender);

    // Update snapshot to post-rebalance state
    _updateSnapshot();
  }

  function _dispatchRebalancingOperation(
    RebalancingOperation calldata operation,
    address _collateralAsset,
    address _debtAsset
  ) internal {
    address position = operation.position;
    uint256 amount = operation.amount;
    RebalancingOperationType operationType = operation.operationType;

    if (operationType == RebalancingOperationType.REPAY) {
      _repay(position, _debtAsset, amount);
    } else if (operationType == RebalancingOperationType.WITHDRAW) {
      _withdraw(position, amount);
    } else if (operationType == RebalancingOperationType.BORROW) {
      _borrow(position, amount);
    } else if (operationType == RebalancingOperationType.SUPPLY) {
      _supply(position, _collateralAsset, amount);
    }
  }
}
