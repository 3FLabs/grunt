// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

// Core contracts
import {Facility} from "src/facility/Facility.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {TransferGuard} from "src/guard/base/TransferGuard.sol";
import {TokenMode} from "src/interfaces/guard/ITransferGuard.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";

// Interfaces
import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {IPositionManager, SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";

// Libraries
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {SwapParams} from "src/interfaces/facility/base/IFacilitySwap.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";

// External
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {CallbackToken} from "test/mock/facility/CallbackToken.sol";

/// @title FacilityReentrancyTest
/// @notice Tests for read-only reentrancy protection and CEI ordering in FacilityLP.
/// @dev Uses a CallbackToken as the debt token so that safeTransfer triggers a callback
///      that can attempt to read intentBalances during claim/withdraw.
contract FacilityReentrancyTest is Test {
  using MarketParamsLib for MarketParams;
  using LibClone for address;

  Facility public facility;
  PositionManager public positionManager;
  TransferGuard public transferGuard;
  CallbackToken public callbackDebt;
  MockERC20 public collateralToken;
  IMorpho public morpho;
  MorphoBorrowPositionFactory public bpFactory;

  address public owner;
  address public facilitator;
  address public guardian;
  address public pauser;
  address public minter;
  address public user;

  uint256 constant GUARDIAN_PK = 0x1234;
  uint256 constant FACILITATOR_ROLE = 1 << 0;
  uint256 constant GUARDIAN_ROLE = 1 << 1;
  uint256 constant COMPLIANCE_ROLE = 1 << 2;
  uint256 constant PM_MINTER_ROLE = 1 << 0;
  uint256 constant PM_CURATOR_ROLE = 1 << 1;
  uint256 constant DEFAULT_DEPOSIT_CAP = 1_000_000e18;
  uint256 constant DEFAULT_LLTV = 0.8e18;
  uint256 constant PM_LTV = 0.7e18;
  uint128 constant BP_SAFE_LTV = 0.72e18;
  uint128 constant BP_LIQUIDATION_LTV = 0.78e18;

  function setUp() public {
    owner = makeAddr("owner");
    facilitator = makeAddr("facilitator");
    guardian = vm.addr(GUARDIAN_PK);
    pauser = makeAddr("pauser");
    minter = makeAddr("minter");
    user = makeAddr("user");

    // Deploy tokens: collateral is normal, debt is the callback token
    collateralToken = new MockERC20("Collateral", "COLL", 18);
    callbackDebt = new CallbackToken();
    vm.label(address(collateralToken), "CollateralToken");
    vm.label(address(callbackDebt), "CallbackDebt");

    // Deploy Morpho infra
    OracleMock oracle = new OracleMock();
    oracle.setPrice(1e36);
    IrmMock irm = new IrmMock();
    morpho = IMorpho(address(new Morpho(owner)));

    vm.startPrank(owner);
    morpho.enableIrm(address(irm));
    morpho.enableLltv(DEFAULT_LLTV);
    vm.stopPrank();

    MarketParams memory mp = MarketParams({
      loanToken: address(callbackDebt),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });
    vm.prank(owner);
    morpho.createMarket(mp);

    // Deploy TransferGuard
    transferGuard = TransferGuard(address(new TransferGuard()).clone());
    transferGuard.initialize(owner);

    // Deploy PositionManager with callbackDebt as debt asset
    positionManager = PositionManager(address(new PositionManager()).clone());
    positionManager.initialize(
      owner,
      PositionManagerMetadata({
        name: "PM Shares", symbol: "PMS", collateralAsset: address(collateralToken), debtAsset: address(callbackDebt)
      }),
      PM_LTV,
      address(transferGuard),
      0,
      0
    );

    // Setup borrow position
    bpFactory = new MorphoBorrowPositionFactory(owner, morpho);
    address bp = bpFactory.createBorrowPosition(mp.id(), address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV);

    vm.prank(owner);
    positionManager.addBorrowModule(bp);

    SupplyQueueEntry[] memory sq = new SupplyQueueEntry[](1);
    sq[0] = SupplyQueueEntry({position: bp, maxBorrow: uint96(type(uint96).max)});
    address[] memory wq = new address[](1);
    wq[0] = bp;

    vm.startPrank(owner);
    positionManager.grantRoles(owner, PM_CURATOR_ROLE);
    positionManager.setSupplyQueue(sq);
    positionManager.setWithdrawalQueue(wq);
    vm.stopPrank();

    // Supply Morpho liquidity
    callbackDebt.mint(address(this), 100_000e18);
    callbackDebt.approve(address(morpho), type(uint256).max);
    morpho.supply(mp, 100_000e18, 0, address(this), "");

    // Deploy Facility
    IntentDescriptor descriptor = new IntentDescriptor();
    facility = Facility(address(new Facility()).clone());
    facility.initialize(owner, facilitator, address(descriptor));

    // Roles
    vm.startPrank(owner);
    positionManager.grantRoles(address(facility), PM_MINTER_ROLE);
    positionManager.grantRoles(minter, PM_MINTER_ROLE);
    facility.grantRoles(guardian, GUARDIAN_ROLE);
    facility.grantRoles(pauser, COMPLIANCE_ROLE);
    transferGuard.setTokenConfig(address(positionManager), false, TokenMode.BLOCKLIST, false);
    vm.stopPrank();

    // User approvals
    vm.startPrank(user);
    collateralToken.approve(address(facility), type(uint256).max);
    callbackDebt.approve(address(facility), type(uint256).max);
    positionManager.approve(address(facility), type(uint256).max);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  READ-ONLY REENTRANCY TESTS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice intentBalances reverts with Reentrancy when called during a claim callback
  function test_intentBalances_revertsOnReadReentrancyDuringClaim() public {
    // Create intent: deposit = PM, target = callbackDebt (non-PM)
    vm.prank(owner);
    uint256 intentId = facility.createIntent(
      IntentProperties({
        depositAsset: Asset({asset: address(positionManager), isPositionManager: true}),
        targetAsset: Asset({asset: address(callbackDebt), isPositionManager: false}),
        depositCap: DEFAULT_DEPOSIT_CAP,
        guardKey: address(positionManager),
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 1,
        transferableIntent: true
      })
    );

    // Deposit PM shares
    uint256 depositAmount = 1000e18;
    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    // Create intent2 with callbackDebt as deposit, PM as target
    vm.prank(owner);
    uint256 intentId2 = facility.createIntent(
      IntentProperties({
        depositAsset: Asset({asset: address(callbackDebt), isPositionManager: false}),
        targetAsset: Asset({asset: address(positionManager), isPositionManager: true}),
        depositCap: DEFAULT_DEPOSIT_CAP,
        guardKey: address(positionManager),
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 1,
        transferableIntent: true
      })
    );

    // Deposit callbackDebt tokens into intent2
    callbackDebt.mint(user, 1000e18);
    vm.prank(user);
    facility.deposit(intentId2, 1000e18);

    // Warp past resolveStart and swap callbackDebt into intent1
    vm.warp(block.timestamp + 1 days + 1);

    SwapParams memory params = SwapParams({
      id1: intentId,
      token1: address(positionManager),
      id2: intentId2,
      token2: address(callbackDebt),
      amount1: 100e18,
      amount2: 100e18,
      deadline: block.timestamp + 1 hours
    });

    address[] memory signers = new address[](1);
    signers[0] = guardian;
    bytes[] memory signatures = new bytes[](1);
    signatures[0] = _signSwap(params, GUARDIAN_PK);

    vm.prank(facilitator);
    facility.swap(params, signers, signatures);

    // Resolve intent1 (now holds PM shares + callbackDebt tokens)
    vm.prank(facilitator);
    facility.resolve(intentId);

    // Enable reentrant attack: on claim transfer of callbackDebt, call intentBalances
    callbackDebt.enableAttack(address(facility), intentId);

    // Claim — callbackDebt transfer triggers callback
    vm.prank(user);
    facility.claim(intentId, user, user, depositAmount);

    // Verify callback was triggered and intentBalances reverted
    assertTrue(callbackDebt.callbackTriggered(), "Callback should have triggered");
    assertTrue(callbackDebt.callbackReverted(), "intentBalances should revert during reentrancy");
  }

  /// @notice intentBalances works normally outside of reentrant context
  function test_intentBalances_worksOutsideReentrancy() public {
    vm.prank(owner);
    uint256 intentId = facility.createIntent(
      IntentProperties({
        depositAsset: Asset({asset: address(positionManager), isPositionManager: true}),
        targetAsset: Asset({asset: address(callbackDebt), isPositionManager: false}),
        depositCap: DEFAULT_DEPOSIT_CAP,
        guardKey: address(positionManager),
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 1,
        transferableIntent: true
      })
    );

    uint256 depositAmount = 1000e18;
    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(intentId);
    assertEq(tokens.length, 1);
    assertEq(tokens[0], address(positionManager));
    assertEq(amounts[0], depositAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              CEI: AMOUNTS DECREMENTED BEFORE TRANSFER         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Verifies withdraw decrements intent amounts correctly
  function test_withdraw_amountsDecrementedBeforeTransfer() public {
    vm.prank(owner);
    uint256 intentId = facility.createIntent(
      IntentProperties({
        depositAsset: Asset({asset: address(positionManager), isPositionManager: true}),
        targetAsset: Asset({asset: address(callbackDebt), isPositionManager: false}),
        depositCap: DEFAULT_DEPOSIT_CAP,
        guardKey: address(positionManager),
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 1,
        transferableIntent: true
      })
    );

    uint256 depositAmount = 1000e18;
    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    vm.prank(user);
    facility.withdraw(intentId, user, user, depositAmount / 2);

    (, uint256[] memory amountsAfter) = facility.intentBalances(intentId);
    assertEq(amountsAfter[0], depositAmount / 2);
  }

  /// @notice Verifies claim decrements intent amounts correctly
  function test_claim_amountsDecrementedBeforeTransfer() public {
    vm.prank(owner);
    uint256 intentId = facility.createIntent(
      IntentProperties({
        depositAsset: Asset({asset: address(positionManager), isPositionManager: true}),
        targetAsset: Asset({asset: address(callbackDebt), isPositionManager: false}),
        depositCap: DEFAULT_DEPOSIT_CAP,
        guardKey: address(positionManager),
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 1,
        transferableIntent: true
      })
    );

    uint256 depositAmount = 1000e18;
    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    vm.warp(block.timestamp + 1 days + 1);
    vm.prank(facilitator);
    facility.resolve(intentId);

    vm.prank(user);
    facility.claim(intentId, user, user, depositAmount / 2);

    (, uint256[] memory amountsAfter) = facility.intentBalances(intentId);
    assertEq(amountsAfter[0], depositAmount / 2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        HELPERS                                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _depositToPM(address _user, uint256 amount) internal returns (uint256 shares) {
    collateralToken.setBalance(minter, amount);
    vm.startPrank(minter);
    collateralToken.approve(address(positionManager), amount);
    int256 s = positionManager.deposit(amount, 0);
    shares = uint256(s);
    positionManager.transfer(_user, shares);
    vm.stopPrank();

    vm.prank(_user);
    positionManager.approve(address(facility), type(uint256).max);
  }

  function _domainSeparator() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("3F"),
        keccak256("1"),
        block.chainid,
        address(facility)
      )
    );
  }

  bytes32 internal constant SWAP_PARAMS_TYPEHASH = 0x8b4e182587850acdf21dcf7a0f61b2fd7267c2cdf71d4692b57fb97237a29be3;

  function _signSwap(SwapParams memory params, uint256 privateKey) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(SWAP_PARAMS_TYPEHASH, params));
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
    return abi.encodePacked(r, s, v);
  }
}
