// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Request} from "../../src/request/Request.sol";
import {RequestFactory} from "../../src/request/RequestFactory.sol";
import {Vault} from "../../src/request/Vault.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MockRequestCallback} from "../mock/request/MockRequestCallback.sol";
import {Offer} from "../../src/interfaces/request/IOfferReceiver.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../src/libs/common/LibCommonErrors.sol";

/// @title RequestConsumeTest
/// @notice Tests for the Request.consume() function with EIP-1271 callback contracts
contract RequestConsumeTest is Test {
  RequestFactory public factory;
  Request public request;
  Vault public ptVault;
  Vault public ytVault;
  MockERC20 public asset;
  MockRequestCallback public callback;

  // Test addresses
  address public owner;
  address public puller;
  address public consumer;
  address public borrower;
  address public beaconOwner;

  // Test wallet for signing (on behalf of callback contract)
  Vm.Wallet internal callbackSigner;

  // Constants for EIP-712
  bytes32 internal constant OFFER_TYPEHASH = 0x3ded0c963332962cf2d273c8fb4f3e69f4ef33407ca72484fcebb56263ad0664;
  bytes32 internal constant TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  function setUp() public {
    owner = makeAddr("owner");
    puller = makeAddr("puller");
    consumer = makeAddr("consumer");
    borrower = makeAddr("borrower");
    beaconOwner = makeAddr("beaconOwner");
    callbackSigner = vm.createWallet("callbackSigner");

    // Deploy asset
    asset = new MockERC20("USDC", "USDC", 6);

    // Deploy factory
    factory = new RequestFactory(beaconOwner);

    // Create request via factory with far future deadline
    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) = factory.createRequest(
      owner, puller, consumer, address(asset), "Test Request", "REQ", uint64(block.timestamp + 90 days), 0
    );

    request = Request(reqAddr);
    ptVault = Vault(ptAddr);
    ytVault = Vault(ytAddr);

    // Deploy callback contract with signer
    callback = new MockRequestCallback(address(asset), callbackSigner.addr);
    callback.setRequest(address(request));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       HELPERS                               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _computeDomainSeparator() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        TYPE_HASH, keccak256(bytes(request.name())), keccak256(bytes("0.0.1")), block.chainid, address(request)
      )
    );
  }

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

  function _signOffer(Offer memory offer) internal returns (bytes memory) {
    return _signOfferWithWallet(offer, callbackSigner);
  }

  function _signOfferWithWallet(Offer memory offer, Vm.Wallet memory wallet) internal returns (bytes memory) {
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
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _computeDomainSeparator(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
    return abi.encodePacked(r, s, v);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CONSUME TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_fullOffer() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    // Create and sign offer (maker is the callback contract)
    Offer memory offer = _createOffer(address(callback), offerAmount, expectedReturn, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    // Fund the callback (maker provides funds, callback approves in onRequestConsumed)
    asset.mint(address(callback), offerAmount);

    // Consume the offer
    vm.prank(owner);
    uint256 ytAmount = request.consume(offer, signature, offerAmount);

    // Verify YT amount calculation
    assertEq(ytAmount, expectedReturn);

    // Verify callback was called
    assertEq(callback.callbackCalled(), true);
    assertEq(callback.lastPrincipal(), offerAmount);
    assertEq(callback.lastYield(), expectedReturn);

    // Verify token minting to maker (callback)
    assertEq(ptVault.balanceOf(address(callback)), offerAmount);
    assertEq(ytVault.balanceOf(address(callback)), expectedReturn);

    // Verify asset transfer to request
    assertEq(asset.balanceOf(address(request)), offerAmount);
    assertEq(asset.balanceOf(address(callback)), 0);
  }

  function test_consume_revertsWhenRepaid() public {
    uint256 offerAmount = 1_000_000e6;

    // Set as repaid first
    vm.prank(owner);
    request.setRepaid(0);

    Offer memory offer = _createOffer(address(callback), offerAmount, 100_000e6, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    vm.prank(owner);
    vm.expectRevert(LibRequestErrors.AlreadyRepaid.selector);
    request.consume(offer, signature, offerAmount);
  }

  function test_consume_onlyOwnerOrConsumer() public {
    uint256 offerAmount = 1_000_000e6;

    Offer memory offer = _createOffer(address(callback), offerAmount, 100_000e6, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    address notAuthorized = makeAddr("notAuthorized");
    vm.prank(notAuthorized);
    vm.expectRevert(LibRequestErrors.Unauthorized.selector);
    request.consume(offer, signature, offerAmount);
  }

  function test_consume_consumerCanCall() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    // Create and sign offer (maker is the callback contract)
    Offer memory offer = _createOffer(address(callback), offerAmount, expectedReturn, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    // Fund the callback (maker provides funds, callback approves in onRequestConsumed)
    asset.mint(address(callback), offerAmount);

    // Consumer consumes the offer
    vm.prank(consumer);
    uint256 ytAmount = request.consume(offer, signature, offerAmount);

    // Verify YT amount calculation
    assertEq(ytAmount, expectedReturn);

    // Verify callback was called
    assertEq(callback.callbackCalled(), true);
    assertEq(callback.lastPrincipal(), offerAmount);
    assertEq(callback.lastYield(), expectedReturn);

    // Verify token minting to maker (callback)
    assertEq(ptVault.balanceOf(address(callback)), offerAmount);
    assertEq(ytVault.balanceOf(address(callback)), expectedReturn);

    // Verify asset transfer to request
    assertEq(asset.balanceOf(address(request)), offerAmount);
    assertEq(asset.balanceOf(address(callback)), 0);
  }

  function test_consume_revertsOnExpiredOffer() public {
    uint256 offerAmount = 1_000_000e6;

    Offer memory offer = _createOffer(address(callback), offerAmount, 100_000e6, 1, block.timestamp - 1, true);
    bytes memory signature = _signOffer(offer);

    vm.prank(owner);
    vm.expectRevert(LibRequestErrors.OfferExpired.selector);
    request.consume(offer, signature, offerAmount);
  }

  function test_consume_revertsOnInvalidNonce() public {
    uint256 offerAmount = 1_000_000e6;

    // Fund the callback
    asset.mint(address(callback), offerAmount * 2);

    Offer memory offer1 = _createOffer(address(callback), offerAmount, 100_000e6, 1, block.timestamp + 1 days, true);
    bytes memory sig1 = _signOffer(offer1);

    vm.prank(owner);
    request.consume(offer1, sig1, offerAmount);

    // Try to consume with same nonce again
    Offer memory offer2 = _createOffer(address(callback), offerAmount, 100_000e6, 1, block.timestamp + 1 days, true);
    bytes memory sig2 = _signOffer(offer2);

    vm.prank(owner);
    vm.expectRevert(LibRequestErrors.InvalidNonce.selector);
    request.consume(offer2, sig2, offerAmount);
  }

  function test_consume_revertsOnZeroMaker() public {
    Offer memory offer = _createOffer(address(0), 1_000_000e6, 100_000e6, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    vm.prank(owner);
    vm.expectRevert(CommonErrors.AddressZero.selector);
    request.consume(offer, signature, 1_000_000e6);
  }

  function test_consume_revertsOnZeroOfferAmount() public {
    // Create an offer with amount=0
    Offer memory offer = _createOffer(address(callback), 0, 100_000e6, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    // Use a non-zero ptAmount to ensure we hit the offer.amount validation
    // ptAmount > offer.amount (1 > 0) triggers InvalidPtAmount first
    vm.prank(owner);
    vm.expectRevert(LibRequestErrors.InvalidPtAmount.selector);
    request.consume(offer, signature, 1);
  }

  function test_consume_revertsOnZeroExpectedReturn() public {
    Offer memory offer = _createOffer(address(callback), 1_000_000e6, 0, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    vm.prank(owner);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    request.consume(offer, signature, 1_000_000e6);
  }

  function test_consume_callbackCanRevert() public {
    uint256 offerAmount = 1_000_000e6;

    callback.setShouldRevert(true);

    // Fund the callback
    asset.mint(address(callback), offerAmount);

    Offer memory offer = _createOffer(address(callback), offerAmount, 100_000e6, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    vm.prank(owner);
    vm.expectRevert("MockRequestCallback: forced revert");
    request.consume(offer, signature, offerAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    EOA MAKER TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_eoaMaker_revertsWithUseCallbackTrue() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    // Create an EOA maker wallet
    Vm.Wallet memory eoaMaker = vm.createWallet("eoaMaker");

    // Create offer with useCallback=true (should revert because EOA has no code)
    Offer memory offer = _createOffer(eoaMaker.addr, offerAmount, expectedReturn, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOfferWithWallet(offer, eoaMaker);

    // Fund the EOA maker and approve
    asset.mint(eoaMaker.addr, offerAmount);
    vm.prank(eoaMaker.addr);
    asset.approve(address(request), offerAmount);

    // Consume should revert because high-level call to EOA fails
    vm.prank(owner);
    vm.expectRevert();
    request.consume(offer, signature, offerAmount);
  }

  function test_consume_eoaMaker_succeedsWithUseCallbackFalse() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    // Create an EOA maker wallet
    Vm.Wallet memory eoaMaker = vm.createWallet("eoaMaker");

    // Create offer with useCallback=false (should succeed)
    Offer memory offer = _createOffer(eoaMaker.addr, offerAmount, expectedReturn, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOfferWithWallet(offer, eoaMaker);

    // Fund the EOA maker and approve
    asset.mint(eoaMaker.addr, offerAmount);
    vm.prank(eoaMaker.addr);
    asset.approve(address(request), offerAmount);

    // Consume should succeed
    vm.prank(owner);
    uint256 ytAmount = request.consume(offer, signature, offerAmount);

    // Verify YT amount calculation
    assertEq(ytAmount, expectedReturn);

    // Verify token minting to EOA maker
    assertEq(ptVault.balanceOf(eoaMaker.addr), offerAmount);
    assertEq(ytVault.balanceOf(eoaMaker.addr), expectedReturn);

    // Verify asset transfer to request
    assertEq(asset.balanceOf(address(request)), offerAmount);
    assertEq(asset.balanceOf(eoaMaker.addr), 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FUZZ TESTS                               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_consume_proportionalYield(uint128 offerAmount, uint128 expectedReturn, uint128 consumeAmount)
    public
  {
    vm.assume(offerAmount > 0);
    vm.assume(expectedReturn > 0);
    vm.assume(consumeAmount > 0 && consumeAmount <= offerAmount);

    // Fund the callback (maker provides funds)
    asset.mint(address(callback), consumeAmount);

    Offer memory offer = _createOffer(address(callback), offerAmount, expectedReturn, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    vm.prank(owner);
    uint256 ytAmount = request.consume(offer, signature, consumeAmount);

    // Verify proportional calculation
    uint256 expectedYt = uint256(expectedReturn) * consumeAmount / offerAmount;
    assertEq(ytAmount, expectedYt);
    assertEq(ptVault.balanceOf(address(callback)), consumeAmount);
    assertEq(ytVault.balanceOf(address(callback)), expectedYt);
  }

  function testFuzz_consume_multipleConsumes(uint8 numConsumes) public {
    numConsumes = uint8(bound(numConsumes, 1, 20));

    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;
    uint256 totalPt = 0;
    uint256 totalYt = 0;

    // Pre-fund the callback with enough for all consumes
    asset.mint(address(callback), offerAmount * numConsumes);

    for (uint256 i = 1; i <= numConsumes; i++) {
      Offer memory offer =
        _createOffer(address(callback), offerAmount, expectedReturn, i, block.timestamp + 1 days, true);
      bytes memory signature = _signOffer(offer);

      vm.prank(owner);
      uint256 ytAmount = request.consume(offer, signature, offerAmount);

      totalPt += offerAmount;
      totalYt += ytAmount;

      assertEq(request.nonce(address(callback)), i);
    }

    assertEq(ptVault.balanceOf(address(callback)), totalPt);
    assertEq(ytVault.balanceOf(address(callback)), totalYt);
    assertEq(totalYt, expectedReturn * numConsumes);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 INTEGRATION TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_integration_consumeAndRedeem() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    // 1. Consume offer - maker (callback) provides the funds
    asset.mint(address(callback), offerAmount);

    Offer memory offer = _createOffer(address(callback), offerAmount, expectedReturn, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    vm.prank(owner);
    request.consume(offer, signature, offerAmount);

    // Callback should have received PT/YT tokens
    assertEq(ptVault.balanceOf(address(callback)), offerAmount);
    assertEq(ytVault.balanceOf(address(callback)), expectedReturn);

    // 2. Pull funds to puller
    vm.prank(puller);
    request.pullFunds(offerAmount, "");

    // 3. Puller repays with full expected return (simulating borrower repayment)
    asset.mint(puller, expectedReturn);
    vm.prank(puller);
    asset.transfer(address(request), offerAmount + expectedReturn);

    // 4. Mark as repaid
    vm.prank(owner);
    request.setRepaid(0);

    // 5. Callback contract redeems its PT/YT tokens
    vm.startPrank(address(callback));
    uint256 ptAssets = ptVault.redeem(offerAmount, address(callback), address(callback));
    uint256 ytAssets = ytVault.redeem(expectedReturn, address(callback), address(callback));
    vm.stopPrank();

    assertEq(ptAssets, offerAmount);
    assertEq(ytAssets, expectedReturn);
    // Callback receives the redeemed assets
    assertEq(asset.balanceOf(address(callback)), offerAmount + expectedReturn);
  }

  function test_integration_mixedFunding() public {
    // Test mixing consume() and authorizeMinting() funding methods

    // 1. First, use consume() for one prime broker
    uint256 consumeAmount = 500_000e6;
    uint256 consumeReturn = 50_000e6;

    // Fund the callback (maker provides funds)
    asset.mint(address(callback), consumeAmount);

    Offer memory offer =
      _createOffer(address(callback), consumeAmount, consumeReturn, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    vm.prank(owner);
    request.consume(offer, signature, consumeAmount);

    // 2. Then use authorizeMinting() for another prime broker
    address broker2 = makeAddr("broker2");
    uint256 mintAmount = 500_000e6;
    uint256 mintYield = 50_000e6;

    vm.prank(owner);
    request.authorizeMinting(broker2, uint128(mintAmount), uint128(mintYield));

    asset.mint(broker2, mintAmount);
    vm.startPrank(broker2);
    asset.approve(address(request), mintAmount);
    request.mint(uint128(mintAmount), uint128(mintYield));
    vm.stopPrank();

    // 3. Verify totals
    assertEq(ptVault.totalSupply(), consumeAmount + mintAmount);
    assertEq(ytVault.totalSupply(), consumeReturn + mintYield);

    // 4. Pull, repay, redeem
    vm.prank(puller);
    request.pullFunds(consumeAmount + mintAmount, "");

    // Full repayment with yield
    asset.mint(puller, consumeReturn + mintYield);
    vm.prank(puller);
    asset.transfer(address(request), consumeAmount + mintAmount + consumeReturn + mintYield);

    vm.prank(owner);
    request.setRepaid(0);

    // Both can redeem fully
    vm.prank(address(callback));
    uint256 callbackTotal = ptVault.redeem(consumeAmount, address(callback), address(callback));
    vm.prank(address(callback));
    callbackTotal += ytVault.redeem(consumeReturn, address(callback), address(callback));

    vm.prank(broker2);
    uint256 broker2Total = ptVault.redeem(mintAmount, broker2, broker2);
    vm.prank(broker2);
    broker2Total += ytVault.redeem(mintYield, broker2, broker2);

    assertEq(callbackTotal, consumeAmount + consumeReturn);
    assertEq(broker2Total, mintAmount + mintYield);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              PTAMOUNT VALIDATION TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Test that consume() reverts when ptAmount == 0
  /// @dev ptAmount = 0 would burn the offer nonce without any transfer
  function test_consume_revertsOnZeroPtAmount() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    // Create an EOA maker wallet
    Vm.Wallet memory eoaMaker = vm.createWallet("eoaMaker");

    Offer memory offer = _createOffer(eoaMaker.addr, offerAmount, expectedReturn, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOfferWithWallet(offer, eoaMaker);

    asset.mint(eoaMaker.addr, offerAmount);
    vm.prank(eoaMaker.addr);
    asset.approve(address(request), offerAmount);

    // Should revert with InvalidPtAmount when ptAmount == 0
    vm.prank(owner);
    vm.expectRevert(LibRequestErrors.InvalidPtAmount.selector);
    request.consume(offer, signature, 0);

    // Verify nonce was NOT burned
    assertEq(request.nonce(eoaMaker.addr), 0, "Nonce should not be consumed on revert");
  }

  /// @notice Test that consume() reverts when ptAmount > offer.amount
  /// @dev ptAmount > offer.amount would pull more assets than the maker signed for
  function test_consume_revertsOnPtAmountExceedsOffer() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;
    uint256 attackAmount = 2_000_000e6; // Double the signed amount

    // Create an EOA maker wallet
    Vm.Wallet memory eoaMaker = vm.createWallet("eoaMaker");

    Offer memory offer = _createOffer(eoaMaker.addr, offerAmount, expectedReturn, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOfferWithWallet(offer, eoaMaker);

    asset.mint(eoaMaker.addr, attackAmount);
    vm.prank(eoaMaker.addr);
    asset.approve(address(request), type(uint256).max); // Infinite approval

    // Should revert with InvalidPtAmount when ptAmount > offer.amount
    vm.prank(owner);
    vm.expectRevert(LibRequestErrors.InvalidPtAmount.selector);
    request.consume(offer, signature, attackAmount);

    // Verify nonce was NOT burned
    assertEq(request.nonce(eoaMaker.addr), 0, "Nonce should not be consumed on revert");
  }

  /// @notice Test that consume() reverts when ptAmount > offer.amount with callback
  function test_consume_revertsOnPtAmountExceedsOffer_withCallback() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;
    uint256 attackAmount = 1_500_000e6; // 1.5x the signed amount

    asset.mint(address(callback), attackAmount);

    Offer memory offer = _createOffer(address(callback), offerAmount, expectedReturn, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    // Should revert with InvalidPtAmount when ptAmount > offer.amount
    vm.prank(owner);
    vm.expectRevert(LibRequestErrors.InvalidPtAmount.selector);
    request.consume(offer, signature, attackAmount);

    // Verify nonce was NOT burned
    assertEq(request.nonce(address(callback)), 0, "Nonce should not be consumed on revert");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              MINT TIMESTAMP TESTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_updatesLastMintTimestamp() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    Offer memory offer = _createOffer(address(callback), offerAmount, expectedReturn, 1, block.timestamp + 1 days, true);
    bytes memory signature = _signOffer(offer);

    asset.mint(address(callback), offerAmount);

    assertEq(request.lastMintTimestamp(), 0, "lastMintTimestamp should be 0 before consume");

    vm.prank(owner);
    request.consume(offer, signature, offerAmount);

    assertEq(request.lastMintTimestamp(), uint40(block.timestamp), "lastMintTimestamp should be updated after consume");
  }
}

