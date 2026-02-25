// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ICentrifugeVault} from "src/interfaces/integrations/centrifuge/ICentrifugeVault.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {MockERC20} from "../../MockERC20.sol";

/// @dev Mock Centrifuge ERC-7540 vault for testing CentrifugeFund.
///      Implements the full ICentrifugeVault interface with controllable state.
///      Test helpers simulate Centrifuge epoch processing (fulfillDeposit, fulfillRedeem, etc.).
contract MockCentrifugeVault is ICentrifugeVault {
  using SafeTransferLib for address;

  address public _asset;
  address public _share;

  /// @dev Conversion rate in 1e18. 1e18 = 1:1.
  uint256 public _conversionRate = 1e18;

  mapping(address => bool) public _permissioned;

  mapping(address => uint256) public _pendingDeposits;
  mapping(address => uint256) public _pendingRedeems;

  mapping(address => uint256) public _claimableMint;
  mapping(address => uint256) public _claimableWithdraw;

  mapping(address => bool) public _pendingCancelDeposit;
  mapping(address => bool) public _pendingCancelRedeem;

  mapping(address => uint256) public _claimableCancelDeposit;
  mapping(address => uint256) public _claimableCancelRedeem;

  uint256 public _maxDepositAmount = type(uint256).max;
  uint256 public _maxRedeemAmount = type(uint256).max;

  constructor(address asset_, address share_) {
    _asset = asset_;
    _share = share_;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ICentrifugeVault VIEWS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function asset() external view override returns (address) {
    return _asset;
  }

  function share() external view override returns (address) {
    return _share;
  }

  function convertToShares(uint256 assets) external view override returns (uint256) {
    return assets * 1e18 / _conversionRate;
  }

  function convertToAssets(uint256 shares) external view override returns (uint256) {
    return shares * _conversionRate / 1e18;
  }

  function maxMint(address controller) external view override returns (uint256) {
    return _claimableMint[controller];
  }

  function maxWithdraw(address controller) external view override returns (uint256) {
    return _claimableWithdraw[controller];
  }

  function maxDeposit(address controller) external view override returns (uint256) {
    if (!_permissioned[controller]) return 0;
    return _maxDepositAmount;
  }

  function maxRedeem(address controller) external view override returns (uint256) {
    if (!_permissioned[controller]) return 0;
    return _maxRedeemAmount;
  }

  function isPermissioned(address controller) external view override returns (bool) {
    return _permissioned[controller];
  }

  function pendingDepositRequest(uint256, address controller) external view override returns (uint256) {
    return _pendingDeposits[controller];
  }

  function pendingRedeemRequest(uint256, address controller) external view override returns (uint256) {
    return _pendingRedeems[controller];
  }

  function pendingCancelDepositRequest(uint256, address controller) external view override returns (bool) {
    return _pendingCancelDeposit[controller];
  }

  function pendingCancelRedeemRequest(uint256, address controller) external view override returns (bool) {
    return _pendingCancelRedeem[controller];
  }

  function claimableCancelDepositRequest(uint256, address controller) external view override returns (uint256) {
    return _claimableCancelDeposit[controller];
  }

  function claimableCancelRedeemRequest(uint256, address controller) external view override returns (uint256) {
    return _claimableCancelRedeem[controller];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  ICentrifugeVault MUTATIONS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function requestDeposit(uint256 assets, address controller, address) external override returns (uint256) {
    _asset.safeTransferFrom(msg.sender, address(this), assets);
    _pendingDeposits[controller] += assets;
    return 0;
  }

  function requestRedeem(uint256 shares, address controller, address) external override returns (uint256) {
    _share.safeTransferFrom(msg.sender, address(this), shares);
    _pendingRedeems[controller] += shares;
    return 0;
  }

  function mint(uint256 shares, address receiver, address controller) external override returns (uint256) {
    require(_claimableMint[controller] >= shares, "MockVault: insufficient claimable mint");
    _claimableMint[controller] -= shares;
    _share.safeTransfer(receiver, shares);
    return shares;
  }

  function withdraw(uint256 assets, address receiver, address controller) external override returns (uint256) {
    require(_claimableWithdraw[controller] >= assets, "MockVault: insufficient claimable withdraw");
    _claimableWithdraw[controller] -= assets;
    _asset.safeTransfer(receiver, assets);
    return assets;
  }

  function cancelDepositRequest(uint256, address controller) external override {
    _pendingCancelDeposit[controller] = true;
  }

  function cancelRedeemRequest(uint256, address controller) external override {
    _pendingCancelRedeem[controller] = true;
  }

  function claimCancelDepositRequest(uint256, address receiver, address controller)
    external
    override
    returns (uint256)
  {
    uint256 amount = _claimableCancelDeposit[controller];
    _claimableCancelDeposit[controller] = 0;
    _asset.safeTransfer(receiver, amount);
    return amount;
  }

  function claimCancelRedeemRequest(uint256, address receiver, address controller) external override returns (uint256) {
    uint256 amount = _claimableCancelRedeem[controller];
    _claimableCancelRedeem[controller] = 0;
    _share.safeTransfer(receiver, amount);
    return amount;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST HELPERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setPermissioned(address controller, bool val) external {
    _permissioned[controller] = val;
  }

  function setConversionRate(uint256 rate) external {
    _conversionRate = rate;
  }

  function setMaxDeposit(uint256 amount) external {
    _maxDepositAmount = amount;
  }

  function setMaxRedeem(uint256 amount) external {
    _maxRedeemAmount = amount;
  }

  /// @dev Simulates epoch fulfillment for a deposit. Mints share tokens and makes them claimable.
  function fulfillDeposit(address controller, uint256 shares) external {
    _pendingDeposits[controller] = 0;
    _claimableMint[controller] += shares;
    MockERC20(_share).mint(address(this), shares);
  }

  /// @dev Simulates epoch fulfillment for a redeem. Mints asset tokens and makes them claimable.
  function fulfillRedeem(address controller, uint256 assets) external {
    _pendingRedeems[controller] = 0;
    _claimableWithdraw[controller] += assets;
    MockERC20(_asset).mint(address(this), assets);
  }

  /// @dev Simulates partial epoch fulfillment for a deposit.
  function partialFulfillDeposit(address controller, uint256 shares, uint256 assetsConsumed) external {
    _pendingDeposits[controller] -= assetsConsumed;
    _claimableMint[controller] += shares;
    MockERC20(_share).mint(address(this), shares);
  }

  /// @dev Simulates partial epoch fulfillment for a redeem.
  function partialFulfillRedeem(address controller, uint256 assets, uint256 sharesConsumed) external {
    _pendingRedeems[controller] -= sharesConsumed;
    _claimableWithdraw[controller] += assets;
    MockERC20(_asset).mint(address(this), assets);
  }

  /// @dev Simulates cancellation fulfillment for a deposit. Returns assets to vault for claiming.
  function fulfillCancelDeposit(address controller, uint256 assets) external {
    _pendingCancelDeposit[controller] = false;
    _pendingDeposits[controller] = 0;
    _claimableCancelDeposit[controller] += assets;
    // Assets are already held by the vault (received during requestDeposit), no mint needed
  }

  /// @dev Simulates cancellation fulfillment for a redeem. Returns shares to vault for claiming.
  function fulfillCancelRedeem(address controller, uint256 shares) external {
    _pendingCancelRedeem[controller] = false;
    _pendingRedeems[controller] = 0;
    _claimableCancelRedeem[controller] += shares;
    // Shares are already held by the vault (received during requestRedeem), no mint needed
  }

  /// @dev Simulates partial cancellation fulfillment for a deposit.
  function partialFulfillCancelDeposit(address controller, uint256 assets, uint256 assetsConsumed) external {
    _pendingDeposits[controller] -= assetsConsumed;
    _claimableCancelDeposit[controller] += assets;
  }

  /// @dev Simulates partial cancellation fulfillment for a redeem.
  function partialFulfillCancelRedeem(address controller, uint256 shares, uint256 sharesConsumed) external {
    _pendingRedeems[controller] -= sharesConsumed;
    _claimableCancelRedeem[controller] += shares;
  }
}
