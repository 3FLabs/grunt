// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {IFacilitySwap, SwapParams} from "src/interfaces/facility/base/IFacilitySwap.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";

/// @title FacilitySwapTest
/// @notice Tests for Facility swap operations
contract FacilitySwapTest is FacilityBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev EIP-712 typehash for SwapParams
  bytes32 internal constant SWAP_PARAMS_TYPEHASH = 0x8b4e182587850acdf21dcf7a0f61b2fd7267c2cdf71d4692b57fb97237a29be3;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SETUP HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates two intents in resolving phase with different tokens
  function _createTwoResolvingIntents() internal returns (uint256 id1, uint256 id2) {
    // Create first intent with PM as deposit asset
    id1 = _createIntentWithDeposits(1000e18);

    // Create second intent with debt token as deposit asset
    vm.prank(owner);
    id2 = facility.createIntent(_intentParamsWithTargetPM());

    // Deposit debt tokens to second intent
    _mintDebt(user2, 1000e18);
    vm.startPrank(user2);
    debtToken.approve(address(facility), 1000e18);
    facility.deposit(id2, 1000e18);
    vm.stopPrank();

    // Warp time again to make the second intent resolving too
    // (the second intent was created after the first warp, so it has a later resolveStart)
    vm.warp(block.timestamp + 1 days + 1);
  }

  /// @notice Helper to get EIP-712 domain separator
  function _domainSeparator() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("3Facility"),
        keccak256("1.0.0"),
        block.chainid,
        address(facility)
      )
    );
  }

  /// @notice Helper to compute swap digest
  function _getSwapDigest(SwapParams memory params) internal view returns (bytes32) {
    bytes32 structHash = keccak256(abi.encode(SWAP_PARAMS_TYPEHASH, params));
    return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
  }

  /// @notice Helper to sign a swap with a guardian's private key
  function _signSwap(SwapParams memory params, uint256 privateKey) internal view returns (bytes memory) {
    bytes32 digest = _getSwapDigest(params);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @notice Creates swap params with valid deadline
  function _createSwapParams(uint256 id1, uint256 id2, uint256 amount1, uint256 amount2)
    internal
    view
    returns (SwapParams memory)
  {
    return SwapParams({
      id1: id1,
      token1: address(positionManager),
      id2: id2,
      token2: address(debtToken),
      amount1: amount1,
      amount2: amount2,
      deadline: block.timestamp + 1 hours
    });
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        SWAP TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Helper to get a specific token balance from an intent
  function _getIntentBalance(uint256 intentId, address token) internal view returns (uint256) {
    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(intentId);
    for (uint256 i = 0; i < tokens.length; i++) {
      if (tokens[i] == token) return amounts[i];
    }
    return 0;
  }

  function test_swap_emitsEvent() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    uint256 amount1 = 100e18;
    uint256 amount2 = 95e18;

    SwapParams memory params = _createSwapParams(id1, id2, amount1, amount2);

    bytes memory sig = _signSwap(params, GUARDIAN_PK);
    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = sig;

    vm.prank(facilitator);
    vm.expectEmit(true, true, false, true);
    emit IFacilitySwap.Swap(id1, id2, address(positionManager), amount1, address(debtToken), amount2);
    facility.swap(params, signers, signatures);
  }

  function test_swap_withMultipleGuardians() public {
    // Create intent with quorum of 2
    vm.prank(owner);
    uint256 id1 = facility.createIntent(_intentParamsWithDualPM());

    // Deposit to first intent
    _depositToPM(user, 1000e18);
    vm.prank(user);
    facility.deposit(id1, 1000e18);

    // Create second intent with quorum of 1
    uint256 id2 = _createIntentWithDeposits(1000e18);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(positionManager),
      id2: id2,
      token2: address(positionManager),
      amount1: 100e18,
      amount2: 100e18,
      deadline: block.timestamp + 1 hours
    });

    // Need 2 signatures (max quorum)
    address[] memory signers = new address[](2);
    bytes[] memory signatures = new bytes[](2);

    // guardian < guardian2 for sorted order
    if (guardian < guardian2) {
      signers[0] = guardian;
      signers[1] = guardian2;
      signatures[0] = _signSwap(params, GUARDIAN_PK);
      signatures[1] = _signSwap(params, GUARDIAN2_PK);
    } else {
      signers[0] = guardian2;
      signers[1] = guardian;
      signatures[0] = _signSwap(params, GUARDIAN2_PK);
      signatures[1] = _signSwap(params, GUARDIAN_PK);
    }

    vm.prank(facilitator);
    facility.swap(params, signers, signatures);
  }

  function test_swap_withZeroQuorum() public {
    // Create intent with 0 quorum
    IntentProperties memory intentParams = _defaultIntentProperties();
    intentParams.quorum = 0;

    vm.prank(owner);
    uint256 id1 = facility.createIntent(intentParams);

    _depositToPM(user, 1000e18);
    vm.prank(user);
    facility.deposit(id1, 1000e18);

    // Create second intent with 0 quorum too
    vm.prank(owner);
    uint256 id2 = facility.createIntent(intentParams);

    _depositToPM(user2, 1000e18);
    vm.prank(user2);
    facility.deposit(id2, 1000e18);

    vm.warp(block.timestamp + 1 days + 1);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(positionManager),
      id2: id2,
      token2: address(positionManager),
      amount1: 100e18,
      amount2: 100e18,
      deadline: block.timestamp + 1 hours
    });

    // No signatures needed with 0 quorum
    address[] memory signers = new address[](0);
    bytes[] memory signatures = new bytes[](0);

    vm.prank(facilitator);
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenPaused() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);

    bytes memory sig = _signSwap(params, GUARDIAN_PK);
    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = sig;

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenNotFacilitator() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);

    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenSameIntent() public {
    uint256 id1 = _createIntentWithDeposits(1000e18);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(positionManager),
      id2: id1, // Same as id1
      token2: address(debtToken),
      amount1: 100e18,
      amount2: 95e18,
      deadline: block.timestamp + 1 hours
    });

    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);

    vm.prank(facilitator);
    vm.expectRevert(LibFacilityErrors.SameIntent.selector);
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenExpired() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);
    params.deadline = block.timestamp - 1; // Expired

    bytes memory sig = _signSwap(params, GUARDIAN_PK);
    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = sig;

    vm.prank(facilitator);
    vm.expectRevert(LibFacilityErrors.SwapExpired.selector);
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenZeroAmount1() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 0, 95e18); // amount1 = 0

    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);

    vm.prank(facilitator);
    vm.expectRevert(LibFacilityErrors.InvalidSwapAmount.selector);
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenZeroAmount2() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 0); // amount2 = 0

    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);

    vm.prank(facilitator);
    vm.expectRevert(LibFacilityErrors.InvalidSwapAmount.selector);
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenNotResolving() public {
    uint256 id1 = _createDefaultIntent();
    uint256 id2 = _createDefaultIntent();

    // Both still in depositing phase
    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);

    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, id1));
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenInvalidSignatureLength() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);

    // Mismatched lengths
    address[] memory signers = new address[](2);
    bytes[] memory signatures = new bytes[](1);

    vm.prank(facilitator);
    vm.expectRevert(LibFacilityErrors.InvalidSignatureLength.selector);
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenInsufficientSignatures() public {
    // Create intent with quorum of 2
    vm.prank(owner);
    uint256 id1 = facility.createIntent(_intentParamsWithDualPM());

    _depositToPM(user, 1000e18);
    vm.prank(user);
    facility.deposit(id1, 1000e18);

    uint256 id2 = _createIntentWithDeposits(1000e18);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(positionManager),
      id2: id2,
      token2: address(positionManager),
      amount1: 100e18,
      amount2: 100e18,
      deadline: block.timestamp + 1 hours
    });

    // Only 1 signature when quorum is 2
    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = _signSwap(params, GUARDIAN_PK);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidSignatureCount.selector, 2, 1));
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenInvalidSignerOrder() public {
    // Create intent with quorum of 2
    vm.prank(owner);
    uint256 id1 = facility.createIntent(_intentParamsWithDualPM());

    _depositToPM(user, 1000e18);
    vm.prank(user);
    facility.deposit(id1, 1000e18);

    uint256 id2 = _createIntentWithDeposits(1000e18);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(positionManager),
      id2: id2,
      token2: address(positionManager),
      amount1: 100e18,
      amount2: 100e18,
      deadline: block.timestamp + 1 hours
    });

    // Signers not in ascending order
    address[] memory signers = new address[](2);
    bytes[] memory signatures = new bytes[](2);

    if (guardian < guardian2) {
      // Put in wrong order (descending)
      signers[0] = guardian2;
      signers[1] = guardian;
      signatures[0] = _signSwap(params, GUARDIAN2_PK);
      signatures[1] = _signSwap(params, GUARDIAN_PK);
    } else {
      signers[0] = guardian;
      signers[1] = guardian2;
      signatures[0] = _signSwap(params, GUARDIAN_PK);
      signatures[1] = _signSwap(params, GUARDIAN2_PK);
    }

    vm.prank(facilitator);
    vm.expectRevert(LibFacilityErrors.InvalidSignerOrder.selector);
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenNotGuardian() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);

    // Sign with non-guardian (user's private key)
    uint256 userPk = 0x9999;
    address userSigner = vm.addr(userPk);

    bytes32 digest = _getSwapDigest(params);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
    bytes memory sig = abi.encodePacked(r, s, v);

    address[] memory signers = new address[](1);
    signers[0] = userSigner;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = sig;

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotGuardian.selector, userSigner));
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenInvalidSignature() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);

    // Create invalid signature (sign different params)
    SwapParams memory differentParams = _createSwapParams(id1, id2, 200e18, 195e18);
    bytes memory invalidSig = _signSwap(differentParams, GUARDIAN_PK);

    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = invalidSig;

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidSignature.selector, guardian));
    facility.swap(params, signers, signatures);
  }

  function test_swap_revertWhenDigestReused() public {
    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);

    bytes memory sig = _signSwap(params, GUARDIAN_PK);
    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = sig;

    // First swap succeeds
    vm.prank(facilitator);
    facility.swap(params, signers, signatures);

    // Compute the expected digest for the error
    bytes32 expectedDigest = _getSwapDigest(params);

    // Second swap with same digest should fail
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.SwapDigestUsed.selector, expectedDigest));
    facility.swap(params, signers, signatures);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_swap_validAmounts(uint256 amount1, uint256 amount2) public {
    amount1 = bound(amount1, 1, 500e18);
    amount2 = bound(amount2, 1, 500e18);

    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, amount1, amount2);

    bytes memory sig = _signSwap(params, GUARDIAN_PK);
    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = sig;

    vm.prank(facilitator);
    facility.swap(params, signers, signatures);
  }

  function testFuzz_swap_validDeadline(uint256 deadlineOffset) public {
    deadlineOffset = bound(deadlineOffset, 1, 365 days);

    (uint256 id1, uint256 id2) = _createTwoResolvingIntents();

    SwapParams memory params = _createSwapParams(id1, id2, 100e18, 95e18);
    params.deadline = block.timestamp + deadlineOffset;

    bytes memory sig = _signSwap(params, GUARDIAN_PK);
    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = sig;

    vm.prank(facilitator);
    facility.swap(params, signers, signatures);
  }
}
