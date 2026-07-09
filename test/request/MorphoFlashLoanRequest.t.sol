// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FacilityBaseTest} from "test/facility/FacilityBase.t.sol";
import {MorphoFlashLoanRequest} from "src/request/MorphoFlashLoanRequest.sol";
import {MorphoFlashLoanRequestFactory} from "src/request/MorphoFlashLoanRequestFactory.sol";
import {SyncDeposit} from "src/request/scripts/SyncDeposit.sol";
import {SyncWithdrawal} from "src/request/scripts/SyncWithdrawal.sol";
import {SyncAllocatorDeposit} from "src/request/scripts/SyncAllocatorDeposit.sol";
import {IMorphoAllocator} from "src/interfaces/request/IMorphoAllocator.sol";
import {MockMorphoAllocator} from "test/mock/request/MockMorphoAllocator.sol";
import {Offer} from "src/interfaces/request/IOfferReceiver.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {Mode, State} from "src/libs/funds/Order.sol";
import {IntentProperties, Asset} from "src/libs/facility/LibIntent.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      HELPER CONTRACTS                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Simple no-op script for basic flash loan mechanic tests.
contract MockScript {
  function run() external {}
}

/// @notice Contract that triggers an excess repay during the flash loan callback.
///         Called by CallbackScript via delegatecall → external call.
contract ExcessRepayer {
  MorphoFlashLoanRequest public target;
  MockERC20 public token;
  uint256 public amount;

  constructor(MorphoFlashLoanRequest _target, MockERC20 _token, uint256 _amount) {
    target = _target;
    token = _token;
    amount = _amount;
    token.approve(address(_target), type(uint256).max);
  }

  function doRepay() external {
    target.repay(amount);
  }
}

/// @notice Contract that seeds excess tokens then calls isRepaid() during the callback.
contract IsRepaidChecker {
  MorphoFlashLoanRequest public target;
  MockERC20 public token;
  uint256 public amount;

  constructor(MorphoFlashLoanRequest _target, MockERC20 _token, uint256 _amount) {
    target = _target;
    token = _token;
    amount = _amount;
  }

  function checkIsRepaid() external {
    token.mint(address(target), amount);
    target.isRepaid();
  }
}

/// @notice Script that calls an external contract during the flash loan callback.
contract CallbackScript {
  function runRepay(address repayer) external {
    ExcessRepayer(repayer).doRepay();
  }

  function runIsRepaidCheck(address checker) external {
    IsRepaidChecker(checker).checkIsRepaid();
  }
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
  SyncWithdrawal public syncWithdrawal;
  SyncAllocatorDeposit public syncAllocatorDeposit;
  MockMorphoAllocator public mockAllocator;

  address public executor = makeAddr("executor");

  uint256 public intentId;

  function setUp() public override {
    super.setUp();

    // Deploy factory
    flashLoanFactory = new MorphoFlashLoanRequestFactory(owner, morpho);
    vm.label(address(flashLoanFactory), "FlashLoanFactory");

    // Create proxy via factory
    address proxy = flashLoanFactory.createFlashLoanRequest(owner, executor, address(facility), address(debtToken));
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

    // Deploy and whitelist SyncWithdrawal
    syncWithdrawal = new SyncWithdrawal();
    vm.label(address(syncWithdrawal), "SyncWithdrawal");
    vm.prank(owner);
    flashLoanRequest.setScript(address(syncWithdrawal), true);

    // Deploy and whitelist SyncAllocatorDeposit
    syncAllocatorDeposit = new SyncAllocatorDeposit();
    vm.label(address(syncAllocatorDeposit), "SyncAllocatorDeposit");
    vm.prank(owner);
    flashLoanRequest.setScript(address(syncAllocatorDeposit), true);

    // Deploy a MorphoAllocator test double and wire its roles:
    // - it holds FACILITATOR_ROLE on the facility (to unlock + depositManager)
    // - the flash loan request proxy holds EXECUTOR_ROLE on it (msg.sender under delegatecall)
    mockAllocator = new MockMorphoAllocator(owner, address(facility));
    vm.label(address(mockAllocator), "MockMorphoAllocator");
    vm.prank(owner);
    facility.grantRoles(address(mockAllocator), FACILITATOR_ROLE);
    vm.prank(owner);
    mockAllocator.grantRoles(address(flashLoanRequest), 1); // EXECUTOR_ROLE == _ROLE_0

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

  function _syncWithdrawalPayload(uint256 _intentId, uint256 withdrawAmount, uint256 repayAmount)
    internal
    view
    returns (bytes memory)
  {
    return abi.encodeCall(
      SyncWithdrawal.run,
      (address(facility), _intentId, withdrawAmount, repayAmount, true, WithdrawalStrategy.SEQUENTIAL, repayAmount)
    );
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
    // Check indexed owner and non-indexed data (executor, facility, asset); skip checking flashLoanRequest address
    vm.expectEmit(false, true, false, true);
    emit MorphoFlashLoanRequestFactory.FlashLoanRequestCreated(
      address(0), owner, executor, address(facility), address(debtToken)
    );
    flashLoanFactory.createFlashLoanRequest(owner, executor, address(facility), address(debtToken));
  }

  function test_factory_createMultiple() public {
    address proxy2 = flashLoanFactory.createFlashLoanRequest(owner, executor, address(facility), address(debtToken));
    address proxy3 = flashLoanFactory.createFlashLoanRequest(owner, executor, address(facility), address(debtToken));

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
    impl.initialize(owner, executor, address(facility), address(debtToken));
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
    flashLoanFactory.createFlashLoanRequest(address(0), executor, address(facility), address(debtToken));
  }

  function test_initialize_revertsOnZeroExecutor() public {
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    flashLoanFactory.createFlashLoanRequest(owner, address(0), address(facility), address(debtToken));
  }

  function test_initialize_revertsOnNonContractFacility() public {
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0xbeef)));
    flashLoanFactory.createFlashLoanRequest(owner, executor, address(0xbeef), address(debtToken));
  }

  function test_initialize_revertsOnNonContractAsset() public {
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0xbeef)));
    flashLoanFactory.createFlashLoanRequest(owner, executor, address(facility), address(0xbeef));
  }

  function test_initialize_revertsOnDoubleInit() public {
    vm.expectRevert();
    flashLoanRequest.initialize(owner, executor, address(facility), address(debtToken));
  }

  function test_initialize_setsExecutorRole() public view {
    assertTrue(flashLoanRequest.hasAllRoles(executor, 1 << 0));
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

  function test_execute_revertsWhenNotExecutor() public {
    (address script, bytes memory payload) = _noOpScript();
    vm.prank(user);
    vm.expectRevert();
    flashLoanRequest.execute(1e18, _defaultSetRequestParams(), script, payload);
  }

  function test_execute_revertsWhenOwner() public {
    (address script, bytes memory payload) = _noOpScript();
    vm.prank(owner);
    vm.expectRevert();
    flashLoanRequest.execute(1e18, _defaultSetRequestParams(), script, payload);
  }

  function test_execute_revertsOnZeroAmount() public {
    (address script, bytes memory payload) = _noOpScript();
    vm.prank(executor);
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

    // Grant executor role to attacker so it can call execute
    vm.prank(owner);
    flashLoanRequest.grantRoles(address(attacker), 1 << 0);

    vm.prank(address(attacker));
    vm.expectRevert();
    flashLoanRequest.execute(
      1e18, _defaultSetRequestParams(), address(attacker), abi.encodeCall(ReentrantAttacker.attack, ())
    );
  }

  function test_execute_revertsOnUnauthorizedScript() public {
    MockScript unauthorizedScript = new MockScript();

    vm.prank(executor);
    vm.expectRevert();
    flashLoanRequest.execute(
      1_000e18, _defaultSetRequestParams(), address(unauthorizedScript), abi.encodeCall(MockScript.run, ())
    );
  }

  function test_setScript_revertsWhenExecutor() public {
    vm.prank(executor);
    vm.expectRevert();
    flashLoanRequest.setScript(address(mockScript), true);
  }

  function test_rescue_revertsWhenExecutor() public {
    vm.prank(executor);
    vm.expectRevert();
    flashLoanRequest.rescue(address(debtToken), executor);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             F. onMorphoFlashLoan ACCESS CONTROL             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_onMorphoFlashLoan_revertsWhenNotMorpho() public {
    vm.prank(user);
    vm.expectRevert(MorphoFlashLoanRequest.UnauthorizedCaller.selector);
    flashLoanRequest.onMorphoFlashLoan(1e18, bytes(""));
  }

  function test_isRepaid_returnsTrueAfterExecute() public {
    (address script, bytes memory payload) = _noOpScript();

    vm.prank(executor);
    flashLoanRequest.execute(1_000e18, _defaultSetRequestParams(), script, payload);

    // Raw debt is cleared at the end of the callback, so isRepaid() returns true
    assertTrue(flashLoanRequest.isRepaid());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              G. INTEGRATION (FULL EXECUTE CYCLE)            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_execute_fullCycleNoOpScript() public {
    uint256 flashAmount = 1_000e18;
    (address script, bytes memory payload) = _noOpScript();

    uint256 morphoBalBefore = debtToken.balanceOf(address(morpho));

    vm.prank(executor);
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

    vm.prank(executor);
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

    vm.prank(executor);
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
    address proxy2 = flashLoanFactory.createFlashLoanRequest(owner, executor, address(facility), address(debtToken));
    MorphoFlashLoanRequest flashLoanRequest2 = MorphoFlashLoanRequest(proxy2);

    vm.startPrank(owner);
    facility.grantRoles(proxy2, FACILITATOR_ROLE);
    flashLoanRequest2.setScript(address(mockScript), true);
    vm.stopPrank();

    // First execution with original proxy
    vm.prank(executor);
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

    vm.prank(executor);
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
    vm.prank(executor);
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
  /*       H1b. SYNC ALLOCATOR DEPOSIT INTEGRATION TEST           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Sets up a fresh targetPM intent in the resolving phase with the mock fund configured for a
  ///      synchronous deposit (create → ACCEPTED, commit → UNLOCKING, unlock → ENDED). Returns the
  ///      intent ID and the amount used for the fund deposit / shares / borrow.
  function _setupSyncAllocatorIntent() internal returns (uint256 syncIntentId, uint256 amount) {
    vm.prank(owner);
    syncIntentId = facility.createIntent(_intentParamsWithTargetPM());

    amount = 1_000e18;
    _mintDebt(user, amount);
    vm.prank(user);
    facility.deposit(syncIntentId, amount);

    // Move to resolving phase
    vm.warp(block.timestamp + 1 days + 1);

    // Set the mock fund on the intent (requires facilitator + guardian sig)
    vm.prank(facilitator);
    _setFund(syncIntentId, address(mockFund));

    mockFund.setNextCreateState(State.ACCEPTED);
    mockFund.setNextCommitState(State.UNLOCKING);
    mockFund.setNextUnlockState(State.ENDED);
    mockFund.setCommitAmount(amount);

    // sharesFromFund == amount so the PM deposit nets to zero shares on the facility.
    mockFund.setUnlockAmount(amount);
    collateralToken.setBalance(address(mockFund), amount);
  }

  function _emptyMarket() internal pure returns (MarketParams memory) {
    return MarketParams(address(0), address(0), address(0), address(0), 0);
  }

  /// @dev Default empty-rebalance SyncAllocatorDeposit payload (borrow == amount, targetPM).
  function _syncAllocatorDepositPayload(uint256 _intentId, uint256 amount) internal view returns (bytes memory) {
    SyncAllocatorDeposit.AllocatorParams memory allocatorParams = SyncAllocatorDeposit.AllocatorParams({
      deallocations: new IMorphoAllocator.Deallocation[](0),
      allocateAdapter: address(0),
      allocateMarket: _emptyMarket(),
      depositAmount: amount,
      borrowAmount: amount,
      useTarget: true,
      minSharesUnlocked: 0
    });
    return abi.encodeCall(
      SyncAllocatorDeposit.run, (address(facility), address(mockAllocator), _intentId, amount, amount, allocatorParams)
    );
  }

  function test_execute_syncAllocatorDepositFullCycle() public {
    (uint256 syncIntentId, uint256 amount) = _setupSyncAllocatorIntent();

    MorphoFlashLoanRequest.SetRequestParams memory params =
      _buildSetRequestParams(syncIntentId, block.timestamp + 1 hours);

    // Empty rebalance: no deallocations, allocation skipped (allocateAdapter == address(0)).
    // borrowAmount = amount; the allocator deposits the measured unlocked amount.
    SyncAllocatorDeposit.AllocatorParams memory allocatorParams = SyncAllocatorDeposit.AllocatorParams({
      deallocations: new IMorphoAllocator.Deallocation[](0),
      allocateAdapter: address(0),
      allocateMarket: _emptyMarket(),
      depositAmount: amount,
      borrowAmount: amount,
      useTarget: true, // targetPM
      minSharesUnlocked: 0
    });

    bytes memory scriptPayload = abi.encodeCall(
      SyncAllocatorDeposit.run,
      (address(facility), address(mockAllocator), syncIntentId, amount, amount, allocatorParams)
    );

    uint256 morphoBalBefore = debtToken.balanceOf(address(morpho));

    vm.prank(executor);
    flashLoanRequest.execute(amount, params, address(syncAllocatorDeposit), scriptPayload);

    // Verify: request removed from intent
    (,, address request,) = facility.getIntent(syncIntentId);
    assertEq(request, address(0));

    // Verify: flash loan fully repaid (Morpho balance only decreased by borrow amount, not flash loan)
    assertEq(debtToken.balanceOf(address(morpho)), morphoBalBefore - amount);

    // Verify: flash loan request has no leftover balance
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);

    // Verify: collateral was deposited into PM (facility no longer holds it)
    assertEq(collateralToken.balanceOf(address(facility)), 0);

    // Verify: the allocator deposited the measured unlocked amount and received the routed params
    assertEq(mockAllocator.lastDepositAmount(), amount);
    assertEq(mockAllocator.lastBorrowAmount(), amount);
    assertEq(mockAllocator.lastDeallocationsLength(), 0);
    assertEq(mockAllocator.lastAllocateAdapter(), address(0));
    assertTrue(mockAllocator.lastUseTarget());
  }

  function test_execute_syncAllocatorDeposit_depositsFullUnlockedAmount() public {
    (uint256 syncIntentId, uint256 amount) = _setupSyncAllocatorIntent();

    // The fund returns more shares than predicted (favorable NAV move between order creation and
    // unlock). The params still carry depositAmount == amount (the stale prediction); the script
    // ignores it and the allocator deposits the full measured amount.
    uint256 unlockedAmount = amount + 50e18;
    mockFund.setUnlockAmount(unlockedAmount);
    collateralToken.setBalance(address(mockFund), unlockedAmount);

    MorphoFlashLoanRequest.SetRequestParams memory params =
      _buildSetRequestParams(syncIntentId, block.timestamp + 1 hours);
    bytes memory scriptPayload = _syncAllocatorDepositPayload(syncIntentId, amount);

    vm.prank(executor);
    flashLoanRequest.execute(amount, params, address(syncAllocatorDeposit), scriptPayload);

    // The full unlocked amount was deposited into the PM; no collateral dust left on the facility.
    assertEq(mockAllocator.lastDepositAmount(), unlockedAmount);
    assertEq(collateralToken.balanceOf(address(facility)), 0);
  }

  function test_execute_syncAllocatorDeposit_forwardsDeallocations() public {
    (uint256 syncIntentId, uint256 amount) = _setupSyncAllocatorIntent();

    MorphoFlashLoanRequest.SetRequestParams memory params =
      _buildSetRequestParams(syncIntentId, block.timestamp + 1 hours);

    // Non-empty rebalance: proves the calldata array survives delegatecall + encode/decode round-trip.
    IMorphoAllocator.Deallocation[] memory deallocations = new IMorphoAllocator.Deallocation[](1);
    deallocations[0] = IMorphoAllocator.Deallocation({
      adapter: address(0xADA9), marketParams: _emptyMarket(), amount: 123, maxUtilisation: 1e18
    });

    SyncAllocatorDeposit.AllocatorParams memory allocatorParams = SyncAllocatorDeposit.AllocatorParams({
      deallocations: deallocations,
      allocateAdapter: address(0xBEEF),
      allocateMarket: _emptyMarket(),
      depositAmount: amount,
      borrowAmount: amount,
      useTarget: true,
      minSharesUnlocked: 0
    });

    bytes memory scriptPayload = abi.encodeCall(
      SyncAllocatorDeposit.run,
      (address(facility), address(mockAllocator), syncIntentId, amount, amount, allocatorParams)
    );

    vm.prank(executor);
    flashLoanRequest.execute(amount, params, address(syncAllocatorDeposit), scriptPayload);

    assertEq(mockAllocator.lastDeallocationsLength(), 1);
    assertEq(mockAllocator.lastAllocateAdapter(), address(0xBEEF));
  }

  function test_execute_syncAllocatorDeposit_revertsWhenRequestLacksExecutorRole() public {
    // Remove EXECUTOR_ROLE from the request proxy on the allocator.
    vm.prank(owner);
    mockAllocator.revokeRoles(address(flashLoanRequest), 1);

    (uint256 syncIntentId, uint256 amount) = _setupSyncAllocatorIntent();

    MorphoFlashLoanRequest.SetRequestParams memory params =
      _buildSetRequestParams(syncIntentId, block.timestamp + 1 hours);
    bytes memory scriptPayload = _syncAllocatorDepositPayload(syncIntentId, amount);

    vm.prank(executor);
    vm.expectRevert();
    flashLoanRequest.execute(amount, params, address(syncAllocatorDeposit), scriptPayload);
  }

  function test_execute_syncAllocatorDeposit_revertsWhenAllocatorLacksFacilitatorRole() public {
    // Remove FACILITATOR_ROLE from the allocator on the facility (so unlock reverts).
    vm.prank(owner);
    facility.revokeRoles(address(mockAllocator), FACILITATOR_ROLE);

    (uint256 syncIntentId, uint256 amount) = _setupSyncAllocatorIntent();

    MorphoFlashLoanRequest.SetRequestParams memory params =
      _buildSetRequestParams(syncIntentId, block.timestamp + 1 hours);
    bytes memory scriptPayload = _syncAllocatorDepositPayload(syncIntentId, amount);

    vm.prank(executor);
    vm.expectRevert();
    flashLoanRequest.execute(amount, params, address(syncAllocatorDeposit), scriptPayload);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*          H2. SYNC WITHDRAWAL INTEGRATION TEST                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_execute_syncWithdrawalFullCycle() public {
    uint256 amount = 1_000e18;
    uint256 morphoBalBefore = debtToken.balanceOf(address(morpho));

    // ── Phase 1: Run SyncDeposit to create a PM position to unwind ──

    // Snapshot Morpho position before SyncDeposit to measure actual deltas
    uint256 pmCollateralBefore = borrowPosition.totalCollateral();
    uint256 pmDebtBefore = borrowPosition.totalBorrowed();

    uint256 syncIntentId;
    {
      vm.prank(owner);
      syncIntentId = facility.createIntent(_intentParamsWithTargetPM());

      _mintDebt(user, amount);
      vm.prank(user);
      facility.deposit(syncIntentId, amount);

      vm.warp(block.timestamp + 1 days + 1);

      vm.prank(facilitator);
      _setFund(syncIntentId, address(mockFund));

      mockFund.setNextCreateState(State.ACCEPTED);
      mockFund.setNextCommitState(State.UNLOCKING);
      mockFund.setNextUnlockState(State.ENDED);
      mockFund.setCommitAmount(amount);
      mockFund.setUnlockAmount(amount);
      collateralToken.setBalance(address(mockFund), amount);

      vm.prank(executor);
      flashLoanRequest.execute(
        amount,
        _buildSetRequestParams(syncIntentId, block.timestamp + 1 hours),
        address(syncDeposit),
        abi.encodeCall(SyncDeposit.run, (address(facility), syncIntentId, amount, amount, amount, true))
      );
    }

    // ── Intermediate checks: capture actual on-chain state after SyncDeposit ──

    // Morpho balance decreased by borrowed amount
    assertEq(debtToken.balanceOf(address(morpho)), morphoBalBefore - amount);

    // Facility holds user's original debtToken deposit, no collateral
    assertEq(debtToken.balanceOf(address(facility)), amount);
    assertEq(collateralToken.balanceOf(address(facility)), 0);

    // Flash loan request fully repaid
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);

    // MockFund received debtToken from deposit commit, sent all collateralToken during unlock
    assertEq(debtToken.balanceOf(address(mockFund)), amount);
    assertEq(collateralToken.balanceOf(address(mockFund)), 0);

    // Capture actual PM position delta from Morpho (avoids off-chain assumptions)
    uint256 actualCollateralDeposited = borrowPosition.totalCollateral() - pmCollateralBefore;
    uint256 actualDebtBorrowed = borrowPosition.totalBorrowed() - pmDebtBefore;
    assertTrue(actualCollateralDeposited > 0, "PM should have new collateral");
    assertTrue(actualDebtBorrowed > 0, "PM should have new debt");

    // ── Phase 2: Run SyncWithdrawal to unwind the position ──

    // Use actual Morpho position deltas for withdrawal amounts
    bytes memory withdrawPayload = _syncWithdrawalPayload(syncIntentId, actualCollateralDeposited, actualDebtBorrowed);

    address proxy2;
    {
      // Deploy a second flash loan request proxy (transient storage requires separate proxy)
      proxy2 = flashLoanFactory.createFlashLoanRequest(owner, executor, address(facility), address(debtToken));

      vm.startPrank(owner);
      facility.grantRoles(proxy2, FACILITATOR_ROLE);
      MorphoFlashLoanRequest(proxy2).setScript(address(syncWithdrawal), true);
      vm.stopPrank();

      // Re-set fund on intent (was cleared when SyncDeposit's unlock returned ENDED)
      {
        address[] memory fundSigners = new address[](1);
        bytes[] memory fundSigs = new bytes[](1);
        uint256 fundDeadline = block.timestamp + 3 hours;
        fundSigners[0] = guardian;
        fundSigs[0] = _signSetFund(syncIntentId, address(mockFund), fundDeadline, GUARDIAN_PK);
        vm.prank(facilitator);
        _setFund(syncIntentId, address(mockFund), fundDeadline, fundSigners, fundSigs);
      }

      // Configure MockFund for synchronous redeem using actual amounts
      mockFund.setCommitAmount(actualCollateralDeposited);
      mockFund.setUnlockAmount(actualDebtBorrowed);
      // Seed fund with enough debtToken for unlock if needed
      uint256 fundDebtBal = debtToken.balanceOf(address(mockFund));
      if (actualDebtBorrowed > fundDebtBal) {
        debtToken.setBalance(address(mockFund), actualDebtBorrowed);
      }

      // Build setRequest params for the second proxy
      address[] memory signers = new address[](1);
      bytes[] memory sigs = new bytes[](1);
      signers[0] = guardian;
      sigs[0] = _signSetRequest(syncIntentId, proxy2, block.timestamp + 2 hours, GUARDIAN_PK);

      // Flash loan amount = actualDebtBorrowed (need enough debtToken to repay PM)
      vm.prank(executor);
      MorphoFlashLoanRequest(proxy2)
        .execute(
          actualDebtBorrowed,
          MorphoFlashLoanRequest.SetRequestParams({
            intentId: syncIntentId, deadline: block.timestamp + 2 hours, signers: signers, signatures: sigs
          }),
          address(syncWithdrawal),
          withdrawPayload
        );
    }

    // ── Final verification ──

    // Request removed from intent
    (,, address request,) = facility.getIntent(syncIntentId);
    assertEq(request, address(0));

    // Morpho balance restored (PM debt fully repaid + flash loan repaid)
    assertEq(debtToken.balanceOf(address(morpho)), morphoBalBefore);

    // PM position unwound back to pre-deposit state
    assertEq(borrowPosition.totalCollateral(), pmCollateralBefore);
    assertEq(borrowPosition.totalBorrowed(), pmDebtBefore);

    // Flash loan request proxies have no leftover balance
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);
    assertEq(debtToken.balanceOf(proxy2), 0);

    // Facility retains the user's original deposit, no collateral
    assertEq(debtToken.balanceOf(address(facility)), amount);
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
    uint256 flashAmount = 1_000e18;
    uint256 excessAmount = 1_001e18;

    // Deploy attacker that will call repay() with excess during the callback
    ExcessRepayer repayer = new ExcessRepayer(flashLoanRequest, debtToken, excessAmount);
    debtToken.setBalance(address(repayer), excessAmount);

    CallbackScript script = new CallbackScript();
    vm.prank(owner);
    flashLoanRequest.setScript(address(script), true);

    vm.prank(executor);
    vm.expectRevert(MorphoFlashLoanRequest.BalanceExceedsDebt.selector);
    flashLoanRequest.execute(
      flashAmount,
      _defaultSetRequestParams(),
      address(script),
      abi.encodeCall(CallbackScript.runRepay, (address(repayer)))
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  K. VIEW FUNCTION TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isRepaid_returnsTrueOutsideFlashLoan() public view {
    // rawDebt == 0 means _debt() == 0 means isRepaid == true
    assertTrue(flashLoanRequest.isRepaid());
  }

  function test_isRepaid_revertsOnBalanceExceedsDebt() public {
    uint256 flashAmount = 1_000e18;
    uint256 excessAmount = 1_001e18; // Must exceed rawDebt (== flashAmount) after pull() zeroes balance

    // Deploy checker that mints excess tokens then calls isRepaid() during the callback
    IsRepaidChecker checker = new IsRepaidChecker(flashLoanRequest, debtToken, excessAmount);

    CallbackScript script = new CallbackScript();
    vm.prank(owner);
    flashLoanRequest.setScript(address(script), true);

    vm.prank(executor);
    vm.expectRevert(MorphoFlashLoanRequest.BalanceExceedsDebt.selector);
    flashLoanRequest.execute(
      flashAmount,
      _defaultSetRequestParams(),
      address(script),
      abi.encodeCall(CallbackScript.runIsRepaidCheck, (address(checker)))
    );
  }

  function test_syncRepaidStatus_returnsTrueOutsideFlashLoan() public view {
    assertTrue(flashLoanRequest.syncRepaidStatus());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             L. UNSUPPORTED IRequest METHODS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setRepaid_revertsNotSupported() public {
    vm.expectRevert(MorphoFlashLoanRequest.NotSupported.selector);
    flashLoanRequest.setRepaid(0, 0);
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
