// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SharesMathLib as LocalSharesMathLib} from "src/libs/borrow/SharesMathLib.sol";
import {SharesMathLib as MorphoSharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";

/// @title SharesMathLibTest
/// @notice Fuzz tests comparing local SharesMathLib against Morpho's SharesMathLib
contract SharesMathLibTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant VIRTUAL_SHARES = 1e6;
  uint256 constant VIRTUAL_ASSETS = 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CONSTANTS TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_constants_VirtualSharesMatch() public pure {
    assertEq(LocalSharesMathLib.VIRTUAL_SHARES, VIRTUAL_SHARES);
  }

  function test_constants_VirtualAssetsMatch() public pure {
    assertEq(LocalSharesMathLib.VIRTUAL_ASSETS, VIRTUAL_ASSETS);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   TO_SHARES_DOWN TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_toSharesDown_MatchesMorpho(uint256 assets, uint256 totalAssets, uint256 totalShares) public pure {
    // Bound inputs to avoid overflow
    assets = bound(assets, 0, type(uint96).max);
    totalAssets = bound(totalAssets, 0, type(uint96).max);
    totalShares = bound(totalShares, 0, type(uint96).max);

    uint256 localResult = LocalSharesMathLib.toSharesDown(assets, totalAssets, totalShares);
    uint256 morphoResult = MorphoSharesMathLib.toSharesDown(assets, totalAssets, totalShares);

    assertEq(localResult, morphoResult, "toSharesDown mismatch");
  }

  function test_toSharesDown_ZeroAssets() public pure {
    uint256 localResult = LocalSharesMathLib.toSharesDown(0, 1000e18, 1000e18);
    uint256 morphoResult = MorphoSharesMathLib.toSharesDown(0, 1000e18, 1000e18);

    assertEq(localResult, morphoResult);
    assertEq(localResult, 0);
  }

  function test_toSharesDown_EmptyMarket() public pure {
    uint256 localResult = LocalSharesMathLib.toSharesDown(1000e18, 0, 0);
    uint256 morphoResult = MorphoSharesMathLib.toSharesDown(1000e18, 0, 0);

    assertEq(localResult, morphoResult);
  }

  function test_toSharesDown_OneToOneRatio() public pure {
    uint256 localResult = LocalSharesMathLib.toSharesDown(100e18, 1000e18, 1000e18);
    uint256 morphoResult = MorphoSharesMathLib.toSharesDown(100e18, 1000e18, 1000e18);

    assertEq(localResult, morphoResult);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   TO_ASSETS_DOWN TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_toAssetsDown_MatchesMorpho(uint256 shares, uint256 totalAssets, uint256 totalShares) public pure {
    // Bound inputs to avoid overflow
    shares = bound(shares, 0, type(uint96).max);
    totalAssets = bound(totalAssets, 0, type(uint96).max);
    totalShares = bound(totalShares, 0, type(uint96).max);

    uint256 localResult = LocalSharesMathLib.toAssetsDown(shares, totalAssets, totalShares);
    uint256 morphoResult = MorphoSharesMathLib.toAssetsDown(shares, totalAssets, totalShares);

    assertEq(localResult, morphoResult, "toAssetsDown mismatch");
  }

  function test_toAssetsDown_ZeroShares() public pure {
    uint256 localResult = LocalSharesMathLib.toAssetsDown(0, 1000e18, 1000e18);
    uint256 morphoResult = MorphoSharesMathLib.toAssetsDown(0, 1000e18, 1000e18);

    assertEq(localResult, morphoResult);
    assertEq(localResult, 0);
  }

  function test_toAssetsDown_EmptyMarket() public pure {
    uint256 localResult = LocalSharesMathLib.toAssetsDown(1000e18, 0, 0);
    uint256 morphoResult = MorphoSharesMathLib.toAssetsDown(1000e18, 0, 0);

    assertEq(localResult, morphoResult);
  }

  function test_toAssetsDown_OneToOneRatio() public pure {
    uint256 localResult = LocalSharesMathLib.toAssetsDown(100e18, 1000e18, 1000e18);
    uint256 morphoResult = MorphoSharesMathLib.toAssetsDown(100e18, 1000e18, 1000e18);

    assertEq(localResult, morphoResult);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    TO_SHARES_UP TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_toSharesUp_MatchesMorpho(uint256 assets, uint256 totalAssets, uint256 totalShares) public pure {
    // Bound inputs to avoid overflow (tighter bounds for mulDivUp)
    assets = bound(assets, 0, type(uint96).max);
    totalAssets = bound(totalAssets, 0, type(uint96).max);
    totalShares = bound(totalShares, 0, type(uint96).max);

    uint256 localResult = LocalSharesMathLib.toSharesUp(assets, totalAssets, totalShares);
    uint256 morphoResult = MorphoSharesMathLib.toSharesUp(assets, totalAssets, totalShares);

    assertEq(localResult, morphoResult, "toSharesUp mismatch");
  }

  function test_toSharesUp_ZeroAssets() public pure {
    uint256 localResult = LocalSharesMathLib.toSharesUp(0, 1000e18, 1000e18);
    uint256 morphoResult = MorphoSharesMathLib.toSharesUp(0, 1000e18, 1000e18);

    assertEq(localResult, morphoResult);
    assertEq(localResult, 0);
  }

  function test_toSharesUp_EmptyMarket() public pure {
    uint256 localResult = LocalSharesMathLib.toSharesUp(1000e18, 0, 0);
    uint256 morphoResult = MorphoSharesMathLib.toSharesUp(1000e18, 0, 0);

    assertEq(localResult, morphoResult);
  }

  function test_toSharesUp_RoundsUp() public pure {
    // Use values that will result in rounding
    uint256 localResult = LocalSharesMathLib.toSharesUp(3, 10, 7);
    uint256 morphoResult = MorphoSharesMathLib.toSharesUp(3, 10, 7);

    assertEq(localResult, morphoResult);
    // Verify it rounds up (result should be >= toSharesDown)
    uint256 downResult = LocalSharesMathLib.toSharesDown(3, 10, 7);
    assertGe(localResult, downResult);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    TO_ASSETS_UP TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_toAssetsUp_MatchesMorpho(uint256 shares, uint256 totalAssets, uint256 totalShares) public pure {
    // Bound inputs to avoid overflow (tighter bounds for mulDivUp)
    shares = bound(shares, 0, type(uint96).max);
    totalAssets = bound(totalAssets, 0, type(uint96).max);
    totalShares = bound(totalShares, 0, type(uint96).max);

    uint256 localResult = LocalSharesMathLib.toAssetsUp(shares, totalAssets, totalShares);
    uint256 morphoResult = MorphoSharesMathLib.toAssetsUp(shares, totalAssets, totalShares);

    assertEq(localResult, morphoResult, "toAssetsUp mismatch");
  }

  function test_toAssetsUp_ZeroShares() public pure {
    uint256 localResult = LocalSharesMathLib.toAssetsUp(0, 1000e18, 1000e18);
    uint256 morphoResult = MorphoSharesMathLib.toAssetsUp(0, 1000e18, 1000e18);

    assertEq(localResult, morphoResult);
    assertEq(localResult, 0);
  }

  function test_toAssetsUp_EmptyMarket() public pure {
    uint256 localResult = LocalSharesMathLib.toAssetsUp(1000e18, 0, 0);
    uint256 morphoResult = MorphoSharesMathLib.toAssetsUp(1000e18, 0, 0);

    assertEq(localResult, morphoResult);
  }

  function test_toAssetsUp_RoundsUp() public pure {
    // Use values that will result in rounding
    uint256 localResult = LocalSharesMathLib.toAssetsUp(3, 10, 7);
    uint256 morphoResult = MorphoSharesMathLib.toAssetsUp(3, 10, 7);

    assertEq(localResult, morphoResult);
    // Verify it rounds up (result should be >= toAssetsDown)
    uint256 downResult = LocalSharesMathLib.toAssetsDown(3, 10, 7);
    assertGe(localResult, downResult);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   ROUNDTRIP TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_roundtrip_AssetsToSharesToAssets(uint256 assets, uint256 totalAssets, uint256 totalShares)
    public
    pure
  {
    // Bound inputs to avoid overflow
    assets = bound(assets, 0, type(uint96).max);
    totalAssets = bound(totalAssets, 0, type(uint96).max);
    totalShares = bound(totalShares, 0, type(uint96).max);

    // Convert assets to shares (down) then back to assets (down)
    uint256 shares = LocalSharesMathLib.toSharesDown(assets, totalAssets, totalShares);
    uint256 assetsBack = LocalSharesMathLib.toAssetsDown(shares, totalAssets, totalShares);

    // Due to rounding down twice, result should be <= original
    assertLe(assetsBack, assets, "Roundtrip should not increase assets");

    // Compare with Morpho
    uint256 morphoShares = MorphoSharesMathLib.toSharesDown(assets, totalAssets, totalShares);
    uint256 morphoAssetsBack = MorphoSharesMathLib.toAssetsDown(morphoShares, totalAssets, totalShares);

    assertEq(assetsBack, morphoAssetsBack, "Roundtrip mismatch with Morpho");
  }

  function testFuzz_roundtrip_SharesToAssetsToShares(uint256 shares, uint256 totalAssets, uint256 totalShares)
    public
    pure
  {
    // Bound inputs to avoid overflow
    shares = bound(shares, 0, type(uint96).max);
    totalAssets = bound(totalAssets, 0, type(uint96).max);
    totalShares = bound(totalShares, 0, type(uint96).max);

    // Convert shares to assets (down) then back to shares (down)
    uint256 assets = LocalSharesMathLib.toAssetsDown(shares, totalAssets, totalShares);
    uint256 sharesBack = LocalSharesMathLib.toSharesDown(assets, totalAssets, totalShares);

    // Due to rounding down twice, result should be <= original
    assertLe(sharesBack, shares, "Roundtrip should not increase shares");

    // Compare with Morpho
    uint256 morphoAssets = MorphoSharesMathLib.toAssetsDown(shares, totalAssets, totalShares);
    uint256 morphoSharesBack = MorphoSharesMathLib.toSharesDown(morphoAssets, totalAssets, totalShares);

    assertEq(sharesBack, morphoSharesBack, "Roundtrip mismatch with Morpho");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   ROUNDING DIRECTION TESTS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_roundingDirection_SharesUpGeDown(uint256 assets, uint256 totalAssets, uint256 totalShares)
    public
    pure
  {
    assets = bound(assets, 0, type(uint96).max);
    totalAssets = bound(totalAssets, 0, type(uint96).max);
    totalShares = bound(totalShares, 0, type(uint96).max);

    uint256 sharesDown = LocalSharesMathLib.toSharesDown(assets, totalAssets, totalShares);
    uint256 sharesUp = LocalSharesMathLib.toSharesUp(assets, totalAssets, totalShares);

    assertGe(sharesUp, sharesDown, "toSharesUp should be >= toSharesDown");
  }

  function testFuzz_roundingDirection_AssetsUpGeDown(uint256 shares, uint256 totalAssets, uint256 totalShares)
    public
    pure
  {
    shares = bound(shares, 0, type(uint96).max);
    totalAssets = bound(totalAssets, 0, type(uint96).max);
    totalShares = bound(totalShares, 0, type(uint96).max);

    uint256 assetsDown = LocalSharesMathLib.toAssetsDown(shares, totalAssets, totalShares);
    uint256 assetsUp = LocalSharesMathLib.toAssetsUp(shares, totalAssets, totalShares);

    assertGe(assetsUp, assetsDown, "toAssetsUp should be >= toAssetsDown");
  }
}
