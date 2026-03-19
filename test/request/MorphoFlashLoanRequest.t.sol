// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FacilityBaseTest} from "test/facility/FacilityBase.t.sol";
import {MorphoFlashLoanRequest} from "src/request/MorphoFlashLoanRequest.sol";
import {MorphoFlashLoanRequestFactory} from "src/request/MorphoFlashLoanRequestFactory.sol";
import {SyncDeposit} from "src/request/scripts/SyncDeposit.sol";
import {Offer} from "src/interfaces/request/IOfferReceiver.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {Mode, State} from "src/libs/funds/Order.sol";
import {IntentProperties, Asset} from "src/libs/facility/LibIntent.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      HELPER CONTRACTS                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Simple no-op script for basic flash loan mechanic tests.
contract MockScript {
  function run() external {}
}

/// @notice Contract that attempts to re-enter execute() when delegatecalled as a script.
contract ReentrantAttacker {
  MorphoFlashLoanRequest public target;
  MorphoFlashLoanRequest.SetRequestParams public params;
  bool public attempted;

  function setTarget(MorphoFlashLoanRequest _target) external {
    target = _target;
  }

  function setParams(MorphoFlashLoanRequest.SetRequestParams memory _params) external {
    params = _params;
  }

  function attack() external {
    attempted = true;
    target.execute(1e18, params, address(this), abi.encodeCall(this.run, ()));
  }

  function run() external {}
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         TEST CONTRACT                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract MorphoFlashLoanRequestTest is FacilityBaseTest {
  MorphoFlashLoanRequestFactory public flashLoanFactory;
  MorphoFlashLoanRequest public flashLoanRequest;
  MockScript public mockScript;
  SyncDeposit public syncDeposit;

  uint256 public intentId;

  function setUp() public override {
    super.setUp();

    // Deploy factory
    flashLoanFactory = new MorphoFlashLoanRequestFactory(owner, morpho);
    vm.label(address(flashLoanFactory), "FlashLoanFactory");

    // Create proxy via factory
    address proxy = flashLoanFactory.createFlashLoanRequest(owner, address(facility), address(debtToken));
    flashLoanRequest = MorphoFlashLoanRequest(proxy);
    vm.label(proxy, "FlashLoanRequest");

    // Grant FACILITATOR_ROLE to the flash loan request on the facility
    vm.prank(owner);
    facility.grantRoles(proxy, FACILITATOR_ROLE);

    // Deploy and whitelist MockScript
    mockScript = new MockScript();
    vm.label(address(mockScript), "MockScript");
    vm.prank(owner);
    flashLoanRequest.setScript(address(mockScript), true);

    // Deploy and whitelist SyncDeposit
    syncDeposit = new SyncDeposit();
    vm.label(address(syncDeposit), "SyncDeposit");
    vm.prank(owner);
    flashLoanRequest.setScript(address(syncDeposit), true);

    // Create an intent with deposits and move to resolving phase
    intentId = _createIntentWithDeposits(DEFAULT_AMOUNT);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _buildSetRequestParams(uint256 _intentId, uint256 deadline)
    internal
    view
    returns (MorphoFlashLoanRequest.SetRequestParams memory)
  {
    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);

    signers[0] = guardian;
    signatures[0] = _signSetRequest(_intentId, address(flashLoanRequest), deadline, GUARDIAN_PK);

    return MorphoFlashLoanRequest.SetRequestParams({
      intentId: _intentId, deadline: deadline, signers: signers, signatures: signatures
    });
  }

  function _defaultSetRequestParams() internal view returns (MorphoFlashLoanRequest.SetRequestParams memory) {
    return _buildSetRequestParams(intentId, block.timestamp + 1 hours);
  }

  function _noOpScript() internal view returns (address, bytes memory) {
    return (address(mockScript), abi.encodeCall(MockScript.run, ()));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    A. FACTORY TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_factory_setsBeaconAndMorpho() public view {
    assertTrue(flashLoanFactory.FLASH_LOAN_REQUEST_BEACON() != address(0));
    assertEq(address(flashLoanFactory.MORPHO()), address(morpho));
  }

  function test_factory_createFlashLoanRequest() public view {
    assertTrue(flashLoanFactory.isFlashLoanRequest(address(flashLoanRequest)));
    assertEq(flashLoanRequest.owner(), owner);
    assertEq(flashLoanRequest.asset(), address(debtToken));
  }

  function test_factory_emitsEvent() public {
    // Check indexed owner and non-indexed data (facility, asset); skip checking flashLoanRequest address
    vm.expectEmit(false, true, false, true);
    emit MorphoFlashLoanRequestFactory.FlashLoanRequestCreated(address(0), owner, address(facility), address(debtToken));
    flashLoanFactory.createFlashLoanRequest(owner, address(facility), address(debtToken));
  }

  function test_factory_createMultiple() public {
    address proxy2 = flashLoanFactory.createFlashLoanRequest(owner, address(facility), address(debtToken));
    address proxy3 = flashLoanFactory.createFlashLoanRequest(owner, address(facility), address(debtToken));

    assertTrue(proxy2 != proxy3);
    assertTrue(flashLoanFactory.isFlashLoanRequest(proxy2));
    assertTrue(flashLoanFactory.isFlashLoanRequest(proxy3));
  }

  function test_factory_isFlashLoanRequest_falseForUnknown() public view {
    assertFalse(flashLoanFactory.isFlashLoanRequest(address(0xdead)));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   B. CONSTRUCTOR TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_constructor_setsMorpho() public view {
    assertEq(address(flashLoanRequest.MORPHO()), address(morpho));
  }

  function test_constructor_disablesInitializers() public {
    // Deploy a raw implementation (not via factory/proxy)
    MorphoFlashLoanRequest impl = new MorphoFlashLoanRequest(address(morpho));
    vm.expectRevert();
    impl.initialize(owner, address(facility), address(debtToken));
  }

  function test_constructor_revertsOnNonContractMorpho() public {
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0xbeef)));
    new MorphoFlashLoanRequest(address(0xbeef));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   C. INITIALIZE TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_setsOwner() public view {
    assertEq(flashLoanRequest.owner(), owner);
  }

  function test_initialize_setsAsset() public view {
    assertEq(flashLoanRequest.asset(), address(debtToken));
  }

  function test_initialize_revertsOnZeroOwner() public {
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    flashLoanFactory.createFlashLoanRequest(address(0), address(facility), address(debtToken));
  }

  function test_initialize_revertsOnNonContractFacility() public {
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0xbeef)));
    flashLoanFactory.createFlashLoanRequest(owner, address(0xbeef), address(debtToken));
  }

  function test_initialize_revertsOnNonContractAsset() public {
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0xbeef)));
    flashLoanFactory.createFlashLoanRequest(owner, address(facility), address(0xbeef));
  }

  function test_initialize_revertsOnDoubleInit() public {
    vm.expectRevert();
    flashLoanRequest.initialize(owner, address(facility), address(debtToken));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               D. SCRIPT MANAGEMENT TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setScript_whitelists() public {
    MockScript newScript = new MockScript();

    vm.prank(owner);
    flashLoanRequest.setScript(address(newScript), true);

    assertTrue(flashLoanRequest.isScript(address(newScript)));
  }

  function test_setScript_dewhitelists() public {
    assertTrue(flashLoanRequest.isScript(address(mockScript)));

    vm.prank(owner);
    flashLoanRequest.setScript(address(mockScript), false);

    assertFalse(flashLoanRequest.isScript(address(mockScript)));
  }

  function test_setScript_emitsEvent() public {
    MockScript newScript = new MockScript();

    vm.expectEmit(true, false, false, true);
    emit MorphoFlashLoanRequest.ScriptSet(address(newScript), true);

    vm.prank(owner);
    flashLoanRequest.setScript(address(newScript), true);
  }

  function test_setScript_emitsEventOnDewhitelist() public {
    vm.expectEmit(true, false, false, true);
    emit MorphoFlashLoanRequest.ScriptSet(address(mockScript), false);

    vm.prank(owner);
    flashLoanRequest.setScript(address(mockScript), false);
  }

  function test_setScript_revertsWhenNotOwner() public {
    vm.prank(user);
    vm.expectRevert();
    flashLoanRequest.setScript(address(mockScript), true);
  }

  function test_setScript_revertsOnNonContract() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0xbeef)));
    flashLoanRequest.setScript(address(0xbeef), true);
  }

  function test_setScript_allowsDewhitelistNonContract() public {
    // Dewhitelisting a non-contract should not revert (no checkContract on remove)
    vm.prank(owner);
    flashLoanRequest.setScript(address(0xbeef), false);
    assertFalse(flashLoanRequest.isScript(address(0xbeef)));
  }

  function test_isScript_returnsFalseByDefault() public view {
    assertFalse(flashLoanRequest.isScript(address(0xdead)));
  }

  function test_isScript_returnsTrueForWhitelisted() public view {
    assertTrue(flashLoanRequest.isScript(address(mockScript)));
    assertTrue(flashLoanRequest.isScript(address(syncDeposit)));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                E. EXECUTE ACCESS CONTROL                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_execute_revertsWhenNotOwner() public {
    (address script, bytes memory payload) = _noOpScript();
    vm.prank(user);
    vm.expectRevert();
    flashLoanRequest.execute(1e18, _defaultSetRequestParams(), script, payload);
  }

  function test_execute_revertsOnZeroAmount() public {
    (address script, bytes memory payload) = _noOpScript();
    vm.prank(owner);
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    flashLoanRequest.execute(0, _defaultSetRequestParams(), script, payload);
  }

  function test_execute_revertsOnReentrancy() public {
    ReentrantAttacker attacker = new ReentrantAttacker();
    attacker.setTarget(flashLoanRequest);
    attacker.setParams(_defaultSetRequestParams());

    // Whitelist attacker as script
    vm.prank(owner);
    flashLoanRequest.setScript(address(attacker), true);

    // Transfer ownership to attacker so it can call execute
    vm.prank(owner);
    flashLoanRequest.transferOwnership(address(attacker));

    vm.prank(address(attacker));
    vm.expectRevert();
    flashLoanRequest.execute(
      1e18, _defaultSetRequestParams(), address(attacker), abi.encodeCall(ReentrantAttacker.attack, ())
    );
  }

  function test_execute_revertsOnUnauthorizedScript() public {
    MockScript unauthorizedScript = new MockScript();

    vm.prank(owner);
    vm.expectRevert();
    flashLoanRequest.execute(
      1_000e18, _defaultSetRequestParams(), address(unauthorizedScript), abi.encodeCall(MockScript.run, ())
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             F. onMorphoFlashLoan ACCESS CONTROL             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_onMorphoFlashLoan_revertsWhenNotMorpho() public {
    vm.prank(user);
    vm.expectRevert(MorphoFlashLoanRequest.UnauthorizedCaller.selector);
    flashLoanRequest.onMorphoFlashLoan(1e18, bytes(""));
  }

  function test_onMorphoFlashLoan_revertsOnDebtNotRepaid() public {
    (address script, bytes memory payload) = _noOpScript();

    // Execute sets rawDebt in transient storage (persists within Foundry tx)
    vm.prank(owner);
    flashLoanRequest.execute(1_000e18, _defaultSetRequestParams(), script, payload);

    // Prank as Morpho and call callback again — rawDebt is still non-zero
    vm.prank(address(morpho));
    vm.expectRevert(MorphoFlashLoanRequest.DebtNotRepaid.selector);
    flashLoanRequest.onMorphoFlashLoan(1_000e18, bytes(""));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              G. INTEGRATION (FULL EXECUTE CYCLE)            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_execute_fullCycleNoOpScript() public {
    uint256 flashAmount = 1_000e18;
    (address script, bytes memory payload) = _noOpScript();

    uint256 morphoBalBefore = debtToken.balanceOf(address(morpho));

    vm.prank(owner);
    flashLoanRequest.execute(flashAmount, _defaultSetRequestParams(), script, payload);

    // After execution, request should be removed from intent
    (,, address request,) = facility.getIntent(intentId);
    assertEq(request, address(0));

    // Morpho balance should be unchanged
    assertEq(debtToken.balanceOf(address(morpho)), morphoBalBefore);

    // Flash loan request should have no balance
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);
  }

  function test_execute_withDustBalance() public {
    uint256 flashAmount = 1_000e18;
    uint256 dustAmount = 1;
    (address script, bytes memory payload) = _noOpScript();

    // Seed dust into the flash loan request
    debtToken.setBalance(address(flashLoanRequest), dustAmount);

    vm.prank(owner);
    flashLoanRequest.execute(flashAmount, _defaultSetRequestParams(), script, payload);

    // Should succeed despite dust — the fix handles this by setting rawDebt to full balance
    // Dust remains after the cycle
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), dustAmount);
  }

  function test_execute_tokenBalancesCorrect() public {
    uint256 flashAmount = 1_000e18;
    (address script, bytes memory payload) = _noOpScript();

    uint256 morphoBalBefore = debtToken.balanceOf(address(morpho));
    uint256 facilityBalBefore = debtToken.balanceOf(address(facility));

    vm.prank(owner);
    flashLoanRequest.execute(flashAmount, _defaultSetRequestParams(), script, payload);

    // Morpho balance unchanged
    assertEq(debtToken.balanceOf(address(morpho)), morphoBalBefore);

    // Facility balance unchanged
    assertEq(debtToken.balanceOf(address(facility)), facilityBalBefore);

    // Flash loan request has no balance
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);
  }

  function test_execute_multipleSeparateExecutions() public {
    (address script, bytes memory payload) = _noOpScript();

    // Multiple executions on the same flash loan request require separate transactions
    // because rawDebt uses transient storage (cleared between txs, not within a tx).
    // We test this by deploying a second flash loan request proxy.
    address proxy2 = flashLoanFactory.createFlashLoanRequest(owner, address(facility), address(debtToken));
    MorphoFlashLoanRequest flashLoanRequest2 = MorphoFlashLoanRequest(proxy2);

    vm.startPrank(owner);
    facility.grantRoles(proxy2, FACILITATOR_ROLE);
    flashLoanRequest2.setScript(address(mockScript), true);
    vm.stopPrank();

    // First execution with original proxy
    vm.prank(owner);
    flashLoanRequest.execute(500e18, _defaultSetRequestParams(), script, payload);

    (,, address request1,) = facility.getIntent(intentId);
    assertEq(request1, address(0));

    // Second execution with fresh proxy (simulating a separate transaction)
    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);
    uint256 deadline2 = block.timestamp + 2 hours;
    signers[0] = guardian;
    signatures[0] = _signSetRequest(intentId, proxy2, deadline2, GUARDIAN_PK);

    MorphoFlashLoanRequest.SetRequestParams memory params2 = MorphoFlashLoanRequest.SetRequestParams({
      intentId: intentId, deadline: deadline2, signers: signers, signatures: signatures
    });

    vm.prank(owner);
    flashLoanRequest2.execute(500e18, params2, script, payload);

    (,, address request2,) = facility.getIntent(intentId);
    assertEq(request2, address(0));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*           H. SYNC DEPOSIT INTEGRATION TEST                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_execute_syncDepositFullCycle() public {
    // Setup: Create a new intent with targetPM config (depositAsset=debtToken, targetAsset=PM)
    vm.prank(owner);
    uint256 syncIntentId = facility.createIntent(_intentParamsWithTargetPM());

    // Deposit debtToken into the intent (user deposits)
    uint256 depositAmount = 1_000e18;
    _mintDebt(user, depositAmount);
    vm.prank(user);
    facility.deposit(syncIntentId, depositAmount);

    // Move to resolving phase
    vm.warp(block.timestamp + 1 days + 1);

    // Set the mock fund on the intent (requires facilitator + guardian sig)
    vm.prank(facilitator);
    _setFund(syncIntentId, address(mockFund));

    // Configure MockFund for synchronous behavior:
    // create → ACCEPTED, commit → UNLOCKING (sync, skip PROCESSING), unlock → ENDED
    mockFund.setNextCreateState(State.ACCEPTED);
    mockFund.setNextCommitState(State.UNLOCKING);
    mockFund.setNextUnlockState(State.ENDED);
    mockFund.setCommitAmount(depositAmount);

    // Supply collateralToken to MockFund so it can return shares on unlock.
    // sharesFromFund must equal borrowAmount so the PM deposit doesn't net-decrease shares
    // (which would underflow the second intent's zero share balance).
    uint256 sharesFromFund = depositAmount;
    mockFund.setUnlockAmount(sharesFromFund);
    collateralToken.setBalance(address(mockFund), sharesFromFund);

    // Build setRequest params for the new intent
    MorphoFlashLoanRequest.SetRequestParams memory params =
      _buildSetRequestParams(syncIntentId, block.timestamp + 1 hours);

    // Build SyncDeposit script payload
    // borrowAmount = depositAmount to cover the flash loan repay.
    // collateral = sharesFromFund = depositAmount so net share change is zero.
    uint256 borrowAmount = depositAmount;
    bytes memory scriptPayload = abi.encodeCall(
      SyncDeposit.run,
      (address(facility), syncIntentId, depositAmount, depositAmount, borrowAmount, true) // useTarget=true for targetPM
    );

    uint256 morphoBalBefore = debtToken.balanceOf(address(morpho));

    // Execute the flash loan with SyncDeposit
    vm.prank(owner);
    flashLoanRequest.execute(depositAmount, params, address(syncDeposit), scriptPayload);

    // Verify: request removed from intent
    (,, address request,) = facility.getIntent(syncIntentId);
    assertEq(request, address(0));

    // Verify: flash loan fully repaid (Morpho balance only decreased by borrow amount, not flash loan)
    assertEq(debtToken.balanceOf(address(morpho)), morphoBalBefore - borrowAmount);

    // Verify: flash loan request has no leftover balance
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);

    // Verify: collateral was deposited into PM (facility no longer holds it)
    assertEq(collateralToken.balanceOf(address(facility)), 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    I. pullFunds() TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pullFunds_revertsWhenNotFacility() public {
    vm.prank(user);
    vm.expectRevert(MorphoFlashLoanRequest.UnauthorizedCaller.selector);
    flashLoanRequest.pullFunds(1e18, bytes(""));
  }

  function test_pullFunds_transfersTokens() public {
    uint256 amount = 100e18;
    debtToken.setBalance(address(flashLoanRequest), amount);

    // Get the facility address stored in the flash loan request
    address facilityAddr = address(facility);

    vm.prank(facilityAddr);
    flashLoanRequest.pullFunds(amount, bytes(""));

    assertEq(debtToken.balanceOf(facilityAddr), amount);
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      J. repay() TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_repay_allowsRepayWhenRawDebtIsZero() public {
    // Outside flash loan, rawDebt is 0, so the balance check (rawDebt != 0 && balance > rawDebt)
    // passes trivially
    uint256 amount = 100e18;
    debtToken.setBalance(user, amount);

    vm.prank(user);
    debtToken.approve(address(flashLoanRequest), amount);

    vm.prank(user);
    flashLoanRequest.repay(amount);

    assertEq(debtToken.balanceOf(address(flashLoanRequest)), amount);
  }

  function test_repay_revertsOnBalanceExceedsDebt() public {
    (address script, bytes memory payload) = _noOpScript();

    vm.prank(owner);
    flashLoanRequest.execute(1_000e18, _defaultSetRequestParams(), script, payload);

    // Repay more than rawDebt to trigger BalanceExceedsDebt
    uint256 excessAmount = 1_001e18;
    debtToken.setBalance(user, excessAmount);
    vm.prank(user);
    debtToken.approve(address(flashLoanRequest), excessAmount);

    vm.prank(user);
    vm.expectRevert(MorphoFlashLoanRequest.BalanceExceedsDebt.selector);
    flashLoanRequest.repay(excessAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  K. VIEW FUNCTION TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isRepaid_returnsTrueOutsideFlashLoan() public view {
    // rawDebt == 0 means _debt() == 0 means isRepaid == true
    assertTrue(flashLoanRequest.isRepaid());
  }

  function test_isRepaid_revertsOnBalanceExceedsDebt() public {
    (address script, bytes memory payload) = _noOpScript();

    vm.prank(owner);
    flashLoanRequest.execute(1_000e18, _defaultSetRequestParams(), script, payload);

    // Seed tokens to push balance above rawDebt
    debtToken.setBalance(address(flashLoanRequest), 1_001e18);

    vm.expectRevert(MorphoFlashLoanRequest.BalanceExceedsDebt.selector);
    flashLoanRequest.isRepaid();
  }

  function test_syncRepaidStatus_returnsTrueOutsideFlashLoan() public view {
    assertTrue(flashLoanRequest.syncRepaidStatus());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             L. UNSUPPORTED IRequest METHODS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setRepaid_revertsNotSupported() public {
    vm.expectRevert(MorphoFlashLoanRequest.NotSupported.selector);
    flashLoanRequest.setRepaid(0);
  }

  function test_setMintToRepaidDelay_revertsNotSupported() public {
    vm.expectRevert(MorphoFlashLoanRequest.NotSupported.selector);
    flashLoanRequest.setMintToRepaidDelay(0);
  }

  function test_authorizeMinting_revertsNotSupported() public {
    vm.expectRevert(MorphoFlashLoanRequest.NotSupported.selector);
    flashLoanRequest.authorizeMinting(user, 0, 0);
  }

  function test_mint_revertsNotSupported() public {
    vm.expectRevert(MorphoFlashLoanRequest.NotSupported.selector);
    flashLoanRequest.mint(0, 0);
  }

  function test_consume_revertsNotSupported() public {
    Offer memory offer = Offer({maker: user, amount: 0, expectedReturn: 0, nonce: 0, expiration: 0, useCallback: false});
    vm.expectRevert(MorphoFlashLoanRequest.NotSupported.selector);
    flashLoanRequest.consume(offer, bytes(""), 0);
  }

  function test_lastMintTimestamp_returnsZero() public view {
    assertEq(flashLoanRequest.lastMintTimestamp(), 0);
  }

  function test_mintToRepaidDelay_returnsZero() public view {
    assertEq(flashLoanRequest.mintToRepaidDelay(), 0);
  }

  function test_repaidAvailableAt_returnsZero() public view {
    assertEq(flashLoanRequest.repaidAvailableAt(), 0);
  }

  function test_mintAuthorization_returnsZeros() public view {
    (uint128 ptAmount, uint128 ytAmount) = flashLoanRequest.mintAuthorization(user);
    assertEq(ptAmount, 0);
    assertEq(ytAmount, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    M. rescue() TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rescue_transfersTokens() public {
    uint256 amount = 500e18;
    debtToken.setBalance(address(flashLoanRequest), amount);

    vm.prank(owner);
    uint256 rescued = flashLoanRequest.rescue(address(debtToken), user);

    assertEq(rescued, amount);
    assertEq(debtToken.balanceOf(user), amount);
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);
  }

  function test_rescue_revertsWhenNotOwner() public {
    vm.prank(user);
    vm.expectRevert();
    flashLoanRequest.rescue(address(debtToken), user);
  }

  function test_rescue_returnsZeroWhenNoBalance() public {
    vm.prank(owner);
    uint256 rescued = flashLoanRequest.rescue(address(debtToken), user);
    assertEq(rescued, 0);
  }
}
