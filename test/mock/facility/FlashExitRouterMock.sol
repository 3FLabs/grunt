// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IInKindExitCallback} from "src/interfaces/facility/IInKindExitCallback.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

interface IMockFlashBorrower {
  function onFlashLoan(uint256 amount, uint256 fee, bytes calldata data) external;
}

/// @notice Flash lender charging `feeBps` (rounded up), repaid by allowance before `flashLoan` returns.
contract MockFlashLender {
  using FixedPointMathLib for uint256;

  MockERC20 public immutable token;
  uint256 public immutable feeBps;

  constructor(MockERC20 token_, uint256 feeBps_) {
    token = token_;
    feeBps = feeBps_;
  }

  function flashFee(uint256 amount) public view returns (uint256) {
    return amount.mulDivUp(feeBps, 10_000);
  }

  function flashLoan(IMockFlashBorrower borrower, uint256 amount, bytes calldata data) external {
    uint256 fee = flashFee(amount);
    token.transfer(address(borrower), amount);
    borrower.onFlashLoan(amount, fee, data);
    token.transferFrom(address(borrower), address(this), amount + fee);
  }
}

/// @notice Buys `tokenIn` for `tokenOut` at a fixed price scaled by 1e36 (the Morpho oracle scale).
contract MockSwapVenue {
  using FixedPointMathLib for uint256;

  MockERC20 public immutable tokenIn;
  MockERC20 public immutable tokenOut;
  uint256 public price;

  constructor(MockERC20 tokenIn_, MockERC20 tokenOut_, uint256 price_) {
    tokenIn = tokenIn_;
    tokenOut = tokenOut_;
    price = price_;
  }

  function setPrice(uint256 price_) external {
    price = price_;
  }

  function quote(uint256 amountIn) public view returns (uint256) {
    return amountIn.mulDiv(price, 1e36);
  }

  function sell(uint256 amountIn, address to) external returns (uint256 amountOut) {
    amountOut = quote(amountIn);
    tokenIn.transferFrom(msg.sender, address(this), amountIn);
    tokenOut.transfer(to, amountOut);
  }
}

/// @notice Instant in-kind exit to the debt asset: pulls the holder's PM shares, flash-borrows
///         `loan` of the debt asset, exits through the facility with the callback approving the
///         pull, sells the underlying on the venue, repays the loan plus fee and forwards the rest.
contract MockExitRouter is IInKindExitCallback, IMockFlashBorrower {
  using SafeTransferLib for address;

  error NotFacility(address caller);
  error NotLender(address caller);
  error InsufficientCashOut(uint256 cashOut, uint256 minCashOut);

  IInKindFacility public immutable facility;
  MockFlashLender public immutable lender;
  MockSwapVenue public immutable venue;
  MockERC20 public immutable debtToken;
  MockERC20 public immutable underlying;

  uint256 public callbackCount;
  uint256 public lastCallbackShares;
  uint256 public lastCallbackDebtIn;

  constructor(
    IInKindFacility facility_,
    MockFlashLender lender_,
    MockSwapVenue venue_,
    MockERC20 debtToken_,
    MockERC20 underlying_
  ) {
    facility = facility_;
    lender = lender_;
    venue = venue_;
    debtToken = debtToken_;
    underlying = underlying_;
  }

  function exitToDebt(address positionManager, uint256 shares, uint256 loan, uint256 minCashOut, address receiver)
    external
    returns (uint256 cashOut)
  {
    positionManager.safeTransferFrom(msg.sender, address(this), shares);
    lender.flashLoan(this, loan, abi.encode(positionManager, shares));
    cashOut = debtToken.balanceOf(address(this));
    if (cashOut < minCashOut) revert InsufficientCashOut(cashOut, minCashOut);
    debtToken.transfer(receiver, cashOut);
  }

  function onFlashLoan(uint256 amount, uint256 fee, bytes calldata data) external {
    if (msg.sender != address(lender)) revert NotLender(msg.sender);
    (address positionManager, uint256 shares) = abi.decode(data, (address, uint256));
    positionManager.safeApprove(address(facility), shares);
    facility.exit(positionManager, shares, amount, 0, address(this), abi.encode(amount));
    uint256 underlyingOut = underlying.balanceOf(address(this));
    underlying.approve(address(venue), underlyingOut);
    venue.sell(underlyingOut, address(this));
    debtToken.approve(address(lender), amount + fee);
  }

  function onInKindExit(address, uint256 shares, uint256 debtIn, bytes calldata) external {
    if (msg.sender != address(facility)) revert NotFacility(msg.sender);
    callbackCount++;
    lastCallbackShares = shares;
    lastCallbackDebtIn = debtIn;
    debtToken.approve(address(facility), debtIn);
  }
}
