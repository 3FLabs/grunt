// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test, Vm} from "forge-std/Test.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibInKindStorage, InKindStorageData} from "src/libs/facility/inkind/LibInKindStorage.sol";
import {IInKindFacility, EntryOffer, ExitOffer, Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @dev Exposes LibInKindStorage over its own storage struct, with debt in an 18-decimal asset.
contract LibInKindStorageHarness {
  using LibInKindStorage for InKindStorageData;

  address public debtAsset = address(new MockERC20("Debt", "DEBT", 18));

  function setEntry(address pm, EntryOffer calldata offer) external {
    LibInKindStorage.inKindStorage().entries[pm] = offer;
  }

  function setExit(address pm, ExitOffer calldata offer) external {
    LibInKindStorage.inKindStorage().exits[pm] = offer;
  }

  function setSecurityCap(address asset, uint256 word) external {
    LibInKindStorage.inKindStorage().securityCaps[asset][debtAsset] = word;
  }

  function setAuth(address asset, address user, uint128 amount, uint40 expiry) external {
    LibInKindStorage.inKindStorage().auths[asset][debtAsset][user] = Auth({amount: amount, expiry: expiry});
  }

  function setPausedUntil(uint40 pausedUntil) external {
    LibInKindStorage.inKindStorage().pausedUntil = pausedUntil;
  }

  function securityCap(address asset) external view returns (uint256) {
    return LibInKindStorage.inKindStorage().securityCaps[asset][debtAsset];
  }

  function auth(address asset, address user) external view returns (Auth memory) {
    return LibInKindStorage.inKindStorage().auths[asset][debtAsset][user];
  }

  function getEnabledEntry(address pm) external view returns (EntryOffer memory) {
    return LibInKindStorage.inKindStorage().getEnabledEntry(pm);
  }

  function getEnabledExit(address pm) external view returns (ExitOffer memory) {
    return LibInKindStorage.inKindStorage().getEnabledExit(pm);
  }

  function available(uint128 amount, uint40 expiry) external view returns (uint256) {
    return LibInKindStorage.available(Auth({amount: amount, expiry: expiry}));
  }

  function authAvailable(address asset, address user) external view returns (uint256) {
    return LibInKindStorage.available(LibInKindStorage.inKindStorage().auths[asset][debtAsset][user]);
  }

  function securityLimit(address asset, address user) external view returns (uint256) {
    return LibInKindStorage.inKindStorage().securityLimit(asset, user, debtAsset);
  }

  function consumeSecurity(address asset, address user, uint256 debt) external {
    LibInKindStorage.inKindStorage().consumeSecurity(asset, user, debt, debtAsset);
  }
}

/// @title LibInKindStorageTest
/// @notice Unit and fuzz tests for LibInKindStorage through a harness: offer gating, auth
///         availability, the security limit and the auth-then-security consumption.
contract LibInKindStorageTest is Test {
  using LibClone for address;

  LibInKindStorageHarness harness;
  FacilityAbsoluteCaps absoluteCaps;

  address owner = makeAddr("owner");
  address user = makeAddr("user");
  address asset = makeAddr("asset");
  address pm = makeAddr("pm");

  uint16 constant POOL_ID = 1;
  int24 constant MULT_1X = 4096;
  uint40 constant FAR_EXPIRY = type(uint40).max;
  uint256 constant NOW = 1_000_000;

  function setUp() public {
    vm.warp(NOW);
    harness = new LibInKindStorageHarness();
    absoluteCaps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory consumers = new address[](1);
    consumers[0] = address(harness);
    absoluteCaps.initialize(owner, managers, consumers);
    vm.prank(owner);
    absoluteCaps.setCap(POOL_ID, 1_000e6, 1_000e6);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OFFERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_getEnabledEntryAndExit_neverSetRevertUnknown() public {
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, pm));
    harness.getEnabledEntry(pm);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, pm));
    harness.getEnabledExit(pm);
  }

  function test_getEnabledEntry_expiresAtTheExpiryTimestamp() public {
    uint40 expiry = uint40(NOW + 1 hours);
    harness.setEntry(pm, EntryOffer({capacityCap: 123e6, expiry: expiry, feeBps: 42, allowUnlevered: true}));

    vm.warp(expiry - 1);
    EntryOffer memory offer = harness.getEnabledEntry(pm);
    assertEq(offer.capacityCap, 123e6, "capacityCap");
    assertEq(offer.expiry, expiry, "expiry");
    assertEq(offer.feeBps, 42, "feeBps");
    assertTrue(offer.allowUnlevered, "allowUnlevered");

    vm.warp(expiry);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, pm));
    harness.getEnabledEntry(pm);
  }

  function test_getEnabledExit_expiresAtTheExpiryTimestamp() public {
    uint40 expiry = uint40(NOW + 1 hours);
    harness.setExit(pm, ExitOffer({cap: 456e6, expiry: expiry, feeBps: 43}));

    vm.warp(expiry - 1);
    ExitOffer memory offer = harness.getEnabledExit(pm);
    assertEq(offer.cap, 456e6, "cap");
    assertEq(offer.expiry, expiry, "expiry");
    assertEq(offer.feeBps, 43, "feeBps");

    vm.warp(expiry);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, pm));
    harness.getEnabledExit(pm);
  }

  function test_getEnabledEntryAndExit_pauseWinsOverUnknownOffers() public {
    harness.setPausedUntil(uint40(NOW + 1));
    vm.expectRevert(LibCommonErrors.Paused.selector);
    harness.getEnabledEntry(pm);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    harness.getEnabledExit(pm);
  }

  function testFuzz_getEnabledEntryAndExit_pauseThenExpiryGate(uint40 expiry, uint40 pausedUntil, uint256 elapsed)
    public
  {
    harness.setEntry(pm, EntryOffer({capacityCap: 1, expiry: expiry, feeBps: 2, allowUnlevered: false}));
    harness.setExit(pm, ExitOffer({cap: 3, expiry: expiry, feeBps: 4}));
    harness.setPausedUntil(pausedUntil);
    vm.warp(bound(elapsed, NOW, type(uint40).max));

    bytes memory entryErr;
    bytes memory exitErr;
    if (block.timestamp < pausedUntil) {
      entryErr = abi.encodeWithSelector(LibCommonErrors.Paused.selector);
      exitErr = entryErr;
    } else if (block.timestamp >= expiry) {
      entryErr = abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, pm);
      exitErr = abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, pm);
    }

    if (entryErr.length > 0) vm.expectRevert(entryErr);
    EntryOffer memory entry = harness.getEnabledEntry(pm);
    if (exitErr.length > 0) vm.expectRevert(exitErr);
    ExitOffer memory exit_ = harness.getEnabledExit(pm);
    if (entryErr.length == 0) {
      assertEq(entry.capacityCap, 1, "entry cap");
      assertEq(exit_.cap, 3, "exit cap");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     AUTH AVAILABILITY                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_available_expiresAtTheExpiryTimestamp() public {
    uint40 expiry = uint40(NOW + 100);
    vm.warp(expiry - 1);
    assertEq(harness.available(7e6, expiry), 7e6, "live one second before expiry");
    vm.warp(expiry);
    assertEq(harness.available(7e6, expiry), 0, "expired at expiry");
  }

  function testFuzz_authAvailable_readsTheCallerAuthOnTheAsset(uint128 amount, uint40 expiry, uint256 time) public {
    harness.setAuth(asset, user, amount, expiry);
    vm.warp(bound(time, NOW, type(uint40).max));
    assertEq(harness.authAvailable(asset, user), block.timestamp < expiry ? amount : 0, "own auth");
    assertEq(harness.authAvailable(asset, owner), 0, "other user");
    assertEq(harness.authAvailable(owner, user), 0, "other asset");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       SECURITY LIMIT                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_securityLimit_maxAuthPlusMaxAbsoluteIsExact() public {
    harness.setAuth(asset, user, type(uint128).max, FAR_EXPIRY);
    harness.setSecurityCap(asset, LibCaps.MAX_ABSOLUTE);
    assertEq(harness.securityLimit(asset, user), uint256(type(uint128).max) + LibCaps.MAX_ABSOLUTE, "limit");
  }

  function test_securityLimit_saturatesOnAnUnboundedWord() public {
    harness.setAuth(asset, user, 1, FAR_EXPIRY);
    // a zero multiplier quotes type(uint256).max (setSecurityCap rejects it, the library does not)
    harness.setSecurityCap(asset, LibCaps.encodeExternal(address(absoluteCaps), POOL_ID, 0));
    assertEq(harness.securityLimit(asset, user), type(uint256).max, "limit");
  }

  function testFuzz_securityLimit_isLiveAuthPlusAbsoluteWord(uint128 amount, uint40 expiry, uint256 word, uint256 time)
    public
  {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    harness.setAuth(asset, user, amount, expiry);
    harness.setSecurityCap(asset, word);
    vm.warp(bound(time, NOW, type(uint40).max));
    uint256 live = block.timestamp < expiry ? amount : 0;
    assertEq(harness.securityLimit(asset, user), live + word, "limit");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONSUME SECURITY                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_consumeSecurity_authFirstThenAbsoluteWord(
    uint128 amount,
    uint40 expiry,
    uint256 word,
    uint256 debt,
    uint256 time
  ) public {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    harness.setAuth(asset, user, amount, expiry);
    harness.setSecurityCap(asset, word);
    vm.warp(bound(time, NOW, type(uint40).max));
    uint256 live = block.timestamp < expiry ? amount : 0;
    debt = bound(debt, 0, live + word);
    uint256 fromAuth = debt < live ? debt : live;

    vm.recordLogs();
    harness.consumeSecurity(asset, user, debt);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    Auth memory after_ = harness.auth(asset, user);
    assertEq(after_.amount, amount - fromAuth, "auth amount");
    assertEq(after_.expiry, expiry, "auth expiry");
    assertEq(harness.securityCap(asset), word - (debt - fromAuth), "security word");
    assertEq(logs.length, fromAuth > 0 ? 1 : 0, "AuthConsumed iff the auth gave");
    if (fromAuth > 0) {
      assertEq(logs[0].emitter, address(harness), "emitter");
      assertEq(logs[0].topics[0], IInKindFacility.AuthConsumed.selector, "event");
      assertEq(logs[0].topics[1], bytes32(uint256(uint160(asset))), "asset topic");
      assertEq(logs[0].topics[2], bytes32(uint256(uint160(harness.debtAsset()))), "debt asset topic");
      assertEq(logs[0].topics[3], bytes32(uint256(uint160(user))), "user topic");
      assertEq(logs[0].data, abi.encode(fromAuth, amount - fromAuth), "consumed and remaining");
    }
  }

  function testFuzz_consumeSecurity_revertsWhenTheWordCannotTakeTheRemainder(
    uint128 amount,
    uint40 expiry,
    uint256 word,
    uint256 debt
  ) public {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    harness.setAuth(asset, user, amount, expiry);
    harness.setSecurityCap(asset, word);
    uint256 live = block.timestamp < expiry ? amount : 0;
    debt = bound(debt, live + word + 1, type(uint256).max);

    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, uint256(uint160(asset)), word, debt - live)
    );
    harness.consumeSecurity(asset, user, debt);
  }

  function test_consumeSecurity_expiredAuthEmitsNothing() public {
    harness.setAuth(asset, user, 600e6, uint40(NOW));
    harness.setSecurityCap(asset, 1_000e6);

    vm.recordLogs();
    harness.consumeSecurity(asset, user, 400e6);

    assertEq(vm.getRecordedLogs().length, 0, "event on an expired auth");
    assertEq(harness.auth(asset, user).amount, 600e6, "expired auth touched");
    assertEq(harness.securityCap(asset), 600e6, "security word");
  }

  function test_consumeSecurity_zeroDebtIsANoop() public {
    harness.setAuth(asset, user, 600e6, FAR_EXPIRY);
    uint256 word = LibCaps.encodeExternal(address(absoluteCaps), POOL_ID, MULT_1X);
    harness.setSecurityCap(asset, word);

    vm.expectCall(address(absoluteCaps), abi.encodeWithSelector(IFacilityCaps.consume.selector), 0);
    vm.recordLogs();
    harness.consumeSecurity(asset, user, 0);

    assertEq(vm.getRecordedLogs().length, 0, "event on zero debt");
    assertEq(harness.auth(asset, user).amount, 600e6, "auth touched");
    assertEq(harness.securityCap(asset), word, "security word touched");
  }

  function test_consumeSecurity_authCoveredDebtNeverCallsTheExternalCap() public {
    harness.setAuth(asset, user, 600e6, FAR_EXPIRY);
    harness.setSecurityCap(asset, LibCaps.encodeExternal(address(absoluteCaps), POOL_ID, MULT_1X));

    vm.expectCall(address(absoluteCaps), abi.encodeWithSelector(IFacilityCaps.consume.selector), 0);
    vm.expectEmit(true, true, true, true, address(harness));
    emit IInKindFacility.AuthConsumed(asset, harness.debtAsset(), user, 600e6, 0);
    harness.consumeSecurity(asset, user, 600e6);

    (uint128 cap,) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, 1_000e6, "pool touched");
  }

  function test_consumeSecurity_externalWordTakesTheExactRemainder() public {
    harness.setAuth(asset, user, 200e6, FAR_EXPIRY);
    uint256 word = LibCaps.encodeExternal(address(absoluteCaps), POOL_ID, MULT_1X);
    harness.setSecurityCap(asset, word);

    vm.expectCall(address(absoluteCaps), abi.encodeCall(IFacilityCaps.consume, (POOL_ID, 300e6, MULT_1X)), 1);
    vm.expectEmit(true, true, true, true, address(harness));
    emit IInKindFacility.AuthConsumed(asset, harness.debtAsset(), user, 200e6, 0);
    vm.expectEmit(true, true, true, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(POOL_ID, 300e6, MULT_1X, 300e6, 700e6);
    harness.consumeSecurity(asset, user, 500e6);

    assertEq(harness.securityCap(asset), word, "external word rewritten");
  }

  function test_consumeSecurity_uint128MaxAuthDrainsThenSpills() public {
    harness.setAuth(asset, user, type(uint128).max, FAR_EXPIRY);
    harness.setSecurityCap(asset, 5);

    vm.expectEmit(true, true, true, true, address(harness));
    emit IInKindFacility.AuthConsumed(asset, harness.debtAsset(), user, type(uint128).max, 0);
    harness.consumeSecurity(asset, user, uint256(type(uint128).max) + 5);

    Auth memory after_ = harness.auth(asset, user);
    assertEq(after_.amount, 0, "auth amount");
    assertEq(after_.expiry, FAR_EXPIRY, "auth expiry");
    assertEq(harness.securityCap(asset), 0, "security word");
  }
}
