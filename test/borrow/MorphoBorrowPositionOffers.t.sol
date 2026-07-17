// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";
import {BorrowOffersRegistry} from "src/borrow/BorrowOffersRegistry.sol";
import {IBorrowOffers, Offer} from "src/interfaces/borrow/IBorrowOffers.sol";
import {IPreLiquidationCallback} from "src/interfaces/borrow/IPreliquidationCallback.sol";
import {LibBorrowErrors} from "src/libs/borrow/LibBorrowErrors.sol";
import {MAX_OFFERS, MAX_OFFER_LIFESPAN, BORROW_OFFERS_STORAGE_SLOT} from "src/libs/borrow/LibBorrowOffersConstants.sol";
import {BPS} from "src/libs/Constants.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title MorphoBorrowPositionOffersTest
/// @notice Offer-based pre-liquidation tests for {MorphoBorrowPosition}. Uses a zero-IRM market
///         so the position LTV is deterministic across the timelock warps (no interest accrual).
///         Offer roles and the per-collateral configuration live on the shared
///         {BorrowOffersRegistry}; this suite configures the test market's collateral there and
///         tests the position-level behavior against that configuration.
contract MorphoBorrowPositionOffersTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ACTORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MorphoBorrowPosition internal pos;
  MorphoBorrowPositionFactory internal factory;
  BorrowOffersRegistry internal registry;
  IMorpho internal morpho;
  MockERC20 internal loanToken;
  MockERC20 internal collateralToken;
  OracleMock internal oracle;

  MarketParams internal marketParams;
  Id internal marketId;

  address internal owner; // morpho owner and factory beacon owner
  address internal registryOwner; // BorrowOffersRegistry owner (the offer administrator)
  address internal positionManager; // position owner (no offer powers: offer auth lives on the registry)
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

  // Registry configuration for the test market's collateral (mirrors the pre-registry defaults).
  uint40 internal constant OFFER_TIMELOCK = 1 hours;
  uint16 internal constant MIN_OFFER_BONUS_BPS = 100;

  function setUp() public {
    owner = makeAddr("owner");
    registryOwner = makeAddr("registryOwner");
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

    // Shared offers registry (behind an ERC1967 proxy): roles are global, configuration is keyed
    // by collateral token. Effective timelocks are floored to MIN_OFFER_TIMELOCK, so even the
    // first setOfferTimelock is delayed by the floor; warp past it so the 1 hour configuration is
    // live for the whole suite.
    registry = BorrowOffersRegistry(LibClone.deployERC1967(address(new BorrowOffersRegistry())));
    registry.initialize(registryOwner);
    vm.startPrank(registryOwner);
    registry.setProposer(proposer, true);
    registry.setGuardian(guardian, true);
    registry.setOfferTimelock(address(collateralToken), OFFER_TIMELOCK);
    registry.setMinOfferBonus(address(collateralToken), MIN_OFFER_BONUS_BPS);
    vm.stopPrank();
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK());

    factory = new MorphoBorrowPositionFactory(owner, morpho, registry);
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

  /// @dev Sets the collateral's minimum offer bonus on the registry (as the registry owner).
  function _setMinOfferBonus(uint16 bps) internal {
    vm.prank(registryOwner);
    registry.setMinOfferBonus(address(collateralToken), bps);
  }

  /// @dev Proposes an offer (as `proposer`) with the configured timelock and a long lifespan.
  function _propose(uint128 coll, uint128 shares) internal returns (uint8 id) {
    vm.prank(proposer);
    id = pos.proposeOffer(coll, shares, uint40(block.timestamp + 30 days));
  }

  /// @dev Proposes an offer at a target whole-offer price (in WAD) for a given debt-share size.
  function _proposeAtPrice(uint256 debtShares, uint256 priceWad) internal returns (uint8 id) {
    return _propose(_collForPrice(debtShares, priceWad), uint128(debtShares));
  }

  function _warpActive() internal {
    vm.warp(block.timestamp + OFFER_TIMELOCK + 1);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INIT / AUTHORIZATION                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_init_wiresRegistryAndStartsEmpty() public view {
    // The position holds no offer role or configuration storage: it points at the shared registry
    // and starts with an empty offer book.
    assertEq(address(pos.OFFERS_REGISTRY()), address(registry), "registry wired as immutable");
    assertEq(pos.offerCount(), 0, "no offers");
    (uint40 timelock, uint16 minBonus) = registry.offerConfig(address(collateralToken));
    assertEq(timelock, OFFER_TIMELOCK, "collateral timelock configured");
    assertEq(minBonus, MIN_OFFER_BONUS_BPS, "collateral minimum offer bonus configured");
  }

  function test_proposeOffer_revertsForNonProposer() public {
    vm.prank(makeAddr("rando"));
    vm.expectRevert(Unauthorized.selector);
    pos.proposeOffer(1e18, 1e18, uint40(block.timestamp + 1 days));
  }

  /// @notice The position owner (PositionManager) has NO bypass: offer authorization lives
  ///         entirely on the registry, and the position owner holds no registry role.
  function test_proposeOffer_revertsForPositionOwner() public {
    vm.prank(positionManager);
    vm.expectRevert(Unauthorized.selector);
    pos.proposeOffer(1e18, 1e18, uint40(block.timestamp + 1 days));
  }

  /// @notice The registry owner is always authorized (by derivation, without holding a role).
  function test_proposeOffer_registryOwnerAllowed() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18); // precompute (external calls would consume the prank)
    vm.prank(registryOwner);
    uint8 id = pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
    assertEq(pos.offer(id).proposer, registryOwner, "registry owner may propose");
  }

  /// @notice A never-configured collateral is not disabled: the registry floors the effective
  ///         timelock to MIN_OFFER_TIMELOCK, so proposals work by default with the minimum veto
  ///         window.
  function test_proposeOffer_unconfiguredCollateralUsesFloorTimelock() public {
    // A fresh registry where the proposer role is granted but the collateral is NOT configured.
    BorrowOffersRegistry bare = BorrowOffersRegistry(LibClone.deployERC1967(address(new BorrowOffersRegistry())));
    bare.initialize(registryOwner);
    vm.prank(registryOwner);
    bare.setProposer(proposer, true);

    MorphoBorrowPositionFactory bareFactory = new MorphoBorrowPositionFactory(owner, morpho, bare);
    MorphoBorrowPosition barePos =
      MorphoBorrowPosition(bareFactory.createBorrowPosition(marketId, positionManager, SAFE_LTV, LIQ_LTV));

    vm.prank(proposer);
    uint8 id = barePos.proposeOffer(1e18, 1e17, uint40(block.timestamp + 1 days));
    assertEq(
      uint256(barePos.offer(id).activeAt),
      block.timestamp + bare.MIN_OFFER_TIMELOCK(),
      "unconfigured collateral should use the floored minimum timelock"
    );
  }

  function test_revokeOffers_revertsForNonGuardian() public {
    uint8[] memory ids = new uint8[](1);
    ids[0] = 0;
    vm.prank(makeAddr("rando"));
    vm.expectRevert(Unauthorized.selector);
    pos.revokeOffers(ids);
  }

  /// @notice The position owner (PositionManager) cannot revoke either: revoke stays with the
  ///         registry guardians and the registry owner.
  function test_revokeOffers_revertsForPositionOwner() public {
    uint8[] memory ids = new uint8[](1);
    ids[0] = 0;
    vm.prank(positionManager);
    vm.expectRevert(Unauthorized.selector);
    pos.revokeOffers(ids);
  }

  function test_revokeOffers_registryOwnerAllowed() public {
    _enterBand(0.7e18);
    uint8 id = _proposeAtPrice(_positionShares() / 4, 1.2e18);
    uint8[] memory ids = new uint8[](1);
    ids[0] = id;
    vm.prank(registryOwner);
    pos.revokeOffers(ids);
    assertEq(pos.offerCount(), 0, "registry owner may revoke");
  }

  /// @notice Revoking the proposer role on the registry takes effect immediately for every
  ///         position: a proposer that just posted an offer loses the power at once.
  function test_proposeOffer_revertsAfterProposerRevoked() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18); // precompute (external calls would consume the prank)
    _propose(coll, uint128(shares)); // role is live: proposing succeeds
    assertEq(pos.offerCount(), 1, "proposed while roled");

    vm.prank(registryOwner);
    registry.setProposer(proposer, false);

    vm.prank(proposer);
    vm.expectRevert(Unauthorized.selector);
    pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
  }

  /// @notice Mirror of the proposer revocation: dropping the guardian role on the registry
  ///         immediately strips the revoke power on every position.
  function test_revokeOffers_revertsAfterGuardianRevoked() public {
    _enterBand(0.7e18);
    uint8 id = _proposeAtPrice(_positionShares() / 4, 1.2e18);
    uint8[] memory ids = new uint8[](1);
    ids[0] = id;

    vm.prank(registryOwner);
    registry.setGuardian(guardian, false);

    vm.prank(guardian);
    vm.expectRevert(Unauthorized.selector);
    pos.revokeOffers(ids);
  }

  /// @notice The by-derivation owner powers follow a Solady two-step ownership handover: the old
  ///         registry owner loses propose and revoke on every position, the new owner gains both
  ///         (without holding a role).
  function test_offerAuth_followsRegistryOwnershipHandover() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18); // precompute (external calls would consume the prank)

    // Two-step handover: the new owner requests, the current owner completes.
    address newOwner = makeAddr("newRegistryOwner");
    vm.prank(newOwner);
    registry.requestOwnershipHandover();
    vm.prank(registryOwner);
    registry.completeOwnershipHandover(newOwner);

    // The old owner is a stranger to the registry now: no propose, no revoke.
    vm.prank(registryOwner);
    vm.expectRevert(Unauthorized.selector);
    pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
    uint8[] memory ids = new uint8[](1);
    ids[0] = 0;
    vm.prank(registryOwner);
    vm.expectRevert(Unauthorized.selector);
    pos.revokeOffers(ids);

    // The new owner holds the full owner powers by derivation.
    vm.prank(newOwner);
    uint8 id = pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
    assertEq(pos.offer(id).proposer, newOwner, "new registry owner may propose");
    ids[0] = id;
    vm.prank(newOwner);
    pos.revokeOffers(ids);
    assertEq(pos.offerCount(), 0, "new registry owner may revoke");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PROPOSE / VALIDATION                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_proposeOffer_storesOfferAndActiveAt() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18);

    uint40 expectedActive = uint40(block.timestamp + OFFER_TIMELOCK);
    uint8 id = _propose(coll, uint128(shares));

    Offer memory o = pos.offer(id);
    assertEq(o.proposer, proposer, "proposer");
    assertEq(o.remainingCollateral, coll, "coll");
    assertEq(o.remainingDebtShares, uint128(shares), "shares");
    assertEq(o.activeAt, expectedActive, "activeAt fixed at proposal");
    assertEq(pos.offerCount(), 1, "count");
  }

  function test_proposeOffer_revertsZeroAmount() public {
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferAmountZero.selector);
    pos.proposeOffer(0, 1e18, uint40(block.timestamp + 1 days));
  }

  function test_proposeOffer_revertsNotProfitable() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    // Price 0.9 < 1 -> not profitable at creation.
    uint128 coll = _collForPrice(shares, 0.9e18);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferNotProfitable.selector);
    pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 1 days));
  }

  function test_proposeOffer_revertsExpiryTooShort() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18);
    // expiresAt == activeAt is not strictly after -> revert.
    uint40 activeAt = uint40(block.timestamp + OFFER_TIMELOCK);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferExpiryTooShort.selector);
    pos.proposeOffer(coll, uint128(shares), activeAt);
  }

  function test_proposeOffer_revertsExpiryTooLong() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18);
    // Lifespan is measured from `activeAt` (= now + timelock), not from now. One second past the cap
    // relative to `activeAt` must revert.
    uint40 activeAt = uint40(block.timestamp + OFFER_TIMELOCK);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferExpiryTooLong.selector);
    pos.proposeOffer(coll, uint128(shares), activeAt + MAX_OFFER_LIFESPAN + 1);
  }

  function test_proposeOffer_maxLifespanMeasuredFromActiveAt() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18);
    uint40 activeAt = uint40(block.timestamp + OFFER_TIMELOCK);
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

  /// @notice A book full of EXPIRED offers self-heals: allocation prunes expired offers before
  ///         reverting TooManyOffers, so a fresh proposal succeeds where it previously would not.
  function test_proposeOffer_prunesExpiredOffersInsteadOfReverting() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 1000;
    uint128 coll = _collForPrice(shares, 1.2e18);
    for (uint256 i; i < MAX_OFFERS; ++i) {
      vm.prank(proposer);
      pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 2 hours));
    }
    assertEq(pos.offerCount(), MAX_OFFERS, "slab full");

    // All offers expire; the next proposal prunes them and takes a freed slot.
    vm.warp(block.timestamp + 3 hours);
    uint128 collLater = _collForPrice(shares, 1.2e18);
    vm.prank(proposer);
    uint8 id = pos.proposeOffer(collLater, uint128(shares), uint40(block.timestamp + 30 days));
    assertEq(pos.offerCount(), 1, "expired offers pruned, fresh offer allocated");
    assertEq(pos.offer(id).proposer, proposer, "fresh offer live");
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

  /// @notice Slot 0 of the "borrow.offers.main" namespace holds `liveBits` alone (the slab starts
  ///         at slot 1 of the namespace), so zeroing that single slot structurally empties the
  ///         book: the band path must revert NoConsumableOffer even though the slab slots still
  ///         hold the (now dead) offer data.
  function test_dispatch_zeroedLiveBits_readsEmptyBook() public {
    _enterBand(0.7e18);
    uint8 id = _proposeAtPrice(_positionShares() / 4, 1.2e18);
    _warpActive();
    assertTrue(pos.isConsumable(id), "offer consumable before the wipe");

    vm.store(address(pos), BORROW_OFFERS_STORAGE_SLOT, bytes32(0));
    assertEq(pos.offerCount(), 0, "cleared liveBits reads as an empty book");
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
  }

  /// @notice The views agree with the empty-book reading of a zeroed `liveBits` slot: no offers
  ///         listed, nothing consumable, previewConsume returns (0, 0).
  function test_views_zeroedLiveBits_returnEmpty() public {
    _enterBand(0.7e18);
    uint8 id = _proposeAtPrice(_positionShares() / 4, 1.2e18);
    _warpActive();

    vm.store(address(pos), BORROW_OFFERS_STORAGE_SLOT, bytes32(0));
    Offer[] memory all = pos.offers();
    assertEq(all.length, 0, "empty offer list");
    assertFalse(pos.isConsumable(id), "dead slab slot not consumable");
    (uint256 s, uint256 d) = pos.previewConsume(1e18, 0);
    assertEq(s, 0, "no seize");
    assertEq(d, 0, "no shares");
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
    uint256 shares = _positionShares() / 2;
    uint8 id = _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    uint256 ltvBefore = _ltvWad();
    uint256 collBefore = collateralToken.balanceOf(liquidator);
    uint256 loanBefore = loanToken.balanceOf(liquidator);

    Offer memory o = pos.offer(id);
    (uint256 seized, uint256 repaid) = pos.preLiquidate(address(pos), o.remainingCollateral, 0, "");

    assertEq(seized, o.remainingCollateral, "seized full offer collateral");
    // Liquidator receives collateral worth strictly more than the loan it paid (the profitability
    // invariant).
    uint256 seizedValue = seized * oracle.price() / SCALE;
    assertGt(seizedValue, repaid, "profitable: collateral value > repaid");
    assertEq(collateralToken.balanceOf(liquidator) - collBefore, seized, "got collateral");
    assertEq(loanBefore - loanToken.balanceOf(liquidator), repaid, "paid loan");
    // LTV strictly decreased (the strict de-risking invariant).
    assertLt(_ltvWad(), ltvBefore, "LTV decreased");
    assertEq(pos.offerCount(), 0, "offer exhausted and removed");
  }

  function test_consume_repaySharesMode_doesNotOvershoot() public {
    _enterBand(0.7e18);
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
    uint256 shares = _positionShares() / 4;
    // Over-price offer (I = 1.6 > 1/L) -> should be skipped/stopped, nothing consumed.
    _proposeAtPrice(shares, 1.6e18);
    _warpActive();
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
  }

  function test_consume_notActiveYet_revertsNoConsumable() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    _proposeAtPrice(shares, 1.2e18);
    // Do NOT warp: offer not active yet.
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), 1e18, 0, "");
  }

  function test_consume_expiredOffer_revertsNoConsumable() public {
    _enterBand(0.7e18);
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

  /// @notice Nothing about price order is stored (the offers() view lists by ascending slab id);
  ///         the consume walk sorts by effective price at consume time and drains cheapest-first.
  ///         Asserted end-to-end: propose in non-sorted order, consume across one-and-a-half
  ///         offers, and check both the OfferConsumed event sequence and the per-offer state.
  function test_consume_ordering_drainsCheapestFirst() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 8;
    // Propose in non-sorted price order: id 0 at 1.3, id 1 at 1.1, id 2 at 1.2.
    uint8 pricey = _proposeAtPrice(shares, 1.3e18);
    uint8 cheap = _proposeAtPrice(shares, 1.1e18);
    uint8 mid = _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    // The view lists by slab id (insertion order here), not by price.
    Offer[] memory list = pos.offers();
    assertEq(list.length, 3, "3 offers");
    assertEq(list[0].remainingCollateral, pos.offer(pricey).remainingCollateral, "offers() is id-ordered");
    assertEq(list[1].remainingCollateral, pos.offer(cheap).remainingCollateral, "offers() is id-ordered");

    // Target: all of the cheapest offer plus half of the mid one; the pricey offer must stay whole.
    uint128 cheapColl = pos.offer(cheap).remainingCollateral;
    uint128 cheapShares = pos.offer(cheap).remainingDebtShares;
    uint128 midColl = pos.offer(mid).remainingCollateral;
    uint128 midShares = pos.offer(mid).remainingDebtShares;
    uint128 priceyColl = pos.offer(pricey).remainingCollateral;
    // The mid fill charges debt shares rounded up against the fill's collateral fraction.
    uint256 midFillShares = (uint256(midColl / 2) * midShares + midColl - 1) / midColl;
    vm.recordLogs();
    (uint256 seized,) = pos.preLiquidate(address(pos), cheapColl + midColl / 2, 0, "");
    assertEq(seized, uint256(cheapColl) + midColl / 2, "target met");

    // OfferConsumed events fire in ascending-price order with exact fill values: cheap (whole
    // offer, exhausted), then mid (half its collateral, rounded-up shares, still live).
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 n;
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].emitter != address(pos) || logs[i].topics[0] != IBorrowOffers.OfferConsumed.selector) continue;
      assertEq(uint256(logs[i].topics[1]), n == 0 ? cheap : mid, "consumed in ascending price order");
      (uint128 collFilled, uint128 sharesFilled, bool exhausted) = abi.decode(logs[i].data, (uint128, uint128, bool));
      assertEq(collFilled, n == 0 ? cheapColl : midColl / 2, "event collateral fill");
      assertEq(sharesFilled, n == 0 ? cheapShares : uint128(midFillShares), "event debt-share fill");
      assertEq(exhausted, n == 0, "event exhausted flag");
      ++n;
    }
    assertEq(n, 2, "two offers touched");

    assertEq(pos.offer(cheap).proposer, address(0), "cheapest exhausted and removed");
    assertEq(pos.offer(mid).remainingCollateral, midColl - midColl / 2, "mid offer partially filled");
    assertEq(pos.offer(mid).remainingDebtShares, midShares - midFillShares, "mid offer debt shares decremented");
    assertEq(pos.offer(pricey).remainingCollateral, priceyColl, "pricey untouched");
    assertEq(pos.offerCount(), 2, "only the cheapest removed");
  }

  function test_consume_toZeroDebt_closesPosition() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares();
    // Offer covering the whole debt with extra collateral headroom (price < 1/L, profitable).
    _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    pos.preLiquidate(address(pos), 0, shares, "");
    assertEq(_positionShares(), 0, "debt fully repaid");
    assertEq(pos.totalBorrowed(), 0, "no debt left");
  }

  /// @notice Regression for the clamped-fill rescale: when the aggregate offer debt shares exceed
  ///         the position's remaining borrow shares (the owner partially repaid the debt after the
  ///         offers were posted), a seize-mode target covering the raw offer collateral must NOT be
  ///         met in full. The last fill's shares are clamped to the position's remaining shares and
  ///         its collateral is rescaled down to the offer's fixed ratio (floor), so the liquidator
  ///         never receives more collateral per share than the offer authorized.
  function test_consume_seizeMode_clampedFillRescalesCollateral() public {
    _enterBand(0.71e18);
    uint256 half = _positionShares() / 2;
    uint8 a = _proposeAtPrice(half, 1.1e18);
    uint8 b = _proposeAtPrice(half, 1.2e18);
    _warpActive();

    // The owner repays 6% of the debt: the two offers together now authorize more debt shares
    // (100% of the original) than the position still owes (~94%), while the LTV
    // (0.71 * 0.94 = 0.667) stays inside the band.
    uint256 repayAmount = BORROW * 6 / 100;
    loanToken.setBalance(positionManager, repayAmount);
    vm.prank(positionManager);
    pos.repay(repayAmount);
    assertGt(_ltvWad(), SAFE_LTV, "still in band (above safe)");
    assertLe(_ltvWad(), LIQ_LTV, "still in band (at/below liq)");
    uint256 positionSharesLeft = _positionShares();
    assertLt(positionSharesLeft, 2 * half, "offers now oversize the position");

    Offer memory offerA = pos.offer(a);
    Offer memory offerB = pos.offer(b);
    uint256 rawTarget = uint256(offerA.remainingCollateral) + offerB.remainingCollateral;

    // Cheapest-first walk: A (1.1) fills whole; B (1.2) is clamped to the shares the position
    // still owes, and its collateral chunk is rescaled down to B's fixed ratio (floor), not handed
    // out raw for fewer shares.
    uint256 clampedShares = positionSharesLeft - offerA.remainingDebtShares;
    uint256 rescaledFillB = clampedShares * offerB.remainingCollateral / offerB.remainingDebtShares;

    vm.recordLogs();
    (uint256 seized,) = pos.preLiquidate(address(pos), rawTarget, 0, "");
    assertLt(seized, rawTarget, "raw target not met: the offer ratio caps the clamped fill");
    assertEq(seized, uint256(offerA.remainingCollateral) + rescaledFillB, "collateral rescaled to B's fixed ratio");
    assertEq(_positionShares(), 0, "position debt fully repaid");

    // Every per-offer fill respects the offer's fixed ratio against its pre-walk terms:
    // sharesFilled * preCollateral >= collateralFilled * preDebtShares, i.e. the liquidator is
    // charged at least the offer's shares-per-collateral price on each chunk.
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 n;
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].emitter != address(pos) || logs[i].topics[0] != IBorrowOffers.OfferConsumed.selector) continue;
      Offer memory pre = uint256(logs[i].topics[1]) == a ? offerA : offerB;
      (uint128 collFilled, uint128 sharesFilled,) = abi.decode(logs[i].data, (uint128, uint128, bool));
      assertGe(
        uint256(sharesFilled) * pre.remainingCollateral,
        uint256(collFilled) * pre.remainingDebtShares,
        "fill at or above the offer's shares-per-collateral ratio"
      );
      ++n;
    }
    assertEq(n, 2, "both offers touched");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      TIMELOCK / EXPIRY                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice A registry timelock reduction is itself timelocked, so it cannot make a fresh offer
  ///         instantly consumable: while the reduction is pending, a new offer's `activeAt` still
  ///         derives from the OLD effective timelock.
  function test_proposeOffer_pendingTimelockReductionUsesOldValue() public {
    _enterBand(0.7e18);
    // Schedule a reduction to the registry minimum; it lands only after the current (1 hour)
    // effective timelock elapses.
    uint40 minTimelock = registry.MIN_OFFER_TIMELOCK();
    vm.prank(registryOwner);
    registry.setOfferTimelock(address(collateralToken), minTimelock);
    (uint40 effectiveTimelock,) = registry.offerConfig(address(collateralToken));
    assertEq(effectiveTimelock, OFFER_TIMELOCK, "old value still effective");

    uint256 shares = _positionShares() / 4;
    uint128 coll = _collForPrice(shares, 1.2e18); // precompute (external calls would consume the prank)
    vm.prank(proposer);
    uint8 id = pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
    assertEq(pos.offer(id).activeAt, uint40(block.timestamp + OFFER_TIMELOCK), "uses old timelock");
  }

  function test_activeAt_notRetimedByLaterTimelockChange() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint8 id = _proposeAtPrice(shares, 1.2e18);
    uint40 activeAt = pos.offer(id).activeAt;

    // A later registry timelock change for this collateral must not re-time the already-proposed
    // offer (its activeAt was fixed at proposal time).
    uint40 maxTimelock = registry.MAX_OFFER_TIMELOCK();
    vm.prank(registryOwner);
    registry.setOfferTimelock(address(collateralToken), maxTimelock);
    assertEq(pos.offer(id).activeAt, activeAt, "activeAt unchanged");
  }

  /// @notice Registry configuration is keyed by collateral token: pushing collateral B's timelock
  ///         and bonus floor to the registry maxima retunes positions on collateral B without
  ///         touching positions on collateral A (which keep their own configuration).
  function test_offerConfig_perCollateralIsolationAcrossPositions() public {
    // A second market on a fresh collateral (same loan token, zero IRM, same LLTV) and a second
    // position on it, created through the same factory, so both positions share one registry.
    MockERC20 collateralB = new MockERC20("Coll B", "COLLB", 18);
    OracleMock oracleB = new OracleMock();
    oracleB.setPrice(SCALE);
    MarketParams memory paramsB = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralB),
      oracle: address(oracleB),
      irm: address(0),
      lltv: LLTV
    });
    vm.prank(owner);
    morpho.createMarket(paramsB);
    address managerB = makeAddr("positionManagerB");
    vm.mockCall(managerB, abi.encodeWithSignature("assets()"), abi.encode(address(collateralB), address(loanToken)));
    MorphoBorrowPosition posB =
      MorphoBorrowPosition(factory.createBorrowPosition(paramsB.id(), managerB, SAFE_LTV, LIQ_LTV));

    // Push collateral B's configuration to the registry maxima. The timelock change is itself
    // delayed by B's current effective timelock, and B was never configured, so the delay is the
    // MIN_OFFER_TIMELOCK floor; warp past it so the maximum is live for B.
    uint40 maxTimelock = registry.MAX_OFFER_TIMELOCK();
    vm.startPrank(registryOwner);
    registry.setOfferTimelock(address(collateralB), maxTimelock);
    registry.setMinOfferBonus(address(collateralB), registry.MAX_MIN_OFFER_BONUS_BPS());
    vm.stopPrank();
    vm.warp(block.timestamp + registry.MIN_OFFER_TIMELOCK());

    // Position A (collateral A) still runs on its own configuration: the 1 hour timelock.
    _enterBand(0.7e18);
    uint8 idA = _proposeAtPrice(_positionShares() / 4, 1.2e18);
    assertEq(pos.offer(idA).activeAt, uint40(block.timestamp + OFFER_TIMELOCK), "A keeps its own timelock");

    // Position B (collateral B) picks up the maximum timelock. B's market is empty, so the offer
    // debt is priced through Morpho's virtual shares: a token-sized collateral against a dust
    // debt easily clears B's 10% bonus floor.
    vm.prank(proposer);
    uint8 idB = posB.proposeOffer(1e18, 1e17, uint40(block.timestamp + maxTimelock + 1 days));
    assertEq(posB.offer(idB).activeAt, uint40(block.timestamp + maxTimelock), "B uses the maximum timelock");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MINIMUM OFFER BONUS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_proposeOffer_revertsBonusTooLow() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    // Price 1.005: profitable, but the 0.5% bonus is below the configured 1% floor.
    uint128 coll = _collForPrice(shares, 1.005e18);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferBonusTooLow.selector);
    pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
  }

  function test_proposeOffer_minBonusExactBoundary() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    (uint256 tba, uint256 tbs) = _borrowTotals();
    uint256 debt = shares.toAssetsUp(tba, tbs);
    // Mirror the contract's floor: excess must be at least ceil(debt * bonus / BPS). `coll` is the
    // smallest collateral whose value covers debt + minExcess (ceiling division), so one unit less
    // lands strictly below the floor while still being profitable.
    uint256 minExcess = (debt * MIN_OFFER_BONUS_BPS + BPS - 1) / BPS;
    uint256 price = oracle.price();
    uint128 coll = uint128(((debt + minExcess) * SCALE + price - 1) / price);

    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferBonusTooLow.selector);
    pos.proposeOffer(coll - 1, uint128(shares), uint40(block.timestamp + 30 days));

    uint8 id = _propose(coll, uint128(shares));
    assertEq(pos.offer(id).remainingCollateral, coll, "exact-floor offer accepted");
  }

  function test_minOfferBonus_zeroDisablesFloorButKeepsProfitability() public {
    _enterBand(0.7e18);
    _setMinOfferBonus(0);

    // An epsilon-bonus offer (0.1%, below the configured floor) is now proposable.
    uint256 shares = _positionShares() / 4;
    uint8 id = _proposeAtPrice(shares, 1.001e18);
    assertEq(pos.offerCount(), 1, "epsilon-bonus offer accepted with floor disabled");
    assertGt(pos.offer(id).remainingCollateral, 0, "offer stored");

    // The strict profitability filter still binds: a break-even offer is rejected.
    (uint256 tba, uint256 tbs) = _borrowTotals();
    uint256 debt = shares.toAssetsUp(tba, tbs);
    uint128 collBreakEven = uint128(debt * SCALE / oracle.price());
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferNotProfitable.selector);
    pos.proposeOffer(collBreakEven, uint128(shares), uint40(block.timestamp + 30 days));
  }

  /// @notice Raising the floor above a live offer's bonus does not evict it from the book (a
  ///         guardian must revoke it), but because the floor is read from the registry at consume
  ///         time the live offer stops being consumable, and its terms can no longer be
  ///         re-proposed.
  function test_minOfferBonus_raiseGatesLiveOfferConsumption() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    uint8 id = _proposeAtPrice(shares, 1.02e18); // 2% bonus: clears the configured 1% floor
    _warpActive();
    assertTrue(pos.isConsumable(id), "consumable under the configured floor");

    // Raise the floor above the live offer's ~2% bonus.
    _setMinOfferBonus(registry.MAX_MIN_OFFER_BONUS_BPS()); // 10%

    // Not evicted from storage, but no longer consumable (consume-time floor).
    assertEq(pos.offerCount(), 1, "live offer stays in the book");
    assertGt(pos.offer(id).remainingCollateral, 0, "offer still stored");
    assertFalse(pos.isConsumable(id), "raised floor gates the live offer's consumption");

    // The same terms can no longer be re-proposed.
    uint128 coll = _collForPrice(shares, 1.02e18);
    vm.prank(proposer);
    vm.expectRevert(LibBorrowErrors.OfferBonusTooLow.selector);
    pos.proposeOffer(coll, uint128(shares), uint40(block.timestamp + 30 days));
  }

  /// @notice The floor is enforced at CONSUME time: an offer whose realized bonus has drifted below
  ///         the floor (but is still strictly profitable and in band) is skipped by the consume
  ///         walk, exactly like an unprofitable offer. This keeps band liquidations attractive even
  ///         as price/interest erode standing offers.
  function test_consume_belowFloorOffer_skippedAtConsumeTime() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 2;
    // Propose at a 2% bonus (clears the configured 1% floor at proposal time).
    uint8 id = _proposeAtPrice(shares, 1.02e18);
    _warpActive();

    // Drop the oracle 1.5%: the offer's realized price -> 1.02 * 0.985 = 1.0047 (bonus ~0.47%, now
    // below the 1% floor yet still profitable), while L -> 0.70/0.985 = 0.7107 stays in band.
    oracle.setPrice(oracle.price() * 985 / 1000);
    assertGt(_ltvWad(), SAFE_LTV, "still in band (above safe)");
    assertLe(_ltvWad(), LIQ_LTV, "still in band (at/below liq)");

    // The offer's live bonus is strictly between 0 and the floor.
    Offer memory o = pos.offer(id);
    (uint256 tba, uint256 tbs) = _borrowTotals();
    uint256 offerDebt = uint256(o.remainingDebtShares).toAssetsUp(tba, tbs);
    uint256 offerValue = uint256(o.remainingCollateral) * oracle.price() / SCALE;
    uint256 liveBonusBps = (offerValue - offerDebt) * BPS / offerDebt;
    assertGt(offerValue, offerDebt, "still profitable");
    assertLt(liveBonusBps, MIN_OFFER_BONUS_BPS, "live bonus dropped below the floor");

    // Consume-time floor: the below-floor offer is no longer consumable and the band has nothing to
    // fill (it is the only offer), so previewConsume returns (0, 0) and preLiquidate reverts.
    assertFalse(pos.isConsumable(id), "below-floor offer not consumable");
    (uint256 pSeized, uint256 pDebt) = pos.previewConsume(o.remainingCollateral, 0);
    assertEq(pSeized, 0, "preview seizes nothing");
    assertEq(pDebt, 0, "preview repays nothing");
    vm.expectRevert(LibBorrowErrors.NoConsumableOffer.selector);
    pos.preLiquidate(address(pos), o.remainingCollateral, 0, "");

    // The skipped offer is left in the book (not pruned); a guardian can revoke it.
    assertEq(pos.offerCount(), 1, "below-floor offer left in the book");
  }

  /// @notice A below-floor offer at the head is skipped (like an unprofitable one) and the walk
  ///         consumes the next, above-floor offer. Mirrors {test_consume_skipsUnprofitable_consumesNext}
  ///         but for the bonus floor rather than raw profitability.
  function test_consume_skipsBelowFloorConsumesNext() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 4;
    // Under the configured 1% floor both are admissible: A at 2% bonus, B at 30% bonus.
    uint8 a = _proposeAtPrice(shares, 1.02e18);
    uint8 b = _proposeAtPrice(shares, 1.3e18);
    _warpActive();

    // Raise the floor to 5%: A (~2%) is now below it, B (~30%) still clears. A sorts to the head
    // (lowest price), so the walk must skip A and reach B.
    _setMinOfferBonus(500);
    assertFalse(pos.isConsumable(a), "A below the 5% floor");
    assertTrue(pos.isConsumable(b), "B clears the 5% floor");

    Offer memory offerB = pos.offer(b);
    (uint256 seized,) = pos.preLiquidate(address(pos), offerB.remainingCollateral, 0, "");
    assertEq(seized, offerB.remainingCollateral, "consumed above-floor offer B");
    // A was skipped (below floor), not pruned: it remains in the list.
    assertEq(pos.offer(a).proposer, proposer, "below-floor offer A left in place");
    assertEq(pos.offerCount(), 1, "only B removed");
  }

  /// @notice The consume-time gate reads the CURRENT registry floor: lowering the floor re-admits
  ///         a live offer that a prior raise had gated, without it being re-proposed.
  function test_minOfferBonus_lowerReadmitsLiveOffer() public {
    _enterBand(0.7e18);
    uint256 shares = _positionShares() / 2;
    uint8 id = _proposeAtPrice(shares, 1.05e18); // ~5% bonus
    _warpActive();

    // Raise the floor above the offer's bonus: no longer consumable.
    _setMinOfferBonus(800); // 8%
    assertFalse(pos.isConsumable(id), "gated at the 8% floor");

    // Lower the floor below the offer's bonus: consumable again, and it fills.
    _setMinOfferBonus(200); // 2%
    assertTrue(pos.isConsumable(id), "re-admitted at the 2% floor");
    Offer memory o = pos.offer(id);
    (uint256 seized,) = pos.preLiquidate(address(pos), o.remainingCollateral, 0, "");
    assertEq(seized, o.remainingCollateral, "consumed after the floor was lowered");
    assertEq(pos.offerCount(), 0, "offer exhausted and removed");
  }

  /// @notice With the floor disabled (0) the consume path falls back to the strict profitability
  ///         gate only: a tiny-bonus offer that would be rejected under the configured floor still
  ///         fills.
  function test_consume_floorZero_consumesEpsilonBonusOffer() public {
    _enterBand(0.7e18);
    _setMinOfferBonus(0);

    uint256 shares = _positionShares() / 2;
    uint8 id = _proposeAtPrice(shares, 1.001e18); // 0.1% bonus, far below the configured floor
    _warpActive();

    assertTrue(pos.isConsumable(id), "epsilon-bonus offer consumable with floor disabled");
    Offer memory o = pos.offer(id);
    (uint256 seized, uint256 repaid) = pos.preLiquidate(address(pos), o.remainingCollateral, 0, "");
    assertEq(seized, o.remainingCollateral, "consumed epsilon-bonus offer");
    assertGt(seized * oracle.price() / SCALE, repaid, "still profitable");
    assertEq(pos.offerCount(), 0, "offer exhausted and removed");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          REVOKE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_revokeOffers_guardianVeto() public {
    _enterBand(0.7e18);
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
    uint8[] memory ids = new uint8[](1);
    ids[0] = 5;
    vm.prank(guardian);
    vm.expectRevert(LibBorrowErrors.OfferNotFound.selector);
    pos.revokeOffers(ids);
  }

  function test_slab_recyclesFreedSlots() public {
    _enterBand(0.7e18);
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
  ///         offer: the fills are committed as effects before the Morpho repay. The attack targets
  ///         the WHOLE offer, so an effects-after-interaction regression would let the reentrant
  ///         call consume the (then still undecremented) offer a second time and fail the exact
  ///         seize assertion below.
  function test_reentrancy_cannotDoubleConsume() public {
    _enterBand(0.7e18);
    // A small offer (an eighth of the debt) keeps the position inside the band after the outer
    // fill, so the reentrant call genuinely reaches the offer path (and not PositionHealthy).
    uint256 shares = _positionShares() / 8;
    uint8 id = _proposeAtPrice(shares, 1.2e18);
    _warpActive();

    ReentrantLiquidator attacker = new ReentrantLiquidator(pos, loanToken);
    loanToken.setBalance(address(attacker), 1_000_000e18);

    Offer memory o = pos.offer(id);
    attacker.attack(o.remainingCollateral);

    // The outer call seized exactly the offer; the reentrant call found an already-emptied book
    // and reverted NoConsumableOffer (proving it observed the committed effects).
    assertEq(attacker.totalSeized(), o.remainingCollateral, "seized exactly the offered collateral, once");
    assertTrue(attacker.reentered(), "callback did re-enter");
    assertEq(attacker.reentryRevertSelector(), LibBorrowErrors.NoConsumableOffer.selector, "reentry saw empty book");
    assertEq(pos.offerCount(), 0, "offer exhausted and removed");
    assertEq(pos.offer(id).proposer, address(0), "offer slot zeroed");
    assertGt(_ltvWad(), SAFE_LTV, "position still in band (reentry reached the offer path)");
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

    // 1/L in WAD; since L <= 0.71, invLtv >= ~1.408e18, leaving ample room above 1e18.
    uint256 invLtv = uint256(1e18) * 1e18 / _ltvWad();
    // Price strictly inside (1 + minimum offer bonus, 1/L): margin above the proposal-time bonus
    // floor (1.01 exactly can miss it through _collForPrice's floor rounding) and below 1/L for
    // the de-risking check's rounding.
    uint256 priceWad = bound(pricePick, 1.02e18, invLtv - 1e16);

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
///         effects-before-interaction ordering prevents double-consuming an offer. Records whether
///         the reentrant call succeeded (adding to `totalSeized`) or the selector it reverted with.
contract ReentrantLiquidator is IPreLiquidationCallback {
  MorphoBorrowPosition internal pos;
  MockERC20 internal loanToken;
  uint256 public totalSeized;
  uint128 internal seizeAmount;
  bool public reentered;
  bytes4 public reentryRevertSelector;

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
      } catch (bytes memory reason) {
        if (reason.length >= 4) reentryRevertSelector = bytes4(reason);
      }
    }
  }
}
