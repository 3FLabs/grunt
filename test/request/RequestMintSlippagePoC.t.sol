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
///      Reference: CS-GRUNT-018 — Facilitator can front-run to increase PT (larger deposit, same yield).
///
///      Attack sequences (without fix):
///        YT reduction attack:
///        1. Facilitator calls authorizeMinting(broker, 1000e6, 500e6)
///        2. BF approves the Request contract and submits mint() transaction
///        3. Facilitator front-runs with authorizeMinting(broker, 1000e6, 0) — same PT, zero YT
///        4. BF's mint() executes: transfers 1000 USDC, receives 1000 PT + 0 YT
///
///        PT inflation attack (CS-GRUNT-018):
///        1. Facilitator calls authorizeMinting(broker, 1000e6, 500e6)
///        2. BF approves the Request contract and submits mint() transaction
///        3. Facilitator front-runs with authorizeMinting(broker, 2000e6, 500e6) — doubled PT, same YT
///        4. BF's mint() executes: transfers 2000 USDC, receives 2000 PT + 500 YT (overpaid for yield)
///
///      With the fix, mint(maxPt, minYt) reverts with SlippageExceeded if the authorized
///      PT exceeds the broker's cap or the authorized YT falls below the broker's floor.
contract RequestMintSlippagePoCTest is Test {
  RequestFactory public factory;
  Request public request;
  Vault public ptVault;
  Vault public ytVault;
  MockERC20 public asset;

  address public owner;
  address public puller;
  address public consumer; // acts as facilitator for authorizeMinting
  address public bridgeFacilitator;

  function setUp() public {
    owner = makeAddr("owner");
    puller = makeAddr("puller");
    consumer = makeAddr("consumer");
    bridgeFacilitator = makeAddr("bridgeFacilitator");

    asset = new MockERC20("USDC", "USDC", 6);
    factory = new RequestFactory(makeAddr("beaconOwner"));

    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) = factory.createRequest(
      owner, puller, consumer, address(asset), "Test Request", "REQ", uint64(block.timestamp + 90 days), 0
    );

    request = Request(reqAddr);
    ptVault = Vault(ptAddr);
    ytVault = Vault(ytAddr);
  }

  /// @notice Demonstrates the YT reduction front-run attack scenario and that slippage protection blocks it.
  /// @dev The facilitator front-runs the broker's mint() by overwriting the YT authorization to zero.
  ///      Without the fix, the broker would lose their entire YT allocation.
  ///      With the fix, mint(maxPt, minYt) reverts with SlippageExceeded.
  function test_poc_facilitatorCannotFrontRunMintToZeroYT() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;

    // Step 1: Facilitator authorizes minting for the bridge facilitator
    vm.prank(consumer);
    request.authorizeMinting(bridgeFacilitator, ptAmount, ytAmount);

    // Verify the broker sees the expected authorization
    (uint128 authPt, uint128 authYt) = request.mintAuthorization(bridgeFacilitator);
    assertEq(authPt, ptAmount, "BF should see 1M PT authorized");
    assertEq(authYt, ytAmount, "BF should see 500k YT authorized");

    // Step 2: BF prepares to mint (approves funds)
    asset.mint(bridgeFacilitator, ptAmount);
    vm.prank(bridgeFacilitator);
    asset.approve(address(request), ptAmount);

    // Step 3: Facilitator FRONT-RUNS by overwriting authorization to zero YT
    vm.prank(consumer);
    request.authorizeMinting(bridgeFacilitator, ptAmount, 0);

    // Step 4: BF's mint() reverts because YT authorization (0) < minYt (500k)
    vm.prank(bridgeFacilitator);
    vm.expectRevert(LibRequestErrors.SlippageExceeded.selector);
    request.mint(ptAmount, ytAmount);

    // --- Verify the attack was prevented ---
    // BF still has their funds (nothing was transferred)
    assertEq(asset.balanceOf(bridgeFacilitator), ptAmount, "BF funds should be intact");
    assertEq(ptVault.balanceOf(bridgeFacilitator), 0, "No PT tokens should be minted");
    assertEq(ytVault.balanceOf(bridgeFacilitator), 0, "No YT tokens should be minted");
  }

  /// @notice Demonstrates that PT inflation attack is now protected (CS-GRUNT-018).
  /// @dev Facilitator increases PT authorization so the broker would deposit more than expected
  ///      for the same yield. The maxPt cap prevents this.
  function test_poc_facilitatorCannotFrontRunMintToIncreasePT() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;

    // Facilitator authorizes
    vm.prank(consumer);
    request.authorizeMinting(bridgeFacilitator, ptAmount, ytAmount);

    asset.mint(bridgeFacilitator, ptAmount * 2);
    vm.prank(bridgeFacilitator);
    asset.approve(address(request), ptAmount * 2);

    // Facilitator front-runs by doubling PT — broker would overpay for same yield
    vm.prank(consumer);
    request.authorizeMinting(bridgeFacilitator, ptAmount * 2, ytAmount);

    // BF's mint reverts because PT authorization (2M) > maxPt (1M)
    vm.prank(bridgeFacilitator);
    vm.expectRevert(LibRequestErrors.SlippageExceeded.selector);
    request.mint(ptAmount, ytAmount);

    // BF funds intact
    assertEq(asset.balanceOf(bridgeFacilitator), ptAmount * 2, "BF funds should be intact");
  }

  /// @notice Verifies that legitimate minting succeeds when authorization matches expectations.
  function test_poc_legitimateMintSucceedsWithSlippageProtection() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;

    // Facilitator authorizes
    vm.prank(consumer);
    request.authorizeMinting(bridgeFacilitator, ptAmount, ytAmount);

    // BF mints with slippage protection matching the authorization
    asset.mint(bridgeFacilitator, ptAmount);
    vm.startPrank(bridgeFacilitator);
    asset.approve(address(request), ptAmount);
    request.mint(ptAmount, ytAmount);
    vm.stopPrank();

    // Verify tokens minted correctly
    assertEq(ptVault.balanceOf(bridgeFacilitator), ptAmount, "PT tokens should be minted");
    assertEq(ytVault.balanceOf(bridgeFacilitator), ytAmount, "YT tokens should be minted");
    assertEq(asset.balanceOf(address(request)), ptAmount, "Assets should be in the request");
    assertEq(asset.balanceOf(bridgeFacilitator), 0, "BF should have spent all funds");
  }

  /// @notice Verifies that a broker can set relaxed bounds to allow partial adjustments.
  /// @dev A broker might accept a range of YT amounts (minYt lower than authorized)
  ///      and a range of PT amounts (maxPt higher than authorized).
  function test_poc_brokerCanAcceptRelaxedBounds() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;
    uint128 maxPt = 1_200_000e6; // BF accepts up to 1.2M PT
    uint128 minYt = 400_000e6; // BF accepts anything >= 400k YT

    // Facilitator authorizes the full amount
    vm.prank(consumer);
    request.authorizeMinting(bridgeFacilitator, ptAmount, ytAmount);

    // BF mints with relaxed bounds — succeeds because 1M <= 1.2M and 500k >= 400k
    asset.mint(bridgeFacilitator, ptAmount);
    vm.startPrank(bridgeFacilitator);
    asset.approve(address(request), ptAmount);
    request.mint(maxPt, minYt);
    vm.stopPrank();

    assertEq(ytVault.balanceOf(bridgeFacilitator), ytAmount, "Should receive full YT amount");
    assertEq(ptVault.balanceOf(bridgeFacilitator), ptAmount, "Should receive full PT amount");
  }

  /// @notice Verifies max PT / zero minYt still works for no-protection behavior.
  /// @dev Callers who don't want slippage protection can pass (type(uint128).max, 0).
  function test_poc_noProtectionWithMaxValues() public {
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 500_000e6;

    vm.prank(consumer);
    request.authorizeMinting(bridgeFacilitator, ptAmount, ytAmount);

    asset.mint(bridgeFacilitator, ptAmount);
    vm.startPrank(bridgeFacilitator);
    asset.approve(address(request), ptAmount);
    request.mint(type(uint128).max, 0); // No slippage protection
    vm.stopPrank();

    assertEq(ptVault.balanceOf(bridgeFacilitator), ptAmount, "PT should be minted");
    assertEq(ytVault.balanceOf(bridgeFacilitator), ytAmount, "YT should be minted");
  }
}
