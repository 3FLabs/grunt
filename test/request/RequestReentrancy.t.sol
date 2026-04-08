// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Request} from "../../src/request/Request.sol";
import {RequestFactory} from "../../src/request/RequestFactory.sol";
import {Vault} from "../../src/request/Vault.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MaliciousRequestCallback} from "../mock/request/MaliciousRequestCallback.sol";
import {Offer} from "../../src/interfaces/request/IOfferReceiver.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";

/// @title RequestReentrancyTest
/// @notice Tests that setRepaid() and mint() are protected against reentrancy during consume() callbacks.
/// @dev The malicious callback contract is set as the Request owner so it can call setRepaid() (onlyOwner).
contract RequestReentrancyTest is Test {
  RequestFactory public factory;
  Request public request;
  Vault public ptVault;
  Vault public ytVault;
  MockERC20 public asset;
  MaliciousRequestCallback public maliciousCallback;

  address public puller;
  address public consumer;
  address public beaconOwner;

  Vm.Wallet internal callbackSigner;

  bytes32 internal constant OFFER_TYPEHASH = 0x3ded0c963332962cf2d273c8fb4f3e69f4ef33407ca72484fcebb56263ad0664;
  bytes32 internal constant TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  function setUp() public {
    puller = makeAddr("puller");
    consumer = makeAddr("consumer");
    beaconOwner = makeAddr("beaconOwner");
    callbackSigner = vm.createWallet("callbackSigner");

    asset = new MockERC20("USDC", "USDC", 6);
    factory = new RequestFactory(beaconOwner);

    // Deploy callback first, then create request with callback as owner
    maliciousCallback = new MaliciousRequestCallback(address(asset), callbackSigner.addr);

    vm.prank(address(maliciousCallback));
    (address reqAddr, address ptAddr, address ytAddr) = factory.createRequest(
      address(maliciousCallback),
      puller,
      consumer,
      address(asset),
      "Test Request",
      "REQ",
      uint64(block.timestamp + 90 days),
      0
    );

    request = Request(reqAddr);
    ptVault = Vault(ptAddr);
    ytVault = Vault(ytAddr);

    maliciousCallback.setRequest(address(request));
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

  function _createOffer(address maker_, uint256 amount, uint256 expectedReturn, uint256 nonce_, uint256 expiration)
    internal
    pure
    returns (Offer memory)
  {
    return Offer({
      maker: maker_,
      amount: amount,
      expectedReturn: expectedReturn,
      nonce: nonce_,
      expiration: expiration,
      useCallback: true
    });
  }

  function _signOffer(Offer memory offer) internal returns (bytes memory) {
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
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(callbackSigner, digest);
    return abi.encodePacked(r, s, v);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  REENTRANCY TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice setRepaid() called during consume() callback is blocked by reentrancy guard
  function test_consume_setRepaid_blockedByReentrancyGuard() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    maliciousCallback.setAttackType(MaliciousRequestCallback.AttackType.SET_REPAID);

    Offer memory offer =
      _createOffer(address(maliciousCallback), offerAmount, expectedReturn, 1, block.timestamp + 1 days);
    bytes memory signature = _signOffer(offer);
    asset.mint(address(maliciousCallback), offerAmount);

    // consume() as consumer (owner is the callback itself)
    vm.prank(consumer);
    request.consume(offer, signature, offerAmount);

    // Attack was attempted and blocked
    assertTrue(maliciousCallback.attackTriggered());
    assertTrue(maliciousCallback.wasReentrancyError());

    // repaid was NOT set — the invariant holds
    assertFalse(request.canWithdraw());

    // consume() still completed — tokens were minted
    assertEq(ptVault.balanceOf(address(maliciousCallback)), offerAmount);
    assertEq(ytVault.balanceOf(address(maliciousCallback)), expectedReturn);
    assertEq(asset.balanceOf(address(request)), offerAmount);
  }

  /// @notice mint() called during consume() callback is blocked by reentrancy guard
  function test_consume_mint_blockedByReentrancyGuard() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;
    uint128 mintAuthPt = 500_000e6;
    uint128 mintAuthYt = 50_000e6;

    // Pre-authorize minting for the callback (owner can call authorizeMinting)
    vm.prank(address(maliciousCallback));
    request.authorizeMinting(address(maliciousCallback), mintAuthPt, mintAuthYt);

    maliciousCallback.setAttackType(MaliciousRequestCallback.AttackType.MINT);

    Offer memory offer =
      _createOffer(address(maliciousCallback), offerAmount, expectedReturn, 1, block.timestamp + 1 days);
    bytes memory signature = _signOffer(offer);
    asset.mint(address(maliciousCallback), offerAmount + mintAuthPt);

    vm.prank(consumer);
    request.consume(offer, signature, offerAmount);

    // Attack was attempted and blocked
    assertTrue(maliciousCallback.attackTriggered());
    assertTrue(maliciousCallback.wasReentrancyError());

    // consume() still completed — only consume-minted tokens exist
    assertEq(ptVault.balanceOf(address(maliciousCallback)), offerAmount);
    assertEq(ytVault.balanceOf(address(maliciousCallback)), expectedReturn);
  }

  /// @notice setRepaid() works normally outside of a reentrant context
  function test_setRepaid_worksOutsideReentrancy() public {
    vm.prank(address(maliciousCallback));
    request.setRepaid(0, type(uint256).max);

    assertTrue(request.canWithdraw());
  }

  /// @notice mint() works normally outside of a reentrant context
  function test_mint_worksOutsideReentrancy() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 100_000e6;

    vm.prank(address(maliciousCallback));
    request.authorizeMinting(address(this), ptAmount, ytAmount);

    asset.mint(address(this), ptAmount);
    asset.approve(address(request), ptAmount);
    request.mint(type(uint128).max, 0);

    assertEq(ptVault.balanceOf(address(this)), ptAmount);
    assertEq(ytVault.balanceOf(address(this)), ytAmount);
  }

  /// @notice Sequential consume then setRepaid in separate txs works fine
  function test_sequential_consume_then_setRepaid() public {
    uint256 offerAmount = 1_000_000e6;
    uint256 expectedReturn = 100_000e6;

    // No attack — just a normal callback
    maliciousCallback.setAttackType(MaliciousRequestCallback.AttackType.NONE);

    Offer memory offer =
      _createOffer(address(maliciousCallback), offerAmount, expectedReturn, 1, block.timestamp + 1 days);
    bytes memory signature = _signOffer(offer);
    asset.mint(address(maliciousCallback), offerAmount);

    vm.prank(consumer);
    request.consume(offer, signature, offerAmount);

    // Separate tx: setRepaid succeeds (mintToRepaidDelay is 0)
    vm.prank(address(maliciousCallback));
    request.setRepaid(0, type(uint256).max);

    assertTrue(request.canWithdraw());
  }
}
