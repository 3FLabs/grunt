// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Request} from "../../src/request/Request.sol";
import {RequestFactory} from "../../src/request/RequestFactory.sol";
import {Vault} from "../../src/request/Vault.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {Offer} from "../../src/interfaces/request/IOfferReceiver.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";

/// @title RequestMintTimelockPoCTest
/// @notice Proof of Concept demonstrating that the mint-to-repaid timelock prevents
///         last-minute YT inflation from stealing yield from legitimate holders.
///
///      Attack sequence (without fix):
///        1. Legitimate brokers deposit 1,000,000 USDC → 1,000,000 PT + 1,000,000 YT
///        2. Borrower uses funds and repays 1,100,000 USDC (100,000 yield)
///        3. Colluding facilitator calls consume() with inflated YT (1 USDC → 1 PT + 9,000,000 YT)
///        4. Facilitator calls setRepaid(uint256) atomically
///        5. Colluding broker extracts 90% of the yield (90,000 USDC) having invested only 1 USDC
///
///      With the mint-to-repaid timelock fix, step 4 reverts because a minimum delay
///      is enforced between the last mint/consume and setRepaid(uint256).
contract RequestMintTimelockPoCTest is Test {
  RequestFactory public factory;
  MockERC20 public asset;

  address public owner;
  address public puller;
  address public consumer;
  address public beaconOwner;

  Vm.Wallet internal legitimateBroker;
  Vm.Wallet internal colludingBroker;

  // Constants
  uint40 constant MINT_TIMELOCK = 24 hours;
  bytes32 internal constant OFFER_TYPEHASH = 0x3ded0c963332962cf2d273c8fb4f3e69f4ef33407ca72484fcebb56263ad0664;
  bytes32 internal constant TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  function setUp() public {
    owner = makeAddr("owner");
    puller = makeAddr("puller");
    consumer = makeAddr("consumer");
    beaconOwner = makeAddr("beaconOwner");
    legitimateBroker = vm.createWallet("legitimateBroker");
    colludingBroker = vm.createWallet("colludingBroker");

    asset = new MockERC20("USDC", "USDC", 6);
    factory = new RequestFactory(beaconOwner);
  }

  function _computeDomainSeparator(address req) internal view returns (bytes32) {
    return keccak256(
      abi.encode(TYPE_HASH, keccak256(bytes(Request(req).name())), keccak256(bytes("0.0.1")), block.chainid, req)
    );
  }

  function _signOffer(address req, Offer memory offer, Vm.Wallet memory wallet) internal returns (bytes memory) {
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
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _computeDomainSeparator(req), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
    return abi.encodePacked(r, s, v);
  }

  function _consumeOffer(address reqAddr, Vm.Wallet memory wallet, uint256 ptAmount, uint256 ytAmount, uint256 nonce)
    internal
  {
    Offer memory offer = Offer({
      maker: wallet.addr,
      amount: ptAmount,
      expectedReturn: ytAmount,
      nonce: nonce,
      expiration: block.timestamp + 1 days,
      useCallback: false
    });
    bytes memory sig = _signOffer(reqAddr, offer, wallet);
    asset.mint(wallet.addr, ptAmount);
    vm.prank(wallet.addr);
    asset.approve(reqAddr, ptAmount);
    vm.prank(consumer);
    Request(reqAddr).consume(offer, sig, ptAmount);
  }

  /// @notice Demonstrates the attack is blocked by the mint-to-repaid timelock.
  function test_poc_ytInflationAttackBlocked() public {
    // --- Deploy request with a 24h mint-to-repaid timelock ---
    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) = factory.createRequest(
      owner,
      puller,
      consumer,
      address(asset),
      "Yield Request",
      "YIELD",
      uint64(block.timestamp + 90 days),
      MINT_TIMELOCK
    );

    // --- Step 1: Legitimate broker deposits 1,000,000 USDC ---
    _consumeOffer(reqAddr, legitimateBroker, 1_000_000e6, 1_000_000e6, 1);

    assertEq(Vault(ptAddr).balanceOf(legitimateBroker.addr), 1_000_000e6, "Legitimate broker should have 1M PT");
    assertEq(Vault(ytAddr).balanceOf(legitimateBroker.addr), 1_000_000e6, "Legitimate broker should have 1M YT");

    // --- Step 2: Borrower repays 1,100,000 USDC (100k yield) ---
    vm.prank(puller);
    Request(reqAddr).pullFunds(1_000_000e6, "");
    asset.mint(reqAddr, 1_100_000e6);

    // --- Step 3: Colluding facilitator tries to inflate YT (1 USDC → 9M YT) ---
    _consumeOffer(reqAddr, colludingBroker, 1e6, 9_000_000e6, 1);
    assertEq(Vault(ytAddr).balanceOf(colludingBroker.addr), 9_000_000e6, "Attacker has inflated YT");

    // --- Step 4: Facilitator tries to call setRepaid(uint256) atomically — BLOCKED ---
    uint40 expectedAvailableAt = uint40(block.timestamp) + MINT_TIMELOCK;
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.MintToRepaidDelayNotElapsed.selector, expectedAvailableAt));
    Request(reqAddr).setRepaid(0);

    assertEq(Request(reqAddr).repaidAvailableAt(), expectedAvailableAt, "repaidAvailableAt should match");

    // --- Verify: after timelock passes, setRepaid works ---
    vm.warp(block.timestamp + MINT_TIMELOCK);
    vm.prank(owner);
    Request(reqAddr).setRepaid(0);
    assertTrue(Request(reqAddr).canWithdraw(), "Withdrawals should be enabled after timelock");
  }

  /// @notice Verifies that setRepaid works immediately when no minting has occurred.
  function test_poc_setRepaidWorksWithoutMinting() public {
    vm.prank(owner);
    (address reqAddr,,) = factory.createRequest(
      owner, puller, consumer, address(asset), "No Mint", "NM", uint64(block.timestamp + 90 days), MINT_TIMELOCK
    );

    vm.prank(owner);
    Request(reqAddr).setRepaid(0);
    assertTrue(Request(reqAddr).canWithdraw());
  }

  /// @notice Verifies that deadline-based auto-repay is NOT affected by the mint timelock.
  function test_poc_deadlineAutoRepayNotAffected() public {
    uint64 deadline = uint64(block.timestamp + 1 days + 1);
    vm.prank(owner);
    (address reqAddr,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline", "DL", deadline, MINT_TIMELOCK);

    // Mint some tokens (sets lastMintTimestamp)
    vm.prank(owner);
    Request(reqAddr).authorizeMinting(address(this), 100e6, 100e6);
    asset.mint(address(this), 100e6);
    asset.approve(reqAddr, 100e6);
    Request(reqAddr).mint(0, 0);

    // setRepaid should revert due to timelock
    vm.prank(owner);
    vm.expectRevert();
    Request(reqAddr).setRepaid(0);

    // But warp past deadline — auto-repay via syncRepaidStatus should work
    vm.warp(deadline);
    Request(reqAddr).syncRepaidStatus();
    assertTrue(Request(reqAddr).canWithdraw(), "Deadline-based auto-repay should not be blocked by mint timelock");
  }

  /// @notice Verifies that authorizeMinting + mint flow also triggers the timelock.
  function test_poc_mintFlowAlsoTriggersTimelock() public {
    vm.prank(owner);
    (address reqAddr,,) = factory.createRequest(
      owner, puller, consumer, address(asset), "Mint Flow", "MF", uint64(block.timestamp + 90 days), MINT_TIMELOCK
    );

    // Authorize and mint
    vm.prank(owner);
    Request(reqAddr).authorizeMinting(address(this), 100e6, 9_000_000e6);
    asset.mint(address(this), 100e6);
    asset.approve(reqAddr, 100e6);
    Request(reqAddr).mint(0, 0);

    // setRepaid should revert
    uint40 expectedAvailableAt = uint40(block.timestamp) + MINT_TIMELOCK;
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibRequestErrors.MintToRepaidDelayNotElapsed.selector, expectedAvailableAt));
    Request(reqAddr).setRepaid(0);
  }
}
