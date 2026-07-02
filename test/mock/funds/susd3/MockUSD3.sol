// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MockERC20} from "../../MockERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @notice Minimal ERC4626-style mock of the USD3 senior tranche (asset = USDC).
/// @dev Ratio-based conversions from the actual USDC held (floor rounding, like ERC4626). Simulate
///      yield/loss by dealing/removing USDC from this contract. Configurable deposit cap, redeem
///      liquidity limit, and `minDeposit` (enforced for first-time depositors) let tests exercise the
///      fund's caps, illiquidity, and slippage paths.
contract MockUSD3 is MockERC20 {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;

  address public immutable asset; // USDC

  uint256 public minDeposit;
  uint256 internal _depositCap = type(uint256).max; // maxDeposit (in assets)
  uint256 internal _maxRedeemShares = type(uint256).max; // liquidity limit (in shares)

  constructor(address usdc) MockERC20("USD3", "USD3", 6) {
    asset = usdc;
  }

  /*//////////////////////////  CONFIG  //////////////////////////*/

  function setMinDeposit(uint256 v) external {
    minDeposit = v;
  }

  function setDepositCap(uint256 v) external {
    _depositCap = v;
  }

  function setMaxRedeemShares(uint256 v) external {
    _maxRedeemShares = v;
  }

  /*//////////////////////////  VIEWS  //////////////////////////*/

  function minCommitmentTime() external pure returns (uint256) {
    return 0;
  }

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

  function maxRedeem(address owner) public view returns (uint256) {
    uint256 bal = balanceOf(owner);
    return bal < _maxRedeemShares ? bal : _maxRedeemShares;
  }

  /*//////////////////////////  MUTATIONS  //////////////////////////*/

  function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
    require(assets <= _depositCap, "USD3: deposit cap");
    if (balanceOf(receiver) == 0) require(assets >= minDeposit, "USD3: <min");
    shares = convertToShares(assets);
    asset.safeTransferFrom(msg.sender, address(this), assets);
    _mint(receiver, shares);
  }

  function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
    require(shares <= maxRedeem(owner), "USD3: exceeds maxRedeem");
    if (owner != msg.sender) _spendAllowance(owner, msg.sender, shares);
    assets = convertToAssets(shares);
    _burn(owner, shares);
    asset.safeTransfer(receiver, assets);
  }
}
