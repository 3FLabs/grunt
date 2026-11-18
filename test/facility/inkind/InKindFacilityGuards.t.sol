// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IInKindExitCallback} from "src/interfaces/facility/IInKindExitCallback.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {AddressStatus} from "src/interfaces/guard/ITransferGuard.sol";
import {IMorpho, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @dev Liquidates `victim` down to 1 wei of collateral inside the exit callback.
contract LiquidatingExiter is IInKindExitCallback {
  IInKindFacility internal immutable facility;
  IMorpho internal immutable morpho;
  MockERC20 internal immutable debtToken;
  address internal immutable victim;
  MarketParams internal market;

  constructor(
    IInKindFacility facility_,
    IMorpho morpho_,
    MockERC20 debtToken_,
    MarketParams memory market_,
    address victim_
  ) {
    facility = facility_;
    morpho = morpho_;
    debtToken = debtToken_;
    market = market_;
    victim = victim_;
  }

  function exit(PositionManager pm, uint256 shares, address to) external {
    pm.approve(address(facility), shares);
    facility.exit(address(pm), shares, type(uint256).max, 0, to, hex"01");
  }

  function onInKindExit(address, uint256, uint256 debtIn, bytes calldata) external {
    uint256 collateral = morpho.position(MarketParamsLib.id(market), victim).collateral;
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.liquidate(market, victim, collateral - 1, 0, "");
    debtToken.approve(address(facility), debtIn);
  }
}

contract InKindFacilityGuardsTest is InKindFacilityBaseTest {
  uint256 internal constant AMOUNT = 100e18;

  function setUp() public override {
    super.setUp();
    _openOffers();
  }

  function test_enter_revertsOnFacilityReceiver() public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _fundEntrant(user, AMOUNT);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InvalidReceiver.selector, address(facility)));
    facility.enter(address(positionManager), AMOUNT, 0, type(uint256).max, 0, address(facility));
  }

  function test_exit_revertsOnFacilityReceiver() public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    (uint256 shares,) = _enter(user, AMOUNT, user);
    vm.startPrank(user);
    positionManager.approve(address(facility), shares);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InvalidReceiver.selector, address(facility)));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, address(facility), "");
    vm.stopPrank();
  }

  function test_enter_revertsWhileTheFeeRecipientFailsThePmGuard() public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _block(feeRecipient);
    _fundEntrant(user, AMOUNT);

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(SafeTransferLib.TransferFailed.selector));
    facility.enter(address(positionManager), AMOUNT, 0, type(uint256).max, 0, receiver);

    vm.prank(owner);
    facility.setFeeRecipient(makeAddr("allowedFeeRecipient"));
    vm.prank(user);
    (uint256 shares,) = facility.enter(address(positionManager), AMOUNT, 0, type(uint256).max, 0, receiver);
    assertEq(positionManager.balanceOf(receiver), shares, "receiver shares");
  }

  function test_exit_revertsWhileTheFeeRecipientFailsThePmGuard() public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    (uint256 shares,) = _enter(user, AMOUNT, user);
    _block(feeRecipient);
    (uint256 debtIn,,, uint256 required) = facility.previewExit(address(positionManager), shares);
    debtToken.setBalance(user, required);
    vm.startPrank(user);
    debtToken.approve(address(facility), required);
    positionManager.approve(address(facility), shares);

    vm.expectRevert(abi.encodeWithSelector(SafeTransferLib.TransferFailed.selector));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
    vm.stopPrank();

    vm.prank(owner);
    facility.setFeeRecipient(makeAddr("allowedFeeRecipient"));
    vm.prank(user);
    (, uint256 repaid) = facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
    assertEq(repaid, debtIn, "debt repaid");
    assertEq(positionManager.balanceOf(user), 0, "user shares");
  }

  function test_zeroFeeFlows_ignoreTheFeeRecipientGuard() public {
    _openOffersNoFee();
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _block(feeRecipient);

    (uint256 shares,) = _enter(user, AMOUNT, user);
    assertGt(shares, 0, "entered");
    (uint256 out,) = _exit(user, shares, user);
    assertGt(out, 0, "exited");
  }

  function test_enter_payerIsNotGuardChecked() public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _block(user);
    _fundEntrant(user, AMOUNT);

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(SafeTransferLib.TransferFailed.selector));
    facility.enter(address(positionManager), AMOUNT, 0, type(uint256).max, 0, user);

    vm.prank(user);
    (uint256 shares, uint256 debt) = facility.enter(address(positionManager), AMOUNT, 0, type(uint256).max, 0, receiver);
    assertGt(shares, 0, "shares");
    assertEq(positionManager.balanceOf(receiver), shares, "receiver shares");
    assertEq(debtToken.balanceOf(receiver), debt, "receiver debt");
    assertEq(underlyingToken.balanceOf(user), 0, "payer underlying");
  }

  function test_entryViews_atTargetLtv() public {
    _seedPool(SEED_COLLATERAL, 7_000e6);
    assertGt(facility.maxEnter(address(positionManager), user), 0);
    (uint256 debt,,) = facility.previewEnter(address(positionManager), AMOUNT);
    (, uint256 entered) = _enter(user, AMOUNT, user);
    assertEq(entered, debt);
  }

  function test_entryViews_aboveTargetLtv() public {
    _seedPool(SEED_COLLATERAL, 7_000e6);
    vm.warp(vm.getBlockTimestamp() + 12);

    assertEq(facility.maxEnter(address(positionManager), user), 0);
    vm.expectRevert(abi.encodeWithSelector(LibManagerErrors.InsufficientBorrowCapacity.selector));
    facility.previewEnter(address(positionManager), AMOUNT);

    _fundEntrant(user, AMOUNT);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibManagerErrors.InsufficientBorrowCapacity.selector));
    facility.enter(address(positionManager), AMOUNT, 0, type(uint256).max, 0, user);
  }

  function test_entryViews_dustAboveTargetLtvRevertsLikeEnter() public {
    _seedPool(SEED_COLLATERAL, 7_000e6);
    vm.warp(vm.getBlockTimestamp() + 12);
    uint256 amount = 1e12;

    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DustEntry.selector, amount));
    facility.previewEnter(address(positionManager), amount);

    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DustEntry.selector, amount));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, user);
  }

  function test_entryViews_afterPriceDrop() public {
    _seedPool(SEED_COLLATERAL, 6_900e6);
    assertGt(facility.maxEnter(address(positionManager), user), 0);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 97 / 100);
    assertEq(facility.maxEnter(address(positionManager), user), 0);
  }

  function _block(address account) internal {
    vm.prank(owner);
    transferGuard.setAddressStatus(account, AddressStatus.BLOCKLIST);
  }
}

/// @dev Two-module PM where module B sits above its LLTV without bad debt, so a liquidation in
///      the exit callback can leave it underwater before PM.burn.
contract InKindFacilityCallbackBadDebtTest is InKindFacilityBaseTest {
  using MarketParamsLib for MarketParams;

  PositionManager internal pm3;
  MorphoBorrowPosition internal moduleB;
  LiquidatingExiter internal exiter;
  uint256 internal exiterShares;

  function setUp() public override {
    super.setUp();
    OracleMock oracleB = new OracleMock();
    oracleB.setPrice(DEFAULT_ORACLE_PRICE);
    MarketParams memory marketB = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(oracleB),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });
    morpho.createMarket(marketB);
    debtToken.setBalance(address(this), MORPHO_LIQUIDITY);
    debtToken.approve(address(morpho), MORPHO_LIQUIDITY);
    morpho.supply(marketB, MORPHO_LIQUIDITY, 0, address(this), "");

    pm3 = PositionManager(LibClone.clone(address(new PositionManager())));
    pm3.initialize(
      owner,
      PositionManagerMetadata({
        name: "P3", symbol: "P3", collateralAsset: address(collateralToken), debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(transferGuard),
      0,
      0
    );
    vm.startPrank(owner);
    MorphoBorrowPosition moduleA = MorphoBorrowPosition(
      borrowPositionFactory.createBorrowPosition(marketId, address(pm3), BP_SAFE_LTV, BP_LIQUIDATION_LTV)
    );
    moduleB = MorphoBorrowPosition(
      borrowPositionFactory.createBorrowPosition(marketB.id(), address(pm3), BP_SAFE_LTV, BP_LIQUIDATION_LTV)
    );
    pm3.grantRoles(owner, PM_CURATOR_ROLE);
    pm3.addBorrowModule(address(moduleA));
    pm3.addBorrowModule(address(moduleB));
    pm3.grantRoles(address(facility), PM_MINTER_ROLE);
    pm3.grantRoles(seeder, PM_MINTER_ROLE);
    collateralToken.grantRoles(address(pm3), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(moduleA), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(moduleB), WA_SENDER_ROLE);
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](1);
    supplyQueue[0] = SupplyQueueEntry({position: address(moduleB), maxBorrow: type(uint96).max});
    pm3.setSupplyQueue(supplyQueue);
    address[] memory withdrawalQueue = new address[](2);
    withdrawalQueue[0] = address(moduleB);
    withdrawalQueue[1] = address(moduleA);
    pm3.setWithdrawalQueue(withdrawalQueue);
    vm.stopPrank();
    _seedPool(pm3, 1_000e18, 690e6);
    supplyQueue[0] = SupplyQueueEntry({position: address(moduleA), maxBorrow: type(uint96).max});
    vm.prank(owner);
    pm3.setSupplyQueue(supplyQueue);
    _seedPool(pm3, 9_000e18, 4_500e6);

    _setEntry(pm3, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    _setExit(pm3, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    _setSecurityCap(LibCaps.MAX_ABSOLUTE);

    exiter = new LiquidatingExiter(facility, morpho, debtToken, marketB, address(moduleB));
    (exiterShares,) = _enter(pm3, user, 1_000e18, address(exiter));
    debtToken.setBalance(address(exiter), 10_000_000e6);

    // module B above its LLTV, not bad debt
    oracleB.setPrice(DEFAULT_ORACLE_PRICE * 69 / 96);
    assertFalse(pm3.hasBadDebt());
  }

  function test_exit_revertsOnBadDebtFromCallback() public {
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.BadDebtState.selector, address(pm3)));
    exiter.exit(pm3, exiterShares, receiver);
  }
}
