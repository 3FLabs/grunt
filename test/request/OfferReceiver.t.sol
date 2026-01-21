// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockOfferReceiver} from "../mock/request/MockOfferReceiver.sol";
import {Offer} from "../../src/interfaces/request/IOfferReceiver.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../src/libs/common/LibCommonErrors.sol";

contract OfferReceiverTest is Test {
  MockOfferReceiver public receiver;

  // Test wallets
  Vm.Wallet internal maker;
  Vm.Wallet internal maker2;
  Vm.Wallet internal maker3;

  // Constants for EIP-712
  bytes32 internal constant OFFER_TYPEHASH = 0x3ded0c963332962cf2d273c8fb4f3e69f4ef33407ca72484fcebb56263ad0664;

  // Events (for testing emission)
  event NonceUpdated(address indexed maker, uint256 newNonce);

  function setUp() public {
    receiver = new MockOfferReceiver("MockOfferReceiver", "MOR");
    maker = vm.createWallet("maker");
    maker2 = vm.createWallet("maker2");
    maker3 = vm.createWallet("maker3");
  }

  /// @notice Helper function to create a valid offer
  function _createOffer(
    address maker_,
    uint256 amount,
    uint256 expectedReturn,
    uint256 nonce_,
    uint256 expiration,
    bool useCallback
  ) internal pure returns (Offer memory) {
    return Offer({
      maker: maker_,
      amount: amount,
      expectedReturn: expectedReturn,
      nonce: nonce_,
      expiration: expiration,
      useCallback: useCallback
    });
  }

  /// @notice Helper function to sign an offer using EIP-712
  function _signOffer(Offer memory offer, Vm.Wallet memory wallet) internal returns (bytes memory) {
    bytes32 structHash = keccak256(
      abi.encode(
        OFFER_TYPEHASH,
        offer.maker,
        offer.amount,
        offer.expectedReturn,
        offer.nonce,
        offer.expiration,
        offer.useCallback
      )
    );
    bytes32 digest = receiver.hashTypedData(structHash);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
    return abi.encodePacked(r, s, v);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      NONCE TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_InitialNonceIsZero() public view {
    assertEq(receiver.nonce(maker.addr), 0);
    assertEq(receiver.nonce(maker2.addr), 0);
    assertEq(receiver.nonce(maker3.addr), 0);
  }

  function test_SetNonce() public {
    vm.prank(maker.addr);
    receiver.setNonce(5);
    assertEq(receiver.nonce(maker.addr), 5);
  }

  function test_SetNonceMultipleTimes() public {
    vm.startPrank(maker.addr);
    receiver.setNonce(5);
    assertEq(receiver.nonce(maker.addr), 5);

    receiver.setNonce(10);
    assertEq(receiver.nonce(maker.addr), 10);

    receiver.setNonce(100);
    assertEq(receiver.nonce(maker.addr), 100);
    vm.stopPrank();
  }

  function test_RevertWhen_SetNonceToSameValue() public {
    vm.startPrank(maker.addr);
    receiver.setNonce(5);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonceUpdate.selector));
    receiver.setNonce(5);
    vm.stopPrank();
  }

  function test_RevertWhen_SetNonceToLowerValue() public {
    vm.startPrank(maker.addr);
    receiver.setNonce(10);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonceUpdate.selector));
    receiver.setNonce(5);
    vm.stopPrank();
  }

  function test_RevertWhen_SetNonceToZeroFromZero() public {
    vm.prank(maker.addr);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonceUpdate.selector));
    receiver.setNonce(0);
  }

  function test_NonceIndependentPerMaker() public {
    vm.prank(maker.addr);
    receiver.setNonce(5);

    vm.prank(maker2.addr);
    receiver.setNonce(10);

    vm.prank(maker3.addr);
    receiver.setNonce(15);

    assertEq(receiver.nonce(maker.addr), 5);
    assertEq(receiver.nonce(maker2.addr), 10);
    assertEq(receiver.nonce(maker3.addr), 15);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   VALID OFFER TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_ValidateOffer_Success() public {
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    receiver.validateOffer(offer, signature);

    // Nonce should be updated to the offer's nonce
    assertEq(receiver.nonce(maker.addr), 1);
  }

  function test_ValidateOffer_WithHigherNonce() public {
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 5, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    receiver.validateOffer(offer, signature);

    assertEq(receiver.nonce(maker.addr), 5);
  }

  function test_ValidateOffer_SequentialOffers() public {
    // First offer with nonce 1
    Offer memory offer1 = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory signature1 = _signOffer(offer1, maker);
    receiver.validateOffer(offer1, signature1);
    assertEq(receiver.nonce(maker.addr), 1);

    // Second offer with nonce 2
    Offer memory offer2 = _createOffer(maker.addr, 2000e6, 200e6, 2, block.timestamp + 1 days, false);
    bytes memory signature2 = _signOffer(offer2, maker);
    receiver.validateOffer(offer2, signature2);
    assertEq(receiver.nonce(maker.addr), 2);

    // Third offer with nonce 3
    Offer memory offer3 = _createOffer(maker.addr, 3000e6, 300e6, 3, block.timestamp + 1 days, false);
    bytes memory signature3 = _signOffer(offer3, maker);
    receiver.validateOffer(offer3, signature3);
    assertEq(receiver.nonce(maker.addr), 3);
  }

  function test_ValidateOffer_DifferentMakers() public {
    Offer memory offer1 = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory signature1 = _signOffer(offer1, maker);
    receiver.validateOffer(offer1, signature1);

    Offer memory offer2 = _createOffer(maker2.addr, 2000e6, 200e6, 1, block.timestamp + 1 days, false);
    bytes memory signature2 = _signOffer(offer2, maker2);
    receiver.validateOffer(offer2, signature2);

    Offer memory offer3 = _createOffer(maker3.addr, 3000e6, 300e6, 1, block.timestamp + 1 days, false);
    bytes memory signature3 = _signOffer(offer3, maker3);
    receiver.validateOffer(offer3, signature3);

    assertEq(receiver.nonce(maker.addr), 1);
    assertEq(receiver.nonce(maker2.addr), 1);
    assertEq(receiver.nonce(maker3.addr), 1);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   INVALID OFFER TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_RevertWhen_MakerIsZero() public {
    Offer memory offer = _createOffer(address(0), 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(CommonErrors.AddressZero.selector);
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_AmountIsZero() public {
    Offer memory offer = _createOffer(maker.addr, 0, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(CommonErrors.AmountZero.selector);
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_ExpectedReturnIsZero() public {
    Offer memory offer = _createOffer(maker.addr, 1000e6, 0, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(CommonErrors.AmountZero.selector);
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_OfferExpired() public {
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp - 1, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.OfferExpired.selector));
    receiver.validateOffer(offer, signature);
  }

  function test_ValidOffer_AtCurrentTimestamp() public {
    // When expiration == block.timestamp, the offer is not valid (contract checks: expiration <= block.timestamp)
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.OfferExpired.selector));
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_NonceIsZero() public {
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 0, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_NonceNotGreaterThanStored() public {
    // Set nonce to 5
    vm.prank(maker.addr);
    receiver.setNonce(5);

    // Try to use nonce 5 (not greater than stored)
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 5, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_NonceIsLessThanStored() public {
    // Set nonce to 10
    vm.prank(maker.addr);
    receiver.setNonce(10);

    // Try to use nonce 5
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 5, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_InvalidSignature() public {
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    // Sign with wrong wallet
    bytes memory signature = _signOffer(offer, maker2);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidSignature.selector));
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_SignatureModified() public {
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    // Modify the signature
    signature[0] = bytes1(uint8(signature[0]) ^ 0xff);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidSignature.selector));
    receiver.validateOffer(offer, signature);
  }

  function test_RevertWhen_ReplayAttack() public {
    Offer memory offer = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    // First validation should succeed
    receiver.validateOffer(offer, signature);

    // Second validation with same offer should fail (replay attack)
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer, signature);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 NONCE CANCELLATION TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_CancelOffersBySettingNonce() public {
    // Maker sets nonce to 3, invalidating offers with nonce 1, 2, 3
    vm.prank(maker.addr);
    receiver.setNonce(3);

    // Offer with nonce 1 should fail
    Offer memory offer1 = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory signature1 = _signOffer(offer1, maker);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer1, signature1);

    // Offer with nonce 2 should fail
    Offer memory offer2 = _createOffer(maker.addr, 1000e6, 100e6, 2, block.timestamp + 1 days, false);
    bytes memory signature2 = _signOffer(offer2, maker);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer2, signature2);

    // Offer with nonce 3 should fail
    Offer memory offer3 = _createOffer(maker.addr, 1000e6, 100e6, 3, block.timestamp + 1 days, false);
    bytes memory signature3 = _signOffer(offer3, maker);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer3, signature3);

    // Offer with nonce 4 should succeed
    Offer memory offer4 = _createOffer(maker.addr, 1000e6, 100e6, 4, block.timestamp + 1 days, false);
    bytes memory signature4 = _signOffer(offer4, maker);
    receiver.validateOffer(offer4, signature4);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       FUZZ TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_ValidOffer(uint256 amount, uint256 expectedReturn, uint256 nonce_, uint256 timeUntilExpiry) public {
    // Bound inputs to reasonable ranges
    amount = bound(amount, 1, type(uint128).max);
    expectedReturn = bound(expectedReturn, 1, type(uint128).max);
    nonce_ = bound(nonce_, 1, type(uint64).max);
    timeUntilExpiry = bound(timeUntilExpiry, 1, 365 days);

    Offer memory offer =
      _createOffer(maker.addr, amount, expectedReturn, nonce_, block.timestamp + timeUntilExpiry, false);
    bytes memory signature = _signOffer(offer, maker);

    receiver.validateOffer(offer, signature);

    assertEq(receiver.nonce(maker.addr), nonce_);
  }

  function testFuzz_RevertWhen_AmountIsZero(uint256 expectedReturn, uint256 nonce_, uint256 timeUntilExpiry) public {
    expectedReturn = bound(expectedReturn, 1, type(uint128).max);
    nonce_ = bound(nonce_, 1, type(uint64).max);
    timeUntilExpiry = bound(timeUntilExpiry, 1, 365 days);

    Offer memory offer = _createOffer(maker.addr, 0, expectedReturn, nonce_, block.timestamp + timeUntilExpiry, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(CommonErrors.AmountZero.selector);
    receiver.validateOffer(offer, signature);
  }

  function testFuzz_RevertWhen_ExpectedReturnIsZero(uint256 amount, uint256 nonce_, uint256 timeUntilExpiry) public {
    amount = bound(amount, 1, type(uint128).max);
    nonce_ = bound(nonce_, 1, type(uint64).max);
    timeUntilExpiry = bound(timeUntilExpiry, 1, 365 days);

    Offer memory offer = _createOffer(maker.addr, amount, 0, nonce_, block.timestamp + timeUntilExpiry, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(CommonErrors.AmountZero.selector);
    receiver.validateOffer(offer, signature);
  }

  function testFuzz_RevertWhen_NonceIsZero(uint256 amount, uint256 expectedReturn, uint256 timeUntilExpiry) public {
    amount = bound(amount, 1, type(uint128).max);
    expectedReturn = bound(expectedReturn, 1, type(uint128).max);
    timeUntilExpiry = bound(timeUntilExpiry, 1, 365 days);

    Offer memory offer = _createOffer(maker.addr, amount, expectedReturn, 0, block.timestamp + timeUntilExpiry, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer, signature);
  }

  function testFuzz_RevertWhen_OfferExpired(
    uint256 amount,
    uint256 expectedReturn,
    uint256 nonce_,
    uint256 timeSinceExpiry
  ) public {
    amount = bound(amount, 1, type(uint128).max);
    expectedReturn = bound(expectedReturn, 1, type(uint128).max);
    nonce_ = bound(nonce_, 1, type(uint64).max);
    // Bound to be from 1 to block.timestamp to avoid underflow
    timeSinceExpiry = bound(timeSinceExpiry, 1, block.timestamp > 0 ? block.timestamp : 1);

    Offer memory offer =
      _createOffer(maker.addr, amount, expectedReturn, nonce_, block.timestamp - timeSinceExpiry, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.OfferExpired.selector));
    receiver.validateOffer(offer, signature);
  }

  function testFuzz_RevertWhen_NonceNotGreater(uint256 amount, uint256 expectedReturn, uint256 storedNonce) public {
    amount = bound(amount, 1, type(uint128).max);
    expectedReturn = bound(expectedReturn, 1, type(uint128).max);
    storedNonce = bound(storedNonce, 1, type(uint64).max);

    // Set the stored nonce
    vm.prank(maker.addr);
    receiver.setNonce(storedNonce);

    // Try to use a nonce <= storedNonce
    uint256 offerNonce = bound(uint256(keccak256(abi.encode(storedNonce))), 0, storedNonce);

    Offer memory offer = _createOffer(maker.addr, amount, expectedReturn, offerNonce, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonce.selector));
    receiver.validateOffer(offer, signature);
  }

  function testFuzz_SetNonce(uint256 newNonce) public {
    newNonce = bound(newNonce, 1, type(uint64).max);

    vm.prank(maker.addr);
    receiver.setNonce(newNonce);

    assertEq(receiver.nonce(maker.addr), newNonce);
  }

  function testFuzz_RevertWhen_SetNonceNotGreater(uint256 currentNonce, uint256 newNonce) public {
    currentNonce = bound(currentNonce, 1, type(uint64).max);
    newNonce = bound(newNonce, 0, currentNonce);

    vm.prank(maker.addr);
    receiver.setNonce(currentNonce);

    vm.prank(maker.addr);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidNonceUpdate.selector));
    receiver.setNonce(newNonce);
  }

  function testFuzz_SequentialOffers(uint8 numOffers) public {
    numOffers = uint8(bound(numOffers, 1, 50)); // Limit to 50 offers to avoid gas issues

    for (uint256 i = 1; i <= numOffers; i++) {
      Offer memory offer = _createOffer(maker.addr, 1000e6 * i, 100e6 * i, i, block.timestamp + 1 days, false);
      bytes memory signature = _signOffer(offer, maker);

      receiver.validateOffer(offer, signature);

      assertEq(receiver.nonce(maker.addr), i);
    }
  }

  function testFuzz_NonceSkipping(uint256 nonce1, uint256 nonce2, uint256 nonce3) public {
    // Test that nonces can skip values (don't need to be consecutive)
    nonce1 = bound(nonce1, 1, type(uint64).max / 3);
    nonce2 = bound(nonce2, nonce1 + 1, type(uint64).max / 3 * 2);
    nonce3 = bound(nonce3, nonce2 + 1, type(uint64).max);

    // First offer
    Offer memory offer1 = _createOffer(maker.addr, 1000e6, 100e6, nonce1, block.timestamp + 1 days, false);
    bytes memory signature1 = _signOffer(offer1, maker);
    receiver.validateOffer(offer1, signature1);
    assertEq(receiver.nonce(maker.addr), nonce1);

    // Second offer with higher nonce (can skip)
    Offer memory offer2 = _createOffer(maker.addr, 2000e6, 200e6, nonce2, block.timestamp + 1 days, false);
    bytes memory signature2 = _signOffer(offer2, maker);
    receiver.validateOffer(offer2, signature2);
    assertEq(receiver.nonce(maker.addr), nonce2);

    // Third offer with even higher nonce
    Offer memory offer3 = _createOffer(maker.addr, 3000e6, 300e6, nonce3, block.timestamp + 1 days, false);
    bytes memory signature3 = _signOffer(offer3, maker);
    receiver.validateOffer(offer3, signature3);
    assertEq(receiver.nonce(maker.addr), nonce3);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              MULTI-MAKER WORKFLOW TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_workflow_MultipleMakersSimultaneous() public {
    // Three makers submit offers with different amounts simultaneously
    Offer memory offer1 = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    Offer memory offer2 = _createOffer(maker2.addr, 2000e6, 150e6, 1, block.timestamp + 1 days, false);
    Offer memory offer3 = _createOffer(maker3.addr, 3000e6, 200e6, 1, block.timestamp + 1 days, false);

    bytes memory signature1 = _signOffer(offer1, maker);
    bytes memory signature2 = _signOffer(offer2, maker2);
    bytes memory signature3 = _signOffer(offer3, maker3);

    receiver.validateOffer(offer1, signature1);
    receiver.validateOffer(offer2, signature2);
    receiver.validateOffer(offer3, signature3);

    assertEq(receiver.nonce(maker.addr), 1);
    assertEq(receiver.nonce(maker2.addr), 1);
    assertEq(receiver.nonce(maker3.addr), 1);
  }

  function test_workflow_MultipleMakersSequentialOffers() public {
    // Each maker submits multiple offers in sequence
    for (uint256 i = 1; i <= 3; i++) {
      Offer memory offer1 = _createOffer(maker.addr, 1000e6 * i, 100e6 * i, i, block.timestamp + 1 days, false);
      Offer memory offer2 = _createOffer(maker2.addr, 2000e6 * i, 150e6 * i, i, block.timestamp + 1 days, false);
      Offer memory offer3 = _createOffer(maker3.addr, 3000e6 * i, 200e6 * i, i, block.timestamp + 1 days, false);

      bytes memory signature1 = _signOffer(offer1, maker);
      bytes memory signature2 = _signOffer(offer2, maker2);
      bytes memory signature3 = _signOffer(offer3, maker3);

      receiver.validateOffer(offer1, signature1);
      receiver.validateOffer(offer2, signature2);
      receiver.validateOffer(offer3, signature3);

      assertEq(receiver.nonce(maker.addr), i);
      assertEq(receiver.nonce(maker2.addr), i);
      assertEq(receiver.nonce(maker3.addr), i);
    }
  }

  function test_workflow_SelectiveCancellation() public {
    // maker submits offers with nonces 1-5
    for (uint256 i = 1; i <= 5; i++) {
      Offer memory offer = _createOffer(maker.addr, 1000e6 * i, 100e6 * i, i, block.timestamp + 1 days, false);
      bytes memory signature = _signOffer(offer, maker);
      receiver.validateOffer(offer, signature);
    }
    assertEq(receiver.nonce(maker.addr), 5);

    // maker2 submits offers with nonces 1-3
    for (uint256 i = 1; i <= 3; i++) {
      Offer memory offer = _createOffer(maker2.addr, 2000e6 * i, 150e6 * i, i, block.timestamp + 1 days, false);
      bytes memory signature = _signOffer(offer, maker2);
      receiver.validateOffer(offer, signature);
    }
    assertEq(receiver.nonce(maker2.addr), 3);

    // maker2 cancels all offers by setting nonce to 10
    vm.prank(maker2.addr);
    receiver.setNonce(10);

    // maker2 can now only use nonce 11+
    Offer memory newOffer = _createOffer(maker2.addr, 5000e6, 500e6, 11, block.timestamp + 1 days, false);
    bytes memory newSignature = _signOffer(newOffer, maker2);
    receiver.validateOffer(newOffer, newSignature);
    assertEq(receiver.nonce(maker2.addr), 11);

    // maker is unaffected and can use nonce 6
    Offer memory makerOffer = _createOffer(maker.addr, 6000e6, 600e6, 6, block.timestamp + 1 days, false);
    bytes memory makerSignature = _signOffer(makerOffer, maker);
    receiver.validateOffer(makerOffer, makerSignature);
    assertEq(receiver.nonce(maker.addr), 6);
  }

  function test_workflow_MixedValidAndInvalid() public {
    // maker has valid offer
    Offer memory validOffer = _createOffer(maker.addr, 1000e6, 100e6, 1, block.timestamp + 1 days, false);
    bytes memory validSignature = _signOffer(validOffer, maker);
    receiver.validateOffer(validOffer, validSignature);

    // maker2 tries invalid signature (signed by maker3)
    Offer memory invalidSigOffer = _createOffer(maker2.addr, 2000e6, 200e6, 1, block.timestamp + 1 days, false);
    bytes memory invalidSignature = _signOffer(invalidSigOffer, maker3);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.InvalidSignature.selector));
    receiver.validateOffer(invalidSigOffer, invalidSignature);

    // maker2's nonce is still 0
    assertEq(receiver.nonce(maker2.addr), 0);

    // maker2 submits valid offer
    Offer memory maker2ValidOffer = _createOffer(maker2.addr, 2000e6, 200e6, 1, block.timestamp + 1 days, false);
    bytes memory maker2ValidSignature = _signOffer(maker2ValidOffer, maker2);
    receiver.validateOffer(maker2ValidOffer, maker2ValidSignature);
    assertEq(receiver.nonce(maker2.addr), 1);

    // maker3 has expired offer
    Offer memory expiredOffer = _createOffer(maker3.addr, 3000e6, 300e6, 1, block.timestamp - 1, false);
    bytes memory expiredSignature = _signOffer(expiredOffer, maker3);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.OfferExpired.selector));
    receiver.validateOffer(expiredOffer, expiredSignature);

    // maker3's nonce is still 0
    assertEq(receiver.nonce(maker3.addr), 0);
  }

  function testFuzz_MultipleMakers(uint8 numMakers, uint8 offersPerMaker) public {
    numMakers = uint8(bound(numMakers, 1, 10));
    offersPerMaker = uint8(bound(offersPerMaker, 1, 10));

    // Create wallets dynamically
    Vm.Wallet[] memory wallets = new Vm.Wallet[](numMakers);
    for (uint256 i = 0; i < numMakers; i++) {
      wallets[i] = vm.createWallet(string(abi.encodePacked("dynamicMaker", vm.toString(i))));
    }

    // Each maker submits multiple offers
    for (uint256 i = 0; i < numMakers; i++) {
      for (uint256 j = 1; j <= offersPerMaker; j++) {
        Offer memory offer = _createOffer(wallets[i].addr, 1000e6 * j, 100e6 * j, j, block.timestamp + 1 days, false);
        bytes memory signature = _signOffer(offer, wallets[i]);
        receiver.validateOffer(offer, signature);

        assertEq(receiver.nonce(wallets[i].addr), j);
      }
    }

    // Verify all makers have correct final nonce
    for (uint256 i = 0; i < numMakers; i++) {
      assertEq(receiver.nonce(wallets[i].addr), offersPerMaker);
    }
  }
}

