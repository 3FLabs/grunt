// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {RetargetterBaseTest} from "test/manager/rebalancer/RetargetterBase.t.sol";
import {MockRetargetterFund} from "test/mock/manager/rebalancer/MockRetargetterFund.sol";
import {MorphoFlashLoanAdapter} from "src/manager/rebalancer/MorphoFlashLoanAdapter.sol";
import {IRetargetter} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {IFlashLoanModule} from "src/interfaces/manager/rebalancer/IFlashLoanModule.sol";
import {IFlashLoanReceiver} from "src/interfaces/manager/rebalancer/IFlashLoanReceiver.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {RebalancingOperationType} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @dev Position manager stub returning a pair that does not match the Retargetter's bound
///      assets; startSyncRetargetting reads only assets() before reverting AssetMismatch.
contract MismatchedPairPositionManager {
  address internal immutable COLLATERAL_ASSET;
  address internal immutable DEBT_ASSET;

  constructor(address collateralAsset_, address debtAsset_) {
    COLLATERAL_ASSET = collateralAsset_;
    DEBT_ASSET = debtAsset_;
  }

  function assets() external view returns (address, address) {
    return (COLLATERAL_ASSET, DEBT_ASSET);
  }
}

/// @dev Flash-loan module calling the receiver back with one token more than the requested
///      amount, without moving any funds. The Retargetter must reject the mismatched amount.
contract WrongAmountFlashLoanModule is IFlashLoanModule {
  function flashLoan(address, uint256 amount, bytes calldata data) external {
    IFlashLoanReceiver(msg.sender).onFlashLoan(amount + 1, data);
  }
}

/// @dev Flash-loan module replaying the callback after the first one returns, without moving
///      any funds. The second call must revert: the Retargetter zeroes its expected-module
///      transient slot on callback entry, making the callback single-shot.
contract ReplayingFlashLoanModule is IFlashLoanModule {
  function flashLoan(address, uint256 amount, bytes calldata data) external {
    IFlashLoanReceiver(msg.sender).onFlashLoan(amount, data);
    IFlashLoanReceiver(msg.sender).onFlashLoan(amount, data);
  }
}

/// @dev Third party attempting a privileged Retargetter call while a flash-loan window is
///      open. Window authority is bound to the module address, so the call must revert
///      Unauthorized before reaching any other check.
contract WindowThirdParty {
  function callPrivileged(address retargetter) external {
    IRetargetter(retargetter).cancelOrder();
  }
}

/// @dev Flash-loan module handing execution control to a third-party contract mid-window,
///      without moving any funds: the shape of any untrusted contract gaining control while
///      the window is open.
contract ThirdPartyCallerFlashLoanModule is IFlashLoanModule {
  WindowThirdParty public immutable thirdParty = new WindowThirdParty();

  function flashLoan(address, uint256, bytes calldata) external {
    thirdParty.callPrivileged(msg.sender);
  }
}

/// @dev Mock fund recording the Retargetter's operation shape when cancel executes inside a
///      flash-loan window, making the intentionally transaction-scoped in-window state
///      (active with a zero Request) observable to a test.
contract WindowProbeFund is MockRetargetterFund {
  bool public probed;
  bool public sawActive;
  address public sawRequest;

  constructor(address asset_, address share_) MockRetargetterFund(asset_, share_) {}

  function cancel(Order calldata order) public override returns (State) {
    probed = true;
    sawActive = IRetargetter(msg.sender).isActive();
    (, sawRequest,,,,,,) = IRetargetter(msg.sender).operation();
    return super.cancel(order);
  }
}

/// @title RetargetterSyncTest
/// @notice SYNC flash-loan window integration tests: both direction happy paths through the
///         real Morpho + adapter chain, atomic-revert scenarios, start guards, window nesting,
///         callback authentication and window authority.
contract RetargetterSyncTest is RetargetterBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Starts a SYNC operation as the rebalancer with the default stack.
  function _startSync(uint256 amount, bytes[] memory calls) internal {
    vm.prank(rebalancer);
    retargetter.startSyncRetargetting(address(positionManager), address(flashLoanAdapter), amount, address(fund), calls);
  }

  /// @dev LTV-up payload: subscribe the loan into the fund, supply the settled shares with
  ///      the full-balance sentinel, borrow exactly the flash repayment.
  function _syncUpPayload(uint256 amount, bytes32 salt) internal view returns (bytes[] memory calls) {
    calls = new bytes[](4);
    calls[0] = abi.encodeCall(retargetter.create, (_order(Mode.DEPOSIT, amount, amount, salt)));
    calls[1] = abi.encodeCall(retargetter.commit, ());
    calls[2] = abi.encodeCall(retargetter.unlock, ());
    calls[3] = abi.encodeCall(
      retargetter.rebalance,
      (_rebalancingData2(
          MAX_SENTINEL, 0, RebalancingOperationType.SUPPLY, MAX_SENTINEL, RebalancingOperationType.BORROW, amount
        ))
    );
  }

  /// @dev LTV-down payload: repay and free exactly the loan, then redeem the freed shares
  ///      into the flash repayment (exact proceeds at share price 1e18).
  function _syncDownPayload(uint256 amount, bytes32 salt) internal view returns (bytes[] memory calls) {
    calls = new bytes[](4);
    calls[0] = abi.encodeCall(
      retargetter.rebalance,
      (_rebalancingData2(0, amount, RebalancingOperationType.REPAY, amount, RebalancingOperationType.WITHDRAW, amount))
    );
    calls[1] = abi.encodeCall(retargetter.create, (_order(Mode.REDEEM, amount, amount, salt)));
    calls[2] = abi.encodeCall(retargetter.commit, ());
    calls[3] = abi.encodeCall(retargetter.unlock, ());
  }

  /// @dev Asserts that no operation state survived the window: inactive, every operation
  ///      field zeroed and no stored order.
  function _assertNoTrace() internal view {
    assertFalse(retargetter.isActive(), "no active operation");
    (
      address operationPositionManager,
      address operationRequest,
      address operationFund,
      uint40 startedAt,
      uint40 repaymentDeadline,
      uint16 operationMaxYieldBps,
      Order memory storedOrder,
      bool orderLive
    ) = retargetter.operation();
    assertEq(operationPositionManager, address(0), "position manager zeroed");
    assertEq(operationRequest, address(0), "request zeroed");
    assertEq(operationFund, address(0), "fund zeroed");
    assertEq(startedAt, 0, "startedAt zeroed");
    assertEq(repaymentDeadline, 0, "repayment deadline zeroed");
    assertEq(operationMaxYieldBps, 0, "yield cap zeroed");
    assertEq(storedOrder.input, 0, "order input zeroed");
    assertEq(storedOrder.output, 0, "order output zeroed");
    assertEq(storedOrder.salt, bytes32(0), "order salt zeroed");
    assertFalse(orderLive, "no stored order");
  }

  /// @dev Asserts the Retargetter holds none of the bound assets.
  function _assertZeroResidual() internal view {
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "zero collateral residual");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "zero debt residual");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        HAPPY PATHS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_startSyncRetargetting_upHappyPath() public {
    // LTV 0.5 with target 0.7: below target, LTV-up direction
    _seedPosition(10_000e18, 5_000e18);
    fund.setSyncSettlement(true);

    uint256 amount = 6_000e18;
    bytes[] memory calls = _syncUpPayload(amount, bytes32(uint256(1)));

    uint256 morphoDebtBefore = debtToken.balanceOf(address(morpho));

    vm.expectEmit(true, true, true, true, address(retargetter));
    emit IRetargetter.SyncRetargettingExecuted(address(positionManager), address(flashLoanAdapter), amount);
    _startSync(amount, calls);

    _assertNoTrace();
    _assertZeroResidual();
    // The flash loan is net zero on Morpho: only the intended BORROW leg moved funds out
    assertEq(debtToken.balanceOf(address(morpho)), morphoDebtBefore - amount, "flash loan repaid to Morpho");
    assertEq(debtToken.balanceOf(address(fund)), amount, "loan subscribed into the fund");
    // 11_000 debt over 16_000 collateral, at or below the 0.7 target
    assertApproxEqAbs(_currentLtv(), 0.6875e18, 1e14, "final LTV");
    assertLe(_currentLtv(), POSITION_MANAGER_LTV, "at or below target");
  }

  function test_startSyncRetargetting_downHappyPathExactProceeds() public {
    // LTV 0.5 with target 0.3: above target, LTV-down direction
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    fund.setSyncSettlement(true);

    // Exact-proceeds sizing: at share price 1e18 and a zero-fee flash loan, redeeming
    // exactly flashLoanAmount shares mints exactly the loan repayment
    uint256 amount = 2_857e18;
    assertLe(amount, retargetter.maxPrincipal(address(positionManager)), "sized at or under the cap");
    bytes[] memory calls = _syncDownPayload(amount, bytes32(uint256(1)));

    uint256 morphoDebtBefore = debtToken.balanceOf(address(morpho));
    uint256 ltvBefore = _currentLtv();

    vm.expectEmit(true, true, true, true, address(retargetter));
    emit IRetargetter.SyncRetargettingExecuted(address(positionManager), address(flashLoanAdapter), amount);
    _startSync(amount, calls);

    _assertNoTrace();
    _assertZeroResidual();
    // The flash loan is net zero on Morpho: only the intended REPAY leg moved funds in
    assertEq(debtToken.balanceOf(address(morpho)), morphoDebtBefore + amount, "repay leg landed on Morpho");
    assertEq(collateralToken.balanceOf(address(fund)), amount, "freed shares redeemed into the fund");
    assertLt(_currentLtv(), ltvBefore, "strictly improved");
    // (5_000 - 2_857) / (10_000 - 2_857), a hair above target and tolerated as improving
    assertApproxEqRel(_currentLtv(), 0.3e18, 1e15, "near target");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ATOMIC REVERTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_startSyncRetargetting_downRateDriftRevertsAtomically() public {
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    fund.setSyncSettlement(true);
    // Rate drift between off-chain sizing and execution: proceeds land 0.1% short of the
    // loan, so the adapter's repayment pull from the Retargetter fails
    fund.setSharePrice(0.999e18);

    uint256 amount = 2_857e18;
    bytes[] memory calls = _syncDownPayload(amount, bytes32(uint256(1)));

    uint256 debtBefore = positionManager.debtAmount();
    uint256 collateralBefore = positionManager.collateralAmountQuoted();

    vm.prank(rebalancer);
    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    retargetter.startSyncRetargetting(address(positionManager), address(flashLoanAdapter), amount, address(fund), calls);

    // The whole transaction reverted: no trace on the Retargetter, position untouched
    _assertNoTrace();
    _assertZeroResidual();
    assertEq(positionManager.debtAmount(), debtBefore, "debt untouched");
    assertEq(positionManager.collateralAmountQuoted(), collateralBefore, "collateral untouched");
  }

  function test_startSyncRetargetting_epochGatedVenueRevertsAtomically() public {
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    // Asynchronous settlement mirrors an epoch-gated venue: the committed order is not
    // unlockable in the same transaction, so the payload's unlock reverts
    fund.setSyncSettlement(false);

    uint256 amount = 2_857e18;
    bytes[] memory calls = _syncDownPayload(amount, bytes32(uint256(1)));

    uint256 debtBefore = positionManager.debtAmount();
    uint256 collateralBefore = positionManager.collateralAmountQuoted();

    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    retargetter.startSyncRetargetting(address(positionManager), address(flashLoanAdapter), amount, address(fund), calls);

    _assertNoTrace();
    _assertZeroResidual();
    assertEq(positionManager.debtAmount(), debtBefore, "debt untouched");
    assertEq(positionManager.collateralAmountQuoted(), collateralBefore, "collateral untouched");
  }

  function test_startSyncRetargetting_unsettledOrderRevertsOrderPending() public {
    _seedPosition(10_000e18, 5_000e18);
    uint256 amount = 1_000e18;
    // Donated debt tokens keep the flash repayment whole, so the failure is exactly the
    // window-close gate on the order the payload created but never settled
    _mintDebt(address(retargetter), amount);

    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeCall(retargetter.create, (_order(Mode.DEPOSIT, amount, amount, bytes32(uint256(1)))));
    calls[1] = abi.encodeCall(retargetter.commit, ());

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OrderPending.selector);
    retargetter.startSyncRetargetting(address(positionManager), address(flashLoanAdapter), amount, address(fund), calls);

    _assertNoTrace();
    assertEq(debtToken.balanceOf(address(retargetter)), amount, "donation restored by the revert");
    assertEq(debtToken.balanceOf(address(fund)), 0, "commit rolled back");
  }

  function test_startSyncRetargetting_spentLoanRevertsAtRepaymentPull() public {
    _seedPosition(10_000e18, 5_000e18);
    fund.setSyncSettlement(true);
    uint256 amount = 1_000e18;

    // The loan is subscribed and settled but the final rebalance is missing, so nothing
    // borrows the repayment back: the adapter's pull from the Retargetter fails
    bytes[] memory calls = new bytes[](3);
    calls[0] = abi.encodeCall(retargetter.create, (_order(Mode.DEPOSIT, amount, amount, bytes32(uint256(1)))));
    calls[1] = abi.encodeCall(retargetter.commit, ());
    calls[2] = abi.encodeCall(retargetter.unlock, ());

    vm.prank(rebalancer);
    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    retargetter.startSyncRetargetting(address(positionManager), address(flashLoanAdapter), amount, address(fund), calls);

    _assertNoTrace();
    _assertZeroResidual();
  }

  function test_startSyncRetargetting_donatedResidualRevertsResidualBalance() public {
    _seedPosition(10_000e18, 5_000e18);
    uint256 amount = 1_000e18;
    // An empty payload leaves the loan untouched (the adapter pulls it back whole); the
    // pre-window collateral donation is what trips the zero-residual gate
    _mintCollateral(address(retargetter), 5);

    bytes[] memory calls = new bytes[](0);

    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.ResidualBalance.selector, address(collateralToken), 5));
    retargetter.startSyncRetargetting(address(positionManager), address(flashLoanAdapter), amount, address(fund), calls);

    _assertNoTrace();
  }

  /// @notice Dust strictly below the configured tolerance passes the window-close gate and
  ///         stays behind.
  function test_startSyncRetargetting_dustWithinResidualTolerance_passes() public {
    _seedPosition(10_000e18, 5_000e18);
    _setResidualExponents(3, 0);
    _mintCollateral(address(retargetter), 7);

    _startSync(1_000e18, new bytes[](0));

    _assertNoTrace();
    assertEq(collateralToken.balanceOf(address(retargetter)), 7, "tolerated dust stays");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "zero debt residual");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        START GUARDS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_startSyncRetargetting_nonWhitelistedModuleReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    MorphoFlashLoanAdapter freshAdapter = new MorphoFlashLoanAdapter(address(morpho));

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.ModuleNotWhitelisted.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(freshAdapter), 1_000e18, address(fund), new bytes[](0)
    );
  }

  function test_startSyncRetargetting_nonWhitelistedFundReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    MockRetargetterFund freshFund = new MockRetargetterFund(address(debtToken), address(collateralToken));

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.FundNotWhitelisted.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(flashLoanAdapter), 1_000e18, address(freshFund), new bytes[](0)
    );
  }

  function test_startSyncRetargetting_assetMismatchReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    // Reversed pair: the position manager's assets do not match the bound pair
    MismatchedPairPositionManager mismatchedPm =
      new MismatchedPairPositionManager(address(debtToken), address(collateralToken));

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.AssetMismatch.selector);
    retargetter.startSyncRetargetting(
      address(mismatchedPm), address(flashLoanAdapter), 1_000e18, address(fund), new bytes[](0)
    );
  }

  function test_startSyncRetargetting_principalCapExceededReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    uint256 cap = retargetter.maxPrincipal(address(positionManager));

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(flashLoanAdapter), cap + 1, address(fund), new bytes[](0)
    );
  }

  function test_startSyncRetargetting_activeAsyncOperationReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(flashLoanAdapter), 1_000e18, address(fund), new bytes[](0)
    );

    assertTrue(retargetter.isActive(), "async operation still active");
  }

  function test_startSyncRetargetting_unauthorizedCallerReverts() public {
    _seedPosition(10_000e18, 5_000e18);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(flashLoanAdapter), 1_000e18, address(fund), new bytes[](0)
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       WINDOW NESTING                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_startSyncRetargetting_nestedSyncStartReverts() public {
    _seedPosition(10_000e18, 5_000e18);

    bytes[] memory inner = new bytes[](0);
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeCall(
      retargetter.startSyncRetargetting, (address(positionManager), address(flashLoanAdapter), 0, address(fund), inner)
    );

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(flashLoanAdapter), 1_000e18, address(fund), calls
    );

    _assertNoTrace();
  }

  function test_startSyncRetargetting_asyncStartInsideWindowReverts() public {
    _seedPosition(10_000e18, 5_000e18);

    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeCall(
      retargetter.startRetargetting, (address(positionManager), 0, 0, address(fund), REQUEST_NAME, REQUEST_SYMBOL)
    );

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(flashLoanAdapter), 1_000e18, address(fund), calls
    );

    _assertNoTrace();
  }

  /// @notice A SYNC window stores no Request, and that absence is what gates the ASYNC-only
  ///         steps: a resolve smuggled into the payload hits checkRequest and reverts.
  function test_startSyncRetargetting_asyncOnlyStepInsideWindowReverts() public {
    _seedPosition(10_000e18, 5_000e18);

    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeCall(retargetter.resolve, ());

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(flashLoanAdapter), 1_000e18, address(fund), calls
    );

    _assertNoTrace();
  }

  /// @notice Mid-window the operation is intentionally active with a zero Request (invariant
  ///         tests run between transactions and never observe this shape, so a fund-side
  ///         probe pins it): the window registers in the operation storage while the missing
  ///         Request gates the ASYNC-only steps.
  function test_startSyncRetargetting_windowRunsActiveWithZeroRequest() public {
    _seedPosition(10_000e18, 5_000e18);
    WindowProbeFund probeFund = new WindowProbeFund(address(debtToken), address(collateralToken));
    vm.prank(owner);
    retargetter.setFund(address(probeFund), true);

    uint256 amount = 1_000e18;
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeCall(retargetter.create, (_order(Mode.DEPOSIT, amount, amount, bytes32(uint256(1)))));
    calls[1] = abi.encodeCall(retargetter.cancelOrder, ());

    vm.prank(rebalancer);
    retargetter.startSyncRetargetting(
      address(positionManager), address(flashLoanAdapter), amount, address(probeFund), calls
    );

    assertTrue(probeFund.probed(), "probe executed inside the window");
    assertTrue(probeFund.sawActive(), "window runs with an active operation");
    assertEq(probeFund.sawRequest(), address(0), "window runs with a zero Request");
    _assertNoTrace();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  CALLBACK AUTHENTICATION                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_onFlashLoan_directCallReverts() public {
    bytes memory data = abi.encode(new bytes[](0));

    // Random caller with no window open
    vm.prank(user);
    vm.expectRevert(LibRetargetterErrors.UnauthorizedFlashLoanCallback.selector);
    retargetter.onFlashLoan(1e18, data);

    // Even the whitelisted adapter's address has no authority without a window
    vm.prank(address(flashLoanAdapter));
    vm.expectRevert(LibRetargetterErrors.UnauthorizedFlashLoanCallback.selector);
    retargetter.onFlashLoan(1e18, data);
  }

  function test_startSyncRetargetting_smuggledCallbackReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    uint256 amount = 1_000e18;

    // The payload element re-enters onFlashLoan; the sub-call runs with the module as
    // msg.sender, but the module transient slot was zeroed on the first callback entry
    bytes[] memory inner = new bytes[](0);
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeCall(retargetter.onFlashLoan, (amount, abi.encode(inner)));

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.UnauthorizedFlashLoanCallback.selector);
    retargetter.startSyncRetargetting(address(positionManager), address(flashLoanAdapter), amount, address(fund), calls);

    _assertNoTrace();
  }

  function test_startSyncRetargetting_wrongAmountCallbackReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    WrongAmountFlashLoanModule wrongAmountModule = new WrongAmountFlashLoanModule();
    vm.prank(owner);
    retargetter.setFlashLoanModule(address(wrongAmountModule), true);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.UnauthorizedFlashLoanCallback.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(wrongAmountModule), 1_000e18, address(fund), new bytes[](0)
    );

    _assertNoTrace();
  }

  function test_startSyncRetargetting_replayedCallbackReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    // Owner-whitelisted hostile module: the first callback succeeds (empty payload, no
    // funds needed), the replay after it returns must hit the zeroed module slot
    ReplayingFlashLoanModule replayingModule = new ReplayingFlashLoanModule();
    vm.prank(owner);
    retargetter.setFlashLoanModule(address(replayingModule), true);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.UnauthorizedFlashLoanCallback.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(replayingModule), 1_000e18, address(fund), new bytes[](0)
    );

    _assertNoTrace();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WINDOW AUTHORITY                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_moduleWithoutWindowReverts() public {
    _seedPosition(10_000e18, 5_000e18);

    // Outside a window the adapter's address is an ordinary unauthorized caller
    vm.prank(address(flashLoanAdapter));
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.BORROW, 1));
  }

  /// @notice Window authority belongs to the module alone: a third party gaining execution
  ///         control mid-window (here handed over by a hostile whitelisted module) stays an
  ///         ordinary unauthorized caller for every privileged function.
  function test_startSyncRetargetting_thirdPartyInsideWindowUnauthorized() public {
    _seedPosition(10_000e18, 5_000e18);
    ThirdPartyCallerFlashLoanModule hostileModule = new ThirdPartyCallerFlashLoanModule();
    vm.prank(owner);
    retargetter.setFlashLoanModule(address(hostileModule), true);

    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.startSyncRetargetting(
      address(positionManager), address(hostileModule), 1_000e18, address(fund), new bytes[](0)
    );

    _assertNoTrace();
  }

  function test_startSyncRetargetting_directionChecksEnforcedInsideWindow() public {
    // Above target (LTV 0.5, target 0.3): any non-improving rebalance must revert
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);

    uint256 amount = 100e18;
    // Donated collateral funds a SUPPLY leg so the position manager's own loss check stays
    // neutral (equal supply and borrow legs) and the direction check is what fires:
    // (5_100 / 10_100) is above target and above the 0.5 snapshot
    _mintCollateral(address(retargetter), amount);

    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeCall(
      retargetter.rebalance,
      (_rebalancingData2(amount, 0, RebalancingOperationType.SUPPLY, amount, RebalancingOperationType.BORROW, amount))
    );

    uint256 debtBefore = positionManager.debtAmount();
    uint256 collateralQuotedBefore = positionManager.collateralAmountQuoted();
    uint256 ltvBefore = debtBefore * WAD / collateralQuotedBefore;
    uint256 ltvAfter = (debtBefore + amount) * WAD / (collateralQuotedBefore + amount);

    // The owner starts the window, but msg.sender inside the payload is the module, so the
    // owner bypass never applies through a window
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.AboveTargetLtv.selector, ltvAfter, ltvBefore, 0.3e18));
    retargetter.startSyncRetargetting(address(positionManager), address(flashLoanAdapter), amount, address(fund), calls);

    _assertNoTrace();
    assertEq(positionManager.debtAmount(), debtBefore, "worsening borrow rolled back");
    assertEq(collateralToken.balanceOf(address(retargetter)), amount, "donation restored by the revert");
  }
}
