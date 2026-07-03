// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MockERC20} from "../../MockERC20.sol";
import {
  IWildcatMarket,
  WithdrawalBatch,
  AccountWithdrawalStatus
} from "src/interfaces/integrations/wildcat/IWildcatMarket.sol";
import {RAY} from "src/libs/Constants.sol";

/// @notice Mock of a Wildcat V2 market: a rebasing token with scaled internal balances and
///         expiry-keyed withdrawal batches paid via test helpers.
/// @dev Mirrors the market's half-up ray rounding (rayMul/rayDiv) for scaled<->normalized
///      conversions. Interest accrual is simulated by setting the scale factor directly.
contract MockWildcatMarket is IWildcatMarket {
  error MarketAlreadyClosed();
  error DepositToClosedMarket();
  error MaxSupplyExceeded();
  error NotApprovedLender();
  error NullBurnAmount();
  error NullWithdrawalAmount();
  error WithdrawalBatchNotExpired();

  MockERC20 public immutable assetToken;

  uint256 public override scaleFactor = RAY;
  uint256 public maxTotalSupply = type(uint128).max;
  uint256 public override withdrawalBatchDuration = 1 days;
  bool public override isClosed;
  bool public depositRequiresCredential;
  mapping(address => bool) public hasCredential;

  // Scaled ERC20 accounting (balances rebase through scaleFactor)
  mapping(address => uint256) public scaledBalanceOf;
  mapping(address => mapping(address => uint256)) public allowance;
  uint256 public scaledTotalSupply;

  // Withdrawal batches
  uint32 public pendingWithdrawalExpiry;
  mapping(uint32 => WithdrawalBatch) internal _batches;
  mapping(uint32 => mapping(address => AccountWithdrawalStatus)) internal _accountStatuses;

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Approval(address indexed owner, address indexed spender, uint256 amount);

  constructor(address asset_) {
    assetToken = MockERC20(asset_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST HELPERS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setScaleFactor(uint256 newScaleFactor) external {
    scaleFactor = newScaleFactor;
  }

  function setMaxTotalSupply(uint256 newMaxTotalSupply) external {
    maxTotalSupply = newMaxTotalSupply;
  }

  function setWithdrawalBatchDuration(uint256 newDuration) external {
    withdrawalBatchDuration = newDuration;
  }

  function setClosed(bool closed) external {
    isClosed = closed;
  }

  function setDepositRequiresCredential(bool required) external {
    depositRequiresCredential = required;
  }

  function setCredential(address account, bool valid) external {
    hasCredential[account] = valid;
  }

  /// @notice Simulates the borrower paying (part of) a batch: mints the underlying into the
  ///         market and marks the corresponding scaled amount as burned.
  /// @param expiry The batch expiry to pay.
  /// @param scaledAmount The scaled amount to burn from the batch (capped at what remains).
  function payBatch(uint32 expiry, uint256 scaledAmount) external {
    WithdrawalBatch storage batch = _batches[expiry];
    uint256 remaining = batch.scaledTotalAmount - batch.scaledAmountBurned;
    if (scaledAmount > remaining) scaledAmount = remaining;
    uint256 normalized = _rayMul(scaledAmount, scaleFactor);
    batch.scaledAmountBurned += uint104(scaledAmount);
    batch.normalizedAmountPaid += uint128(normalized);
    scaledTotalSupply -= scaledAmount;
    assetToken.mint(address(this), normalized);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ERC20 (rebasing)                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function name() external pure returns (string memory) {
    return "Mock Wildcat Market";
  }

  function symbol() external pure returns (string memory) {
    return "mockWMT";
  }

  function decimals() external view returns (uint8) {
    return assetToken.decimals();
  }

  function balanceOf(address account) public view returns (uint256) {
    return _rayMul(scaledBalanceOf[account], scaleFactor);
  }

  function totalSupply() external view returns (uint256) {
    return _rayMul(scaledTotalSupply, scaleFactor);
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    emit Approval(msg.sender, spender, amount);
    return true;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    _transfer(msg.sender, to, amount);
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    uint256 allowed = allowance[from][msg.sender];
    if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
    _transfer(from, to, amount);
    return true;
  }

  function _transfer(address from, address to, uint256 amount) internal {
    uint256 scaledAmount = _rayDiv(amount, scaleFactor);
    scaledBalanceOf[from] -= scaledAmount;
    scaledBalanceOf[to] += scaledAmount;
    emit Transfer(from, to, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function deposit(uint256 amount) external override {
    if (isClosed) revert DepositToClosedMarket();
    if (depositRequiresCredential && !hasCredential[msg.sender]) revert NotApprovedLender();
    uint256 currentSupply = _rayMul(scaledTotalSupply, scaleFactor);
    if (currentSupply + amount > maxTotalSupply) revert MaxSupplyExceeded();

    assetToken.transferFrom(msg.sender, address(this), amount);
    uint256 scaledAmount = _rayDiv(amount, scaleFactor);
    scaledBalanceOf[msg.sender] += scaledAmount;
    scaledTotalSupply += scaledAmount;
    emit Transfer(address(0), msg.sender, amount);
  }

  function queueWithdrawal(uint256 amount) external override returns (uint32 expiry) {
    uint256 scaledAmount = _rayDiv(amount, scaleFactor);
    if (scaledAmount == 0) revert NullBurnAmount();

    expiry = pendingWithdrawalExpiry;
    if (expiry == 0 || expiry < block.timestamp) {
      expiry = uint32(block.timestamp + (isClosed ? 0 : withdrawalBatchDuration));
      pendingWithdrawalExpiry = expiry;
    }

    scaledBalanceOf[msg.sender] -= scaledAmount;
    _batches[expiry].scaledTotalAmount += uint104(scaledAmount);
    _accountStatuses[expiry][msg.sender].scaledAmount += uint104(scaledAmount);
    emit Transfer(msg.sender, address(this), amount);
  }

  function executeWithdrawal(address accountAddress, uint32 expiry) external override returns (uint256) {
    uint256 claimable = getAvailableWithdrawalAmount(accountAddress, expiry);
    if (claimable == 0) revert NullWithdrawalAmount();
    _accountStatuses[expiry][accountAddress].normalizedAmountWithdrawn += uint128(claimable);
    assetToken.transfer(accountAddress, claimable);
    return claimable;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function asset() external view override returns (address) {
    return address(assetToken);
  }

  function maximumDeposit() external view override returns (uint256) {
    uint256 currentSupply = _rayMul(scaledTotalSupply, scaleFactor);
    return currentSupply >= maxTotalSupply ? 0 : maxTotalSupply - currentSupply;
  }

  function getWithdrawalBatch(uint32 expiry) external view override returns (WithdrawalBatch memory) {
    return _batches[expiry];
  }

  function getAccountWithdrawalStatus(address accountAddress, uint32 expiry)
    external
    view
    override
    returns (AccountWithdrawalStatus memory)
  {
    return _accountStatuses[expiry][accountAddress];
  }

  function getAvailableWithdrawalAmount(address accountAddress, uint32 expiry) public view override returns (uint256) {
    if (expiry >= block.timestamp) revert WithdrawalBatchNotExpired();
    WithdrawalBatch memory batch = _batches[expiry];
    if (batch.scaledTotalAmount == 0) return 0;
    AccountWithdrawalStatus memory status = _accountStatuses[expiry][accountAddress];
    uint256 newTotalWithdrawn = uint256(batch.normalizedAmountPaid) * status.scaledAmount / batch.scaledTotalAmount;
    return newTotalWithdrawn - status.normalizedAmountWithdrawn;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Half-up ray multiplication, matching Wildcat's MathUtils.rayMul.
  function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
    return (a * b + RAY / 2) / RAY;
  }

  /// @dev Half-up ray division, matching Wildcat's MathUtils.rayDiv.
  function _rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    return (a * RAY + b / 2) / b;
  }
}
