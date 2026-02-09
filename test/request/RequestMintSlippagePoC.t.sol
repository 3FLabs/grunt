// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Request} from "../../src/request/Request.sol";
import {RequestFactory} from "../../src/request/RequestFactory.sol";
import {Vault} from "../../src/request/Vault.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";

/// @title RequestMintSlippagePoCTest
/// @notice Proof of Concept demonstrating that the mint slippage protection prevents the CS-I-12 attack.
/// @dev Reference: ChainSecurity I-12 — MEDIUM: Facilitator can front-run mint() to zero YT allocation.
///
///      Attack sequence (without fix):
///        1. Facilitator calls authorizeMinting(broker, 1000e6, 500e6)
///           — broker sees 1000 PT + 500 YT authorization
///        2. Broker approves the Request contract and submits mint() transaction
///        3. Facilitator front-runs with authorizeMinting(broker, 1000e6, 0)
///           — same PT, zero YT
///        4. Broker's mint() executes: transfers 1000 USDC, receives 1000 PT + 0 YT
///        5. Broker paid full amount but gets no yield token
///
///      With the slippage protection fix, mint(minPt, minYt) reverts with SlippageExceeded
///      if the authorized amounts have been tampered with below the broker's expectations.
contract RequestMintSlippagePoCTest is Test {
  RequestFactory public factory;
  Request public request;
  Vault public ptVault;
  Vault public ytVault;
  MockERC20 public asset;

  address public owner;
  address public puller;
  address public consumer; // acts as facilitator for authorizeMinting
  address public primeBroker;

  function setUp() public {
    owner = makeAddr("owner");
    puller = makeAddr("puller");
    consumer = makeAddr("consumer");
    primeBroker = makeAddr("primeBroker");

    asset = new MockERC20("USDC", "USDC", 6);
    factory = new RequestFactory(makeAddr("beaconOwner"));

    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) =
      factory.createRequest(owner, puller, consumer, address(asset), "Test Request", "REQ", uint64(type(uint64).max));

    request = Request(reqAddr);
    ptVault = Vault(ptAddr);
    ytVault = Vault(ytAddr);
  }

  /// @notice Demonstrates the front-run attack scenario and that slippage protection blocks it.
  /// @dev The facilitator front-runs the broker's mint() by overwriting the YT authorization to zero.
  ///      Without the fix, the broker would lose their entire YT allocation.
  ///      With the fix, mint(minPt, minYt) reverts with SlippageExceeded.
  function test_poc_facilitatorCannotFrontRunMintToZeroYT() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;

    // Step 1: Facilitator authorizes minting for the prime broker
    vm.prank(consumer);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    // Verify the broker sees the expected authorization
    (uint128 authPt, uint128 authYt) = request.mintAuthorization(primeBroker);
    assertEq(authPt, ptAmount, "Broker should see 1M PT authorized");
    assertEq(authYt, ytAmount, "Broker should see 500k YT authorized");

    // Step 2: Broker prepares to mint (approves funds)
    asset.mint(primeBroker, ptAmount);
    vm.prank(primeBroker);
    asset.approve(address(request), ptAmount);

    // Step 3: Facilitator FRONT-RUNS by overwriting authorization to zero YT
    vm.prank(consumer);
    request.authorizeMinting(primeBroker, ptAmount, 0);

    // Step 4: Broker's mint() reverts because YT authorization (0) < minYt (500k)
    vm.prank(primeBroker);
    vm.expectRevert(LibRequestErrors.SlippageExceeded.selector);
    request.mint(ptAmount, ytAmount);

    // --- Verify the attack was prevented ---
    // Broker still has their funds (nothing was transferred)
    assertEq(asset.balanceOf(primeBroker), ptAmount, "Broker funds should be intact");
    assertEq(ptVault.balanceOf(primeBroker), 0, "No PT tokens should be minted");
    assertEq(ytVault.balanceOf(primeBroker), 0, "No YT tokens should be minted");
  }

  /// @notice Demonstrates that PT amount can also be front-run and is protected.
  /// @dev Facilitator reduces PT authorization, so the broker would deposit less
  ///      but the broker expected a certain PT amount.
  function test_poc_facilitatorCannotFrontRunMintToReducePT() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;

    // Facilitator authorizes
    vm.prank(consumer);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    asset.mint(primeBroker, ptAmount);
    vm.prank(primeBroker);
    asset.approve(address(request), ptAmount);

    // Facilitator front-runs by reducing PT
    vm.prank(consumer);
    request.authorizeMinting(primeBroker, ptAmount / 2, ytAmount);

    // Broker's mint reverts because PT authorization (500k) < minPt (1M)
    vm.prank(primeBroker);
    vm.expectRevert(LibRequestErrors.SlippageExceeded.selector);
    request.mint(ptAmount, ytAmount);

    // Broker funds intact
    assertEq(asset.balanceOf(primeBroker), ptAmount, "Broker funds should be intact");
  }

  /// @notice Verifies that legitimate minting succeeds when authorization matches expectations.
  function test_poc_legitimateMintSucceedsWithSlippageProtection() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;

    // Facilitator authorizes
    vm.prank(consumer);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    // Broker mints with slippage protection matching the authorization
    asset.mint(primeBroker, ptAmount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), ptAmount);
    request.mint(ptAmount, ytAmount);
    vm.stopPrank();

    // Verify tokens minted correctly
    assertEq(ptVault.balanceOf(primeBroker), ptAmount, "PT tokens should be minted");
    assertEq(ytVault.balanceOf(primeBroker), ytAmount, "YT tokens should be minted");
    assertEq(asset.balanceOf(address(request)), ptAmount, "Assets should be in the request");
    assertEq(asset.balanceOf(primeBroker), 0, "Broker should have spent all funds");
  }

  /// @notice Verifies that a broker can set lower minimums to allow partial adjustments.
  /// @dev A broker might accept a range of YT amounts, so minYt can be lower than authorized.
  function test_poc_brokerCanAcceptHigherThanMinimum() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;
    uint128 minYt = 400_000e6; // Broker accepts anything >= 400k YT

    // Facilitator authorizes the full amount
    vm.prank(consumer);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    // Broker mints with a lower minimum — succeeds because 500k >= 400k
    asset.mint(primeBroker, ptAmount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), ptAmount);
    request.mint(ptAmount, minYt);
    vm.stopPrank();

    assertEq(ytVault.balanceOf(primeBroker), ytAmount, "Should receive full YT amount");
  }

  /// @notice Verifies zero minimums still work for backwards-compatible behavior.
  /// @dev Callers who don't want slippage protection can pass (0, 0).
  function test_poc_zeroMinimumsAllowAnyAuthorization() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;

    vm.prank(consumer);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    asset.mint(primeBroker, ptAmount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), ptAmount);
    request.mint(0, 0); // No slippage protection
    vm.stopPrank();

    assertEq(ptVault.balanceOf(primeBroker), ptAmount, "PT should be minted");
    assertEq(ytVault.balanceOf(primeBroker), ytAmount, "YT should be minted");
  }
}
