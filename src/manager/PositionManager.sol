// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "../interfaces/borrow/IBorrowPosition.sol";
import {
  IPositionManager,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "../interfaces/manager/IPositionManager.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

// the position manager contract transforms multiple

contract PositionManager is IPositionManager, OwnableRoles, ERC20, Initializable {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;

  uint256 internal constant _ROLE_MINTER = _ROLE_0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  struct FeeData {
    address feeRecipient;
    uint24 managementFees;
    uint24 performanceFees;
  }

  /// @notice Storage struct containing all persistent state for the PositionManager contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param positions Map of position address to max borrow amount
  struct PositionManagerStorage {
    FeeData feeData;
    EnumerableMapLib.AddressToUint256Map positions;
    string name;
    string symbol;
    uint8 decimals;
    address collateralAsset;
    address debtAsset;
  }

  /// @dev Storage slot for the PositionManager contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("positionmanager.main")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _POSITION_MANAGER_STORAGE_SLOT =
    0x5214b8a11a99e3fe330cebe436fd1668609fe97b04b87c673ddbf614b1920c00;

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return positionManagerStorage A storage pointer to the PositionManagerStorage struct
  function _positionManagerStorage() internal pure returns (PositionManagerStorage storage positionManagerStorage) {
    /// @solidity memory-safe-assembly
    assembly {
      positionManagerStorage.slot := _POSITION_MANAGER_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function initialize(
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    address collateralAsset_,
    address debtAsset_
  ) external initializer {
    PositionManagerStorage storage ps = _positionManagerStorage();
    ps.name = name_;
    ps.symbol = symbol_;
    ps.decimals = decimals_;
    ps.collateralAsset = collateralAsset_;
    ps.debtAsset = debtAsset_;
    // TODO: add fee data and emit fee data event
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEW                             */
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

  function borrowPositions() public view override returns (address[] memory) {
    return _positionManagerStorage().positions.keys();
  }

  function collateralAmount() public view override returns (uint256 amount) {
    EnumerableMapLib.AddressToUint256Map storage positions = _positionManagerStorage().positions;
    for (uint256 i = 0; i < positions.length(); i++) {
      (address position,) = positions.at(i);
      amount += IBorrowPosition(position).totalCollateralQuoted();
    }
  }

  function debtAmount() public view override returns (uint256 amount) {
    EnumerableMapLib.AddressToUint256Map storage positions = _positionManagerStorage().positions;
    for (uint256 i = 0; i < positions.length(); i++) {
      (address position,) = positions.at(i);
      amount += IBorrowPosition(position).totalBorrowed();
    }
  }

  function feeData()
    public
    view
    override
    returns (address feeRecipient, uint24 managementFees, uint24 performanceFees)
  {
    FeeData memory fd = _positionManagerStorage().feeData;
    return (fd.feeRecipient, fd.managementFees, fd.performanceFees);
  }

  function pendingFeeShares() public view override returns (uint256 amount) {
    return 0; // TODO: Implement pending fee shares
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function deposit(uint256 collateral, uint256 debt)
    public
    override
    onlyRoles(_ROLE_MINTER)
    returns (int256 sharesDelta)
  {
    PositionManagerStorage storage ps = _positionManagerStorage();
    uint256 totalAssetsBefore = _totalAssets();

    if (collateral > 0) ps.collateralAsset.safeTransferFrom(msg.sender, address(this), collateral);
    if (ps.positions.length() == 0) return 0;

    uint256[] memory borrowCapacities = _calculateBorrowCapacities(ps);
    _processDeposits(collateral, debt, borrowCapacities, ps);

    return _calculateSharesDelta(totalAssetsBefore);
  }

  function _calculateBorrowCapacities(PositionManagerStorage storage ps)
    internal
    view
    returns (uint256[] memory capacities)
  {
    uint256 len = ps.positions.length();
    capacities = new uint256[](len);

    for (uint256 i = 0; i < len; i++) {
      (address position, uint256 maxBorrow) = ps.positions.at(i);
      uint256 available = IBorrowPosition(position).availableLiquidity();
      capacities[i] = available.min(maxBorrow);
    }
  }

  function _processDeposits(
    uint256 collateral,
    uint256 debt,
    uint256[] memory borrowCapacities,
    PositionManagerStorage storage ps
  ) internal {
    uint256 totalBorrowCap = 0;
    for (uint256 i = 0; i < borrowCapacities.length; i++) {
      totalBorrowCap += borrowCapacities[i];
    }

    uint256 collPerPos = collateral / ps.positions.length();
    uint256 collRemainder = collateral % ps.positions.length();

    for (uint256 i = 0; i < ps.positions.length(); i++) {
      (address position,) = ps.positions.at(i);

      uint256 collAmt = collPerPos;
      if (i == ps.positions.length() - 1) collAmt += collRemainder;

      if (collAmt > 0) _supply(position, ps.collateralAsset, collAmt);

      if (debt > 0 && totalBorrowCap > 0) {
        uint256 borrowAmt = debt.mulDiv(borrowCapacities[i], totalBorrowCap);
        if (borrowAmt > 0) _borrow(position, borrowAmt);
      }
    }
  }

  function withdraw(uint256 collateral, uint256 debt)
    public
    override
    onlyRoles(_ROLE_MINTER)
    returns (int256 sharesDelta)
  {
    PositionManagerStorage storage ps = _positionManagerStorage();
    uint256 totalAssetsBefore = _totalAssets();

    if (debt > 0) ps.debtAsset.safeTransferFrom(msg.sender, address(this), debt);
    if (ps.positions.length() == 0) return 0;

    _processWithdrawals(collateral, debt, ps);

    sharesDelta = _calculateSharesDelta(totalAssetsBefore);

    ps.collateralAsset.safeTransferAll(msg.sender);
    ps.debtAsset.safeTransferAll(msg.sender);
  }

  function _processWithdrawals(uint256 collateral, uint256 debt, PositionManagerStorage storage ps) internal {
    uint256 totalDebt = debtAmount();
    uint256 totalRawColl = _getTotalRawCollateral(ps);

    for (uint256 i = 0; i < ps.positions.length(); i++) {
      (address position,) = ps.positions.at(i);
      IBorrowPosition bp = IBorrowPosition(position);

      if (debt > 0 && totalDebt > 0) {
        uint256 repayAmt = debt.mulDiv(bp.totalBorrowed(), totalDebt);
        if (repayAmt > 0) _repay(position, ps.debtAsset, repayAmt);
      }

      if (collateral > 0 && totalRawColl > 0) {
        uint256 withdrawAmt = collateral.mulDiv(bp.totalCollateral(), totalRawColl);
        if (withdrawAmt > 0) _withdraw(position, withdrawAmt);
      }
    }
  }

  function _calculateSharesDelta(uint256 totalAssetsBefore) internal returns (int256 sharesDelta) {
    uint256 totalAssetsAfter = _totalAssets();

    if (totalAssetsAfter > totalAssetsBefore) {
      uint256 increase = totalAssetsAfter - totalAssetsBefore;
      _mint(msg.sender, increase);
      return int256(increase);
    } else if (totalAssetsAfter < totalAssetsBefore) {
      uint256 decrease = totalAssetsBefore - totalAssetsAfter;
      _burn(msg.sender, decrease);
      return -int256(decrease);
    }
  }

  function burn(uint256 shares) public override onlyRoles(_ROLE_MINTER) returns (uint256 collateral, uint256 debt) {
    _burn(msg.sender, shares);
    if (shares == 0 || shares > _totalAssets()) return (0, 0);

    PositionManagerStorage storage ps = _positionManagerStorage();
    if (ps.positions.length() == 0) return (0, 0);

    return _burnFromPositions(shares, ps);
  }

  function _burnFromPositions(uint256 shares, PositionManagerStorage storage ps)
    internal
    returns (uint256 collateral, uint256 debt)
  {
    uint256 totalDebt = debtAmount();
    uint256 totalRawColl = _getTotalRawCollateral(ps);

    for (uint256 i = 0; i < ps.positions.length(); i++) {
      (uint256 coll, uint256 debtAmt) = _processPositionBurn(shares, totalDebt, totalRawColl, ps, i, debt);
      collateral += coll;
      debt += debtAmt;
    }

    if (collateral > 0) ps.collateralAsset.safeTransfer(msg.sender, collateral);
    ps.debtAsset.safeTransferAll(msg.sender);
  }

  function _getTotalRawCollateral(PositionManagerStorage storage ps) internal view returns (uint256 total) {
    for (uint256 i = 0; i < ps.positions.length(); i++) {
      (address pos,) = ps.positions.at(i);
      total += IBorrowPosition(pos).totalCollateral();
    }
  }

  function _processPositionBurn(
    uint256 shares,
    uint256 totalDebt,
    uint256 totalRawColl,
    PositionManagerStorage storage ps,
    uint256 index,
    uint256 debtSoFar
  ) internal returns (uint256 collateral, uint256 debt) {
    (address position,) = ps.positions.at(index);
    IBorrowPosition bp = IBorrowPosition(position);

    // Repay proportionally
    if (totalDebt > 0) {
      uint256 repayAmt = shares.mulDiv(bp.totalBorrowed(), totalDebt + totalRawColl);
      if (repayAmt > bp.totalBorrowed()) repayAmt = bp.totalBorrowed();
      if (repayAmt > 0) {
        ps.debtAsset.safeTransferFrom(msg.sender, address(this), repayAmt);
        _repay(position, ps.debtAsset, repayAmt);
        debt = repayAmt;
      }
    }

    // Withdraw proportionally
    if (totalRawColl > 0) {
      uint256 withdrawAmt = (shares + debtSoFar).mulDiv(bp.totalCollateral(), totalRawColl);
      if (withdrawAmt > bp.totalCollateral()) withdrawAmt = bp.totalCollateral();
      if (withdrawAmt > 0) {
        _withdraw(position, withdrawAmt);
        collateral = withdrawAmt;
      }
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        internal functions                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the total assets (collateral - debt) across all positions.
  /// @return Total assets value in debt asset terms
  function _totalAssets() internal view returns (uint256) {
    return collateralAmount() - debtAmount();
  }

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

  function addBorrowPosition(address position) public override onlyOwner {
    _positionManagerStorage().positions.set(position, 0);
    // TODO: emit event if it was added otherwise revert
  }

  function removeBorrowPosition(address position) public override onlyOwner {
    _positionManagerStorage().positions.remove(position);
    // TODO: emit event if it was removed otherwise revert
  }

  function setMaxBorrowAmount(address position, uint256 maxBorrowAmount) public override onlyOwner {
    _positionManagerStorage().positions.set(position, maxBorrowAmount);
    // TODO: emit event
  }

  function setFeeData(address feeRecipient, uint24 managementFees, uint24 performanceFees) public override onlyOwner {
    FeeData memory fd;
    fd.feeRecipient = feeRecipient;
    fd.managementFees = managementFees;
    fd.performanceFees = performanceFees;
    _positionManagerStorage().feeData = fd;
    // TODO: emit event
  }

  function _dispatchRebalancingOperation(
    RebalancingOperation calldata operation,
    address collateralAsset,
    address debtAsset
  ) internal {
    address position = operation.position;
    uint256 amount = operation.amount;
    RebalancingOperationType operationType = operation.operationType;
    if (operationType == RebalancingOperationType.REPAY) {
      _repay(position, debtAsset, amount);
    } else if (operationType == RebalancingOperationType.WITHDRAW) {
      _withdraw(position, amount);
    } else if (operationType == RebalancingOperationType.BORROW) {
      _borrow(position, amount);
    } else if (operationType == RebalancingOperationType.SUPPLY) {
      _supply(position, collateralAsset, amount);
    }
  }

  function rebalance(RebalancingData calldata data)
    public
    override
    onlyOwner
    returns (uint256 collateralExcess, uint256 debtExcess)
  {
    PositionManagerStorage storage ps = _positionManagerStorage();
    address collateralAsset = ps.collateralAsset;
    address debtAsset = ps.debtAsset;
    if (data.collateral > 0) {
      collateralAsset.safeTransferFrom(msg.sender, address(this), data.collateral);
    }
    if (data.debt > 0) {
      debtAsset.safeTransferFrom(msg.sender, address(this), data.debt);
    }
    for (uint256 i = 0; i < data.operations.length; i++) {
      _dispatchRebalancingOperation(data.operations[i], collateralAsset, debtAsset);
    }
    collateralExcess = collateralAsset.safeTransferAll(msg.sender);
    debtExcess = debtAsset.safeTransferAll(msg.sender);
  }
}
