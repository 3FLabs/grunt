// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IWildcat4626Wrapper} from "src/interfaces/integrations/wildcat/IWildcat4626Wrapper.sol";
import {MockWildcatMarket} from "./MockWildcatMarket.sol";
import {RAY} from "src/libs/Constants.sol";

/// @notice Mock of Wildcat's official ERC-4626 wrapper: non-rebasing shares mirroring the
///         market's scaled balances (1 share = scaleFactor / 1e27 market tokens).
contract MockWildcat4626Wrapper is IWildcat4626Wrapper {
  error ZeroAssets();
  error ZeroShares();

  MockWildcatMarket public immutable wrappedMarket;

  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;
  uint256 public totalSupply;

  constructor(address market_) {
    wrappedMarket = MockWildcatMarket(market_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERC20                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function name() external pure returns (string memory) {
    return "mockWMT [4626 Vault Shares]";
  }

  function symbol() external pure returns (string memory) {
    return "v-mockWMT";
  }

  function decimals() external view returns (uint8) {
    return wrappedMarket.decimals();
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    emit Approval(msg.sender, spender, amount);
    return true;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    emit Transfer(msg.sender, to, amount);
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    uint256 allowed = allowance[from][msg.sender];
    if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
    balanceOf[from] -= amount;
    balanceOf[to] += amount;
    emit Transfer(from, to, amount);
    return true;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
    if (assets == 0) revert ZeroAssets();
    uint256 scaledBefore = wrappedMarket.scaledBalanceOf(address(this));
    wrappedMarket.transferFrom(msg.sender, address(this), assets);
    shares = wrappedMarket.scaledBalanceOf(address(this)) - scaledBefore;
    if (shares == 0) revert ZeroShares();
    balanceOf[receiver] += shares;
    totalSupply += shares;
    emit Transfer(address(0), receiver, shares);
  }

  function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
    if (shares == 0) revert ZeroShares();
    if (msg.sender != owner) {
      uint256 allowed = allowance[owner][msg.sender];
      if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
    }
    // Half-up rounding, matching the real wrapper (and the market's transfer scaling)
    assets = (shares * wrappedMarket.scaleFactor() + RAY / 2) / RAY;
    if (assets == 0) revert ZeroAssets();
    balanceOf[owner] -= shares;
    totalSupply -= shares;
    wrappedMarket.transfer(receiver, assets);
    emit Transfer(owner, address(0), shares);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function market() external view override returns (address) {
    return address(wrappedMarket);
  }

  function convertToShares(uint256 assets) public view override returns (uint256) {
    return assets * RAY / wrappedMarket.scaleFactor();
  }

  function convertToAssets(uint256 shares) public view override returns (uint256) {
    return shares * wrappedMarket.scaleFactor() / RAY;
  }

  function asset() external view override returns (address) {
    return address(wrappedMarket);
  }

  function totalAssets() external view override returns (uint256) {
    return wrappedMarket.balanceOf(address(this));
  }

  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  function maxMint(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  function maxWithdraw(address owner) external view override returns (uint256) {
    return convertToAssets(balanceOf[owner]);
  }

  function maxRedeem(address owner) external view override returns (uint256) {
    return balanceOf[owner];
  }

  function previewDeposit(uint256 assets) external view override returns (uint256) {
    return convertToShares(assets);
  }

  function previewMint(uint256 shares) external view override returns (uint256) {
    return convertToAssets(shares);
  }

  function previewWithdraw(uint256 assets) external view override returns (uint256) {
    return convertToShares(assets);
  }

  function previewRedeem(uint256 shares) external view override returns (uint256) {
    return convertToAssets(shares);
  }

  function mint(uint256, address) external pure override returns (uint256) {
    revert("MockWildcat4626Wrapper: mint not implemented");
  }

  function withdraw(uint256, address, address) external pure override returns (uint256) {
    revert("MockWildcat4626Wrapper: withdraw not implemented");
  }
}
