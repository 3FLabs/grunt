// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {SharedCapsE2EBaseTest} from "./SharedCapsE2EBase.t.sol";
import {Facility} from "src/facility/Facility.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {InKindFacility} from "src/facility/inkind/InKindFacility.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {FacilityCapsWhitelist} from "src/facility/caps/FacilityCapsWhitelist.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {Mode} from "src/libs/funds/Order.sol";
import {MockFund} from "test/mock/facility/MockFund.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title SetupSequenceE2ETest
/// @notice Deploys the caps registry, caps contracts and both facilities in operator order (replacing
///         the fixture's stack), then runs each facility's happy path and the common wrong orderings.
contract SetupSequenceE2ETest is SharedCapsE2EBaseTest {
  using LibClone for address;

  uint256 constant FACILITY_GUARDIAN_ROLE = 1 << 1;
  uint256 constant GUARDIAN_PK = 0xA11CE;
  uint64 constant SECURITY_RATE_ID = 7;
  uint128 constant SECURITY_RECOVERY = 1_200e6;
  uint256 constant EXIT_BUDGET = 2_000e6;
  uint128 constant AUTH_AMOUNT = 300e6;
  bytes32 constant SET_FUND_PARAMS_TYPEHASH = keccak256("SetFundParams(uint256 id,address newFund,uint256 deadline)");

  address public capsManager;
  address public guardian;
  uint256 public intentId;

  function setUp() public override {
    super.setUp();
    capsManager = makeAddr("capsManager");
    guardian = vm.addr(GUARDIAN_PK);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     DEPLOYMENT STEPS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _deployContracts() internal {
    whitelist = new FacilityCapsWhitelist(owner);
    absoluteCaps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    dynamicCaps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    implementation = new InKindFacility(address(whitelist));
    facility = InKindFacility(address(implementation).clone());
    facility.initialize(owner, facilitator, feeRecipient);
    descriptor = new IntentDescriptor();
    intents = Facility(address(new Facility(address(whitelist))).clone());
    intents.initialize(owner, facilitator, address(descriptor));
  }

  function _initializeCaps(address[] memory consumers) internal {
    address[] memory managers = new address[](1);
    managers[0] = capsManager;
    absoluteCaps.initialize(owner, managers, consumers);
    dynamicCaps.initialize(owner, managers, consumers);
  }

  function _bothFacilities() internal view returns (address[] memory consumers) {
    consumers = new address[](2);
    consumers[0] = address(facility);
    consumers[1] = address(intents);
  }

  function _allowCaps() internal {
    vm.startPrank(owner);
    whitelist.setAllowed(address(absoluteCaps), true);
    whitelist.setAllowed(address(dynamicCaps), true);
    vm.stopPrank();
  }

  function _grantFacilityRoles() internal {
    vm.startPrank(owner);
    facility.grantRoles(operator, FACILITY_OPERATOR_ROLE);
    facility.grantRoles(compliance, FACILITY_COMPLIANCE_ROLE);
    intents.grantRoles(compliance, FACILITY_COMPLIANCE_ROLE);
    intents.grantRoles(guardian, FACILITY_GUARDIAN_ROLE);
    vm.stopPrank();
  }

  function _grantMinterRoles() internal {
    vm.startPrank(owner);
    positionManager.grantRoles(address(facility), PM_MINTER_ROLE);
    positionManager.grantRoles(address(intents), PM_MINTER_ROLE);
    vm.stopPrank();
  }

  function _grantSenderRoles() internal {
    vm.startPrank(owner);
    collateralToken.grantRoles(address(facility), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(intents), WA_SENDER_ROLE);
    vm.stopPrank();
  }

  function _setCaps() internal {
    vm.startPrank(capsManager);
    absoluteCaps.setCap(POOL_ID, uint128(_capsUnits(SHARED_POOL_CAP)), uint128(_capsUnits(SHARED_POOL_CAP)));
    dynamicCaps.setCap(
      SECURITY_RATE_ID, uint128(_capsUnits(SECURITY_RECOVERY)), 1 days, uint64(block.timestamp - 1 days)
    );
    vm.stopPrank();
  }

  /// @dev Capacity +1x on the shared pool, an exit budget, the security rate on `securityKey`,
  ///      an auth for `user`, and a deposit intent on the shared pool.
  function _setWords(address securityKey) internal {
    _setEntry(positionManager, _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, EXIT_BUDGET, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.prank(operator);
    facility.setSecurityCap(securityKey, address(debtToken), _rateWord(SECURITY_RATE_ID, MULT_1X));
    _setAuth(user, AUTH_AMOUNT, FAR_EXPIRY);
    intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
  }

  function _deployFromScratch() internal {
    _deployContracts();
    _initializeCaps(_bothFacilities());
    _allowCaps();
    _grantFacilityRoles();
    _grantMinterRoles();
    _grantSenderRoles();
    _setCaps();
    _setWords(address(underlyingToken));
  }

  /// @dev Sets the intent's fund with the guardian's signature (quorum 1).
  function _setFundSigned(address fund) internal {
    uint256 deadline = block.timestamp + 1 hours;
    bytes32 domainSeparator = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("3F"),
        keccak256("1"),
        block.chainid,
        address(intents)
      )
    );
    bytes32 structHash = keccak256(abi.encode(SET_FUND_PARAMS_TYPEHASH, intentId, fund, deadline));
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(GUARDIAN_PK, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = abi.encodePacked(r, s, v);
    vm.prank(facilitator);
    intents.setFund(intentId, fund, deadline, signers, signatures);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        HAPPY PATHS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setupSequence_inKindRoundTrip() public {
    _deployFromScratch();

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectEmit(true, true, false, true, address(facility));
    emit IInKindFacility.AuthConsumed(address(underlyingToken), address(debtToken), user, AUTH_AMOUNT, 0);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, user);
    assertEq(debtToken.balanceOf(user), 500e6, "entry debt");
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 500e6, "capacity pool");
    assertEq(_dynRemaining(SECURITY_RATE_ID), SECURITY_RECOVERY - 200e6, "security rate");

    uint256 shares = positionManager.balanceOf(user);
    (uint256 debtIn, uint256 underlyingOut) = _exitMirror(positionManager, shares, DEFAULT_FEE_BPS);
    _exit(user, shares, receiver);
    assertEq(underlyingToken.balanceOf(receiver), underlyingOut, "underlying out");
    assertEq(facility.getExit(address(positionManager)).cap, EXIT_BUDGET - debtIn, "exit budget");
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 500e6, "exits leave the capacity pool");
    _assertFacilityClean();
  }

  function test_setupSequence_intentLifecycle() public {
    _deployFromScratch();
    // the fund delivers wrapper it holds, so it needs SENDER_ROLE like an issuer fund
    MockFund fund = new MockFund(address(debtToken), address(collateralToken));
    vm.prank(owner);
    collateralToken.grantRoles(address(fund), WA_SENDER_ROLE);
    underlyingToken.setBalance(address(fund), 1_000e18);
    vm.startPrank(address(fund));
    underlyingToken.approve(address(collateralToken), 1_000e18);
    collateralToken.mint(address(fund), 1_000e18);
    vm.stopPrank();

    _depositIntent(intentId, depositor, 600e6);
    _depositIntent(intentId, depositor2, 400e6);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_000e6, "deposits consume the pool");

    _setFundSigned(address(fund));
    vm.startPrank(facilitator);
    intents.lock(intentId);
    intents.create(intentId, 1_000e6, 1_000e18, Mode.DEPOSIT);
    intents.commit(intentId);
    intents.unlock(intentId);
    intents.depositManager(intentId, 1_000e18, 500e6, true);
    intents.resolve(intentId);
    vm.stopPrank();

    uint256 pmShares = positionManager.balanceOf(address(intents));
    (address[] memory tokens, uint256[] memory amounts) = intents.intentBalances(intentId);
    assertEq(tokens.length, 2, "intent tokens");
    assertEq(tokens[0], address(debtToken), "debt token");
    assertEq(amounts[0], 500e6, "borrowed debt");
    assertEq(tokens[1], address(positionManager), "PM shares");
    assertEq(amounts[1], pmShares, "PM shares amount");

    vm.prank(depositor);
    intents.claim(intentId, depositor, depositor, 600e6);
    vm.prank(depositor2);
    intents.claim(intentId, depositor2, depositor2, 400e6);
    assertEq(debtToken.balanceOf(depositor), 300e6, "depositor debt");
    assertEq(debtToken.balanceOf(depositor2), 200e6, "depositor2 debt");
    assertEq(positionManager.balanceOf(depositor), pmShares * 6 / 10, "depositor shares");
    assertEq(positionManager.balanceOf(depositor2), pmShares - pmShares * 6 / 10, "depositor2 shares");
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_000e6, "claims keep the consumption");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WRONG ORDERINGS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setupSequence_wordsBeforeWhitelistingRevert() public {
    _deployContracts();
    _initializeCaps(_bothFacilities());
    _grantFacilityRoles();
    uint256 word = _poolWord(POOL_ID, MULT_1X);
    bytes memory notAllowed = abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(absoluteCaps));

    vm.prank(facilitator);
    vm.expectRevert(notAllowed);
    facility.setEntry(address(positionManager), word, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
    vm.prank(facilitator);
    vm.expectRevert(notAllowed);
    intents.createIntent(_usdcIntent(word));

    _allowCaps();
    _setEntry(positionManager, word, FAR_EXPIRY, DEFAULT_FEE_BPS);
    uint256 id = _createIntent(word);
    assertEq(facility.getEntry(address(positionManager)).capacityCap, word, "entry word");
    (IntentProperties memory props,,,) = intents.getIntent(id);
    assertEq(props.depositCap, word, "intent word");
  }

  function test_setupSequence_missingConsumerRoleRevertsFlowsUntilGranted() public {
    _deployContracts();
    _initializeCaps(new address[](0));
    _allowCaps();
    _grantFacilityRoles();
    _grantMinterRoles();
    _grantSenderRoles();
    _setCaps();
    _setWords(address(underlyingToken));

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
    _fundDepositor(depositor, 1_000e6);
    vm.prank(depositor);
    vm.expectRevert(Ownable.Unauthorized.selector);
    intents.deposit(intentId, 1_000e6);

    vm.startPrank(owner);
    absoluteCaps.grantRoles(address(facility), CAPS_CONSUMER_ROLE);
    absoluteCaps.grantRoles(address(intents), CAPS_CONSUMER_ROLE);
    dynamicCaps.grantRoles(address(facility), CAPS_CONSUMER_ROLE);
    vm.stopPrank();
    vm.prank(user);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
    vm.prank(depositor);
    intents.deposit(intentId, 1_000e6);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_500e6, "pool");
  }

  function test_setupSequence_securityCapOnWrapperLeavesUnderlyingClosed() public {
    _deployContracts();
    _initializeCaps(_bothFacilities());
    _allowCaps();
    _grantFacilityRoles();
    _grantMinterRoles();
    _grantSenderRoles();
    _setCaps();
    _setWords(address(collateralToken));

    _fundEntrant(depositor, 1_000e18);
    vm.prank(depositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibFacilityErrors.CapExceeded.selector, uint256(uint160(address(underlyingToken))), 0, 500e6
      )
    );
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
  }

  function test_setupSequence_missingWrapperSenderRoleRevertsEntry() public {
    _deployContracts();
    _initializeCaps(_bothFacilities());
    _allowCaps();
    _grantFacilityRoles();
    _grantMinterRoles();
    _setCaps();
    _setWords(address(underlyingToken));

    // the PM's pull of the wrapper from the facility fails
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP, "capacity");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, AUTH_AMOUNT, "auth");
  }
}
