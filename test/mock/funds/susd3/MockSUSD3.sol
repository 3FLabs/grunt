// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MockERC20} from "../../MockERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @notice Minimal ERC4626-style mock of the sUSD3 subordinate tranche (asset = USD3).
/// @dev Ratio-based conversions from the actual USD3 held (floor rounding). Reproduces the sUSD3
///      cooldown state machine (startCooldown/cancelCooldown/getCooldownStatus + maxRedeem gating),
///      the deposit self/whitelist restriction, the lock/cooldown transfer guard, and configurable
///      knobs to simulate a subordination cap (`depositCap`), a backing-limited partial redeem
///      (`maxRedeemCap`), and a fully blocked withdrawal (`blocked`).
contract MockSUSD3 is MockERC20 {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;

  struct UserCooldown {
    uint64 cooldownEnd;
    uint64 windowEnd;
    uint128 shares;
  }

  mapping(address => UserCooldown) public cooldowns;
  mapping(address => uint256) public lockedUntil;
  mapping(address => bool) public depositorWhitelist;

  address public immutable asset; // USD3

  uint256 public lockDuration;
  uint256 public cooldownDuration = 30 days;
  uint256 public withdrawalWindow = 3155760000; // ~100 years
  uint256 internal _depositCap = type(uint256).max; // maxDeposit / availableDepositLimit (in assets)
  uint256 internal _maxRedeemCap = type(uint256).max; // partial/backing limit (in shares)
  bool public blocked;

  constructor(address usd3) MockERC20("sUSD3", "sUSD3", 6) {
    asset = usd3;
  }

  /*//////////////////////////  CONFIG  //////////////////////////*/

  function setLockDuration(uint256 v) external {
    lockDuration = v;
  }

  function setCooldownDuration(uint256 v) external {
    cooldownDuration = v;
  }

  function setWithdrawalWindow(uint256 v) external {
    withdrawalWindow = v;
  }

  function setDepositCap(uint256 v) external {
    _depositCap = v;
  }

  function setMaxRedeemCap(uint256 v) external {
    _maxRedeemCap = v;
  }

  function setBlocked(bool v) external {
    blocked = v;
  }

  function setDepositorWhitelist(address d, bool a) external {
    depositorWhitelist[d] = a;
  }

  /*//////////////////////////  VIEWS  //////////////////////////*/

  function totalAssets() public view returns (uint256) {
    return MockERC20(asset).balanceOf(address(this));
  }

  function convertToShares(uint256 assets) public view returns (uint256) {
    uint256 ts = totalSupply();
    return ts == 0 ? assets : assets.mulDiv(ts, totalAssets());
  }

  function convertToAssets(uint256 shares) public view returns (uint256) {
    uint256 ts = totalSupply();
    return ts == 0 ? shares : shares.mulDiv(totalAssets(), ts);
  }

  function previewDeposit(uint256 assets) external view returns (uint256) {
    return convertToShares(assets);
  }

  function previewRedeem(uint256 shares) external view returns (uint256) {
    return convertToAssets(shares);
  }

  function maxDeposit(address) external view returns (uint256) {
    return _depositCap;
  }

  function availableDepositLimit(address) external view returns (uint256) {
    return _depositCap;
  }

  function maxRedeem(address owner) public view returns (uint256) {
    if (blocked) return 0;

    uint256 limit;
    if (cooldownDuration == 0) {
      limit = balanceOf(owner);
    } else {
      UserCooldown memory c = cooldowns[owner];
      if (c.shares == 0) return 0;
      if (block.timestamp < c.cooldownEnd) return 0;
      if (block.timestamp > c.windowEnd) return 0;
      limit = c.shares;
    }

    uint256 bal = balanceOf(owner);
    if (limit > bal) limit = bal;
    if (limit > _maxRedeemCap) limit = _maxRedeemCap;
    return limit;
  }

  function availableWithdrawLimit(address owner) external view returns (uint256) {
    return convertToAssets(maxRedeem(owner));
  }

  function getCooldownStatus(address user)
    external
    view
    returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares)
  {
    UserCooldown memory c = cooldowns[user];
    return (c.cooldownEnd, c.windowEnd, c.shares);
  }

  /*//////////////////////////  MUTATIONS  //////////////////////////*/

  function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
    require(
      msg.sender == receiver || depositorWhitelist[msg.sender], "sUSD3: Only self or whitelisted deposits allowed"
    );
    require(assets <= _depositCap, "sUSD3: deposit cap");
    shares = convertToShares(assets);
    asset.safeTransferFrom(msg.sender, address(this), assets);
    _mint(receiver, shares);
    if (lockDuration > 0) lockedUntil[receiver] = block.timestamp + lockDuration;
  }

  function startCooldown(uint256 shares) external {
    require(shares > 0, "Invalid shares");
    require(block.timestamp >= lockedUntil[msg.sender], "Still in lock period");
    require(shares <= balanceOf(msg.sender), "Insufficient balance for cooldown");
    cooldowns[msg.sender] = UserCooldown({
      cooldownEnd: uint64(block.timestamp + cooldownDuration),
      windowEnd: uint64(block.timestamp + cooldownDuration + withdrawalWindow),
      shares: uint128(shares)
    });
  }

  function cancelCooldown() external {
    require(cooldowns[msg.sender].shares > 0, "No active cooldown");
    delete cooldowns[msg.sender];
  }

  function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
    require(shares <= maxRedeem(owner), "sUSD3: exceeds maxRedeem");
    if (owner != msg.sender) _spendAllowance(owner, msg.sender, shares);
    assets = convertToAssets(shares);
    _burn(owner, shares);

    // Mirror sUSD3._postWithdrawHook cooldown decrement.
    UserCooldown storage c = cooldowns[owner];
    if (c.shares > 0) {
      if (shares >= c.shares) delete cooldowns[owner];
      else c.shares -= uint128(shares);
    }

    asset.safeTransfer(receiver, assets);
  }

  /// @dev Mirror sUSD3._preTransferHook: block transfers during lock or for shares in cooldown.
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal view override {
    if (from == address(0) || to == address(0)) return;
    require(block.timestamp >= lockedUntil[from], "sUSD3: Cannot transfer during lock period");
    UserCooldown memory c = cooldowns[from];
    if (c.shares > 0) {
      uint256 bal = balanceOf(from);
      uint256 nonCooldown = bal > c.shares ? bal - c.shares : 0;
      require(amount <= nonCooldown, "sUSD3: Cannot transfer shares in cooldown");
    }
  }
}
