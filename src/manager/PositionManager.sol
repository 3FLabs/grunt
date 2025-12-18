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
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

// the position manager contract transforms multiple

contract PositionManager is IPositionManager, OwnableRoles, ERC20, Initializable {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using SafeTransferLib for address;

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
  struct PositionManagerStorage {
    FeeData feeData;
    EnumerableSetLib.AddressSet positions;
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
    return _positionManagerStorage().positions.values();
  }

  function collateralAmount() public view override returns (uint256 amount) {
    for (uint256 i = 0; i < _positionManagerStorage().positions.length(); i++) {
      amount += IBorrowPosition(_positionManagerStorage().positions.at(i)).totalCollateral();
    }
  }

  function debtAmount() public view override returns (uint256 amount) {
    for (uint256 i = 0; i < _positionManagerStorage().positions.length(); i++) {
      amount += IBorrowPosition(_positionManagerStorage().positions.at(i)).totalBorrowed();
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
    return 0; // TODO: Implement deposit
  }

  function withdraw(uint256 collateral, uint256 debt)
    public
    override
    onlyRoles(_ROLE_MINTER)
    returns (int256 sharesDelta)
  {
    return 0; // TODO: Implement withdraw
  }

  function burn(uint256 shares) public override onlyRoles(_ROLE_MINTER) returns (uint256 collateral, uint256 debt) {
    return (0, 0); // TODO: Implement burn
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        internal functions                      */
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

  function addBorrowPosition(address position) public override onlyOwner {
    _positionManagerStorage().positions.add(position);
    // TODO: emit event if it was added otherwise revert
  }

  function removeBorrowPosition(address position) public override onlyOwner {
    _positionManagerStorage().positions.remove(position);
    // TODO: emit event if it was removed otherwise revert
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
