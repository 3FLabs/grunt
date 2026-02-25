// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

// Core contracts
import {Facility} from "src/facility/Facility.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {TransferGuard} from "src/guard/TransferGuard.sol";

// Interfaces
import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {IFacilityIntents} from "src/interfaces/facility/base/IFacilityIntents.sol";
import {IPositionManager, SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";

// Libraries
import {Asset, IntentProperties, Intent, BalanceSnapshot} from "src/libs/facility/LibIntent.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";

// Mocks
import {MockFund} from "test/mock/facility/MockFund.sol";
import {MockRequest} from "test/mock/facility/MockRequest.sol";

// External mocks
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";

// Cloning
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

// Morpho dependencies
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";

// Borrow position
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";

/// @title FacilityBaseTest
/// @notice Base test contract with setup and helpers for Facility tests
contract FacilityBaseTest is Test {
  using MarketParamsLib for MarketParams;
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  Facility public facility;
  IntentDescriptor public descriptor;
  PositionManager public positionManager;
  PositionManager public positionManager2;
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

  // Mock fund and request
  MockFund public mockFund;
  MockRequest public mockRequest;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST PARAMETERS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MarketParams public marketParams;
  Id public marketId;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public facilitator;
  address public guardian;
  address public guardian2;
  address public pauser;
  address public minter; // Has MINTER_ROLE on PositionManager for test setup
  address public user;
  address public user2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // Role constants (from FacilityRoles)
  uint256 constant FACILITATOR_ROLE = 1 << 0;
  uint256 constant GUARDIAN_ROLE = 1 << 1;
  uint256 constant PAUSER_ROLE = 1 << 2;

  // PositionManager roles
  uint256 constant PM_MINTER_ROLE = 1 << 0;
  uint256 constant PM_CURATOR_ROLE = 1 << 1;
  uint256 constant PM_REBALANCER_ROLE = 1 << 2;

  // Test amounts
  uint256 constant DEFAULT_AMOUNT = 10_000e18;
  uint256 constant DEFAULT_DEPOSIT_CAP = 1_000_000e18;
  uint256 constant WAD = 1e18;

  // Morpho constants
  uint256 constant DEFAULT_LLTV = 0.8e18;
  uint256 constant PM_LTV = 0.7e18;
  uint128 constant BP_SAFE_LTV = 0.65e18; // Position LTV for borrow position
  uint128 constant BP_LIQUIDATION_LTV = 0.72e18; // Liquidation LTV for borrow position
  uint256 constant ORACLE_PRICE_SCALE = 1e36;
  uint256 constant DEFAULT_ORACLE_PRICE = 1e36;

  // Guardian private keys for signing
  uint256 constant GUARDIAN_PK = 0x1234;
  uint256 constant GUARDIAN2_PK = 0x5678;

  // Repay timelock (1 hour default for tests)
  uint40 constant DEFAULT_REPAY_TIMELOCK = 1 hours;

  /// @notice EIP-712 typehash for setFund params.
  bytes32 internal constant SET_FUND_PARAMS_TYPEHASH =
    0x5b29fe7a3c7ef719629449a6e2c108e8c6d692027b5327c7edbdc163a7ce1b0b;

  /// @notice EIP-712 typehash for setRequest params.
  bytes32 internal constant SET_REQUEST_PARAMS_TYPEHASH =
    0x3fab97cdfeba7b67ca42aeebb63ab14ea67e6637d1e42acb3a06b721f7d72438;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public virtual {
    // Create test addresses
    owner = makeAddr("owner");
    facilitator = makeAddr("facilitator");
    guardian = vm.addr(GUARDIAN_PK);
    guardian2 = vm.addr(GUARDIAN2_PK);
    pauser = makeAddr("pauser");
    minter = makeAddr("minter"); // Dedicated minter for PM deposits in tests
    user = makeAddr("user");
    user2 = makeAddr("user2");

    // Deploy mock tokens
    collateralToken = new MockERC20("Collateral Token", "COLL", 18);
    vm.label(address(collateralToken), "CollateralToken");

    debtToken = new MockERC20("Debt Token", "DEBT", 18);
    vm.label(address(debtToken), "DebtToken");

    // Deploy oracle and IRM
    oracle = new OracleMock();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    vm.label(address(oracle), "Oracle");

    irm = new IrmMock();
    vm.label(address(irm), "IRM");

    // Deploy Morpho
    morpho = IMorpho(address(new Morpho(owner)));
    vm.label(address(morpho), "Morpho");

    // Configure Morpho
    vm.startPrank(owner);
    morpho.enableIrm(address(irm));
    morpho.enableLltv(DEFAULT_LLTV);
    vm.stopPrank();

    // Create Morpho market
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

    // Deploy TransferGuard
    transferGuard = TransferGuard(address(new TransferGuard()).clone());
    transferGuard.initialize(owner);
    vm.label(address(transferGuard), "TransferGuard");

    // Deploy PositionManager
    positionManager = PositionManager(address(new PositionManager()).clone());
    positionManager.initialize(
      owner,
      PositionManagerMetadata({
        name: "Position Manager Shares",
        symbol: "PMS",
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      PM_LTV,
      address(transferGuard),
      0,
      0
    );
    vm.label(address(positionManager), "PositionManager");

    // Deploy second PositionManager (for dual PM tests)
    positionManager2 = PositionManager(address(new PositionManager()).clone());
    positionManager2.initialize(
      owner,
      PositionManagerMetadata({
        name: "Position Manager Shares 2",
        symbol: "PMS2",
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      PM_LTV,
      address(transferGuard),
      0,
      0
    );
    vm.label(address(positionManager2), "PositionManager2");

    // Deploy MorphoBorrowPosition for PositionManager
    borrowPositionFactory = new MorphoBorrowPositionFactory(owner);
    address bp = borrowPositionFactory.createBorrowPosition(
      morpho, marketId, address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
    borrowPosition = MorphoBorrowPosition(bp);
    vm.label(address(borrowPosition), "BorrowPosition");

    // Setup PositionManager borrow modules
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

    // Supply liquidity to Morpho market
    _supplyMorphoLiquidity(100_000e18);

    // Deploy IntentDescriptor
    descriptor = new IntentDescriptor();
    vm.label(address(descriptor), "IntentDescriptor");

    // Deploy Facility
    facility = Facility(address(new Facility()).clone());
    facility.initialize(owner, facilitator, address(descriptor), DEFAULT_REPAY_TIMELOCK);
    vm.label(address(facility), "Facility");

    // Grant facility and test minter the minter role on position managers
    vm.startPrank(owner);
    positionManager.grantRoles(address(facility), PM_MINTER_ROLE);
    positionManager.grantRoles(minter, PM_MINTER_ROLE);
    positionManager2.grantRoles(minter, PM_MINTER_ROLE);
    vm.stopPrank();

    // Grant roles
    vm.startPrank(owner);
    facility.grantRoles(guardian, GUARDIAN_ROLE);
    facility.grantRoles(guardian2, GUARDIAN_ROLE);
    facility.grantRoles(pauser, PAUSER_ROLE);
    vm.stopPrank();

    // Deploy mock fund and request
    // Fund.asset() must match PM's debt asset, Fund.share() must match PM's collateral asset
    mockFund = new MockFund(address(debtToken), address(collateralToken));
    vm.label(address(mockFund), "MockFund");

    mockRequest = new MockRequest(address(debtToken));
    vm.label(address(mockRequest), "MockRequest");

    // Configure transfer guard (allow facility)
    vm.startPrank(owner);
    transferGuard.setTokenConfig(address(positionManager), false, false); // blocklist mode
    vm.stopPrank();

    // Setup user approvals
    _setupUserApprovals(user);
    _setupUserApprovals(user2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _supplyMorphoLiquidity(uint256 amount) internal {
    debtToken.setBalance(address(this), amount);
    debtToken.approve(address(morpho), amount);
    morpho.supply(marketParams, amount, 0, address(this), "");
  }

  function _setupUserApprovals(address _user) internal {
    vm.startPrank(_user);
    collateralToken.approve(address(facility), type(uint256).max);
    debtToken.approve(address(facility), type(uint256).max);
    collateralToken.approve(address(positionManager), type(uint256).max);
    debtToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();
  }

  function _mintCollateral(address to, uint256 amount) internal {
    collateralToken.setBalance(to, amount);
  }

  function _mintDebt(address to, uint256 amount) internal {
    debtToken.setBalance(to, amount);
  }

  function _mintTokens(address to, uint256 collateralAmount, uint256 debtAmount) internal {
    if (collateralAmount > 0) _mintCollateral(to, collateralAmount);
    if (debtAmount > 0) _mintDebt(to, debtAmount);
  }

  /// @notice Builds the EIP-712 domain separator used by Facility signatures.
  function _facilityDomainSeparator() internal view returns (bytes32) {
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

  /// @notice Computes the digest for setFund actions.
  function _getSetFundDigest(uint256 id, address newFund, uint256 deadline) internal view returns (bytes32) {
    return keccak256(
      abi.encodePacked(
        "\x19\x01", _facilityDomainSeparator(), keccak256(abi.encode(SET_FUND_PARAMS_TYPEHASH, id, newFund, deadline))
      )
    );
  }

  /// @notice Computes the digest for setRequest actions.
  function _getSetRequestDigest(uint256 id, address newRequest, uint256 deadline) internal view returns (bytes32) {
    return keccak256(
      abi.encodePacked(
        "\x19\x01",
        _facilityDomainSeparator(),
        keccak256(abi.encode(SET_REQUEST_PARAMS_TYPEHASH, id, newRequest, deadline))
      )
    );
  }

  /// @notice Signs a setFund approval.
  function _signSetFund(uint256 id, address newFund, uint256 deadline, uint256 privateKey)
    internal
    view
    returns (bytes memory)
  {
    bytes32 digest = _getSetFundDigest(id, newFund, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @notice Signs a setRequest approval.
  function _signSetRequest(uint256 id, address newRequest, uint256 deadline, uint256 privateKey)
    internal
    view
    returns (bytes memory)
  {
    bytes32 digest = _getSetRequestDigest(id, newRequest, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @notice Calls setFund as facilitator with default guardian signature.
  function _setFund(uint256 id, address newFund) internal {
    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);
    uint256 deadline = block.timestamp + 1 hours;

    signers[0] = guardian;
    signatures[0] = _signSetFund(id, newFund, deadline, GUARDIAN_PK);
    _setFund(id, newFund, deadline, signers, signatures);
  }

  /// @notice Calls setFund as facilitator with explicit signature args.
  function _setFund(uint256 id, address newFund, uint256 deadline, address[] memory signers, bytes[] memory signatures)
    internal
  {
    facility.setFund(id, newFund, deadline, signers, signatures);
  }

  /// @notice Calls setRequest as facilitator with default guardian signature.
  function _setRequest(uint256 id, address newRequest) internal {
    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);
    uint256 deadline = block.timestamp + 1 hours;

    signers[0] = guardian;
    signatures[0] = _signSetRequest(id, newRequest, deadline, GUARDIAN_PK);
    _setRequest(id, newRequest, deadline, signers, signatures);
  }

  /// @notice Calls setRequest as facilitator with explicit signature args.
  function _setRequest(
    uint256 id,
    address newRequest,
    uint256 deadline,
    address[] memory signers,
    bytes[] memory signatures
  ) internal {
    facility.setRequest(id, newRequest, deadline, signers, signatures);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTENT HELPERS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates default intent params with PositionManager as deposit asset
  function _defaultIntentProperties() internal view returns (IntentProperties memory) {
    return IntentProperties({
      depositAsset: Asset({asset: address(positionManager), isPositionManager: true}),
      targetAsset: Asset({asset: address(debtToken), isPositionManager: false}),
      depositCap: DEFAULT_DEPOSIT_CAP,
      guardKey: address(positionManager),
      resolveStart: uint40(block.timestamp + 1 days),
      quorum: 1,
      transferableIntent: true
    });
  }

  /// @notice Creates intent params with target as PositionManager
  function _intentParamsWithTargetPM() internal view returns (IntentProperties memory) {
    return IntentProperties({
      depositAsset: Asset({asset: address(debtToken), isPositionManager: false}),
      targetAsset: Asset({asset: address(positionManager), isPositionManager: true}),
      depositCap: DEFAULT_DEPOSIT_CAP,
      guardKey: address(positionManager),
      resolveStart: uint40(block.timestamp + 1 days),
      quorum: 1,
      transferableIntent: true
    });
  }

  /// @notice Creates intent params with both assets as PositionManagers
  function _intentParamsWithDualPM() internal view returns (IntentProperties memory) {
    return IntentProperties({
      depositAsset: Asset({asset: address(positionManager), isPositionManager: true}),
      targetAsset: Asset({asset: address(positionManager2), isPositionManager: true}),
      depositCap: DEFAULT_DEPOSIT_CAP,
      guardKey: address(positionManager),
      resolveStart: uint40(block.timestamp + 1 days),
      quorum: 2,
      transferableIntent: false
    });
  }

  /// @notice Creates an intent with default parameters and returns the ID
  function _createDefaultIntent() internal returns (uint256 intentId) {
    vm.prank(owner);
    intentId = facility.createIntent(_defaultIntentProperties());
  }

  /// @notice Creates an intent and moves it to resolving phase
  function _createResolvingIntent() internal returns (uint256 intentId) {
    intentId = _createDefaultIntent();
    // Move time past resolveStart
    vm.warp(block.timestamp + 1 days + 1);
  }

  /// @notice Creates an intent, deposits LP tokens, and moves to resolving
  function _createIntentWithDeposits(uint256 depositAmount) internal returns (uint256 intentId) {
    intentId = _createDefaultIntent();

    // Mint PM shares to user and deposit to facility
    _depositToPM(user, depositAmount);

    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    // Move to resolving phase
    vm.warp(block.timestamp + 1 days + 1);
  }

  /// @notice Helper to deposit to PositionManager and get shares
  /// @dev Uses the minter (which has MINTER_ROLE) to deposit, then transfers shares to user
  function _depositToPM(address _user, uint256 collateralAmount) internal returns (uint256 shares) {
    // Minter deposits collateral to PM
    _mintCollateral(minter, collateralAmount);

    vm.startPrank(minter);
    collateralToken.approve(address(positionManager), collateralAmount);
    int256 sharesSigned = positionManager.deposit(collateralAmount, 0);
    shares = uint256(sharesSigned);
    // Transfer shares to user
    positionManager.transfer(_user, shares);
    vm.stopPrank();

    // User approves facility to spend their shares
    vm.prank(_user);
    positionManager.approve(address(facility), type(uint256).max);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       VIEW HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _getIntent(uint256 id)
    internal
    view
    returns (IntentProperties memory properties, address fund, address request, bool resolved, uint40 requestSetAt)
  {
    return facility.getIntent(id);
  }

  function _isDepositing(uint256 id) internal view returns (bool) {
    (IntentProperties memory props,,, bool resolved,) = _getIntent(id);
    return !resolved && props.resolveStart > block.timestamp;
  }

  function _isResolving(uint256 id) internal view returns (bool) {
    (IntentProperties memory props,,, bool resolved,) = _getIntent(id);
    return props.resolveStart <= block.timestamp && !resolved;
  }

  function _isResolved(uint256 id) internal view returns (bool) {
    (,,, bool resolved,) = _getIntent(id);
    return resolved;
  }

  function test_empty() public pure {}
}
