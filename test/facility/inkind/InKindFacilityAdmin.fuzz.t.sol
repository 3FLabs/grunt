// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {IInKindFacility, EntryOffer, ExitOffer, Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title InKindFacilityAdminFuzzTest
/// @notice Fuzzed admin properties of InKindFacility: the role gate of every setter, the cap
///         word accept set against a reference, exact storage and events, and the pause gate.
contract InKindFacilityAdminFuzzTest is InKindFacilityBaseTest {
  using LibClone for address;

  address rogueCaps;

  function setUp() public override {
    super.setUp();
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
    rogueCaps = address(new FacilityAbsoluteCaps()).clone();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The owner, or a fresh address holding `roleBits`.
  function _caller(uint256 seed, bool asOwner, uint256 roleBits) internal returns (address caller) {
    if (asOwner) return owner;
    caller = address(uint160(uint256(keccak256(abi.encode("caller", seed)))));
    vm.prank(owner);
    facility.grantRoles(caller, roleBits);
  }

  /// @dev An ABSOLUTE word, an EXTERNAL word (whitelisted, rogue or arbitrary caps) or an
  ///      unknown type byte.
  function _fuzzWord(uint256 kindSeed, uint256 capsSeed, uint64 id, int24 multiplier, uint256 low)
    internal
    view
    returns (uint256)
  {
    uint256 kind = kindSeed % 4;
    if (kind == 0) return bound(low, 0, LibCaps.MAX_ABSOLUTE);
    if (kind == 3) return (bound(kindSeed >> 8, 2, 255) << 248) | (low & LibCaps.MAX_ABSOLUTE);
    address[4] memory caps = [address(absoluteCaps), address(dynamicCaps), rogueCaps, address(uint160(low))];
    return _externalWord(caps[capsSeed % 4], id, multiplier);
  }

  /// @dev Reference revert data of a setter on `word`; empty when it must be accepted.
  function _wordError(uint256 word, bool consuming) internal view returns (bytes memory) {
    uint256 rawType = word >> 248;
    if (rawType > 1) return abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, word);
    if (rawType == 0) return "";
    address caps = address(uint160(word));
    uint64 id = uint64(word >> 160);
    int24 multiplier = int24(uint24(word >> 224));
    if (!whitelist.isAllowed(caps)) return abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, caps);
    try IFacilityCaps(caps).validate(id, multiplier) {}
    catch (bytes memory err) {
      return err;
    }
    if (consuming && multiplier <= 0) return abi.encodeWithSelector(IInKindFacility.NonConsumingCap.selector, word);
    return "";
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ROLE GATE                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_setEntry_ownerOrFacilitator(uint256 seed, uint256 roleBits, bool asOwner) public {
    address caller = _caller(seed, asOwner, roleBits);
    bool allowed = asOwner || (roleBits & FACILITY_FACILITATOR_ROLE) != 0;
    if (!allowed) vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(caller);
    facility.setEntry(address(positionManager2), 123e6, FAR_EXPIRY, 7, true);
    assertEq(facility.getEntry(address(positionManager2)).capacityCap, allowed ? 123e6 : 0, "stored");
  }

  function testFuzz_setExit_ownerOrFacilitator(uint256 seed, uint256 roleBits, bool asOwner) public {
    address caller = _caller(seed, asOwner, roleBits);
    bool allowed = asOwner || (roleBits & FACILITY_FACILITATOR_ROLE) != 0;
    if (!allowed) vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(caller);
    facility.setExit(address(positionManager2), 123e6, FAR_EXPIRY, 7);
    assertEq(facility.getExit(address(positionManager2)).cap, allowed ? 123e6 : 0, "stored");
  }

  function testFuzz_setSecurityCap_ownerOrOperator(uint256 seed, uint256 roleBits, bool asOwner) public {
    address caller = _caller(seed, asOwner, roleBits);
    bool allowed = asOwner || (roleBits & FACILITY_OPERATOR_ROLE) != 0;
    if (!allowed) vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(caller);
    facility.setSecurityCap(address(debtToken), address(debtToken), 123e6);
    assertEq(facility.getSecurityCap(address(debtToken), address(debtToken)), allowed ? 123e6 : 0, "stored");
  }

  function testFuzz_setAuth_ownerOrOperator(uint256 seed, uint256 roleBits, bool asOwner) public {
    address caller = _caller(seed, asOwner, roleBits);
    bool allowed = asOwner || (roleBits & FACILITY_OPERATOR_ROLE) != 0;
    if (!allowed) vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(caller);
    facility.setAuth(address(underlyingToken), address(debtToken), user, 123e6, FAR_EXPIRY);
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, allowed ? 123e6 : 0, "stored");
  }

  function testFuzz_pauseFor_ownerOrCompliance(uint256 seed, uint256 roleBits, bool asOwner) public {
    address caller = _caller(seed, asOwner, roleBits);
    bool allowed = asOwner || (roleBits & FACILITY_COMPLIANCE_ROLE) != 0;
    if (!allowed) vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(caller);
    facility.pauseFor(1 days);
    (,, uint40 pausedUntil) = facility.config();
    assertEq(pausedUntil, allowed ? vm.getBlockTimestamp() + 1 days : 0, "stored");
  }

  function testFuzz_setFeeRecipient_ownerOnly(uint256 seed, uint256 roleBits, bool asOwner) public {
    address caller = _caller(seed, asOwner, roleBits);
    address newRecipient = makeAddr("newRecipient");
    if (!asOwner) vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(caller);
    facility.setFeeRecipient(newRecipient);
    (address recipient,,) = facility.config();
    assertEq(recipient, asOwner ? newRecipient : feeRecipient, "stored");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       WORD VALIDATION                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_setEntry_acceptsExactlyValidConsumingWords(
    uint256 kindSeed,
    uint256 capsSeed,
    uint64 id,
    int24 multiplier,
    uint256 low
  ) public {
    uint256 word = _fuzzWord(kindSeed, capsSeed, id, multiplier, low);
    bytes memory err = _wordError(word, true);
    if (err.length > 0) {
      vm.expectRevert(err);
    } else {
      vm.expectEmit(true, true, true, true, address(facility));
      emit IInKindFacility.EntrySet(address(positionManager2), word, FAR_EXPIRY, 0, false);
    }
    vm.prank(facilitator);
    facility.setEntry(address(positionManager2), word, FAR_EXPIRY, 0, false);
    assertEq(facility.getEntry(address(positionManager2)).capacityCap, err.length > 0 ? 0 : word, "stored");
  }

  function testFuzz_setSecurityCap_acceptsExactlyValidConsumingWords(
    uint256 kindSeed,
    uint256 capsSeed,
    uint64 id,
    int24 multiplier,
    uint256 low
  ) public {
    uint256 word = _fuzzWord(kindSeed, capsSeed, id, multiplier, low);
    bytes memory err = _wordError(word, true);
    if (err.length > 0) {
      vm.expectRevert(err);
    } else {
      vm.expectEmit(true, true, true, true, address(facility));
      emit IInKindFacility.SecurityCapSet(address(debtToken), address(debtToken), word);
    }
    vm.prank(operator);
    facility.setSecurityCap(address(debtToken), address(debtToken), word);
    assertEq(facility.getSecurityCap(address(debtToken), address(debtToken)), err.length > 0 ? 0 : word, "stored");
  }

  function testFuzz_setExit_acceptsExactlyValidWords(
    uint256 kindSeed,
    uint256 capsSeed,
    uint64 id,
    int24 multiplier,
    uint256 low
  ) public {
    uint256 word = _fuzzWord(kindSeed, capsSeed, id, multiplier, low);
    bytes memory err = _wordError(word, false);
    if (err.length > 0) {
      vm.expectRevert(err);
    } else {
      vm.expectEmit(true, true, true, true, address(facility));
      emit IInKindFacility.ExitSet(address(positionManager2), word, FAR_EXPIRY, 0);
    }
    vm.prank(facilitator);
    facility.setExit(address(positionManager2), word, FAR_EXPIRY, 0);
    assertEq(facility.getExit(address(positionManager2)).cap, err.length > 0 ? 0 : word, "stored");
  }

  function testFuzz_setEntry_feeGate(uint24 feeBps, bool nearMax) public {
    if (nearMax) feeBps = uint24(bound(feeBps, MAX_FEE - 1, MAX_FEE + 1));
    bool allowed = feeBps <= MAX_FEE;
    if (!allowed) vm.expectRevert(IInKindFacility.FeeExceedsMax.selector);
    vm.prank(facilitator);
    facility.setEntry(address(positionManager2), 1e6, FAR_EXPIRY, feeBps, false);
    assertEq(facility.getEntry(address(positionManager2)).feeBps, allowed ? feeBps : 0, "stored");
  }

  function testFuzz_setExit_feeGate(uint24 feeBps, bool nearMax) public {
    if (nearMax) feeBps = uint24(bound(feeBps, MAX_FEE - 1, MAX_FEE + 1));
    bool allowed = feeBps <= MAX_FEE;
    if (!allowed) vm.expectRevert(IInKindFacility.FeeExceedsMax.selector);
    vm.prank(facilitator);
    facility.setExit(address(positionManager2), 1e6, FAR_EXPIRY, feeBps);
    assertEq(facility.getExit(address(positionManager2)).feeBps, allowed ? feeBps : 0, "stored");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     STORAGE AND EVENTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_setEntry_storesAndEmitsExactFields(uint256 cap, uint40 expiry, uint24 feeBps, bool allowUnlevered)
    public
  {
    cap = bound(cap, 0, LibCaps.MAX_ABSOLUTE);
    feeBps = uint24(bound(feeBps, 0, MAX_FEE));
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.EntrySet(address(positionManager2), cap, expiry, feeBps, allowUnlevered);
    _setEntry(positionManager2, cap, expiry, feeBps, allowUnlevered);

    EntryOffer memory offer = facility.getEntry(address(positionManager2));
    assertEq(offer.capacityCap, cap, "capacityCap");
    assertEq(offer.expiry, expiry, "expiry");
    assertEq(offer.feeBps, feeBps, "feeBps");
    assertEq(offer.allowUnlevered, allowUnlevered, "allowUnlevered");
    assertEq(facility.getExit(address(positionManager2)).expiry, 0, "exit side written");
    assertEq(facility.getEntry(address(positionManager)).capacityCap, LibCaps.MAX_ABSOLUTE, "other PM written");
  }

  function testFuzz_setExit_storesAndEmitsExactFields(uint256 cap, uint40 expiry, uint24 feeBps) public {
    cap = bound(cap, 0, LibCaps.MAX_ABSOLUTE);
    feeBps = uint24(bound(feeBps, 0, MAX_FEE));
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.ExitSet(address(positionManager2), cap, expiry, feeBps);
    _setExit(positionManager2, cap, expiry, feeBps);

    ExitOffer memory offer = facility.getExit(address(positionManager2));
    assertEq(offer.cap, cap, "cap");
    assertEq(offer.expiry, expiry, "expiry");
    assertEq(offer.feeBps, feeBps, "feeBps");
    assertEq(facility.getEntry(address(positionManager2)).expiry, 0, "entry side written");
    assertEq(facility.getExit(address(positionManager)).cap, LibCaps.MAX_ABSOLUTE, "other PM written");
  }

  function testFuzz_setSecurityCap_storesAndEmitsExactFields(address asset, uint256 cap) public {
    asset = address(uint160(bound(uint160(asset), 1, type(uint160).max)));
    cap = bound(cap, 0, LibCaps.MAX_ABSOLUTE);
    address other = address(uint160(asset) ^ 1);
    uint256 otherCap = facility.getSecurityCap(other, address(debtToken));
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.SecurityCapSet(asset, address(debtToken), cap);
    vm.prank(operator);
    facility.setSecurityCap(asset, address(debtToken), cap);

    assertEq(facility.getSecurityCap(asset, address(debtToken)), cap, "cap");
    assertEq(facility.getSecurityCap(other, address(debtToken)), otherCap, "other asset written");
  }

  function testFuzz_setAuth_storesAndEmitsExactFields(address asset, address who, uint128 amount, uint40 expiry)
    public
  {
    asset = address(uint160(bound(uint160(asset), 1, type(uint160).max)));
    who = address(uint160(bound(uint160(who), 1, type(uint160).max)));
    address otherUser = address(uint160(who) ^ 1);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.AuthSet(asset, address(debtToken), who, amount, expiry);
    vm.prank(operator);
    facility.setAuth(asset, address(debtToken), who, amount, expiry);

    Auth memory auth = facility.getAuth(asset, address(debtToken), who);
    assertEq(auth.amount, amount, "amount");
    assertEq(auth.expiry, expiry, "expiry");
    assertEq(facility.getAuth(asset, address(debtToken), otherUser).amount, 0, "other user written");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           PAUSE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_pauseFor_setsSaturatedPausedUntil(uint256 duration, uint256 time) public {
    vm.warp(bound(time, 1, type(uint40).max));
    uint256 capped = duration < type(uint40).max ? duration : type(uint40).max;
    uint256 end = vm.getBlockTimestamp() + capped;
    uint40 expected = duration == 0 ? 0 : uint40(end < type(uint40).max ? end : type(uint40).max);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.InKindFacilityPausedSet(expected);
    vm.prank(compliance);
    facility.pauseFor(duration);

    (, bool isPaused, uint40 pausedUntil) = facility.config();
    assertEq(pausedUntil, expected, "pausedUntil");
    assertEq(isPaused, vm.getBlockTimestamp() < expected, "isPaused");
  }

  function testFuzz_pauseFor_gatesEveryFlowUntilItLapses(uint256 duration, uint256 elapsed, bool atLapse) public {
    duration = bound(duration, 1, 30 days);
    elapsed = atLapse ? duration - (elapsed % 2) : bound(elapsed, 0, 2 * duration);
    address pm = address(positionManager);
    (uint256 shares,) = _enter(user, 1_000e18, user);
    _fundEntrant(user, 1_000e18);
    debtToken.setBalance(user, 1_000e6);
    vm.startPrank(user);
    debtToken.approve(address(facility), type(uint256).max);
    positionManager.approve(address(facility), shares);
    vm.stopPrank();

    vm.prank(compliance);
    facility.pauseFor(duration);
    vm.warp(vm.getBlockTimestamp() + elapsed);
    bool paused = elapsed < duration;
    (, bool isPaused,) = facility.config();
    assertEq(isPaused, paused, "config");

    if (paused) {
      vm.expectRevert(LibCommonErrors.Paused.selector);
      facility.previewEnter(pm, 1_000e18);
      vm.expectRevert(LibCommonErrors.Paused.selector);
      facility.maxEnter(pm, user);
      vm.expectRevert(LibCommonErrors.Paused.selector);
      facility.previewExit(pm, shares);
      vm.expectRevert(LibCommonErrors.Paused.selector);
      facility.maxExit(pm);
      vm.prank(user);
      vm.expectRevert(LibCommonErrors.Paused.selector);
      facility.enter(pm, 1_000e18, 0, type(uint256).max, 0, user);
      vm.prank(user);
      vm.expectRevert(LibCommonErrors.Paused.selector);
      facility.exit(pm, shares, type(uint256).max, 0, user, "");
    } else {
      facility.previewEnter(pm, 1_000e18);
      facility.maxEnter(pm, user);
      facility.previewExit(pm, shares);
      facility.maxExit(pm);
      vm.prank(user);
      facility.enter(pm, 1_000e18, 0, type(uint256).max, 0, user);
      vm.prank(user);
      facility.exit(pm, shares, type(uint256).max, 0, user, "");
    }
  }
}
