// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {RetargetterBaseTest} from "./RetargetterBase.t.sol";
import {IRetargetter, YieldEstimates} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {IFlashLoanModule} from "src/interfaces/manager/rebalancer/IFlashLoanModule.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";
import {ASSETS_STORAGE_SLOT} from "src/libs/manager/rebalancer/LibRetargetterConstants.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {MockRetargetterFund} from "test/mock/manager/rebalancer/MockRetargetterFund.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @dev Fund reentering setTargetLtvOverride from inside cancel. The test makes it the
///      position manager's owner, so only the reentrancy guard can stop the call.
contract OverrideReenteringFund is MockRetargetterFund {
  constructor(address asset_, address share_) MockRetargetterFund(asset_, share_) {}

  function cancel(Order calldata order) public override returns (State) {
    IRetargetter(msg.sender).setTargetLtvOverride(IRetargetter(msg.sender).boundPositionManager(), 0.6e18);
    return super.cancel(order);
  }
}

/// @dev Flash-loan module setting the override from inside the window, before the callback.
///      The test makes it the position manager's owner and the reentrancy guard is not held
///      there, so only the idle check can stop the call.
contract OverrideSettingFlashLoanModule is IFlashLoanModule {
  function flashLoan(address, uint256, bytes calldata) external {
    IRetargetter(msg.sender).setTargetLtvOverride(IRetargetter(msg.sender).boundPositionManager(), 0.6e18);
  }
}

/// @title RetargetterTargetLtvOverrideTest
/// @notice Target LTV override: authorization, bounds, the idle-only rule, the lower-of rule
///         against the live position manager ltv, clearing on bind, storage packing, and its
///         effect on the
///         principal cap and the rebalance direction checks. The equivalence fuzz tests pin
///         that an override behaves exactly like setting the position manager's ltv to the
///         same value.
/// @dev The fixture's position manager ltv is 0.70 (the buffered target); the override
///      models the 0.60 off-chain target. Prices are 1:1 and nothing warps, so LTVs are exact.
contract RetargetterTargetLtvOverrideTest is RetargetterBaseTest {
  uint256 internal constant OVERRIDE = 0.6e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Sets the override as the fixture's position manager owner.
  function _setOverride(uint256 targetLtvOverride) internal {
    vm.prank(owner);
    retargetter.setTargetLtvOverride(address(positionManager), targetLtvOverride);
  }

  /// @dev Reads the third assets slot: position manager (bits 0..159), override (160..223).
  function _assetsSlot2() internal view returns (uint256) {
    return uint256(vm.load(address(retargetter), bytes32(uint256(ASSETS_STORAGE_SLOT) + 2)));
  }

  /// @dev The stored override, read from storage (there is no raw getter).
  function _storedOverride() internal view returns (uint256) {
    return uint64(_assetsSlot2() >> 160);
  }

  /// @dev Marks the untouched operation Request repaid, disarming the value gate.
  function _settleBridge() internal {
    vm.prank(rebalancer);
    retargetter.repay();
  }

  function _setMaxRebalanceLoss(uint16 maxLossBps) internal {
    vm.prank(owner);
    positionManager.setRebalanceConfig(maxLossBps, 0);
  }

  /// @dev Rebalances as the rebalancer, returning the outcome instead of bubbling it.
  function _tryRebalance(RebalancingData memory data) internal returns (bool ok, bytes memory ret) {
    vm.prank(rebalancer);
    (ok, ret) = address(retargetter).call(abi.encodeCall(retargetter.rebalance, (data)));
  }

  /// @dev Rebalancing data with one leg each on two positions.
  function _dataOn2(
    address firstPosition,
    RebalancingOperationType firstType,
    uint256 firstAmount,
    address secondPosition,
    RebalancingOperationType secondType,
    uint256 secondAmount
  ) internal pure returns (RebalancingData memory data) {
    data.operations = new RebalancingOperation[](2);
    data.operations[0] = RebalancingOperation({position: firstPosition, operationType: firstType, amount: firstAmount});
    data.operations[1] =
      RebalancingOperation({position: secondPosition, operationType: secondType, amount: secondAmount});
  }

  /// @dev LTV-down SYNC payload: repay and free the loan, redeem the freed shares into the
  ///      flash repayment (exact proceeds at share price 1e18).
  function _syncDownPayload(uint256 amount) internal view returns (bytes[] memory calls) {
    calls = new bytes[](4);
    calls[0] = abi.encodeCall(
      retargetter.rebalance,
      (_rebalancingData2(0, amount, RebalancingOperationType.REPAY, amount, RebalancingOperationType.WITHDRAW, amount))
    );
    calls[1] = abi.encodeCall(retargetter.create, (_order(Mode.REDEEM, amount, amount, bytes32(uint256(1)))));
    calls[2] = abi.encodeCall(retargetter.commit, ());
    calls[3] = abi.encodeCall(retargetter.unlock, ());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       AUTHORIZATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setTargetLtvOverride_positionManagerOwnerSetsAndEmits() public {
    vm.expectEmit(true, true, true, true, address(retargetter));
    emit IRetargetter.TargetLtvOverrideSet(address(positionManager), OVERRIDE);
    _setOverride(OVERRIDE);

    assertEq(_storedOverride(), OVERRIDE, "override stored");
    assertEq(retargetter.targetLtv(), OVERRIDE, "override is the effective target");
  }

  /// @notice The gate is the position manager's owner, not the Retargetter's: once the two
  ///         differ, the Retargetter owner is rejected and the new position manager owner
  ///         is accepted.
  function test_setTargetLtvOverride_gatedOnPositionManagerOwnerOnly() public {
    address pmOwner = makeAddr("pmOwner");
    vm.prank(owner);
    positionManager.transferOwnership(pmOwner);
    assertEq(retargetter.owner(), owner, "retargetter owner unchanged");

    address[3] memory rejected = [owner, rebalancer, consumer];
    for (uint256 i; i < rejected.length; ++i) {
      vm.prank(rejected[i]);
      vm.expectRevert(Ownable.Unauthorized.selector);
      retargetter.setTargetLtvOverride(address(positionManager), OVERRIDE);
    }

    vm.prank(pmOwner);
    retargetter.setTargetLtvOverride(address(positionManager), OVERRIDE);
    assertEq(retargetter.targetLtv(), OVERRIDE, "position manager owner set the override");
  }

  function testFuzz_setTargetLtvOverride_revertsForNonPositionManagerOwner(address caller, uint256 value) public {
    vm.assume(caller != owner);
    value = bound(value, 0, WAD);

    vm.prank(caller);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setTargetLtvOverride(address(positionManager), value);
  }

  /// @notice The expected position manager must be the bound one, even for its owner.
  function testFuzz_setTargetLtvOverride_revertsForWrongPositionManager(address expected, uint256 value) public {
    vm.assume(expected != address(positionManager));
    value = bound(value, 0, WAD);

    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setTargetLtvOverride(expected, value);
  }

  /// @notice A call made for one binding cannot land on the next, even when the same address
  ///         owns both position managers: the stale call reverts and the owner sets the
  ///         override again for the new binding.
  function test_setTargetLtvOverride_staleCallRevertsAfterRebind() public {
    PositionManager second = PositionManager(LibClone.clone(address(new PositionManager())));
    second.initialize(
      owner,
      PositionManagerMetadata({
        name: "Second Position Manager",
        symbol: "PMS2",
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );
    vm.prank(owner);
    retargetter.setPositionManager(address(second));

    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setTargetLtvOverride(address(positionManager), OVERRIDE);
    assertEq(_storedOverride(), 0, "stale call stores nothing");

    vm.expectEmit(true, true, true, true, address(retargetter));
    emit IRetargetter.TargetLtvOverrideSet(address(second), OVERRIDE);
    vm.prank(owner);
    retargetter.setTargetLtvOverride(address(second), OVERRIDE);
    assertEq(retargetter.targetLtv(), OVERRIDE, "override set for the new binding");
  }

  /// @notice Unbound, nothing authorizes: the previous position manager mismatches, and the
  ///         zero address fails the owner read (a low-level call, as that revert carries no
  ///         data).
  function test_setTargetLtvOverride_revertsWhileUnbound() public {
    vm.prank(owner);
    retargetter.setPositionManager(address(0));

    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.setTargetLtvOverride(address(positionManager), OVERRIDE);

    vm.prank(owner);
    (bool ok,) = address(retargetter).call(abi.encodeCall(retargetter.setTargetLtvOverride, (address(0), OVERRIDE)));
    assertFalse(ok, "unbound setter reverts");
    assertEq(_storedOverride(), 0, "nothing stored");
  }

  /// @notice The guard rejects a reentrant set from inside a guarded step, even from the
  ///         position manager's owner.
  function test_setTargetLtvOverride_reentrantCallReverts() public {
    OverrideReenteringFund reenteringFund = new OverrideReenteringFund(address(debtToken), address(collateralToken));
    _seedPosition(10_000e18, 5_000e18);
    vm.startPrank(owner);
    retargetter.setFund(address(reenteringFund), true);
    positionManager.transferOwnership(address(reenteringFund));
    vm.stopPrank();

    vm.startPrank(rebalancer);
    retargetter.startRetargetting(0, 100, address(reenteringFund), REQUEST_NAME, REQUEST_SYMBOL);
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(1))));
    vm.expectRevert(LibRetargetterErrors.Reentrancy.selector);
    retargetter.cancelOrder();
    vm.stopPrank();

    assertEq(_storedOverride(), 0, "nothing stored");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IDLE ONLY                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice An ASYNC operation freezes the override: neither a change nor a clear lands
  ///         until it resolves.
  function test_setTargetLtvOverride_revertsWhileAsyncOperationActive() public {
    _seedPosition(10_000e18, 6_900e18);
    _setOverride(OVERRIDE);
    _startAsync(0, 100);

    uint256[2] memory values = [uint256(0.65e18), 0];
    for (uint256 i; i < values.length; ++i) {
      vm.prank(owner);
      vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
      retargetter.setTargetLtvOverride(address(positionManager), values[i]);
    }
    assertEq(retargetter.targetLtv(), OVERRIDE, "override unchanged during the operation");

    _settleBridge();
    vm.prank(rebalancer);
    retargetter.resolve();
    _setOverride(0);
    assertEq(retargetter.targetLtv(), POSITION_MANAGER_LTV, "settable again once idle");
  }

  /// @notice A SYNC window counts as active: the position manager owner cannot move the
  ///         override from inside it, even where the reentrancy guard is not held.
  function test_setTargetLtvOverride_revertsInsideSyncWindow() public {
    OverrideSettingFlashLoanModule module = new OverrideSettingFlashLoanModule();
    _seedPosition(10_000e18, 5_000e18);
    vm.startPrank(owner);
    retargetter.setFlashLoanModule(address(module), true);
    positionManager.transferOwnership(address(module));
    vm.stopPrank();

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.startSyncRetargetting(address(module), 0, address(fund), new bytes[](0));
    assertEq(_storedOverride(), 0, "nothing stored");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           BOUNDS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_setTargetLtvOverride_revertsAboveWad(uint256 value) public {
    value = bound(value, WAD + 1, type(uint256).max);

    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    retargetter.setTargetLtvOverride(address(positionManager), value);
  }

  /// @notice WAD is accepted but inert (the live ltv is lower); zero unsets.
  function test_setTargetLtvOverride_wadInertAndZeroUnsets() public {
    _setOverride(WAD);
    assertEq(_storedOverride(), WAD, "wad stored");
    assertEq(retargetter.targetLtv(), POSITION_MANAGER_LTV, "wad above the live ltv is inert");

    _setOverride(OVERRIDE);
    assertEq(retargetter.targetLtv(), OVERRIDE, "override applies");

    vm.expectEmit(true, true, true, true, address(retargetter));
    emit IRetargetter.TargetLtvOverrideSet(address(positionManager), 0);
    _setOverride(0);
    assertEq(_storedOverride(), 0, "zero stored");
    assertEq(retargetter.targetLtv(), POSITION_MANAGER_LTV, "zero falls back to the live ltv");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      EFFECTIVE TARGET                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_targetLtv_defaultsToPositionManagerLtv() public view {
    assertEq(_storedOverride(), 0, "no override at creation");
    assertEq(retargetter.targetLtv(), POSITION_MANAGER_LTV, "position manager ltv");
  }

  /// @notice The effective target is the lower of a nonzero override and the live ltv, in
  ///         either update order; a later ltv change applies without touching the override.
  function testFuzz_targetLtv_isLowerOfOverrideAndLiveLtv(uint256 value, uint256 ltv, bool ltvFirst) public {
    value = bound(value, 0, WAD);
    // setLtv requires a nonzero ltv at or below every module's 0.72 safe LTV
    ltv = bound(ltv, 1, BP_SAFE_LTV);

    if (ltvFirst) _setTargetLtv(ltv);
    _setOverride(value);
    if (!ltvFirst) _setTargetLtv(ltv);

    uint256 expected = value != 0 && value < ltv ? value : ltv;
    assertEq(retargetter.targetLtv(), expected, "lower of override and live ltv");
    assertEq(_storedOverride(), value, "override untouched by setLtv");
  }

  function test_targetLtv_revertsWhileUnbound() public {
    vm.prank(owner);
    retargetter.setPositionManager(address(0));

    (bool ok,) = address(retargetter).staticcall(abi.encodeCall(retargetter.targetLtv, ()));
    assertFalse(ok, "unbound view reverts");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     BINDING AND STORAGE                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Any bind clears the override, rebinding the same manager included.
  function test_setPositionManager_rebindClearsOverride() public {
    _setOverride(OVERRIDE);

    vm.prank(owner);
    retargetter.setPositionManager(address(positionManager));

    assertEq(_storedOverride(), 0, "override cleared");
    assertEq(retargetter.targetLtv(), POSITION_MANAGER_LTV, "back to the live ltv");
  }

  function test_setPositionManager_unbindClearsOverride() public {
    _setOverride(OVERRIDE);

    vm.startPrank(owner);
    retargetter.setPositionManager(address(0));
    assertEq(_storedOverride(), 0, "override cleared on unbind");
    retargetter.setPositionManager(address(positionManager));
    vm.stopPrank();

    assertEq(_storedOverride(), 0, "rebind does not restore it");
    assertEq(retargetter.targetLtv(), POSITION_MANAGER_LTV, "back to the live ltv");
  }

  /// @notice The override packs above the position manager in the third assets slot and
  ///         uses no new slot. Before this field existed those bits were always zero, which
  ///         reads as unset, so upgraded proxies keep the position manager ltv.
  function test_storageLayout_overridePacksAbovePositionManager() public {
    _setOverride(OVERRIDE);

    uint256 slot2 = _assetsSlot2();
    assertEq(address(uint160(slot2)), address(positionManager), "position manager bits unchanged");
    assertEq(uint64(slot2 >> 160), OVERRIDE, "override bits 160..223");
    assertEq(slot2 >> 224, 0, "bits 224..255 clean");
    assertEq(vm.load(address(retargetter), bytes32(uint256(ASSETS_STORAGE_SLOT) + 3)), bytes32(0), "no new slot");

    vm.prank(owner);
    retargetter.setPositionManager(address(positionManager));
    assertEq(_assetsSlot2(), uint256(uint160(address(positionManager))), "bind clears only the override bits");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       PRINCIPAL CAP                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Book at 0.69, between the 0.60 off-chain target and the 0.70 ltv. Without the
  ///         override the cap sizes an LTV-up move toward 0.70; with it, the LTV-down move to
  ///         0.60: (6,900 - 0.6 * 10,000) / (1 - 0.6) = 2,250, plus the 1% buffer.
  function test_maxPrincipal_betweenOverrideAndLtv_sizesTowardOverride() public {
    _seedPosition(10_000e18, 6_900e18);
    assertEq(retargetter.maxPrincipal(), _gateCap(DEFAULT_MAX_YIELD_BPS), "ltv-up cap toward the ltv");
    assertLt(retargetter.maxPrincipal(), 2_250e18, "too small for the ltv-down move");

    _setOverride(OVERRIDE);
    assertEq(retargetter.maxPrincipal(), 2_272.5e18, "ltv-down cap toward the override");
  }

  /// @notice The ASYNC start gate admits the LTV-down principal only with the override.
  function test_startRetargetting_ltvDownToOverride_admittedOnlyWithOverride() public {
    _seedPosition(10_000e18, 6_900e18);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.startRetargetting(2_250e18, 100, address(fund), REQUEST_NAME, REQUEST_SYMBOL);

    _setOverride(OVERRIDE);
    _startAsync(2_250e18, 100);
    assertTrue(retargetter.isActive(), "operation started");
  }

  /// @notice End to end through the real Morpho flash loan: the LTV-down retarget to the
  ///         off-chain target is rejected at the cap without the override and lands the book
  ///         exactly on it with the override.
  function test_startSyncRetargetting_ltvDownToOverride_landsOnOverride() public {
    _seedPosition(10_000e18, 6_900e18);
    fund.setSyncSettlement(true);
    uint256 amount = 2_250e18;
    bytes[] memory calls = _syncDownPayload(amount);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.startSyncRetargetting(address(flashLoanAdapter), amount, address(fund), calls);

    _setOverride(OVERRIDE);
    vm.prank(rebalancer);
    retargetter.startSyncRetargetting(address(flashLoanAdapter), amount, address(fund), calls);

    // (6,900 - 2,250) / (10,000 - 2,250) = 0.60
    assertEq(_currentLtv(), OVERRIDE, "landed on the override");
    assertFalse(retargetter.isActive(), "window closed");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "no debt residual");
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "no collateral residual");
  }

  /// @notice The cap under an override equals the cap under the same value set as the
  ///         position manager's ltv, across book LTVs on both sides of the target and with
  ///         nonzero estimates.
  function testFuzz_maxPrincipal_overrideMatchesPositionManagerLtv(uint256 debt, uint256 target, bool withEstimates)
    public
  {
    debt = bound(debt, 100e18, 6_900e18);
    target = bound(target, 1, POSITION_MANAGER_LTV);
    _seedPosition(10_000e18, debt);
    if (withEstimates) {
      vm.prank(owner);
      retargetter.setEstimates(
        YieldEstimates({
          requestYieldRate: 0.1e18,
          borrowRate: 0.05e18,
          collateralYieldRate: 0.08e18,
          subscriptionDuration: 30 days,
          redemptionDuration: 15 days
        })
      );
    }

    uint256 snapshot = vm.snapshotState();
    _setOverride(target);
    uint256 withOverride = retargetter.maxPrincipal();
    assertEq(retargetter.targetLtv(), target, "override is the target");

    vm.revertToState(snapshot);
    _setTargetLtv(target);
    assertEq(retargetter.targetLtv(), target, "ltv is the target");
    assertEq(retargetter.maxPrincipal(), withOverride, "same cap");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      DIRECTION CHECKS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Book at 0.65: a borrow to 0.66 passes against the 0.70 ltv but reverts against
  ///         the 0.60 override (above target and not improving).
  function test_rebalance_betweenOverrideAndLtv_worseningReverts() public {
    _seedPosition(10_000e18, 6_500e18);
    _setMaxRebalanceLoss(1000);
    RebalancingData memory data = _rebalancingData(0, 0, RebalancingOperationType.BORROW, 100e18);

    uint256 snapshot = vm.snapshotState();
    _startAsync(0, 100);
    (bool ok,) = _tryRebalance(data);
    assertTrue(ok, "passes against the ltv");
    vm.revertToState(snapshot);

    _setOverride(OVERRIDE);
    _startAsync(0, 100);
    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.AboveTargetLtv.selector, 0.66e18, 0.65e18, OVERRIDE));
    retargetter.rebalance(data);
  }

  /// @notice Book at 0.65 with the 0.60 override: a repayment to 0.64 strictly improves and
  ///         passes.
  function test_rebalance_betweenOverrideAndLtv_improvingPasses() public {
    _seedPosition(10_000e18, 6_500e18);
    _setOverride(OVERRIDE);
    _startAsync(0, 100);
    _settleBridge();
    _mintDebt(address(retargetter), 100e18);

    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(0, 100e18, RebalancingOperationType.REPAY, 100e18));

    assertEq(_currentLtv(), 0.64e18, "improved toward the override");
  }

  /// @notice The per-module check uses the override too: a module worsening from 0.60 to
  ///         0.61 reverts while the aggregate stays far below target.
  function test_rebalance_moduleAboveOverride_reverts() public {
    _seedPosition(10_000e18, 600e18);
    _setOverride(OVERRIDE);
    _startAsync(0, 100);

    // Owner shaping (direction checks skipped): borrowPosition1 keeps 600 / 1,000 = 0.60
    vm.prank(owner);
    retargetter.rebalance(
      _dataOn2(
        address(borrowPosition1),
        RebalancingOperationType.WITHDRAW,
        9_000e18,
        address(borrowPosition2),
        RebalancingOperationType.SUPPLY,
        9_000e18
      )
    );
    _setMaxRebalanceLoss(1000);

    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.PositionAboveTarget.selector, address(borrowPosition1)));
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.BORROW, 10e18));
  }

  /// @notice An override above the live ltv is inert: the 0.70 ltv still bounds the move.
  function test_rebalance_overrideAboveLtv_isInert() public {
    _seedPosition(10_000e18, 5_000e18);
    _setOverride(0.9e18);
    _startAsync(0, 100);
    _setMaxRebalanceLoss(1000);
    _mintCollateral(address(retargetter), 6_000e18);

    vm.prank(rebalancer);
    vm.expectRevert(
      abi.encodeWithSelector(LibRetargetterErrors.AboveTargetLtv.selector, 0.70625e18, 0.5e18, POSITION_MANAGER_LTV)
    );
    retargetter.rebalance(
      _rebalancingData2(
        6_000e18, 0, RebalancingOperationType.SUPPLY, 6_000e18, RebalancingOperationType.BORROW, 6_300e18
      )
    );
  }

  /// @notice A rebalance under an override has the same outcome (success, revert data and
  ///         resulting LTV) as under the same value set as the position manager's ltv.
  function testFuzz_rebalance_overrideMatchesPositionManagerLtv(uint256 target, uint256 amount, bool borrow) public {
    target = bound(target, 1, POSITION_MANAGER_LTV);
    // Naked borrows stay within the 10% rebalance loss tolerance of the 5,000 net value
    amount = bound(amount, 1e18, 400e18);
    _seedPosition(10_000e18, 5_000e18);
    _setMaxRebalanceLoss(1000);
    _mintDebt(address(retargetter), amount);
    RebalancingData memory data = borrow
      ? _rebalancingData(0, 0, RebalancingOperationType.BORROW, amount)
      : _rebalancingData(0, amount, RebalancingOperationType.REPAY, amount);

    // The target is set before the operation starts (the override is idle only)
    uint256 snapshot = vm.snapshotState();
    _setOverride(target);
    _startAsync(0, 100);
    _settleBridge();
    (bool okOverride, bytes memory retOverride) = _tryRebalance(data);
    uint256 ltvOverride = _currentLtv();

    vm.revertToState(snapshot);
    _setTargetLtv(target);
    _startAsync(0, 100);
    _settleBridge();
    (bool okLtv, bytes memory retLtv) = _tryRebalance(data);

    assertEq(okOverride, okLtv, "same outcome");
    assertEq(retOverride, retLtv, "same revert data");
    assertEq(ltvOverride, _currentLtv(), "same resulting ltv");
  }
}
