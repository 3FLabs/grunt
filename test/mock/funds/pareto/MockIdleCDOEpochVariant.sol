// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IIdleCDOEpochVariant} from "src/interfaces/integrations/pareto/IIdleCDOEpochVariant.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {MockERC20} from "../../MockERC20.sol";
import {MockIdleCreditVault} from "./MockIdleCreditVault.sol";

/// @dev Mock IdleCDOEpochVariant for testing ParetoFund.
///      Simulates the CDO's deposit/withdraw lifecycle with epoch-based withdrawals.
contract MockIdleCDOEpochVariant is IIdleCDOEpochVariant {
  using SafeTransferLib for address;

  address public _underlying;
  MockERC20 public _aaTranche;
  MockIdleCreditVault public _strategy;

  uint256 public _virtualPrice = 1e6;
  bool public _isEpochRunning;
  uint256 public _epochEndDate;
  mapping(address => bool) public _walletAllowed;
  uint256 public _claimAmountOverride;
  uint256 public _epochDiscountBps;

  constructor(address underlying_, address aaTranche_, address strategy_) {
    _underlying = underlying_;
    _aaTranche = MockERC20(aaTranche_);
    _strategy = MockIdleCreditVault(strategy_);
    _walletAllowed[address(0)] = false;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  IIdleCDOEpochVariant VIEWS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function AATranche() external view override returns (address) {
    return address(_aaTranche);
  }

  function token() external view override returns (address) {
    return _underlying;
  }

  function strategy() external view override returns (address) {
    return address(_strategy);
  }

  function virtualPrice(address) external view override returns (uint256) {
    return _virtualPrice;
  }

  function isEpochRunning() external view override returns (bool) {
    return _isEpochRunning;
  }

  function epochEndDate() external view override returns (uint256) {
    return _epochEndDate;
  }

  function isWalletAllowed(address wallet) external view override returns (bool) {
    return _walletAllowed[wallet];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                IIdleCDOEpochVariant MUTATIONS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function depositAA(uint256 amount) external override returns (uint256) {
    require(!_isEpochRunning, "MockCDO: paused during epoch");
    // Pull underlying from caller
    _underlying.safeTransferFrom(msg.sender, address(this), amount);
    // Mint AA tranche tokens to caller based on virtualPrice
    // AA tranche is 18 decimals, underlying is 6 decimals
    // mintAmount = amount * 1e18 / virtualPrice (scaled from 6 to 18 decimals)
    uint256 mintAmount = amount * 1e18 / _virtualPrice;
    _aaTranche.mint(msg.sender, mintAmount);
    return mintAmount;
  }

  function depositDuringEpoch(uint256 amount, address) external override returns (uint256) {
    require(_isEpochRunning, "MockCDO: epoch not running");
    // Pull underlying from caller
    _underlying.safeTransferFrom(msg.sender, address(this), amount);
    // The real CDO mints at a future end-of-epoch price, which is higher than the current
    // virtualPrice (because it includes expected interest). This means the depositor receives
    // fewer tokens than depositAA would give at the same virtualPrice.
    uint256 mintAmount = amount * 1e18 / _virtualPrice;
    if (_epochDiscountBps > 0) {
      mintAmount = mintAmount * (10_000 - _epochDiscountBps) / 10_000;
    }
    _aaTranche.mint(msg.sender, mintAmount);
    return mintAmount;
  }

  function requestWithdraw(uint256 amount, address) external override returns (uint256) {
    // Burn AA tranche tokens directly from caller (matches real IdleCDO behavior — no approval needed)
    _aaTranche.burn(msg.sender, amount);
    // Convert AA tranche amount to underlying amount
    uint256 underlyingAmount = amount * _virtualPrice / 1e18;
    // Register withdrawal in strategy
    uint256 epoch = _strategy.epochNumber();
    _strategy.registerWithdraw(msg.sender, underlyingAmount, epoch);
    return epoch;
  }

  function claimWithdrawRequest() external override {
    uint256 amount = _strategy.withdrawsRequests(msg.sender);
    require(amount > 0, "MockCDO: no withdrawal");
    uint256 lastEpoch = _strategy.lastWithdrawRequest(msg.sender);
    uint256 currentEpoch = _strategy.epochNumber();
    require(_epochEndDate == 0 || currentEpoch > lastEpoch, "MockCDO: epoch not ended");
    _strategy.clearWithdraw(msg.sender);
    // Transfer underlying to caller — use override if set
    uint256 transferAmount = _claimAmountOverride > 0 ? _claimAmountOverride : amount;
    _underlying.safeTransfer(msg.sender, transferAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST HELPERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setWalletAllowed(address wallet, bool allowed) external {
    _walletAllowed[wallet] = allowed;
  }

  function setClaimAmountOverride(uint256 amount) external {
    _claimAmountOverride = amount;
  }

  function setVirtualPrice(uint256 price) external {
    _virtualPrice = price;
  }

  function setEpochEndDate(uint256 date) external {
    _epochEndDate = date;
  }

  function setIsEpochRunning(bool running) external {
    _isEpochRunning = running;
  }

  function setEpochDiscountBps(uint256 discountBps) external {
    _epochDiscountBps = discountBps;
  }

  /// @dev Advances the epoch: clears epochEndDate and increments strategy epoch number.
  ///      This makes pending withdrawals claimable.
  function advanceEpoch() external {
    _epochEndDate = 0;
    _strategy.advanceEpoch();
  }

  /// @dev Funds the CDO with underlying tokens so claimWithdrawRequest can transfer them.
  function fundUnderlying(uint256 amount) external {
    MockERC20(_underlying).mint(address(this), amount);
  }
}
