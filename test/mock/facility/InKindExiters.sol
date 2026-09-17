// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IInKindExitCallback} from "src/interfaces/facility/IInKindExitCallback.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {IMorpho, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title BaseExiter
/// @notice Shared skeleton for in-kind exit callback mocks: holds the facility/PM/token
///         references, records every callback invocation and refuses callbacks not issued by the
///         facility. Subclasses implement `_onExit`.
abstract contract BaseExiter is IInKindExitCallback {
  error NotFacility(address caller);

  IInKindFacility public immutable facility;
  PositionManager public immutable pm;
  MockERC20 public immutable debtToken;

  uint256 public callCount;
  address public lastPm;
  uint256 public lastShares;
  uint256 public lastDebtIn;
  bytes public lastData;

  constructor(IInKindFacility facility_, PositionManager pm_, MockERC20 debtToken_) {
    facility = facility_;
    pm = pm_;
    debtToken = debtToken_;
  }

  /// @inheritdoc IInKindExitCallback
  function onInKindExit(address positionManager, uint256 shares, uint256 debtIn, bytes calldata data) external {
    if (msg.sender != address(facility)) revert NotFacility(msg.sender);
    callCount++;
    lastPm = positionManager;
    lastShares = shares;
    lastDebtIn = debtIn;
    lastData = data;
    _onExit(positionManager, shares, debtIn, data);
  }

  /// @dev Approves the PM shares then exits through the facility from this contract.
  function exit(uint256 shares, uint256 maxDebtIn, uint256 minUnderlyingOut, address receiver, bytes calldata data)
    external
    returns (uint256 underlyingOut, uint256 debtIn)
  {
    pm.approve(address(facility), shares);
    return facility.exit(address(pm), shares, maxDebtIn, minUnderlyingOut, receiver, data);
  }

  /// @dev Pre-approves the facility for the debt asset (the no-callback path).
  function approveDebt(uint256 amount) external {
    debtToken.approve(address(facility), amount);
  }

  function _onExit(address positionManager, uint256 shares, uint256 debtIn, bytes calldata data) internal virtual;
}

/// @notice Checks the preview matches the callback figure, then approves exactly `debtIn`.
contract ApproveExactExiter is BaseExiter {
  error PreviewMismatch(uint256 preview, uint256 debtIn);

  constructor(IInKindFacility facility_, PositionManager pm_, MockERC20 debtToken_)
    BaseExiter(facility_, pm_, debtToken_)
  {}

  function _onExit(address positionManager, uint256 shares, uint256 debtIn, bytes calldata) internal override {
    (,,, uint256 preview) = facility.previewExit(positionManager, shares);
    if (preview != debtIn) revert PreviewMismatch(preview, debtIn);
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Snapshots every PM view, the facility's exit cap word and the share balances of the
///         facility and the fee recipient from inside the callback, then approves exactly `debtIn`.
contract ViewReaderExiter is BaseExiter {
  struct Snapshot {
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 pfTotalAssets;
    uint256 pfTotalSupply;
    uint256 pfMgmtShares;
    uint256 pfPerfShares;
    uint256 collateralAmount;
    uint256 debtAmount;
    bool hasBadDebt;
    uint256 facilityBalance;
    uint256 selfBalance;
    uint256 feeRecipientBalance;
    uint256 exitCap;
  }

  Snapshot internal snap;

  constructor(IInKindFacility facility_, PositionManager pm_, MockERC20 debtToken_)
    BaseExiter(facility_, pm_, debtToken_)
  {}

  function snapshot() external view returns (Snapshot memory) {
    return snap;
  }

  function _onExit(address positionManager, uint256, uint256 debtIn, bytes calldata) internal override {
    snap.totalAssets = pm.totalAssets();
    snap.totalSupply = pm.totalSupply();
    (snap.pfTotalAssets, snap.pfTotalSupply, snap.pfMgmtShares, snap.pfPerfShares) = pm.pendingFees();
    snap.collateralAmount = pm.collateralAmount();
    snap.debtAmount = pm.debtAmount();
    snap.hasBadDebt = pm.hasBadDebt();
    snap.facilityBalance = pm.balanceOf(address(facility));
    snap.selfBalance = pm.balanceOf(address(this));
    (address feeRecipient,,) = facility.config();
    snap.feeRecipientBalance = pm.balanceOf(feeRecipient);
    snap.exitCap = facility.getExit(positionManager).cap;
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Base for mocks that touch the Morpho market inside the callback.
abstract contract MorphoExiter is BaseExiter {
  IMorpho public immutable morpho;
  address public immutable borrowPosition;
  MarketParams internal _marketParams;

  constructor(
    IInKindFacility facility_,
    PositionManager pm_,
    MockERC20 debtToken_,
    IMorpho morpho_,
    MarketParams memory marketParams_,
    address borrowPosition_
  ) BaseExiter(facility_, pm_, debtToken_) {
    morpho = morpho_;
    _marketParams = marketParams_;
    borrowPosition = borrowPosition_;
  }
}

/// @notice Repays `abi.decode(data, (uint256))` debt on Morpho on behalf of the borrow module
///         inside the callback (moves the PM's debt below the mirror), then approves `debtIn`.
contract RepayOnBehalfExiter is MorphoExiter {
  constructor(
    IInKindFacility facility_,
    PositionManager pm_,
    MockERC20 debtToken_,
    IMorpho morpho_,
    MarketParams memory marketParams_,
    address borrowPosition_
  ) MorphoExiter(facility_, pm_, debtToken_, morpho_, marketParams_, borrowPosition_) {}

  function _onExit(address, uint256, uint256 debtIn, bytes calldata data) internal override {
    uint256 repayAssets = abi.decode(data, (uint256));
    debtToken.approve(address(morpho), repayAssets);
    morpho.repay(_marketParams, repayAssets, 0, borrowPosition, "");
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Wraps `abi.decode(data, (uint256))` underlying and supplies it as collateral on Morpho
///         on behalf of the borrow module inside the callback (a donation to the pool), then
///         approves `debtIn`.
contract SupplyCollateralExiter is MorphoExiter {
  MockERC20 public immutable underlying;
  WrappedAsset public immutable collateral;

  constructor(
    IInKindFacility facility_,
    PositionManager pm_,
    MockERC20 debtToken_,
    IMorpho morpho_,
    MarketParams memory marketParams_,
    address borrowPosition_,
    MockERC20 underlying_,
    WrappedAsset collateral_
  ) MorphoExiter(facility_, pm_, debtToken_, morpho_, marketParams_, borrowPosition_) {
    underlying = underlying_;
    collateral = collateral_;
  }

  function _onExit(address, uint256, uint256 debtIn, bytes calldata data) internal override {
    uint256 donation = abi.decode(data, (uint256));
    underlying.approve(address(collateral), donation);
    collateral.mint(address(this), donation);
    collateral.approve(address(morpho), donation);
    morpho.supplyCollateral(_marketParams, donation, borrowPosition, "");
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Materializes pending Morpho interest inside the callback (no economic change: the
///         mirror already priced the accrual), then approves `debtIn`.
contract AccrueInterestExiter is MorphoExiter {
  constructor(
    IInKindFacility facility_,
    PositionManager pm_,
    MockERC20 debtToken_,
    IMorpho morpho_,
    MarketParams memory marketParams_,
    address borrowPosition_
  ) MorphoExiter(facility_, pm_, debtToken_, morpho_, marketParams_, borrowPosition_) {}

  function _onExit(address, uint256, uint256 debtIn, bytes calldata) internal override {
    morpho.accrueInterest(_marketParams);
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Flash-funded exit wrapping the whole `exit`: borrows `loan` debt asset from Morpho,
///         exits inside the flash frame with the callback approving exactly `debtIn`, then
///         repays the loan from the leftover plus its own balance.
contract FlashWrappedExiter is MorphoExiter, IMorphoFlashLoanCallback {
  error NotMorpho(address caller);

  uint256 public flashAssets;
  uint256 public flashExitOut;
  uint256 public flashExitDebtIn;

  constructor(
    IInKindFacility facility_,
    PositionManager pm_,
    MockERC20 debtToken_,
    IMorpho morpho_,
    MarketParams memory marketParams_,
    address borrowPosition_
  ) MorphoExiter(facility_, pm_, debtToken_, morpho_, marketParams_, borrowPosition_) {}

  function flashExit(uint256 shares, uint256 loan, address receiver) external {
    morpho.flashLoan(address(debtToken), loan, abi.encode(shares, receiver));
  }

  function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
    if (msg.sender != address(morpho)) revert NotMorpho(msg.sender);
    flashAssets = assets;
    (uint256 shares, address receiver) = abi.decode(data, (uint256, address));
    pm.approve(address(facility), shares);
    (flashExitOut, flashExitDebtIn) =
      facility.exit(address(pm), shares, type(uint256).max, 0, receiver, abi.encode(true));
    debtToken.approve(address(morpho), assets);
  }

  function _onExit(address, uint256, uint256 debtIn, bytes calldata) internal override {
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Takes a flash loan INSIDE the exit callback and repays it from its own pre-funded
///         balance, then approves `debtIn`.
/// @dev The exit proceeds cannot fund the flash repayment: the facility delivers the underlying
///      only after `onInKindExit` returns (burn + unwrap run after the callback frame), while
///      Morpho pulls the loan back before `flashLoan` returns, i.e. still inside the callback.
///      A proceeds-funded flash exit must wrap the whole `exit` call (see FlashWrappedExiter).
contract FlashInCallbackExiter is MorphoExiter, IMorphoFlashLoanCallback {
  error NotMorpho(address caller);

  uint256 public flashAssets;
  uint256 public balanceInsideFlash;

  constructor(
    IInKindFacility facility_,
    PositionManager pm_,
    MockERC20 debtToken_,
    IMorpho morpho_,
    MarketParams memory marketParams_,
    address borrowPosition_
  ) MorphoExiter(facility_, pm_, debtToken_, morpho_, marketParams_, borrowPosition_) {}

  function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
    if (msg.sender != address(morpho)) revert NotMorpho(msg.sender);
    flashAssets = assets;
    balanceInsideFlash = debtToken.balanceOf(address(this));
    debtToken.approve(address(morpho), assets);
  }

  function _onExit(address, uint256, uint256 debtIn, bytes calldata) internal override {
    morpho.flashLoan(address(debtToken), debtIn, abi.encode(debtIn));
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Re-enters the facility from the callback. The mode is `abi.decode(data, (uint8))`:
///         0 = exit, 1 = enter, 2 = previewExit (view, must pass).
contract ReenterExiter is BaseExiter {
  uint256 public previewDebtInFromCallback;

  constructor(IInKindFacility facility_, PositionManager pm_, MockERC20 debtToken_)
    BaseExiter(facility_, pm_, debtToken_)
  {}

  function _onExit(address positionManager, uint256 shares, uint256 debtIn, bytes calldata data) internal override {
    uint8 mode = abi.decode(data, (uint8));
    if (mode == 0) {
      facility.exit(positionManager, shares, type(uint256).max, 0, address(this), "");
    } else if (mode == 1) {
      facility.enter(positionManager, 1, 0, type(uint256).max, 0, address(this));
    } else {
      (previewDebtInFromCallback,,,) = facility.previewExit(positionManager, shares);
    }
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Pushes `debtIn` directly to the facility instead of approving it (settlement is
///         pull-only, so the exit must fail on the allowance pull).
contract DirectTransferExiter is BaseExiter {
  constructor(IInKindFacility facility_, PositionManager pm_, MockERC20 debtToken_)
    BaseExiter(facility_, pm_, debtToken_)
  {}

  function _onExit(address, uint256, uint256 debtIn, bytes calldata) internal override {
    debtToken.transfer(address(facility), debtIn);
  }
}

/// @notice Does nothing in the callback.
contract NoopExiter is BaseExiter {
  constructor(IInKindFacility facility_, PositionManager pm_, MockERC20 debtToken_)
    BaseExiter(facility_, pm_, debtToken_)
  {}

  function _onExit(address, uint256, uint256, bytes calldata) internal override {}
}

/// @notice Facilitator-role contract: raises the exit offer fee to `abi.decode(data, (uint24))`
///         from inside the callback, then approves `debtIn`.
contract FacilitatorExiter is BaseExiter {
  constructor(IInKindFacility facility_, PositionManager pm_, MockERC20 debtToken_)
    BaseExiter(facility_, pm_, debtToken_)
  {}

  function _onExit(address positionManager, uint256, uint256 debtIn, bytes calldata data) internal override {
    uint24 newFeeBps = abi.decode(data, (uint24));
    facility.setExit(positionManager, LibCaps.MAX_ABSOLUTE, type(uint40).max, newFeeBps);
    debtToken.approve(address(facility), debtIn);
  }
}
