// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IMidasDepositVault} from "src/interfaces/integrations/midas/IMidasDepositVault.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

import {MockERC20} from "../../MockERC20.sol";
import {MockMidasDataFeed} from "./MockMidasDataFeed.sol";

/// @dev Mock Midas DepositVault (issuance vault) for testing MidasFund.
///      Mirrors the base-18 Midas vault API with decimal-correct native transfers:
///      - depositInstant pulls `amountToken / scale` tokenIn (native decimals) from the caller
///        and synchronously mints `amountToken * tokenInRate / mTokenRate` mToken
///        (minus the optional instant fee), enforcing `minReceiveAmount`.
///      - `withdrawToken` simulates the off-band refund performed by the Midas admin.
contract MockMidasDepositVault is IMidasDepositVault {
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

  address internal _mToken;
  address internal _mTokenDataFeed;
  address internal _accessControl;

  bool internal _paused;
  bool internal _greenlistEnabled;
  bytes32 internal _greenlistedRole = keccak256("GREENLISTED_ROLE");
  uint256 internal _minAmount;
  uint256 internal _instantFee;
  uint256 internal _instantDailyLimit = type(uint256).max;
  uint256 internal _minMTokenAmountForFirstDeposit;

  bytes32 public lastReferrerId;

  mapping(bytes4 => bool) internal _fnPaused;
  mapping(address => TokenConfig) internal _tokensConfig;
  mapping(address => uint256) internal _totalMinted;

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

  function tokensReceiver() external view override returns (address) {
    return address(this);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                IMidasDepositVault OPERATIONS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function depositInstant(address tokenIn, uint256 amountToken, uint256 minReceiveAmount, bytes32 referrerId)
    external
    override
  {
    _depositInstant(tokenIn, amountToken, minReceiveAmount, referrerId, msg.sender);
  }

  function depositInstant(
    address tokenIn,
    uint256 amountToken,
    uint256 minReceiveAmount,
    bytes32 referrerId,
    address recipient
  ) external override {
    _depositInstant(tokenIn, amountToken, minReceiveAmount, referrerId, recipient);
  }

  function minMTokenAmountForFirstDeposit() external view override returns (uint256) {
    return _minMTokenAmountForFirstDeposit;
  }

  function totalMinted(address user) external view override returns (uint256) {
    return _totalMinted[user];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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

  function setMinMTokenAmountForFirstDeposit(uint256 amount) external {
    _minMTokenAmountForFirstDeposit = amount;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _depositInstant(
    address tokenIn,
    uint256 amountToken,
    uint256 minReceiveAmount,
    bytes32 referrerId,
    address recipient
  ) internal {
    require(!_paused, "MockDepositVault: paused");
    lastReferrerId = referrerId;
    _pullTokenIn(tokenIn, amountToken);

    uint256 mintAmount = amountToken * _tokenInRate(tokenIn) / _mTokenRate();
    if (_instantFee > 0) {
      mintAmount = mintAmount * (_ONE_HUNDRED_PERCENT - _instantFee) / _ONE_HUNDRED_PERCENT;
    }
    require(mintAmount >= minReceiveAmount, "MockDepositVault: slippage");

    MockERC20(_mToken).mint(recipient, mintAmount);
    _totalMinted[recipient] += mintAmount;
  }

  /// @dev Pulls `amountToken` (base-18) from the caller, converted to tokenIn native decimals.
  function _pullTokenIn(address tokenIn, uint256 amountToken) internal {
    uint256 scale = 10 ** (18 - MockERC20(tokenIn).decimals());
    tokenIn.safeTransferFrom(msg.sender, address(this), amountToken / scale);
  }

  function _tokenInRate(address tokenIn) internal view returns (uint256) {
    TokenConfig storage config = _tokensConfig[tokenIn];
    require(config.dataFeed != address(0), "MockDepositVault: token not supported");
    if (config.stable) return _BASE18;
    return MockMidasDataFeed(config.dataFeed).getDataInBase18();
  }

  function _mTokenRate() internal view returns (uint256) {
    return MockMidasDataFeed(_mTokenDataFeed).getDataInBase18();
  }
}
