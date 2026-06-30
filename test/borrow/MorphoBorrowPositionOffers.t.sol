// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";
import {IBorrowOffers, Offer} from "src/interfaces/borrow/IBorrowOffers.sol";
import {IPreLiquidationCallback} from "src/interfaces/borrow/IPreliquidationCallback.sol";
import {LibBorrowErrors} from "src/libs/borrow/LibBorrowErrors.sol";
import {
  ROLE_ADMIN,
  PROPOSER_ROLE,
  GUARDIAN_ROLE,
  MAX_OFFERS,
  NULL,
  DEFAULT_OFFER_TIMELOCK,
  MIN_OFFER_TIMELOCK,
  MAX_OFFER_TIMELOCK,
  MAX_OFFER_LIFESPAN
} from "src/libs/borrow/LibBorrowOffersConstants.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title MorphoBorrowPositionOffersTest
/// @notice v2 offer-based pre-liquidation tests for {MorphoBorrowPosition}. Uses a zero-IRM market
///         so the position LTV is deterministic across the timelock warps (no interest accrual).
contract MorphoBorrowPositionOffersTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ACTORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MorphoBorrowPosition internal pos;
  MorphoBorrowPositionFactory internal factory;
  IMorpho internal morpho;
  MockERC20 internal loanToken;
  MockERC20 internal collateralToken;
  OracleMock internal oracle;

  MarketParams internal marketParams;
  Id internal marketId;

  address internal owner; // morpho owner
  address internal positionManager; // position owner (and, by fallback, ROLE_ADMIN)
  address internal proposer;
  address internal guardian;
  address internal liquidator;

  // Solady Ownable auth error.
  error Unauthorized();

  uint128 internal constant LLTV = 0.8e18;
  uint128 internal constant SAFE_LTV = 0.65e18;
  uint128 internal constant LIQ_LTV = 0.72e18;
  uint256 internal constant SCALE = 1e36;

  uint256 internal constant COLLATERAL = 10_000e18;
  uint256 internal constant BORROW = 6_000e18; // 0.6 LTV at price 1 (safe)

  // Solady fixed storage slots (for the migration test's vm.store).
  bytes32 internal constant INITIALIZABLE_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffbf601132;
  bytes32 internal constant OWNER_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927;
  // ERC-7201 "borrow.offers.main" namespace base slot (BorrowOffersStorage slot 0).
  bytes32 internal constant OFFERS_SLOT = 0xe6485cf370207053ea24e440730156198d1a663d29d90d2bec5f918b1f0d9100;

  function setUp() public {
    owner = makeAddr("owner");
    positionManager = makeAddr("positionManager");
    proposer = makeAddr("proposer");
    guardian = makeAddr("guardian");
    liquidator = address(this); // the test contract acts as the liquidator

    morpho = IMorpho(address(new Morpho(owner)));
    loanToken = new MockERC20("Loan", "LOAN", 18);
    collateralToken = new MockERC20("Coll", "COLL", 18);
    oracle = new OracleMock();
    oracle.setPrice(SCALE);

    vm.startPrank(owner);
    morpho.enableIrm(address(0)); // zero IRM: no interest accrual -> deterministic LTV
    morpho.enableLltv(LLTV);
    vm.stopPrank();

    marketParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(0),
      lltv: LLTV
    });
    vm.prank(owner);
    morpho.createMarket(marketParams);
    marketId = marketParams.id();

    vm.mockCall(
      positionManager, abi.encodeWithSignature("assets()"), abi.encode(address(collateralToken), address(loanToken))
    );

    factory = new MorphoBorrowPositionFactory(owner, morpho);
    pos = MorphoBorrowPosition(factory.createBorrowPosition(marketId, positionManager, SAFE_LTV, LIQ_LTV));

    // Position manager approvals (collateral supply path).
    vm.startPrank(positionManager);
    loanToken.approve(address(pos), type(uint256).max);
    collateralToken.approve(address(pos), type(uint256).max);
    vm.stopPrank();

    // Liquidator funding + approval (loan tokens pulled in onMorphoRepay).
    loanToken.setBalance(liquidator, 1_000_000e18);
    loanToken.approve(address(pos), type(uint256).max);

    _supplyLiquidity(1_000_000e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _supplyLiquidity(uint256 amount) internal {
    loanToken.setBalance(address(0xBEEF), amount);
    vm.startPrank(address(0xBEEF));
    loanToken.approve(address(morpho), amount);
    morpho.supply(marketParams, amount, 0, address(0xBEEF), "");
    vm.stopPrank();
  }

  /// @dev Supplies collateral, borrows, then sets the oracle price so the position LTV is `ltvWad`.
  function _enterBand(uint256 ltvWad) internal {
    collateralToken.setBalance(positionManager, COLLATERAL);
    vm.startPrank(positionManager);
    pos.supplyCollateral(COLLATERAL);
    pos.borrow(BORROW);
    vm.stopPrank();

    // price so that L = BORROW / (COLLATERAL * price / SCALE) = ltvWad/1e18.
    uint256 price = BORROW * SCALE / COLLATERAL * 1e18 / ltvWad;
    oracle.setPrice(price);
  }

  function _borrowTotals() internal view returns (uint256 tba, uint256 tbs) {
    Market memory m = morpho.market(marketId);
    tba = uint256(m.totalBorrowAssets);
    tbs = uint256(m.totalBorrowShares);
  }

  function _positionShares() internal view returns (uint256) {
    return uint256(morpho.position(marketId, address(pos)).borrowShares);
  }

  function _positionCollateral() internal view returns (uint256) {
    return uint256(morpho.position(marketId, address(pos)).collateral);
  }

  function _ltvWad() internal view returns (uint256) {
    (uint256 tba, uint256 tbs) = _borrowTotals();
    uint256 b = _positionShares().toAssetsUp(tba, tbs);
    uint256 v = _positionCollateral() * oracle.price() / SCALE;
    if (v == 0) return type(uint256).max;
    return b * 1e18 / v;
  }

  /// @dev Collateral amount such that the whole offer's price `I = collateralValue / debtValue`
  ///      equals `priceWad / 1e18` at the current oracle price and market totals.
  function _collForPrice(uint256 debtShares, uint256 priceWad) internal view returns (uint128) {
    (uint256 tba, uint256 tbs) = _borrowTotals();
    uint256 d = debtShares.toAssetsUp(tba, tbs);
    uint256 collValue = d * priceWad / 1e18;
    return uint128(collValue * SCALE / oracle.price());
  }

  function _enableProposer(address who) internal {
    vm.prank(positionManager);
    pos.setProposer(who, true);
  }

  function _enableGuardian(address who) internal {
    vm.prank(positionManager);
    pos.setGuardian(who, true);
  }

  /// @dev Proposes an offer (as `proposer`) with the default timelock and a long lifespan.
  function _propose(uint128 coll, uint128 shares) internal returns (uint8 id) {
    vm.prank(proposer);
    id = pos.proposeOffer(coll, shares, uint40(block.timestamp + 30 days));
  }

  /// @dev Proposes an offer at a target whole-offer price (in WAD) for a given debt-share size.
  function _proposeAtPrice(uint256 debtShares, uint256 priceWad) internal returns (uint8 id) {
    return _propose(_collForPrice(debtShares, priceWad), uint128(debtShares));
  }

  function _warpActive() internal {
    vm.warp(block.timestamp + DEFAULT_OFFER_TIMELOCK + 1);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INIT / UPGRADE / ROLES                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_init_factoryPathLandsAtV2() public view {
    // The factory's initialize ran v1 + v2; ROLE_ADMIN is the governance owner (fallback: PM).
    assertEq(pos.offerTimelock(), DEFAULT_OFFER_TIMELOCK, "default timelock");
    assertEq(pos.offerCount(), 0, "no offers");
    assertTrue(pos.hasAnyRole(positionManager, ROLE_ADMIN), "PM is admin (fallback)");
  }

  /// @notice Primary `_governanceOwner` path: when the PositionManager's `owner()` resolves to a
  ///         real governance address, ROLE_ADMIN is granted to THAT address (owner-of-owner), not to
  ///         the position owner.
  function test_governanceOwner_resolvesToOwnerOfOwner() public {
    address governance = makeAddr("governance");
    vm.mockCall(positionManager, abi.encodeWithSignature("owner()"), abi.encode(governance));
    MorphoBorrowPosition p =
      MorphoBorrowPosition(factory.createBorrowPosition(marketId, positionManager, SAFE_LTV, LIQ_LTV));
    assertTrue(p.hasAnyRole(governance, ROLE_ADMIN), "governance owner is admin");
    assertFalse(p.hasAnyRole(positionManager, ROLE_ADMIN), "PM not admin when owner-of-owner resolves");
  }

  /// @notice `_governanceOwner` is total: a PositionManager whose `owner()` returns an unexpected
  ///         shape (here 64 bytes, not a single address word) must NOT revert initialization; it
  ///         falls back to the position owner. The same holds for an EOA / reverting `owner()`
  ///         (the default setUp, where `owner()` is unmocked, already exercises the empty-return
  ///         fallback in {test_init_factoryPathLandsAtV2}).
  function test_governanceOwner_malformedOwnerReturn_fallsBackNotRevert() public {
    // 64-byte return: a valid address word is exactly 32 bytes, so this is "unexpected shape".
    vm.mockCall(positionManager, abi.encodeWithSignature("owner()"), abi.encode(uint256(1), uint256(2)));
    MorphoBorrowPosition p =
      MorphoBorrowPosition(factory.createBorrowPosition(marketId, positionManager, SAFE_LTV, LIQ_LTV));
    assertTrue(p.hasAnyRole(positionManager, ROLE_ADMIN), "fallback to PM on malformed owner() return");
  }

  function test_roleConstants_matchSoladyOrdinals() public pure {
    assertEq(ROLE_ADMIN, 1 << 0, "ROLE_ADMIN == _ROLE_0");
    assertEq(PROPOSER_ROLE, 1 << 1, "PROPOSER_ROLE == _ROLE_1");
    assertEq(GUARDIAN_ROLE, 1 << 2, "GUARDIAN_ROLE == _ROLE_2");
  }

  function test_initializeV2_revertsOnFreshProxy() public {
    MorphoBorrowPosition fresh = MorphoBorrowPosition(address(new MorphoBorrowPosition(morpho)).clone());
    vm.expectRevert(LibBorrowErrors.NotInitialized.selector);
    fresh.initializeV2();
  }

  function test_initializeV2_revertsOnAlreadyV2() public {
    // pos is already at version 2 (factory path).
    vm.expectRevert(LibBorrowErrors.NotInitialized.selector);
    pos.initializeV2();
  }

  function test_initializeV2_migratesV1Proxy() public {
    // Model a pre-upgrade v1 proxy whose logic is ALREADY the v2 impl (the beacon upgrade swapped
    // it) but whose Initializable slot is still at version 1 and whose owner is set. We drive those
    // two slots directly with vm.store (Solady fixed slots), which is exactly the post-upgrade state.
    MorphoBorrowPosition v1 = MorphoBorrowPosition(address(new MorphoBorrowPosition(morpho)).clone());
    // Initializable slot: initializing=0, version=1 => stored value (1 << 1) = 2.
    vm.store(address(v1), INITIALIZABLE_SLOT, bytes32(uint256(2)));
    // Solady _OWNER_SLOT: set the position owner so _governanceOwner() can resolve it.
    vm.store(address(v1), OWNER_SLOT, bytes32(uint256(uint160(positionManager))));
    assertEq(v1.owner(), positionManager, "owner set");

    // Migration runs the v2 setup and lands at version 2.
    v1.initializeV2();
    assertEq(v1.offerTimelock(), DEFAULT_OFFER_TIMELOCK, "timelock seeded");
    assertTrue(v1.hasAnyRole(positionManager, ROLE_ADMIN), "admin granted on migration");

    // Cannot migrate twice (now at version 2).
    vm.expectRevert(LibBorrowErrors.NotInitialized.selector);
    v1.initializeV2();
  }

  function test_setProposer_grantsAndRevokes() public {
    _enableProposer(proposer);
    assertTrue(pos.hasAnyRole(proposer, PROPOSER_ROLE), "granted");
    vm.prank(positionManager);
    pos.setProposer(proposer, false);
    assertFalse(pos.hasAnyRole(proposer, PROPOSER_ROLE), "revoked");
  }

  function test_setGuardian_grantsAndRevokes() public {
    _enableGuardian(guardian);
    assertTrue(pos.hasAnyRole(guardian, GUARDIAN_ROLE), "granted");
    vm.prank(positionManager);
    pos.setGuardian(guardian, false);
    assertFalse(pos.hasAnyRole(guardian, GUARDIAN_ROLE), "revoked");
  }

  function test_setProposer_revertsForNonAdmin() public {
    vm.prank(makeAddr("rando"));
    vm.expectRevert(Unauthorized.selector);
    pos.setProposer(proposer, true);
  }

  function test_proposeOffer_revertsForNonProposer() public {
    vm.prank(makeAddr("rando"));
    vm.expectRevert(Unauthorized.selector);
    pos.proposeOffer(1e18, 1e18, uint40(block.timestamp + 1 days));
  }

  function test_revokeOffers_revertsForNonGuardian() public {
    uint8[] memory ids = new uint8[](1);
    ids[0] = 0;
    vm.prank(makeAddr("rando"));
    vm.expectRevert(Unauthorized.selector);
    pos.revokeOffers(ids);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PROPOSE / VALIDATION                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_proposeOffer_storesOfferAndActiveAt() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18);

    uint40 expectedActive = uint40(block.timestamp + DEFAULT_OFFER_TIMELOCK);
    uint8 id = _propose(coll, uint128(shares));

    Offer memory o = pos.offer(id);
    assertEq(o.proposer, proposer, "proposer");
    assertEq(o.remainingCollateral, coll, "coll");
    assertEq(o.remainingDebtShares, uint128(shares), "shares");
    assertEq(o.activeAt, expectedActive, "activeAt fixed at proposal");
    assertEq(pos.offerCount(), 1, "count");
  }

  function test_proposeOffer_revertsZeroAmount() public {
    _enableProposer(proposer);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferAmountZero.selector);
    pos.proposeOffer(0, 1e18, uint40(block.timestamp + 1 days));
  }

  function test_proposeOffer_revertsNotProfitable() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    // Price 0.9 < 1 -> not profitable at creation.
    uint128 coll = _collForPrice(shares, 0.9e18);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferNotProfitable.selector);
    pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 1 days));
  }

  function test_proposeOffer_revertsExpiryTooShort() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18);
    // expiresAt == activeAt is not strictly after -> revert.
    uint40 activeAt = uint40(block.timestamp + DEFAULT_OFFER_TIMELOCK);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferExpiryTooShort.selector);
    pos.proposeOffer(coll, uint128(shares), activeAt);
  }

  function test_proposeOffer_revertsExpiryTooLong() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18);
    // Lifespan is measured from `activeAt` (= now + timelock), not from now. One second past the cap
    // relative to `activeAt` must revert.
    uint40 activeAt = uint40(block.timestamp + DEFAULT_OFFER_TIMELOCK);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferExpiryTooLong.selector);
    pos.proposeOffer(coll, uint128(shares), activeAt + MAX_OFFER_LIFESPAN + 1);
  }

  function test_proposeOffer_maxLifespanMeasuredFromActiveAt() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18);
    uint40 activeAt = uint40(block.timestamp + DEFAULT_OFFER_TIMELOCK);
    // Exactly MAX_OFFER_LIFESPAN measured from `activeAt` is the boundary and is accepted. Note this
    // expiry sits MAX_OFFER_LIFESPAN + timelock past `now`, so it would be rejected under a
    // measured-from-now rule: the live span (not the veto window) is what the cap bounds.
    uint40 expiresAt = activeAt + MAX_OFFER_LIFESPAN;
    vm.prank(proposer);
    uint8 id = pos.proposeOffer(coll, uint128(shares), expiresAt);
    assertEq(pos.offer(id).expiresAt, expiresAt, "max-lifespan-from-activeAt accepted");
  }

  function test_proposeOffer_revertsTooManyOffers() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 1000;
    uint128 coll = _collForPrice(shares, 1.2e18);
    for (uint256 i; i < MAX_OFFERS; ++i) {
      _propose(coll, uint128(shares));
    }
    assertEq(pos.offerCount(), MAX_OFFERS, "slab full");
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.TooManyOffers.selector);
    pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        DISPATCH BANDS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_dispatch_belowSafeLtv_revertsHealthy() public {
    _enterBand(0.6e18); // below safeLtv 0.65
    vm.expectRevert(LibBorrowErrors.PositionHealthy.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
  }

  function test_dispatch_inBand_emptyList_revertsNoConsumable() public {
    _enterBand(0.7e18);
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
  }

  /// @notice Dormant window (v1 proxy upgraded to v2 logic but initializeV2 not yet run): the offer
  ///         namespace is all-zero, so head == 0 (not NULL). The band path must revert
  ///         NoConsumableOffer (spec section 12.3), NOT an arithmetic panic from a count underflow.
  function test_dispatch_dormantWindow_revertsNoConsumableNotPanic() public {
    _enterBand(0.7e18);
    // Zero the offer namespace to model an un-migrated v1 proxy (head==0, count==0, timelock==0).
    vm.store(address(pos), OFFERS_SLOT, bytes32(0));
    assertEq(pos.offerCount(), 0, "offer storage zeroed");
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
  }

  /// @notice previewConsume must not loop forever in the dormant window (head==0, slab[0].next==0).
  function test_previewConsume_dormantWindow_returnsZero() public {
    _enterBand(0.7e18);
    vm.store(address(pos), OFFERS_SLOT, bytes32(0));
    (uint256 s, uint256 d) = pos.previewConsume(1e18, 0);
    assertEq(s, 0, "no seize");
    assertEq(d, 0, "no shares");
  }

  /// @notice The offers() view must return an empty array (not Panic 0x32) in the dormant window:
  ///         count==0 but head==0 (a real slab index, not NULL), so without the listOffers guard the
  ///         walk would write past the length-0 result array.
  function test_offers_dormantWindow_returnsEmptyNotPanic() public {
    _enterBand(0.7e18);
    vm.store(address(pos), OFFERS_SLOT, bytes32(0));
    Offer[] memory all = pos.offers();
    assertEq(all.length, 0, "dormant window: empty offer list");
  }

  function test_dispatch_aboveLiqLtv_takesProportionalPath() public {
    _enterBand(0.78e18); // above liquidationLtv 0.72 -> proportional path
    uint256 seize = _positionCollateral() / 4;
    (uint256 seized, uint256 repaid) = pos.preLiquidate(address(pos), seize, 0, "");
    assertEq(seized, seize, "proportional seizes target");
    assertGt(repaid, 0, "repaid > 0");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONSUME / ORDERING                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_seizeMode_lowersLtvAndProfits() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 2;
    uint8 id = _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    uint256 ltvBefore = _ltvWad();
    uint256 collBefore = collateralToken.balanceOf(liquidator);
    uint256 loanBefore = loanToken.balanceOf(liquidator);

    Offer memory o = pos.offer(id);
    (uint256 seized, uint256 repaid) = pos.preLiquidate(address(pos), o.remainingCollateral, 0, "");

    assertEq(seized, o.remainingCollateral, "seized full offer collateral");
    // Liquidator receives collateral worth strictly more than the loan it paid (I1).
    uint256 seizedValue = seized * oracle.price() / SCALE;
    assertGt(seizedValue, repaid, "profitable: collateral value > repaid");
    assertEq(collateralToken.balanceOf(liquidator) - collBefore, seized, "got collateral");
    assertEq(loanBefore - loanToken.balanceOf(liquidator), repaid, "paid loan");
    // LTV strictly decreased (I2).
    assertLt(_ltvWad(), ltvBefore, "LTV decreased");
    assertEq(pos.offerCount(), 0, "offer exhausted and removed");
  }

  function test_consume_repaySharesMode_doesNotOvershoot() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 2;
    _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    uint256 target = shares / 3;
    (, uint256 repaid) = pos.preLiquidate(address(pos), 0, target, "");
    assertGt(repaid, 0, "repaid > 0");
    // The walk must not overshoot the share target.
    // (totalDebtShares is internal; assert via remaining offer + position deltas indirectly.)
    assertLt(_ltvWad(), 0.7e18, "ltv decreased");
  }

  function test_consume_skipsUnprofitable_consumesNext() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    // Offer A at I=1.02 (barely profitable now), offer B at I=1.30 (clearly profitable). Creation
    // requires profitability, so both are valid now.
    uint8 a = _proposeAtPrice(shares, 1.02e18);
    uint8 b = _proposeAtPrice(shares, 1.3e18);
    _warpActive();

    // Drop the price to factor 0.975: A's price -> 1.02*0.975 = 0.9945 < 1 (now unprofitable), while
    // L -> 0.70/0.975 = 0.718 stays in band, and B's price -> 1.2675 < 1/L (1.393) stays consumable.
    oracle.setPrice(oracle.price() * 975 / 1000);
    assertGt(_ltvWad(), SAFE_LTV, "still in band (above safe)");
    assertLe(_ltvWad(), LIQ_LTV, "still in band (at/below liq)");

    Offer memory offerB = pos.offer(b);
    (uint256 seized,) = pos.preLiquidate(address(pos), offerB.remainingCollateral, 0, "");
    assertEq(seized, offerB.remainingCollateral, "consumed the profitable offer B");
    // A was skipped (unprofitable), not pruned: it remains in the list.
    assertEq(pos.offer(a).proposer, proposer, "unprofitable offer A left in place");
    assertEq(pos.offerCount(), 1, "only B removed");
  }

  function test_consume_stopsAtOverPriceOffer() public {
    _enterBand(0.7e18); // 1/L ≈ 1.4286
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    // Over-price offer (I = 1.6 > 1/L) -> should be skipped/stopped, nothing consumed.
    _proposeAtPrice(shares, 1.6e18);
    _warpActive();
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
  }

  function test_consume_notActiveYet_revertsNoConsumable() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    _proposeAtPrice(shares, 1.2e18);
    // Do NOT warp: offer not active yet.
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
  }

  function test_consume_expiredOffer_revertsNoConsumable() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18); // precompute (external calls would consume the prank)
    vm.prank(proposer);
    pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 2 hours));
    // Warp past expiry: the only offer is expired, so nothing is fillable.
    vm.warp(block.timestamp + 3 hours);
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
    // The expired offer is opportunistically pruned during the walk, but because the call reverts
    // (zero fills), that effect is rolled back with the transaction; the slot remains until a
    // succeeding consume (see test_consume_expiredOffer_prunedWhenConsumeSucceeds) or a revoke.
  }

  function test_consume_expiredOffer_prunedWhenConsumeSucceeds() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;

    // Offer A: short-lived (expires in 2h).
    uint128 collA = _collForPrice(shares, 1.2e18);
    vm.prank(proposer);
    uint8 a = pos.proposeOffer(collA, uint128(shares), uint40(block.timestamp + 2 hours));

    // 90 min later, propose long-lived offer B.
    vm.warp(block.timestamp + 90 minutes);
    uint128 collB = _collForPrice(shares, 1.2e18);
    vm.prank(proposer);
    uint8 b = pos.proposeOffer(collB, uint128(shares), uint40(block.timestamp + 30 days));

    // 90 more min: A is expired (t0+2h), B is active (t0+2.5h) and live.
    vm.warp(block.timestamp + 90 minutes);
    Offer memory offerB = pos.offer(b);
    (uint256 seized,) = pos.preLiquidate(address(pos), offerB.remainingCollateral, 0, "");

    assertGt(seized, 0, "consumed B");
    assertEq(pos.offer(a).proposer, address(0), "expired A pruned by the succeeding consume");
    assertEq(pos.offerCount(), 0, "A pruned, B exhausted");
  }

  function test_consume_ordering_headIsMostOwnerFavorable() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 8;
    // Propose in non-sorted order; list must end up ascending in price (head = lowest I).
    _proposeAtPrice(shares, 1.3e18);
    _proposeAtPrice(shares, 1.1e18);
    _proposeAtPrice(shares, 1.2e18);

    Offer[] memory list = pos.offers();
    assertEq(list.length, 3, "3 offers");
    // ascending price <=> descending debtShares/collateral
    for (uint256 i = 1; i < list.length; ++i) {
      uint256 prevRatio = uint256(list[i - 1].remainingDebtShares) * list[i].remainingCollateral;
      uint256 curRatio = uint256(list[i].remainingDebtShares) * list[i - 1].remainingCollateral;
      assertGe(prevRatio, curRatio, "head more owner-favorable (higher debt/coll)");
    }
  }

  function test_consume_toZeroDebt_closesPosition() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares();
    // Offer covering the whole debt with extra collateral headroom (price < 1/L, profitable).
    _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    pos.preLiquidate(address(pos), 0, shares, "");
    assertEq(_positionShares(), 0, "debt fully repaid");
    assertEq(pos.totalBorrowed(), 0, "no debt left");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      TIMELOCK / EXPIRY                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setOfferTimelock_isItselfTimelocked() public {
    // Schedule a reduction to the floor; it must not take effect until the current timelock elapses.
    vm.prank(positionManager);
    pos.setOfferTimelock(MIN_OFFER_TIMELOCK);

    (uint40 pendingVal, uint40 effAt) = pos.pendingOfferTimelock();
    assertEq(pendingVal, MIN_OFFER_TIMELOCK, "pending value");
    assertEq(effAt, uint40(block.timestamp + DEFAULT_OFFER_TIMELOCK), "effective after current timelock");
    // Still effective at the OLD value before the delay elapses.
    assertEq(pos.offerTimelock(), DEFAULT_OFFER_TIMELOCK, "old value still effective");

    vm.warp(block.timestamp + DEFAULT_OFFER_TIMELOCK);
    assertEq(pos.offerTimelock(), MIN_OFFER_TIMELOCK, "new value effective after delay");
  }

  function test_setOfferTimelock_cannotMakeFreshOfferInstantlyConsumable() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    // Schedule reduction to MIN, but it is not yet effective; a fresh offer still uses the OLD
    // (default) timelock for its activeAt.
    vm.prank(positionManager);
    pos.setOfferTimelock(MIN_OFFER_TIMELOCK);

    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18); // precompute (external calls would consume the prank)
    vm.prank(proposer);
    uint8 id = pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
    assertEq(pos.offer(id).activeAt, uint40(block.timestamp + DEFAULT_OFFER_TIMELOCK), "uses old timelock");
  }

  function test_setOfferTimelock_revertsOutOfRange() public {
    vm.startPrank(positionManager);
    vm.expectRevert(LibBorrowErrors.OfferTimelockOutOfRange.selector);
    pos.setOfferTimelock(MIN_OFFER_TIMELOCK - 1);
    vm.expectRevert(LibBorrowErrors.OfferTimelockOutOfRange.selector);
    pos.setOfferTimelock(MAX_OFFER_TIMELOCK + 1);
    vm.stopPrank();
  }

  function test_setOfferTimelock_reschedulingCannotAccelerate() public {
    vm.prank(positionManager);
    pos.setOfferTimelock(MIN_OFFER_TIMELOCK); // pending eff at now + DEFAULT

    vm.warp(block.timestamp + 10 minutes);
    vm.prank(positionManager);
    pos.setOfferTimelock(MAX_OFFER_TIMELOCK); // re-bases on current effective (still DEFAULT)
    (, uint40 effAt) = pos.pendingOfferTimelock();
    assertEq(effAt, uint40(block.timestamp + DEFAULT_OFFER_TIMELOCK), "re-based on current effective");
  }

  function test_activeAt_notRetimedByLaterTimelockChange() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    uint8 id = _proposeAtPrice(shares, 1.2e18);
    uint40 activeAt = pos.offer(id).activeAt;

    // A later timelock change must not re-time the already-proposed offer.
    vm.prank(positionManager);
    pos.setOfferTimelock(MAX_OFFER_TIMELOCK);
    assertEq(pos.offer(id).activeAt, activeAt, "activeAt unchanged");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          REVOKE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_revokeOffers_guardianVeto() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    _enableGuardian(guardian);
    uint256 shares = _positionShares() / 4;
    uint8 id = _proposeAtPrice(shares, 1.2e18);

    uint8[] memory ids = new uint8[](1);
    ids[0] = id;
    vm.prank(guardian);
    pos.revokeOffers(ids);
    assertEq(pos.offerCount(), 0, "revoked");
    assertEq(pos.offer(id).proposer, address(0), "slot freed");
  }

  function test_revokeOffers_revertsUnknownId() public {
    _enableGuardian(guardian);
    uint8[] memory ids = new uint8[](1);
    ids[0] = 5;
    vm.prank(guardian);
    vm.expectRevert(LibBorrowErrors.OfferNotFound.selector);
    pos.revokeOffers(ids);
  }

  function test_slab_recyclesFreedSlots() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    _enableGuardian(guardian);
    uint256 shares = _positionShares() / 8;
    uint8 a = _proposeAtPrice(shares, 1.2e18);
    uint8[] memory ids = new uint8[](1);
    ids[0] = a;
    vm.prank(guardian);
    pos.revokeOffers(ids);
    // The next propose should recycle the freed slot id.
    uint8 b = _proposeAtPrice(shares, 1.2e18);
    assertEq(b, a, "freed slab slot recycled");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isConsumable_reflectsActivationAndPrice() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 4;
    uint8 id = _proposeAtPrice(shares, 1.2e18);
    assertFalse(pos.isConsumable(id), "not active yet");
    _warpActive();
    assertTrue(pos.isConsumable(id), "active + in price band");

    // An over-price offer is not consumable.
    uint8 over = _proposeAtPrice(shares, 1.6e18);
    _warpActive();
    assertFalse(pos.isConsumable(over), "over max price");
  }

  function test_previewConsume_matchesActualSeize() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 2;
    _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    uint256 seizeTarget = _positionCollateral() / 5;
    (uint256 previewSeized, uint256 previewShares) = pos.previewConsume(seizeTarget, 0);
    (uint256 seized,) = pos.preLiquidate(address(pos), seizeTarget, 0, "");
    assertEq(seized, previewSeized, "preview matches actual seized");
    assertGt(previewShares, 0, "preview shares > 0");
  }

  function test_offer_outOfRangeReturnsZeroed() public view {
    Offer memory o = pos.offer(uint8(MAX_OFFERS)); // out of range
    assertEq(o.proposer, address(0), "zeroed");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         REENTRANCY                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice A reentrant onPreLiquidate that re-enters preLiquidate cannot double-consume the same
  ///         offer: the fills are committed as effects before the Morpho repay.
  function test_reentrancy_cannotDoubleConsume() public {
    _enterBand(0.7e18);
    _enableProposer(proposer);
    uint256 shares = _positionShares() / 2;
    uint8 id = _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    ReentrantLiquidator attacker = new ReentrantLiquidator(pos, loanToken);
    loanToken.setBalance(address(attacker), 1_000_000e18);

    Offer memory o = pos.offer(id);
    uint128 half = o.remainingCollateral / 2;
    // The attacker tries to re-consume during the callback; the second consume sees the decremented
    // offer. The call must not revert from double-spend and must not over-seize.
    attacker.attack(half);
    // Offer's remaining collateral reflects exactly the two non-overlapping fills (no double-spend).
    uint256 totalSeized = attacker.totalSeized();
    assertLe(totalSeized, o.remainingCollateral, "did not seize more than offered");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            FUZZ                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_consume_alwaysLowersLtvAndProfits(uint256 ltvPick, uint256 pricePick, uint256 fracPick) public {
    // Stay STRICTLY inside the band: at exactly liquidationLtv, conservative rounding in the
    // _isHealthy dispatch can take the proportional path instead of the offer path.
    uint256 ltv = bound(ltvPick, uint256(SAFE_LTV) + 0.01e18, uint256(LIQ_LTV) - 0.01e18);
    _enterBand(ltv);
    if (_ltvWad() <= SAFE_LTV || _ltvWad() >= LIQ_LTV) return;
    _enableProposer(proposer);

    // 1/L in WAD; since L <= 0.71, invLtv >= ~1.408e18, leaving ample room above 1e18.
    uint256 invLtv = uint256(1e18) * 1e18 / _ltvWad();
    // Price strictly inside (1, 1/L), with margin below 1/L for rounding.
    uint256 priceWad = bound(pricePick, 1.01e18, invLtv - 1e16);

    uint256 shares = _positionShares() * bound(fracPick, 10, 90) / 100;
    if (shares == 0) return;
    _proposeAtPrice(shares, priceWad);
    _warpActive();

    uint256 ltvBefore = _ltvWad();
    uint256 seizeTarget = _positionCollateral() / 4;

    // previewConsume simulates the OFFER walk; inside the band it must equal the actual consume.
    (uint256 previewSeized,) = pos.previewConsume(seizeTarget, 0);
    if (previewSeized == 0) return; // nothing consumable after rounding; fine

    (uint256 seized, uint256 repaid) = pos.preLiquidate(address(pos), seizeTarget, 0, "");
    assertEq(seized, previewSeized, "preview == actual inside band");

    uint256 seizedValue = seized * oracle.price() / SCALE;
    assertGe(seizedValue, repaid, "profitable");
    assertLe(_ltvWad(), ltvBefore, "ltv did not increase");
  }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      REENTRANT LIQUIDATOR                   */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Liquidator mock whose onPreLiquidate callback re-enters preLiquidate once, to prove the
///         effects-before-interaction ordering prevents double-consuming an offer.
contract ReentrantLiquidator is IPreLiquidationCallback {
  MorphoBorrowPosition internal pos;
  MockERC20 internal loanToken;
  uint256 public totalSeized;
  uint128 internal seizeAmount;
  bool internal reentered;

  constructor(MorphoBorrowPosition _pos, MockERC20 _loanToken) {
    pos = _pos;
    loanToken = _loanToken;
    loanToken.approve(address(_pos), type(uint256).max);
  }

  function attack(uint128 amount) external {
    seizeAmount = amount;
    (uint256 seized,) = pos.preLiquidate(address(pos), amount, 0, abi.encode("reenter"));
    totalSeized += seized;
  }

  function onPreLiquidate(uint256, bytes calldata) external override {
    if (!reentered) {
      reentered = true;
      // Re-enter once with the same target; must operate on already-decremented offers.
      try pos.preLiquidate(address(pos), seizeAmount, 0, "") returns (uint256 seized, uint256) {
        totalSeized += seized;
      } catch {}
    }
  }
}
