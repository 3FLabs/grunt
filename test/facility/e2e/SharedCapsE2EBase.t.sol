// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {InKindFacilityBaseTest} from "test/facility/inkind/InKindFacilityBase.t.sol";
import {Facility} from "src/facility/Facility.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {IntentProperties, Asset} from "src/libs/facility/LibIntent.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title SharedCapsE2EBaseTest
/// @notice InKindFacilityBaseTest plus a Facility clone on the same caps whitelist. Both facilities
///         consume the fixture's FacilityAbsoluteCaps and FacilityDynamicCaps, PM and PM2 are
///         seeded, and the PM entry offer consumes the shared pool at 1x.
abstract contract SharedCapsE2EBaseTest is InKindFacilityBaseTest {
  using LibClone for address;
  using FixedPointMathLib for uint256;

  Facility public intents;
  IntentDescriptor public descriptor;

  address public depositor;
  address public depositor2;

  uint128 constant SHARED_POOL_CAP = 10_000e6;
  uint40 constant RESOLVE_DELAY = 30 days;

  function setUp() public virtual override {
    super.setUp();
    depositor = makeAddr("depositor");
    depositor2 = makeAddr("depositor2");

    descriptor = new IntentDescriptor();
    intents = Facility(address(new Facility(address(whitelist))).clone());
    intents.initialize(owner, facilitator, address(descriptor));

    vm.startPrank(owner);
    intents.grantRoles(compliance, FACILITY_COMPLIANCE_ROLE);
    absoluteCaps.grantRoles(address(intents), CAPS_CONSUMER_ROLE);
    dynamicCaps.grantRoles(address(intents), CAPS_CONSUMER_ROLE);
    absoluteCaps.setCap(POOL_ID, SHARED_POOL_CAP, SHARED_POOL_CAP);
    vm.stopPrank();

    _seedPool(positionManager, SEED_COLLATERAL, SEED_DEBT);
    _seedPool(positionManager2, SEED_COLLATERAL, SEED_DEBT);
    _setEntry(positionManager, _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(LibCaps.MAX_ABSOLUTE);

    vm.label(address(intents), "Facility");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _poolWord(uint64 ids, int24 multiplier) internal view returns (uint256) {
    return LibCaps.encodeExternal(address(absoluteCaps), ids, multiplier);
  }

  function _rateWord(uint64 id, int24 multiplier) internal view returns (uint256) {
    return LibCaps.encodeExternal(address(dynamicCaps), id, multiplier);
  }

  function _poolCap(uint16 id) internal view returns (uint128 cap) {
    (cap,) = absoluteCaps.getCap(id);
  }

  function _setPool(uint16 id, uint128 cap, uint128 hardCap) internal {
    vm.prank(owner);
    absoluteCaps.setCap(id, cap, hardCap);
  }

  /// @dev A dynamic cap recovering `recovery` per day, fully recovered now.
  function _setRateFull(uint64 id, uint128 recovery) internal {
    vm.prank(owner);
    dynamicCaps.setCap(id, recovery, 1 days, uint64(block.timestamp - 1 days));
  }

  /// @dev A debt-asset deposit intent targeting the PM: its word is in the in-kind debt units.
  function _usdcIntent(uint256 word) internal view returns (IntentProperties memory) {
    return IntentProperties({
      depositAsset: Asset({asset: address(debtToken), isPositionManager: false}),
      targetAsset: Asset({asset: address(positionManager), isPositionManager: true}),
      depositCap: word,
      guardKey: address(positionManager),
      resolveStart: uint40(block.timestamp + RESOLVE_DELAY),
      quorum: 1,
      transferableIntent: true
    });
  }

  function _createIntent(uint256 word) internal returns (uint256 id) {
    vm.prank(facilitator);
    id = intents.createIntent(_usdcIntent(word));
  }

  function _fundDepositor(address who, uint256 amount) internal {
    debtToken.setBalance(who, debtToken.balanceOf(who) + amount);
    vm.prank(who);
    debtToken.approve(address(intents), amount);
  }

  function _depositIntent(uint256 id, address who, uint256 amount) internal {
    _fundDepositor(who, amount);
    vm.prank(who);
    intents.deposit(id, amount);
  }

  /// @dev Funds `who` with `debtAllowance` debt asset and approves an exit of `shares`.
  function _approveExit(PositionManager pm, address who, uint256 shares, uint256 debtAllowance) internal {
    debtToken.setBalance(who, debtToken.balanceOf(who) + debtAllowance);
    vm.startPrank(who);
    debtToken.approve(address(facility), debtAllowance);
    pm.approve(address(facility), shares);
    vm.stopPrank();
  }

  /// @dev Burn's debt and collateral slices for an exit of `shares` (fee rounded up), the
  ///      amounts an exit word consumes and the receiver gets.
  function _exitMirror(PositionManager pm, uint256 shares, uint24 feeBps)
    internal
    view
    returns (uint256 debt, uint256 collateral)
  {
    uint256 burnShares = shares - shares.mulDivUp(feeBps, BPS);
    (, uint256 supply, uint256 mgmtShares, uint256 perfShares) = pm.pendingFees();
    uint256 adjustedSupply = supply + mgmtShares + perfShares + pm.virtualShareOffset();
    debt = pm.debtAmount().mulDivUp(burnShares, adjustedSupply);
    collateral = pm.collateralAmount().mulDiv(burnShares, adjustedSupply);
  }
}
