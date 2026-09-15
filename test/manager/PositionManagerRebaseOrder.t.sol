// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {IMorpho, Id, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {ReentrantCollateral} from "../mock/manager/ReentrantCollateral.sol";

/// @title PositionManagerRebaseOrderTest
/// @notice The performance reference must be rebased (and the rebalance loss checked) before
///         any outgoing token transfer: a callback-capable token hands control to the receiver
///         mid-call, and a direct Morpho supply/repay on behalf of a module during that window
///         must not land inside the new reference or mask a rebalance loss.
contract PositionManagerRebaseOrderTest is PositionManagerBaseTest {
  using MarketParamsLib for MarketParams;
  using FixedPointMathLib for uint256;
  using LibClone for address;

  uint24 constant PERF_FEE = 1500; // 15%

  ReentrantCollateral public cbCollateral;
  PositionManager public cbPm;
  MorphoBorrowPosition public cbModule;
  MarketParams public cbMarketParams;
  Id public cbMarketId;
  DonatingActor public actor;

  function setUp() public override {
    super.setUp();

    // A market whose collateral token hands control to the recipient on every transfer.
    cbCollateral = new ReentrantCollateral();
    vm.label(address(cbCollateral), "CallbackCollateral");
    cbMarketParams = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(cbCollateral),
      oracle: address(oracle),
      irm: address(0),
      lltv: DEFAULT_LLTV
    });
    vm.prank(owner);
    morpho.createMarket(cbMarketParams);
    cbMarketId = cbMarketParams.id();
    _supplyLiquidity(cbMarketParams, 100_000e18);

    cbPm = PositionManager(address(new PositionManager()).clone());
    cbPm.initialize(
      owner,
      PositionManagerMetadata({
        name: "Callback PM", symbol: "CPM", collateralAsset: address(cbCollateral), debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );
    cbModule = MorphoBorrowPosition(
      borrowPositionFactory.createBorrowPosition(cbMarketId, address(cbPm), BP_SAFE_LTV, BP_LIQUIDATION_LTV)
    );
    vm.label(address(cbPm), "CallbackPM");
    vm.label(address(cbModule), "CallbackModule");

    actor = new DonatingActor(cbPm, morpho, cbMarketParams, cbCollateral, address(cbModule));
    vm.label(address(actor), "DonatingActor");

    vm.startPrank(owner);
    cbPm.addBorrowModule(address(cbModule));
    cbPm.grantRoles(address(actor), _ROLE_MINTER);
    cbPm.grantRoles(rebalancer, _ROLE_REBALANCER);
    cbPm.grantRoles(curator, _ROLE_CURATOR);
    cbPm.setFeeData(feeRecipient, 0, PERF_FEE);
    cbPm.setRebalanceConfig(1000, 0);
    vm.stopPrank();

    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](1);
    supplyQueue[0] = SupplyQueueEntry({position: address(cbModule), maxBorrow: uint96(type(uint96).max)});
    address[] memory withdrawalQueue = new address[](1);
    withdrawalQueue[0] = address(cbModule);
    vm.startPrank(curator);
    cbPm.setSupplyQueue(supplyQueue);
    cbPm.setWithdrawalQueue(withdrawalQueue);
    vm.stopPrank();

    cbCollateral.setBalance(address(actor), 50_000e18);
    debtToken.setBalance(address(actor), 50_000e18);
    vm.prank(address(actor));
    debtToken.approve(address(cbPm), type(uint256).max);
  }

  function _cbLastTotalAssets() internal view returns (uint256 lastTotalAssets_) {
    (,,, lastTotalAssets_,,) = cbPm.feeData();
  }

  /// @dev Expected perf fee shares for a basis on cbPm, replicating `_pendingFees` (perf-only).
  function _cbExpectedPerfShares(uint256 basis) internal view returns (uint256) {
    uint256 feeAssets = basis * PERF_FEE / 10_000;
    return feeAssets * (cbPm.totalSupply() + cbPm.virtualShareOffset()) / (cbPm.totalAssets() - feeAssets + 1);
  }

  /// @notice A donation made from the collateral transfer callback of `burn()` must land after
  ///         the reference, not inside it, and is then charged as performance like any external
  ///         donation.
  function test_burn_referenceExcludesCallbackDonation() public {
    actor.doDeposit(10_000e18, 3_000e18);
    uint256 sharesTotal = cbPm.balanceOf(address(actor));

    cbCollateral.setCallbackEnabled(true);
    actor.arm(500e18);
    actor.doBurn(sharesTotal / 2);
    cbCollateral.setCallbackEnabled(false);
    assertEq(actor.donationAmount(), 0, "the callback donation executed");

    // The reference anchors on the post-flow module state; the donated 500 stays out of it.
    assertEq(cbPm.lastDebt(), cbPm.debtAmount(), "reference debt anchors on the post-flow debt");
    assertEq(_cbLastTotalAssets(), cbPm.totalAssets() - 500e18, "the donation stays out of the reference");

    // The next accrual charges the donation as a gain, at the levered slice capped by the true
    // NAV increase.
    uint256 refDebt = cbPm.lastDebt();
    uint256 refCollat = _cbLastTotalAssets() + refDebt;
    uint256 debtNow = cbPm.debtAmount();
    uint256 levered = refDebt.mulDivUp(cbPm.totalAssets() + debtNow, refCollat) - debtNow;
    uint256 basis = levered.min(cbPm.totalAssets() - _cbLastTotalAssets());
    uint256 expectedShares = _cbExpectedPerfShares(basis);
    assertGt(expectedShares, 0, "the donation is fee-bearing");
    vm.prank(owner);
    cbPm.setFeeData(feeRecipient, 0, PERF_FEE);
    assertEq(cbPm.balanceOf(feeRecipient), expectedShares, "the callback donation is charged as performance");
  }

  /// @notice A donation made from the excess-collateral transfer callback of `rebalance()` must
  ///         land after the reference, not inside it.
  function test_rebalance_referenceExcludesCallbackDonation() public {
    actor.doDeposit(10_000e18, 3_000e18);

    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(cbModule), operationType: RebalancingOperationType.WITHDRAW, amount: 500e18
    });
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    cbCollateral.setCallbackEnabled(true);
    actor.arm(400e18);
    vm.prank(rebalancer);
    cbPm.rebalance(data, address(actor));
    cbCollateral.setCallbackEnabled(false);
    assertEq(actor.donationAmount(), 0, "the callback donation executed");

    // Module state at the rebase: 9_500 collateral against 3_000 debt; the donated 400 landed
    // after it.
    assertEq(cbPm.lastDebt(), 3_000e18, "reference debt anchors on the post-rebalance debt");
    assertEq(_cbLastTotalAssets(), cbPm.totalAssets() - 400e18, "the donation stays out of the reference");
  }

  /// @notice The rebalance loss check runs before the outgoing transfers, so a receiver callback
  ///         can no longer donate the withdrawn collateral back to mask a loss that must revert.
  function test_rebalance_callbackDonationCannotMaskLoss() public {
    actor.doDeposit(10_000e18, 3_000e18);
    vm.prank(owner);
    cbPm.setRebalanceConfig(100, 0);

    // Withdraw ~7% of NAV as excess with a 1% loss cap; the armed donation would fully restore
    // the module during the transfer window.
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(cbModule), operationType: RebalancingOperationType.WITHDRAW, amount: 500e18
    });
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    cbCollateral.setCallbackEnabled(true);
    actor.arm(500e18);
    vm.prank(rebalancer);
    vm.expectRevert(LibManagerErrors.RebalanceLossExceedsMax.selector);
    cbPm.rebalance(data, address(actor));
  }
}

/// @notice Minter/receiver that donates collateral straight to Morpho on behalf of the borrow
///         module from inside the collateral token's transfer callback, standing in for an
///         ERC777-style receiver abusing the transfer window.
contract DonatingActor {
  PositionManager public immutable pm;
  IMorpho public immutable morpho;
  ReentrantCollateral public immutable collateral;
  address public immutable module;
  MarketParams internal marketParams;

  uint256 public donationAmount;

  constructor(
    PositionManager pm_,
    IMorpho morpho_,
    MarketParams memory marketParams_,
    ReentrantCollateral collateral_,
    address module_
  ) {
    pm = pm_;
    morpho = morpho_;
    marketParams = marketParams_;
    collateral = collateral_;
    module = module_;
    collateral_.approve(address(pm_), type(uint256).max);
    collateral_.approve(address(morpho_), type(uint256).max);
  }

  function arm(uint256 amount) external {
    donationAmount = amount;
  }

  /// @dev Called by ReentrantCollateral on every transfer to this contract.
  function onTokenReceived() external {
    uint256 amount = donationAmount;
    if (amount == 0) return;
    donationAmount = 0;
    morpho.supplyCollateral(marketParams, amount, module, "");
  }

  function doDeposit(uint256 collateralAmount, uint256 debtAmount) external returns (int256) {
    return pm.deposit(collateralAmount, debtAmount);
  }

  function doBurn(uint256 shares) external returns (uint256, uint256) {
    return pm.burn(shares, WithdrawalStrategy.PROPORTIONAL);
  }
}
