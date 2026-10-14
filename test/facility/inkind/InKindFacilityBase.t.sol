// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {InKindFacility} from "src/facility/inkind/InKindFacility.sol";
import {IInKindFacility, EntryOffer, ExitOffer, Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {FacilityCapsWhitelist} from "src/facility/caps/FacilityCapsWhitelist.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";
import {BorrowOffersRegistry} from "src/borrow/BorrowOffersRegistry.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {TransferGuard} from "src/guard/TransferGuard.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibInKindView} from "src/libs/facility/inkind/LibInKindView.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, MarketParams, Id} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title InKindFacilityBaseTest
/// @notice Base fixture for InKindFacility tests: two PMs over one WrappedAsset collateral
///         (18 dec) and a USDC-like debt asset (6 dec, so the virtual share offset is 1e12), one
///         Morpho market with interest, an in-kind facility with MINTER_ROLE on both PMs, and the
///         shared caps contracts (absolute pools, dynamic caps, whitelist).
contract InKindFacilityBaseTest is Test {
  using MarketParamsLib for MarketParams;
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  InKindFacility public facility;
  InKindFacility public implementation;
  FacilityAbsoluteCaps public absoluteCaps;
  FacilityDynamicCaps public dynamicCaps;
  FacilityCapsWhitelist public whitelist;
  PositionManager public positionManager;
  PositionManager public positionManager2;
  MorphoBorrowPositionFactory public borrowPositionFactory;
  MorphoBorrowPosition public borrowPosition;
  MorphoBorrowPosition public borrowPosition2;
  BorrowOffersRegistry public offersRegistry;
  TransferGuard public transferGuard;
  IMorpho public morpho;
  MockERC20 public underlyingToken;
  WrappedAsset public collateralToken;
  MockERC20 public debtToken;
  OracleMock public oracle;
  IrmMock public irm;

  MarketParams public marketParams;
  Id public marketId;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public facilitator;
  address public operator;
  address public compliance;
  address public feeRecipient;
  address public pmFeeRecipient;
  address public seeder;
  address public user;
  address public receiver;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant DEFAULT_LLTV = 0.8e18;
  uint128 constant BP_SAFE_LTV = 0.72e18;
  uint128 constant BP_LIQUIDATION_LTV = 0.78e18;
  uint256 constant POSITION_MANAGER_LTV = 0.7e18;
  // Collateral is 18 decimals, debt 6 decimals: a 1:1 value price is 1e36 * 1e6 / 1e18.
  uint256 constant DEFAULT_ORACLE_PRICE = 1e24;
  uint256 constant SEED_COLLATERAL = 10_000e18;
  uint256 constant SEED_DEBT = 5_000e6;
  uint256 constant MORPHO_LIQUIDITY = 1_000_000e6;

  // Solady role bit constants mirrored locally.
  uint256 constant PM_MINTER_ROLE = 1 << 0;
  uint256 constant PM_CURATOR_ROLE = 1 << 1;
  uint256 constant FACILITY_FACILITATOR_ROLE = 1 << 0;
  uint256 constant FACILITY_COMPLIANCE_ROLE = 1 << 2;
  uint256 constant FACILITY_OPERATOR_ROLE = 1 << 3;
  uint256 constant WA_ISSUER_ROLE = 1 << 0;
  uint256 constant WA_SENDER_ROLE = 1 << 1;
  uint256 constant WA_RECEIVER_ROLE = 1 << 2;
  uint256 constant CAPS_MANAGER_ROLE = 1 << 0;
  uint256 constant CAPS_CONSUMER_ROLE = 1 << 1;

  uint256 constant MAX_FEE = 1_000;
  uint24 constant DEFAULT_FEE_BPS = 25;
  uint40 constant FAR_EXPIRY = type(uint40).max;
  uint16 constant POOL_ID = 1;
  uint16 constant SECURITY_POOL_ID = 2;
  uint16 constant OTHER_POOL_ID = 3;
  int24 constant MULT_1X = 4096; // 1.0 in Q12.12
  int24 constant MULT_NEG_1X = -4096;
  uint256 constant BPS = 10_000;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public virtual {
    owner = makeAddr("owner");
    facilitator = makeAddr("facilitator");
    operator = makeAddr("operator");
    compliance = makeAddr("compliance");
    feeRecipient = makeAddr("feeRecipient");
    pmFeeRecipient = makeAddr("pmFeeRecipient");
    seeder = makeAddr("seeder");
    user = makeAddr("user");
    receiver = makeAddr("receiver");

    // Start away from timestamp 0 so expiry semantics are meaningful.
    vm.warp(1_000_000);

    // Tokens: underlying wrapped 1:1 into the PM collateral, USDC-like debt.
    underlyingToken = new MockERC20("Underlying", "UND", 18);
    debtToken = new MockERC20("USD Coin", "USDC", 6);
    collateralToken = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    collateralToken.initialize(owner, address(0), address(underlyingToken), "wUND", "Wrapped UND");

    // Morpho market on (wrapped, debt) with interest.
    morpho = IMorpho(address(new Morpho(owner)));
    oracle = new OracleMock();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    irm = new IrmMock();
    vm.startPrank(owner);
    morpho.enableIrm(address(irm));
    morpho.enableLltv(DEFAULT_LLTV);
    vm.stopPrank();
    marketParams = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });
    morpho.createMarket(marketParams);
    marketId = marketParams.id();

    // Transfer guard in BLOCKLIST mode: unlisted addresses pass.
    transferGuard = TransferGuard(address(new TransferGuard()).clone());
    transferGuard.initialize(owner);

    // Position managers and their borrow modules.
    offersRegistry = BorrowOffersRegistry(LibClone.deployERC1967(address(new BorrowOffersRegistry())));
    offersRegistry.initialize(owner);
    borrowPositionFactory = new MorphoBorrowPositionFactory(owner, morpho, offersRegistry);
    (positionManager, borrowPosition) = _deployPositionManager("Position Manager Shares", "PMS");
    (positionManager2, borrowPosition2) = _deployPositionManager("Position Manager Shares 2", "PMS2");

    // Caps: whitelist, absolute pools and dynamic caps, facility as consumer.
    whitelist = new FacilityCapsWhitelist(owner);
    implementation = new InKindFacility(address(whitelist));
    facility = InKindFacility(address(implementation).clone());
    facility.initialize(owner, facilitator, feeRecipient);
    absoluteCaps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    dynamicCaps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory consumers = new address[](1);
    consumers[0] = address(facility);
    absoluteCaps.initialize(owner, managers, consumers);
    dynamicCaps.initialize(owner, managers, consumers);
    vm.startPrank(owner);
    whitelist.setAllowed(address(absoluteCaps), true);
    whitelist.setAllowed(address(dynamicCaps), true);
    vm.stopPrank();

    // Roles: the facility (and the seeder) mint on the PMs; every wrapper mover has SENDER_ROLE.
    vm.startPrank(owner);
    positionManager.grantRoles(address(facility), PM_MINTER_ROLE);
    positionManager.grantRoles(seeder, PM_MINTER_ROLE);
    positionManager2.grantRoles(address(facility), PM_MINTER_ROLE);
    positionManager2.grantRoles(seeder, PM_MINTER_ROLE);
    facility.grantRoles(compliance, FACILITY_COMPLIANCE_ROLE);
    facility.grantRoles(operator, FACILITY_OPERATOR_ROLE);
    collateralToken.grantRoles(address(positionManager), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(positionManager2), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(borrowPosition), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(borrowPosition2), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(morpho), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(facility), WA_SENDER_ROLE);
    collateralToken.grantRoles(seeder, WA_SENDER_ROLE);
    vm.stopPrank();

    // Morpho lending liquidity to borrow against.
    _supplyLiquidity(MORPHO_LIQUIDITY);

    vm.label(address(facility), "InKindFacility");
    vm.label(address(positionManager), "PositionManager");
    vm.label(address(positionManager2), "PositionManager2");
    vm.label(address(collateralToken), "wUND");
    vm.label(address(underlyingToken), "UND");
    vm.label(address(debtToken), "USDC");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Deploys a PM over the shared market with one borrow module and full queues.
  function _deployPositionManager(string memory name, string memory symbol)
    internal
    returns (PositionManager pm, MorphoBorrowPosition bp)
  {
    pm = PositionManager(address(new PositionManager()).clone());
    pm.initialize(
      owner,
      PositionManagerMetadata({
        name: name, symbol: symbol, collateralAsset: address(collateralToken), debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(transferGuard),
      0,
      0
    );
    vm.prank(owner);
    bp = MorphoBorrowPosition(
      borrowPositionFactory.createBorrowPosition(marketId, address(pm), BP_SAFE_LTV, BP_LIQUIDATION_LTV)
    );
    vm.startPrank(owner);
    pm.grantRoles(owner, PM_CURATOR_ROLE);
    pm.addBorrowModule(address(bp));
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](1);
    supplyQueue[0] = SupplyQueueEntry({position: address(bp), maxBorrow: type(uint96).max});
    pm.setSupplyQueue(supplyQueue);
    address[] memory withdrawalQueue = new address[](1);
    withdrawalQueue[0] = address(bp);
    pm.setWithdrawalQueue(withdrawalQueue);
    vm.stopPrank();
  }

  /// @dev Supplies debt-asset liquidity into the Morpho market.
  function _supplyLiquidity(uint256 amount) internal {
    debtToken.setBalance(address(this), amount);
    debtToken.approve(address(morpho), amount);
    morpho.supply(marketParams, amount, 0, address(this), "");
  }

  /// @dev Seeds and levers `pm` through the ops path: the seeder wraps underlying and deposits
  ///      (collateral, debt) into the PM directly.
  function _seedPool(PositionManager pm, uint256 collateral, uint256 debt) internal returns (int256 shares) {
    underlyingToken.setBalance(seeder, underlyingToken.balanceOf(seeder) + collateral);
    vm.startPrank(seeder);
    underlyingToken.approve(address(collateralToken), collateral);
    collateralToken.mint(seeder, collateral);
    collateralToken.approve(address(pm), collateral);
    shares = pm.deposit(collateral, debt);
    vm.stopPrank();
  }

  /// @dev Seeds the default PM.
  function _seedPool(uint256 collateral, uint256 debt) internal returns (int256 shares) {
    return _seedPool(positionManager, collateral, debt);
  }

  /// @dev Sets the entry offer of `pm` as the facilitator, closed to unlevered pools.
  function _setEntry(PositionManager pm, uint256 cap, uint40 expiry, uint24 feeBps) internal {
    _setEntry(pm, cap, expiry, feeBps, false);
  }

  /// @dev Sets the entry offer of `pm` as the facilitator.
  function _setEntry(PositionManager pm, uint256 cap, uint40 expiry, uint24 feeBps, bool allowUnlevered) internal {
    vm.prank(facilitator);
    facility.setEntry(address(pm), cap, expiry, feeBps, allowUnlevered);
  }

  /// @dev Sets the exit offer of `pm` as the facilitator.
  function _setExit(PositionManager pm, uint256 cap, uint40 expiry, uint24 feeBps) internal {
    vm.prank(facilitator);
    facility.setExit(address(pm), cap, expiry, feeBps);
  }

  /// @dev Sets the security cap word of the underlying as the facilitator.
  function _setSecurityCap(uint256 cap) internal {
    vm.prank(operator);
    facility.setSecurityCap(address(underlyingToken), cap);
  }

  /// @dev Sets an auth on the underlying as the operator.
  function _setAuth(address who, uint128 amount, uint40 expiry) internal {
    vm.prank(operator);
    facility.setAuth(address(underlyingToken), who, amount, expiry);
  }

  /// @dev Opens both sides of the default PM with an effectively unlimited ABSOLUTE cap and the
  ///      default fee, and opens the security cap wide.
  function _openOffers() internal {
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(LibCaps.MAX_ABSOLUTE);
  }

  /// @dev Opens both sides of the default PM with no fee and the security cap wide.
  function _openOffersNoFee() internal {
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    _setSecurityCap(LibCaps.MAX_ABSOLUTE);
  }

  /// @dev Encodes an EXTERNAL cap word.
  function _externalWord(address caps, uint64 id, int24 multiplier) internal pure returns (uint256) {
    return LibCaps.encodeExternal(caps, id, multiplier);
  }

  /// @dev Funds `who` with underlying and approves the facility for an entry.
  function _fundEntrant(address who, uint256 amount) internal {
    underlyingToken.setBalance(who, underlyingToken.balanceOf(who) + amount);
    vm.prank(who);
    underlyingToken.approve(address(facility), amount);
  }

  /// @dev Enters the default PM through the facility as `who` with unconstrained bounds.
  function _enter(address who, uint256 amount, address to) internal returns (uint256 shares, uint256 debt) {
    return _enter(positionManager, who, amount, to);
  }

  /// @dev Enters `pm` through the facility as `who` with unconstrained bounds.
  function _enter(PositionManager pm, address who, uint256 amount, address to)
    internal
    returns (uint256 shares, uint256 debt)
  {
    _fundEntrant(who, amount);
    vm.prank(who);
    return facility.enter(address(pm), amount, 0, type(uint256).max, 0, to);
  }

  /// @dev Approves shares and debt then exits the default PM through the facility as `who`.
  function _exit(address who, uint256 shares, address to) internal returns (uint256 out, uint256 debtIn) {
    return _exit(positionManager, who, shares, to);
  }

  /// @dev Approves shares and debt then exits `pm` through the facility as `who`.
  function _exit(PositionManager pm, address who, uint256 shares, address to)
    internal
    returns (uint256 out, uint256 debtIn)
  {
    (uint256 previewDebtIn,,, uint256 required) = facility.previewExit(address(pm), shares);
    // Headroom over the required pull: it drifts up with interest accrual.
    uint256 allowance = required + previewDebtIn / 10;
    debtToken.setBalance(who, debtToken.balanceOf(who) + allowance);
    vm.startPrank(who);
    debtToken.approve(address(facility), allowance);
    pm.approve(address(facility), shares);
    (out, debtIn) = facility.exit(address(pm), shares, type(uint256).max, 0, to, "");
    vm.stopPrank();
  }

  /// @dev Enables PM fees (bps per the PM caps: mgmt <= 200, perf <= 5000).
  function _setPmFees(uint24 managementFee, uint24 performanceFee) internal {
    vm.prank(owner);
    positionManager.setFeeData(pmFeeRecipient, managementFee, performanceFee);
  }

  /// @dev The debt an exit pulls up front for a mirrored `debtIn` (headroom included).
  function _required(uint256 debtIn) internal pure returns (uint256) {
    return LibInKindView.exitDebtRequired(debtIn);
  }

  /// @dev Asserts the facility retains no tokens: it is a pure pass-through.
  function _assertFacilityClean() internal view {
    assertEq(underlyingToken.balanceOf(address(facility)), 0, "facility holds underlying");
    assertEq(collateralToken.balanceOf(address(facility)), 0, "facility holds wrapper");
    assertEq(debtToken.balanceOf(address(facility)), 0, "facility holds debt asset");
    assertEq(positionManager.balanceOf(address(facility)), 0, "facility holds PM shares");
    assertEq(positionManager2.balanceOf(address(facility)), 0, "facility holds PM2 shares");
  }

  /// @dev Asserts the facility left no allowance behind on any token it approves.
  function _assertNoAllowances() internal view {
    assertEq(underlyingToken.allowance(address(facility), address(collateralToken)), 0, "underlying allowance");
    assertEq(collateralToken.allowance(address(facility), address(positionManager)), 0, "wrapper allowance");
    assertEq(debtToken.allowance(address(facility), address(positionManager)), 0, "debt allowance");
  }

  function test_empty() public pure {}
}
