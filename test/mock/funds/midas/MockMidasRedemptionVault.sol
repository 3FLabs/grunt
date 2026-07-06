// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IMidasRedemptionVault} from "src/interfaces/integrations/midas/IMidasRedemptionVault.sol";
import {MidasRequestStatus} from "src/interfaces/integrations/midas/IMidasVault.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

import {MockERC20} from "../../MockERC20.sol";
import {MockMidasDataFeed} from "./MockMidasDataFeed.sol";

/// @dev Mock Midas RedemptionVault for testing MidasFund.
///      Mirrors the base-18 Midas vault API with decimal-correct native transfers:
///      - redeemInstant pulls and burns `amountMTokenIn` mToken from the caller and
///        synchronously pays out `amountMTokenIn * mTokenRate / tokenOutRate` (minus the
///        optional instant fee) in tokenOut native decimals, enforcing `minReceiveAmount`.
///      - redeemRequest escrows the mToken in the vault and stores a PENDING request.
///        Test helpers approve (burn escrow + push tokenOut to the requester) or reject
///        the request. Rejections keep the mToken escrowed (mirroring Midas); use
///        `withdrawToken` to simulate the off-band refund performed by the Midas admin.
contract MockMidasRedemptionVault is IMidasRedemptionVault {
  using SafeTransferLib for address;

  uint256 internal constant _BASE18 = 1e18;
  /// @dev Midas percent units: 1% = 100.
  uint256 internal constant _ONE_HUNDRED_PERCENT = 100 * 100;

  struct TokenConfig {
    address dataFeed;
    uint256 fee;
    uint256 allowance;
    bool stable;
  }

  struct RedeemRequest {
    address sender;
    address tokenOut;
    MidasRequestStatus status;
    uint256 amountMToken;
    uint256 mTokenRate;
    uint256 tokenOutRate;
  }

  address internal _mToken;
  address internal _mTokenDataFeed;
  address internal _accessControl;

  bool internal _paused;
  bool internal _greenlistEnabled;
  bytes32 internal _greenlistedRole = keccak256("GREENLISTED_ROLE");
  uint256 internal _minAmount;
  uint256 internal _instantFee;
  uint256 internal _instantDailyLimit = type(uint256).max;
  uint256 internal _requestIdCounter = 1;

  mapping(bytes4 => bool) internal _fnPaused;
  mapping(address => TokenConfig) internal _tokensConfig;
  mapping(uint256 => RedeemRequest) internal _redeemRequests;

  constructor(address mToken_, address mTokenDataFeed_, address accessControl_) {
    _mToken = mToken_;
    _mTokenDataFeed = mTokenDataFeed_;
    _accessControl = accessControl_;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    IMidasVault VIEWS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function mToken() external view override returns (address) {
    return _mToken;
  }

  function mTokenDataFeed() external view override returns (address) {
    return _mTokenDataFeed;
  }

  function tokensConfig(address token)
    external
    view
    override
    returns (address dataFeed, uint256 fee, uint256 allowance, bool stable)
  {
    TokenConfig storage config = _tokensConfig[token];
    return (config.dataFeed, config.fee, config.allowance, config.stable);
  }

  function paused() external view override returns (bool) {
    return _paused;
  }

  function fnPaused(bytes4 fn) external view override returns (bool) {
    return _fnPaused[fn];
  }

  function greenlistEnabled() external view override returns (bool) {
    return _greenlistEnabled;
  }

  function greenlistedRole() external view override returns (bytes32) {
    return _greenlistedRole;
  }

  function accessControl() external view override returns (address) {
    return _accessControl;
  }

  function minAmount() external view override returns (uint256) {
    return _minAmount;
  }

  function instantFee() external view override returns (uint256) {
    return _instantFee;
  }

  function instantDailyLimit() external view override returns (uint256) {
    return _instantDailyLimit;
  }

  function currentRequestId() external view override returns (uint256) {
    return _requestIdCounter;
  }

  function tokensReceiver() external view override returns (address) {
    return address(this);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              IMidasRedemptionVault OPERATIONS              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) external override {
    _redeemInstant(tokenOut, amountMTokenIn, minReceiveAmount, msg.sender);
  }

  function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount, address recipient)
    external
    override
  {
    _redeemInstant(tokenOut, amountMTokenIn, minReceiveAmount, recipient);
  }

  function redeemRequest(address tokenOut, uint256 amountMTokenIn) external override returns (uint256 requestId) {
    return _redeemRequest(tokenOut, amountMTokenIn, msg.sender);
  }

  function redeemRequest(address tokenOut, uint256 amountMTokenIn, address recipient)
    external
    override
    returns (uint256 requestId)
  {
    return _redeemRequest(tokenOut, amountMTokenIn, recipient);
  }

  function redeemFiatRequest(uint256 amountMTokenIn) external override returns (uint256 requestId) {
    return _redeemRequest(address(0), amountMTokenIn, msg.sender);
  }

  function redeemRequests(uint256 requestId)
    external
    view
    override
    returns (
      address sender,
      address tokenOut,
      MidasRequestStatus status,
      uint256 amountMToken,
      uint256 mTokenRate,
      uint256 tokenOutRate
    )
  {
    RedeemRequest storage request = _redeemRequests[requestId];
    return
      (request.sender, request.tokenOut, request.status, request.amountMToken, request.mTokenRate, request.tokenOutRate);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Approves a PENDING redeem request: burns the escrowed mToken and pushes
  ///      `amountTokenOut` (tokenOut native decimals) to the requester.
  function approveRedeemRequest(uint256 requestId, uint256 amountTokenOut) external {
    RedeemRequest storage request = _redeemRequests[requestId];
    require(request.status == MidasRequestStatus.PENDING, "MockRedemptionVault: not pending");
    request.status = MidasRequestStatus.PROCESSED;
    MockERC20(_mToken).burn(address(this), request.amountMToken);
    MockERC20(request.tokenOut).mint(request.sender, amountTokenOut);
  }

  /// @dev Rejects a PENDING redeem request. The escrowed mToken stays in the vault.
  function rejectRedeemRequest(uint256 requestId) external {
    RedeemRequest storage request = _redeemRequests[requestId];
    require(request.status == MidasRequestStatus.PENDING, "MockRedemptionVault: not pending");
    request.status = MidasRequestStatus.CANCELED;
  }

  /// @dev Mirrors the Midas admin `withdrawToken` used for off-band refunds.
  function withdrawToken(address token, address to, uint256 amount) external {
    token.safeTransfer(to, amount);
  }

  function setTokenConfig(address token, address dataFeed, uint256 fee, uint256 allowance, bool stable) external {
    _tokensConfig[token] = TokenConfig({dataFeed: dataFeed, fee: fee, allowance: allowance, stable: stable});
  }

  function setPaused(bool paused_) external {
    _paused = paused_;
  }

  function setFnPaused(bytes4 fn, bool paused_) external {
    _fnPaused[fn] = paused_;
  }

  function setGreenlistEnabled(bool enabled) external {
    _greenlistEnabled = enabled;
  }

  function setGreenlistedRole(bytes32 role) external {
    _greenlistedRole = role;
  }

  function setMinAmount(uint256 amount) external {
    _minAmount = amount;
  }

  function setInstantFee(uint256 fee) external {
    _instantFee = fee;
  }

  function setInstantDailyLimit(uint256 limit) external {
    _instantDailyLimit = limit;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount, address recipient)
    internal
  {
    require(!_paused, "MockRedemptionVault: paused");
    _mToken.safeTransferFrom(msg.sender, address(this), amountMTokenIn);
    MockERC20(_mToken).burn(address(this), amountMTokenIn);

    uint256 amountOutBase18 = amountMTokenIn * _mTokenRate() / _tokenOutRate(tokenOut);
    if (_instantFee > 0) {
      amountOutBase18 = amountOutBase18 * (_ONE_HUNDRED_PERCENT - _instantFee) / _ONE_HUNDRED_PERCENT;
    }
    require(amountOutBase18 >= minReceiveAmount, "MockRedemptionVault: slippage");

    uint256 scale = 10 ** (18 - MockERC20(tokenOut).decimals());
    MockERC20(tokenOut).mint(recipient, amountOutBase18 / scale);
  }

  function _redeemRequest(address tokenOut, uint256 amountMTokenIn, address recipient)
    internal
    returns (uint256 requestId)
  {
    require(!_paused, "MockRedemptionVault: paused");
    _mToken.safeTransferFrom(msg.sender, address(this), amountMTokenIn);

    requestId = _requestIdCounter++;
    _redeemRequests[requestId] = RedeemRequest({
      sender: recipient,
      tokenOut: tokenOut,
      status: MidasRequestStatus.PENDING,
      amountMToken: amountMTokenIn,
      mTokenRate: _mTokenRate(),
      tokenOutRate: tokenOut == address(0) ? _BASE18 : _tokenOutRate(tokenOut)
    });
  }

  function _tokenOutRate(address tokenOut) internal view returns (uint256) {
    TokenConfig storage config = _tokensConfig[tokenOut];
    require(config.dataFeed != address(0), "MockRedemptionVault: token not supported");
    if (config.stable) return _BASE18;
    return MockMidasDataFeed(config.dataFeed).getDataInBase18();
  }

  function _mTokenRate() internal view returns (uint256) {
    return MockMidasDataFeed(_mTokenDataFeed).getDataInBase18();
  }
}
