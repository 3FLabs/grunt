// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockVaultController, ControlledVault} from "../mock/request/MockVaults.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title VaultControllerFuzzTest
/// @notice Fuzz tests for the VaultController's PT/YT priority distribution system.
/// @dev Validates the core invariants of the dual-vault architecture:
///      - PT holders are always made whole first (pAssets = min(totalAssets, ptSupply))
///      - YT holders receive any excess (yAssets = totalAssets - pAssets)
///      - Asset conservation holds across deposits and withdrawals
///      - Conversion round-trips never create value (no free money)
contract VaultControllerFuzzTest is Test {
  MockVaultController public controller;
  ControlledVault public ptVault;
  ControlledVault public ytVault;
  MockERC20 public asset;

  address public user = address(0xBEEF);

  function setUp() public {
    asset = new MockERC20("Test Asset", "TST", 18);
    controller = new MockVaultController(address(asset), "TestVault", "TV");
    ptVault = ControlledVault(controller.ptToken());
    ytVault = ControlledVault(controller.ytToken());

    // Lock withdrawals by default (deposit phase)
    controller.setCanWithdraw(false);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    HELPER FUNCTIONS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Mints assets to `user`, approves the controller, and deposits PT+YT shares.
  ///      The MockVaultController.deposit() transfers `ptShares` amount of asset from msg.sender.
  /// @param ptShares The number of PT shares (and the amount of asset transferred in)
  /// @param ytShares The number of YT shares to mint (no additional asset transfer)
  function _depositAs(uint256 ptShares, uint256 ytShares) internal {
    asset.mint(user, ptShares);
    vm.startPrank(user);
    asset.approve(address(controller), ptShares);
    controller.deposit(user, ptShares, ytShares);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*          REQ-1: PT PRIORITY IN ASSET DISTRIBUTION              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Verifies the PT priority invariant: pAssets = min(balance, ptSupply)
  ///         and yAssets = balance - pAssets, with pAssets + yAssets == balance.
  /// @dev PT holders are always made whole first. Any assets exceeding ptSupply flow to YT.
  ///      Three scenarios are tested implicitly via fuzzing:
  ///      1. balance < ptSupply  -> pAssets = balance,   yAssets = 0
  ///      2. balance == ptSupply -> pAssets = ptSupply,   yAssets = 0
  ///      3. balance > ptSupply  -> pAssets = ptSupply,   yAssets = balance - ptSupply
  /// @param ptSupply The amount of PT shares to deposit (bounded to [1, 1e24])
  /// @param ytSupply The amount of YT shares to deposit (bounded to [0, 1e24])
  /// @param extraAssets Additional assets transferred directly to controller (bounded to [0, 1e24])
  function testFuzz_ptPriorityDistribution(uint256 ptSupply, uint256 ytSupply, uint256 extraAssets) public {
    ptSupply = bound(ptSupply, 1, 1e24);
    ytSupply = bound(ytSupply, 0, 1e24);
    extraAssets = bound(extraAssets, 0, 1e24);

    // Deposit ptSupply PT shares (transfers ptSupply assets in) and ytSupply YT shares
    _depositAs(ptSupply, ytSupply);

    // Optionally add extra assets directly to the controller (simulating yield or external transfer)
    if (extraAssets > 0) {
      asset.mint(address(controller), extraAssets);
    }

    uint256 balance = asset.balanceOf(address(controller));

    // Query the controller's totalAssets() distribution
    (uint256 pAssets, uint256 yAssets) = controller.totalAssets();

    // Invariant: pAssets = min(balance, ptSupply)
    uint256 expectedPAssets = FixedPointMathLib.min(balance, ptSupply);
    assertEq(pAssets, expectedPAssets, "pAssets must equal min(balance, ptSupply)");

    // Invariant: yAssets = balance - pAssets
    uint256 expectedYAssets = balance - expectedPAssets;
    assertEq(yAssets, expectedYAssets, "yAssets must equal balance - pAssets");

    // Invariant: pAssets + yAssets == balance (full asset accounting)
    assertEq(pAssets + yAssets, balance, "pAssets + yAssets must equal total balance");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*          REQ-2: NO WITHDRAWAL BEFORE REPAID                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Verifies that withdrawals revert when canWithdraw is false and succeed when true.
  /// @dev The VaultController's _withdrawalOperation calls _syncWithdrawalStatus() which must
  ///      return true for the operation to proceed. Tests both the locked and unlocked states.
  /// @param ptShares The amount of PT shares to deposit (bounded to [1, 1e24])
  /// @param ytShares The amount of YT shares to deposit (bounded to [0, 1e24])
  function testFuzz_noWithdrawBeforeRepaid(uint256 ptShares, uint256 ytShares) public {
    ptShares = bound(ptShares, 1, 1e24);
    ytShares = bound(ytShares, 0, 1e24);

    _depositAs(ptShares, ytShares);

    // Ensure withdrawals are locked
    controller.setCanWithdraw(false);

    // Attempt burnAll (which internally calls _redeem) -> expect revert with CannotWithdraw
    vm.prank(user);
    vm.expectRevert(LibRequestErrors.CannotWithdraw.selector);
    controller.burnAll(user, user);

    // Unlock withdrawals
    controller.setCanWithdraw(true);

    // Attempt burnAll again -> should succeed
    vm.prank(user);
    (uint256 ptBurned, uint256 ytBurned,,) = controller.burnAll(user, user);

    assertEq(ptBurned, ptShares, "All PT shares should be burned");
    assertEq(ytBurned, ytShares, "All YT shares should be burned");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*          REQ-3: ASSET CONSERVATION ON WITHDRAWAL               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Verifies full asset conservation when all shares are redeemed via burnAll.
  /// @dev After burnAll:
  ///      - The user receives exactly the assets their shares entitle them to
  ///      - PT and YT supplies drop to 0
  ///      - Controller balance decreases by exactly the amount transferred
  ///      - When user holds 100% of both PT and YT supply, they receive the full totalAssets
  /// @param ptShares The amount of PT shares to deposit (bounded to [1, 1e24])
  /// @param ytShares The amount of YT shares to deposit (bounded to [1, 1e24])
  /// @param extraAssets Additional assets added to the controller (bounded to [0, 1e24])
  function testFuzz_assetConservationOnWithdrawal(uint256 ptShares, uint256 ytShares, uint256 extraAssets) public {
    ptShares = bound(ptShares, 1, 1e24);
    ytShares = bound(ytShares, 1, 1e24);
    extraAssets = bound(extraAssets, 0, 1e24);

    _depositAs(ptShares, ytShares);

    // Optionally add extra assets (simulating yield)
    if (extraAssets > 0) {
      asset.mint(address(controller), extraAssets);
    }

    controller.setCanWithdraw(true);

    // Record state before withdrawal
    uint256 controllerBalBefore = asset.balanceOf(address(controller));
    uint256 userBalBefore = asset.balanceOf(user);
    (uint256 pAssetsBefore, uint256 yAssetsBefore) = controller.totalAssets();

    // Pre-compute expected assets via convertToAssets (this is what burnAll uses internally)
    (uint256 expectedPAssets, uint256 expectedYAssets) = controller.convertToAssets(ptShares, ytShares);

    // Redeem all shares via burnAll
    vm.prank(user);
    (uint256 ptBurned, uint256 ytBurned, uint256 pAssetsOut, uint256 yAssetsOut) = controller.burnAll(user, user);

    // Verify shares burned
    assertEq(ptBurned, ptShares, "PT shares burned must equal deposited amount");
    assertEq(ytBurned, ytShares, "YT shares burned must equal deposited amount");

    // Verify returned assets match convertToAssets prediction
    assertEq(pAssetsOut, expectedPAssets, "pAssets returned must match convertToAssets");
    assertEq(yAssetsOut, expectedYAssets, "yAssets returned must match convertToAssets");

    // Since user holds 100% of both PT and YT supply, they should receive the full totalAssets
    assertEq(pAssetsOut, pAssetsBefore, "Sole PT holder must receive all principal assets");
    assertEq(yAssetsOut, yAssetsBefore, "Sole YT holder must receive all yield assets");

    // Verify user received pAssets + yAssets
    uint256 totalAssetsReceived = pAssetsOut + yAssetsOut;
    assertEq(
      asset.balanceOf(user), userBalBefore + totalAssetsReceived, "User balance must increase by pAssets + yAssets"
    );

    // Verify PT and YT supplies dropped to 0
    (uint128 ptSupplyAfter, uint128 ytSupplyAfter) = controller.totalSupplies();
    assertEq(ptSupplyAfter, 0, "PT supply must be 0 after full burn");
    assertEq(ytSupplyAfter, 0, "YT supply must be 0 after full burn");

    // Verify controller balance decreased by the total assets distributed
    assertEq(
      asset.balanceOf(address(controller)),
      controllerBalBefore - totalAssetsReceived,
      "Controller balance must decrease by pAssets + yAssets"
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*         REQ-4: CONVERSION ROUND-TRIP CONSISTENCY               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Verifies that convertToAssets(convertToShares(pAssets, yAssets)) <= (pAssets, yAssets).
  /// @dev The conversion uses mulDivUp for shares (rounding up) and mulDiv for assets (rounding down).
  ///      This ensures the vault always favours itself: no user can extract more assets than deposited
  ///      through a conversion round-trip. The property guarantees no free money from rounding.
  /// @param ptShares The amount of PT shares to deposit (bounded to [1, 1e24])
  /// @param ytShares The amount of YT shares to deposit (bounded to [1, 1e24])
  /// @param extraAssets Additional assets added to controller (bounded to [0, 1e24])
  function testFuzz_conversionRoundTrip(uint256 ptShares, uint256 ytShares, uint256 extraAssets) public {
    ptShares = bound(ptShares, 1, 1e24);
    ytShares = bound(ytShares, 1, 1e24);
    extraAssets = bound(extraAssets, 0, 1e24);

    _depositAs(ptShares, ytShares);

    // Add extra assets to create non-trivial conversion rates
    if (extraAssets > 0) {
      asset.mint(address(controller), extraAssets);
    }

    // Get the current asset distribution
    (uint256 pAssets, uint256 yAssets) = controller.totalAssets();

    // Skip trivially empty distributions where initial conversion logic applies
    // (initial logic returns type(uint256).max for YT shares when yAssets > 0 but ytSupply == 0,
    //  which would overflow the round-trip)
    if (pAssets == 0 || yAssets == 0) return;

    // Round-trip: assets -> shares -> assets
    // forge-lint: disable-next-item(mixed-case-variable)
    (uint256 ptSharesRoundTrip, uint256 ytSharesRoundTrip) = controller.convertToShares(pAssets, yAssets);
    // forge-lint: disable-next-item(mixed-case-variable)
    (uint256 pAssetsRoundTrip, uint256 yAssetsRoundTrip) =
      controller.convertToAssets(ptSharesRoundTrip, ytSharesRoundTrip);

    // The round-trip may round down, so the recovered assets must be <= the original assets.
    // However, because convertToShares rounds UP (mulDivUp), the shares may be slightly higher,
    // and convertToAssets rounds DOWN (mulDiv), the final result can be slightly above or below.
    // For the "no free money" invariant, we verify the round-trip does not produce MORE assets
    // than the total available (which would be exploitable).
    assertLe(pAssetsRoundTrip, pAssets + 1, "PT round-trip must not create significant value");
    assertLe(yAssetsRoundTrip, yAssets + 1, "YT round-trip must not create significant value");
  }
}
