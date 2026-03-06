// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FacilityBaseTest} from "test/facility/FacilityBase.t.sol";
import {MorphoFlashLoanRequest} from "src/request/MorphoFlashLoanRequest.sol";
import {MorphoFlashLoanRequestFactory} from "src/request/MorphoFlashLoanRequestFactory.sol";
import {Offer} from "src/interfaces/request/IOfferReceiver.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      HELPER CONTRACTS                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Simple target contract for operation testing.
contract MockTarget {
  uint256 public lastValue;
  uint256 public callCount;
  bool public shouldRevert;

  function doSomething(uint256 value) external {
    if (shouldRevert) revert("MockTarget: reverted");
    lastValue = value;
    callCount++;
  }

  function setShouldRevert(bool _shouldRevert) external {
    shouldRevert = _shouldRevert;
  }
}

/// @notice Contract that attempts to re-enter execute() when called as an operation.
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
    MorphoFlashLoanRequest.Operation[] memory ops = new MorphoFlashLoanRequest.Operation[](0);
    target.execute(1e18, params, ops);
  }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         TEST CONTRACT                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract MorphoFlashLoanRequestTest is FacilityBaseTest {
  MorphoFlashLoanRequestFactory public flashLoanFactory;
  MorphoFlashLoanRequest public flashLoanRequest;
  MockTarget public mockTarget;

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

    // Deploy MockTarget
    mockTarget = new MockTarget();
    vm.label(address(mockTarget), "MockTarget");

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

  function _noOperations() internal pure returns (MorphoFlashLoanRequest.Operation[] memory) {
    return new MorphoFlashLoanRequest.Operation[](0);
  }

  function _singleOperation() internal view returns (MorphoFlashLoanRequest.Operation[] memory ops) {
    ops = new MorphoFlashLoanRequest.Operation[](1);
    ops[0] = MorphoFlashLoanRequest.Operation({
      target: address(mockTarget), data: abi.encodeCall(MockTarget.doSomething, (42))
    });
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
  /*                D. EXECUTE ACCESS CONTROL                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_execute_revertsWhenNotOwner() public {
    vm.prank(user);
    vm.expectRevert();
    flashLoanRequest.execute(1e18, _defaultSetRequestParams(), _noOperations());
  }

  function test_execute_revertsOnZeroAmount() public {
    vm.prank(owner);
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    flashLoanRequest.execute(0, _defaultSetRequestParams(), _noOperations());
  }

  function test_execute_revertsOnReentrancy() public {
    ReentrantAttacker attacker = new ReentrantAttacker();
    attacker.setTarget(flashLoanRequest);
    attacker.setParams(_defaultSetRequestParams());

    // Transfer ownership to attacker so it can call execute
    vm.prank(owner);
    flashLoanRequest.transferOwnership(address(attacker));

    MorphoFlashLoanRequest.Operation[] memory ops = new MorphoFlashLoanRequest.Operation[](1);
    ops[0] =
      MorphoFlashLoanRequest.Operation({target: address(attacker), data: abi.encodeCall(ReentrantAttacker.attack, ())});

    vm.prank(address(attacker));
    vm.expectRevert();
    flashLoanRequest.execute(1e18, _defaultSetRequestParams(), ops);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             E. onMorphoFlashLoan ACCESS CONTROL             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_onMorphoFlashLoan_revertsWhenNotMorpho() public {
    vm.prank(user);
    vm.expectRevert(MorphoFlashLoanRequest.UnauthorizedCaller.selector);
    flashLoanRequest.onMorphoFlashLoan(1e18, bytes(""));
  }

  function test_onMorphoFlashLoan_revertsOnDebtNotRepaid() public {
    // Execute sets rawDebt in transient storage (persists within Foundry tx)
    vm.prank(owner);
    flashLoanRequest.execute(1_000e18, _defaultSetRequestParams(), _noOperations());

    // Prank as Morpho and call callback again — rawDebt is still non-zero
    vm.prank(address(morpho));
    vm.expectRevert(MorphoFlashLoanRequest.DebtNotRepaid.selector);
    flashLoanRequest.onMorphoFlashLoan(1_000e18, bytes(""));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              F. INTEGRATION (FULL EXECUTE CYCLE)            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_execute_fullCycleNoOperations() public {
    uint256 flashAmount = 1_000e18;

    uint256 morphoBalBefore = debtToken.balanceOf(address(morpho));

    vm.prank(owner);
    flashLoanRequest.execute(flashAmount, _defaultSetRequestParams(), _noOperations());

    // After execution, request should be removed from intent
    (,, address request,) = facility.getIntent(intentId);
    assertEq(request, address(0));

    // Morpho balance should be unchanged
    assertEq(debtToken.balanceOf(address(morpho)), morphoBalBefore);

    // Flash loan request should have no balance
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);

    // Note: isRepaid() cannot be checked here because rawDebt (transient storage)
    // is not cleared within a single Foundry test transaction. In production,
    // transient storage resets between transactions, so isRepaid() returns true.
  }

  function test_execute_fullCycleWithOperations() public {
    uint256 flashAmount = 1_000e18;

    vm.prank(owner);
    flashLoanRequest.execute(flashAmount, _defaultSetRequestParams(), _singleOperation());

    // Verify the operation was executed
    assertEq(mockTarget.lastValue(), 42);
    assertEq(mockTarget.callCount(), 1);

    // Request removed
    (,, address request,) = facility.getIntent(intentId);
    assertEq(request, address(0));
  }

  function test_execute_fullCycleWithMultipleOperations() public {
    uint256 flashAmount = 1_000e18;

    MorphoFlashLoanRequest.Operation[] memory ops = new MorphoFlashLoanRequest.Operation[](3);
    ops[0] = MorphoFlashLoanRequest.Operation({
      target: address(mockTarget), data: abi.encodeCall(MockTarget.doSomething, (1))
    });
    ops[1] = MorphoFlashLoanRequest.Operation({
      target: address(mockTarget), data: abi.encodeCall(MockTarget.doSomething, (2))
    });
    ops[2] = MorphoFlashLoanRequest.Operation({
      target: address(mockTarget), data: abi.encodeCall(MockTarget.doSomething, (3))
    });

    vm.prank(owner);
    flashLoanRequest.execute(flashAmount, _defaultSetRequestParams(), ops);

    assertEq(mockTarget.lastValue(), 3);
    assertEq(mockTarget.callCount(), 3);
  }

  function test_execute_withDustBalance() public {
    uint256 flashAmount = 1_000e18;
    uint256 dustAmount = 1;

    // Seed dust into the flash loan request
    debtToken.setBalance(address(flashLoanRequest), dustAmount);

    vm.prank(owner);
    flashLoanRequest.execute(flashAmount, _defaultSetRequestParams(), _noOperations());

    // Should succeed despite dust — the fix handles this by setting rawDebt to full balance
    // Dust remains after the cycle
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), dustAmount);
  }

  function test_execute_tokenBalancesCorrect() public {
    uint256 flashAmount = 1_000e18;

    uint256 morphoBalBefore = debtToken.balanceOf(address(morpho));
    uint256 facilityBalBefore = debtToken.balanceOf(address(facility));

    vm.prank(owner);
    flashLoanRequest.execute(flashAmount, _defaultSetRequestParams(), _noOperations());

    // Morpho balance unchanged
    assertEq(debtToken.balanceOf(address(morpho)), morphoBalBefore);

    // Facility balance unchanged
    assertEq(debtToken.balanceOf(address(facility)), facilityBalBefore);

    // Flash loan request has no balance
    assertEq(debtToken.balanceOf(address(flashLoanRequest)), 0);
  }

  function test_execute_revertsWhenOperationReverts() public {
    mockTarget.setShouldRevert(true);

    vm.prank(owner);
    vm.expectRevert();
    flashLoanRequest.execute(1_000e18, _defaultSetRequestParams(), _singleOperation());
  }

  function test_execute_multipleSeparateExecutions() public {
    // Multiple executions on the same flash loan request require separate transactions
    // because rawDebt uses transient storage (cleared between txs, not within a tx).
    // We test this by deploying a second flash loan request proxy.
    address proxy2 = flashLoanFactory.createFlashLoanRequest(owner, address(facility), address(debtToken));
    MorphoFlashLoanRequest flashLoanRequest2 = MorphoFlashLoanRequest(proxy2);

    vm.prank(owner);
    facility.grantRoles(proxy2, FACILITATOR_ROLE);

    // First execution with original proxy
    vm.prank(owner);
    flashLoanRequest.execute(500e18, _defaultSetRequestParams(), _noOperations());

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
    flashLoanRequest2.execute(500e18, params2, _noOperations());

    (,, address request2,) = facility.getIntent(intentId);
    assertEq(request2, address(0));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    G. pullFunds() TESTS                     */
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
  /*                      H. repay() TESTS                       */
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
    vm.prank(owner);
    flashLoanRequest.execute(1_000e18, _defaultSetRequestParams(), _noOperations());

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
  /*                  I. VIEW FUNCTION TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isRepaid_returnsTrueOutsideFlashLoan() public view {
    // rawDebt == 0 means _debt() == 0 means isRepaid == true
    assertTrue(flashLoanRequest.isRepaid());
  }

  function test_isRepaid_revertsOnBalanceExceedsDebt() public {
    vm.prank(owner);
    flashLoanRequest.execute(1_000e18, _defaultSetRequestParams(), _noOperations());

    // Seed tokens to push balance above rawDebt
    debtToken.setBalance(address(flashLoanRequest), 1_001e18);

    vm.expectRevert(MorphoFlashLoanRequest.BalanceExceedsDebt.selector);
    flashLoanRequest.isRepaid();
  }

  function test_syncRepaidStatus_returnsTrueOutsideFlashLoan() public view {
    assertTrue(flashLoanRequest.syncRepaidStatus());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             J. UNSUPPORTED IRequest METHODS                 */
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
  /*                    K. rescue() TESTS                        */
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
