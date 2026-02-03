// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

// Core contracts
import {Facility} from "src/facility/Facility.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {TransferGuard} from "src/guard/TransferGuard.sol";

// Borrow position
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";

// Interfaces
import {IPositionManager, SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";

// Libraries
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";

// Morpho dependencies
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";

// Mocks
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";

// Handler
import {FacilityHandler} from "test/mock/facility/FacilityHandler.sol";

/// @title FacilityInvariantTest
/// @notice Invariant test suite for the Facility contract.
/// @dev Exercises the Facility lifecycle via a FacilityHandler and asserts
///      core protocol invariants after every fuzzed action sequence.
contract FacilityInvariantTest is StdInvariant, Test {
  using MarketParamsLib for MarketParams;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  Facility public facility;
  IntentDescriptor public descriptor;
  PositionManager public positionManager;
  TransferGuard public transferGuard;

  // Morpho infrastructure
  IMorpho public morpho;
  MorphoBorrowPositionFactory public borrowPositionFactory;
  MorphoBorrowPosition public borrowPosition;

  // Mock tokens
  MockERC20 public collateralToken;
  MockERC20 public debtToken;
  OracleMock public oracle;
  IrmMock public irm;

  // Market params
  MarketParams public marketParams;
  Id public marketId;

  // Handler
  FacilityHandler public handler;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST ADDRESSES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public facilitator;
  address public guardian;
  uint256 public guardianPk;
  address public pauser;
  address public minter;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // Facility roles
  uint256 constant FACILITATOR_ROLE = 1 << 0;
  uint256 constant GUARDIAN_ROLE = 1 << 1;
  uint256 constant PAUSER_ROLE = 1 << 2;

  // PositionManager roles
  uint256 constant PM_MINTER_ROLE = 1 << 0;
  uint256 constant PM_CURATOR_ROLE = 1 << 1;

  // Morpho / PM constants
  uint256 constant DEFAULT_LLTV = 0.8e18;
  uint256 constant PM_LLTV = 0.7e18;
  uint128 constant BP_SAFE_LTV = 0.65e18;
  uint128 constant BP_LIQUIDATION_LTV = 0.72e18;
  uint256 constant DEFAULT_ORACLE_PRICE = 1e36;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    // ----- 1. Create test addresses -----
    owner = makeAddr("owner");
    facilitator = makeAddr("facilitator");
    (guardian, guardianPk) = makeAddrAndKey("guardian");
    pauser = makeAddr("pauser");
    minter = makeAddr("minter");

    // ----- 2. Deploy MockERC20 tokens (both 18 decimals) -----
    collateralToken = new MockERC20("Collateral Token", "COLL", 18);
    vm.label(address(collateralToken), "CollateralToken");

    debtToken = new MockERC20("Debt Token", "DEBT", 18);
    vm.label(address(debtToken), "DebtToken");

    // ----- 3. Deploy OracleMock (price = 1e36) and IrmMock -----
    oracle = new OracleMock();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    vm.label(address(oracle), "Oracle");

    irm = new IrmMock();
    vm.label(address(irm), "IRM");

    // ----- 4. Deploy Morpho (real), enable IRM and LLTV, create market -----
    morpho = IMorpho(address(new Morpho(owner)));
    vm.label(address(morpho), "Morpho");

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

    vm.prank(owner);
    morpho.createMarket(marketParams);
    marketId = marketParams.id();

    // ----- 5. Deploy TransferGuard, initialize -----
    transferGuard = new TransferGuard();
    transferGuard.initialize(owner);
    vm.label(address(transferGuard), "TransferGuard");

    // ----- 6. Deploy PositionManager, initialize with metadata + transfer guard -----
    positionManager = new PositionManager();
    positionManager.initialize(
      owner,
      PositionManagerMetadata({
        name: "Position Manager Shares",
        symbol: "PMS",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      PM_LLTV,
      address(transferGuard)
    );
    vm.label(address(positionManager), "PositionManager");

    // ----- 7. Deploy MorphoBorrowPositionFactory, create borrow position -----
    borrowPositionFactory = new MorphoBorrowPositionFactory(owner);
    address bp = borrowPositionFactory.createBorrowPosition(
      morpho, marketId, address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
    borrowPosition = MorphoBorrowPosition(bp);
    vm.label(address(borrowPosition), "BorrowPosition");

    // ----- 8. Add borrow module, set supply/withdrawal queues (needs CURATOR_ROLE) -----
    vm.prank(owner);
    positionManager.addBorrowModule(address(borrowPosition));

    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](1);
    supplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition), maxBorrow: uint96(type(uint96).max)});

    address[] memory withdrawalQueue = new address[](1);
    withdrawalQueue[0] = address(borrowPosition);

    vm.startPrank(owner);
    positionManager.grantRoles(owner, PM_CURATOR_ROLE);
    positionManager.setSupplyQueue(supplyQueue);
    positionManager.setWithdrawalQueue(withdrawalQueue);
    vm.stopPrank();

    // ----- 9. Supply Morpho liquidity (100_000e18) -----
    debtToken.setBalance(address(this), 100_000e18);
    debtToken.approve(address(morpho), 100_000e18);
    morpho.supply(marketParams, 100_000e18, 0, address(this), "");

    // ----- 10. Deploy IntentDescriptor (real) -----
    descriptor = new IntentDescriptor();
    vm.label(address(descriptor), "IntentDescriptor");

    // ----- 11. Deploy Facility, initialize(owner, facilitator, descriptor) -----
    facility = new Facility();
    facility.initialize(owner, facilitator, address(descriptor));
    vm.label(address(facility), "Facility");

    // ----- 12. Grant PM_MINTER_ROLE to facility and minter on PM -----
    vm.startPrank(owner);
    positionManager.grantRoles(address(facility), PM_MINTER_ROLE);
    positionManager.grantRoles(minter, PM_MINTER_ROLE);
    vm.stopPrank();

    // ----- 13. Grant GUARDIAN_ROLE, PAUSER_ROLE on facility -----
    vm.startPrank(owner);
    facility.grantRoles(guardian, GUARDIAN_ROLE);
    facility.grantRoles(pauser, PAUSER_ROLE);
    vm.stopPrank();

    // ----- 14. Set transfer guard config: blocklist mode for PM token -----
    vm.prank(owner);
    transferGuard.setTokenConfig(address(positionManager), false, false); // blocklist mode, not paused

    // ----- 15. Create handler, initialize, configure target selectors -----
    handler = new FacilityHandler();
    handler.initialize(facility, positionManager, collateralToken, debtToken, owner, facilitator, minter, guardianPk);

    // Register handler action selectors with the invariant fuzzer
    bytes4[] memory selectors = new bytes4[](9);
    selectors[0] = FacilityHandler.act_createIntent.selector;
    selectors[1] = FacilityHandler.act_deposit.selector;
    selectors[2] = FacilityHandler.act_withdraw.selector;
    selectors[3] = FacilityHandler.act_lock.selector;
    selectors[4] = FacilityHandler.act_warpToResolving.selector;
    selectors[5] = FacilityHandler.act_resolve.selector;
    selectors[6] = FacilityHandler.act_claim.selector;
    selectors[7] = FacilityHandler.act_transfer.selector;
    selectors[8] = FacilityHandler.act_swap.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INVARIANTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice FAC-1: Intent state machine is one-way (DEPOSITING -> RESOLVING -> RESOLVED).
  /// @dev Verifies that the on-chain resolved flag is consistent with the handler's
  ///      tracked state. A resolved intent must have been tracked as RESOLVED (state 2)
  ///      in the handler, meaning it transitioned through RESOLVING first.
  function invariant_stateOnlyAdvances() public view {
    uint256[] memory ids = handler.getIntentIds();
    for (uint256 i = 0; i < ids.length; i++) {
      uint8 trackedState = handler.intentStates(ids[i]);
      (IntentProperties memory props,,, bool resolved) = facility.getIntent(ids[i]);
      if (resolved) {
        assertTrue(trackedState == 2, "FAC-1: state went backwards to resolved without passing through resolving");
      }
    }
  }

  /// @notice FAC-2: totalSupply for each intent equals the sum of all tracked user balances.
  /// @dev Iterates over all tracked users and sums their ERC6909 balances for each intent.
  ///      The result must equal the intent's totalSupply as returned by the Facility.
  function invariant_totalSupplyConsistency() public view {
    uint256[] memory ids = handler.getIntentIds();
    address[] memory trackedUsers = handler.getUsers();
    for (uint256 i = 0; i < ids.length; i++) {
      uint256 id = ids[i];
      uint256 sumBalances = 0;
      for (uint256 j = 0; j < trackedUsers.length; j++) {
        sumBalances += facility.balanceOf(trackedUsers[j], id);
      }
      assertEq(facility.totalSupply(id), sumBalances, "FAC-2: totalSupply != sum of balances");
    }
  }

  /// @notice FAC-4: Deposit cap is never exceeded for any intent.
  /// @dev Checks that each intent's totalSupply does not exceed its configured depositCap.
  function invariant_depositCapNotExceeded() public view {
    uint256[] memory ids = handler.getIntentIds();
    for (uint256 i = 0; i < ids.length; i++) {
      (IntentProperties memory props,,,) = facility.getIntent(ids[i]);
      assertLe(facility.totalSupply(ids[i]), props.depositCap, "FAC-4: totalSupply exceeds depositCap");
    }
  }

  /// @notice FAC-5: The sum of tracked token amounts across all intents does not exceed the
  ///         Facility's actual token balances.
  /// @dev Aggregates intent-level token balances for both PM shares and debtToken and compares
  ///      to the Facility's real balances. This ensures the Facility is solvent.
  function invariant_tokenBalanceSolvency() public view {
    uint256[] memory ids = handler.getIntentIds();
    uint256 totalPmSharesTracked = 0;
    uint256 totalDebtTokenTracked = 0;
    for (uint256 i = 0; i < ids.length; i++) {
      (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(ids[i]);
      for (uint256 j = 0; j < tokens.length; j++) {
        if (tokens[j] == address(positionManager)) {
          totalPmSharesTracked += amounts[j];
        }
        if (tokens[j] == address(debtToken)) {
          totalDebtTokenTracked += amounts[j];
        }
      }
    }
    assertLe(
      totalPmSharesTracked,
      positionManager.balanceOf(address(facility)),
      "FAC-5: tracked PM shares exceed actual balance"
    );
    assertLe(
      totalDebtTokenTracked, debtToken.balanceOf(address(facility)), "FAC-5: tracked debt tokens exceed actual balance"
    );
  }

  /// @notice FAC-9: address(0) never holds any intent token balance.
  /// @dev The Facility overrides transfer/transferFrom to revert on transfers to address(0).
  ///      This invariant confirms that enforcement by checking the zero address balance for
  ///      every intent.
  function invariant_noTransferToZero() public view {
    uint256[] memory ids = handler.getIntentIds();
    for (uint256 i = 0; i < ids.length; i++) {
      assertEq(facility.balanceOf(address(0), ids[i]), 0, "FAC-9: address(0) has balance");
    }
  }

  /// @notice FAC-3: Deposit and withdraw must be 1:1 with LP tokens.
  /// @dev Checked per-action in the handler. This invariant verifies the ghost flags.
  function invariant_depositWithdrawOneToOne() public view {
    assertFalse(handler.depositNotOneToOne(), "FAC-3: deposit did not mint 1:1 LP tokens");
    assertFalse(handler.withdrawNotOneToOne(), "FAC-3: withdraw did not burn 1:1 LP tokens");
  }

  /// @notice FAC-6: Claim distributes tokens proportionally to shares burned.
  /// @dev Checked per-action in the handler. This invariant verifies the ghost flag.
  function invariant_claimProportionality() public view {
    assertFalse(handler.claimProportionalityViolated(), "FAC-6: claim did not distribute tokens proportionally");
  }

  /// @notice FAC-7: Swaps are zero-sum between intents.
  /// @dev Checked per-action in the handler. This invariant verifies the ghost flag.
  function invariant_swapZeroSum() public view {
    assertFalse(handler.swapNotZeroSum(), "FAC-7: swap was not zero-sum between intents");
  }

  /// @notice FAC-8: Swap digest replay is prevented.
  /// @dev Checked per-action in the handler. This invariant verifies the ghost flag.
  function invariant_swapReplayPrevention() public view {
    assertFalse(handler.swapReplaySucceeded(), "FAC-8: swap digest replay succeeded");
  }
}
