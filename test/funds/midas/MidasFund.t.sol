// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {MidasFund} from "src/funds/midas/MidasFund.sol";
import {MidasFundFactory} from "src/funds/midas/MidasFundFactory.sol";
import {BondConfig} from "src/interfaces/funds/midas/IMidasFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockMidasDataFeed} from "../../mock/funds/midas/MockMidasDataFeed.sol";
import {MockMidasAccessControl} from "../../mock/funds/midas/MockMidasAccessControl.sol";
import {MockMidasDepositVault} from "../../mock/funds/midas/MockMidasDepositVault.sol";
import {MockMidasRedemptionVault} from "../../mock/funds/midas/MockMidasRedemptionVault.sol";
import {
  ReentrantMidasDepositVault,
  ReentrantMidasRedemptionVault
} from "../../mock/funds/midas/ReentrantMidasVaults.sol";
import {MockChainlinkOracle} from "../../mock/funds/MockChainlinkOracle.sol";

contract MidasFundTest is Test {
  using LibOrder for Order;

  error InvalidInitialization();
  error Unauthorized();

  event OrderCreated(
    bytes32 indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount, uint256 requestId);
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);
  event OrderRecovering(bytes32 indexed orderId);
  event OrderProcessing(bytes32 indexed orderId);
  event OrderResolved(bytes32 indexed orderId, uint256 newInput, uint256 newOutput, address indexed operator);
  event BondConfigUpdated(uint256 amount, address indexed recipient, address indexed operator);
  event BondPaid(bytes32 indexed orderId, uint256 amount, address indexed recipient);
  event InstantRedeemUnlocked(bytes32 indexed orderId, address indexed caller);
  event DepositVaultUpdated(address indexed depositVault, address indexed operator);
  event RedemptionVaultUpdated(address indexed redemptionVault, address indexed operator);
  event ReferrerIdUpdated(bytes32 referrerId, address indexed operator);
  event OracleUpdated(address indexed newOracle, address indexed operator);

  uint256 private constant ONE_USDC = 1e6;
  uint256 private constant ONE_MTOKEN = 1e18;
  uint256 private constant ASSET_SCALE = 1e12; // 10 ** (18 - 6)
  uint256 private constant BPS = 10_000;
  uint256 private constant BOND_BPS = 200; // 2%
  bytes4 private constant SEL_DEPOSIT_REQUEST = bytes4(keccak256("depositRequest(address,uint256,bytes32)"));
  bytes4 private constant SEL_REDEEM_INSTANT = bytes4(keccak256("redeemInstant(address,uint256,uint256)"));

  // MidasFund roles
  uint256 private constant OPERATOR_ROLE = 1 << 0;
  uint256 private constant DEPOSITOR_ROLE = 1 << 1;
  uint256 private constant PAYMENT_ROLE = 1 << 2;
  uint256 private constant VAULT_MANAGER_ROLE = 1 << 3;

  // WrappedAsset roles
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         TEST STATE                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MidasFundFactory public factory;
  MidasFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockERC20 public mGlobal;
  MockMidasAccessControl public midasAcl;
  MockMidasDataFeed public depositMTokenFeed;
  MockMidasDataFeed public depositAssetFeed;
  MockMidasDataFeed public redemptionMTokenFeed;
  MockMidasDataFeed public redemptionAssetFeed;
  MockMidasDepositVault public depositVault;
  MockMidasRedemptionVault public redemptionVault;
  MockChainlinkOracle public oracle;

  address public owner;
  address public operator;
  address public paymentOperator;
  address public vaultManager;
  address public bondRecipient;
  address public outsider;

  function setUp() public {
    owner = makeAddr("owner");
    operator = makeAddr("operator");
    paymentOperator = makeAddr("paymentOperator");
    vaultManager = makeAddr("vaultManager");
    bondRecipient = makeAddr("bondRecipient");
    outsider = makeAddr("outsider");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    mGlobal = new MockERC20("Midas Global", "mGLOBAL", 18);
    midasAcl = new MockMidasAccessControl();
    depositMTokenFeed = new MockMidasDataFeed();
    depositAssetFeed = new MockMidasDataFeed();
    redemptionMTokenFeed = new MockMidasDataFeed();
    redemptionAssetFeed = new MockMidasDataFeed();
    oracle = new MockChainlinkOracle(8);
    oracle.setRoundData(1, int256(1e8), block.timestamp, 1);
    oracle.setLatestRound(1);

    depositVault = new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    redemptionVault = new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    depositVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);
    redemptionVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(mGlobal), "wmGLOBAL", "Wrapped mGLOBAL");

    factory = new MidasFundFactory(owner);
    address fundAddress = factory.createFund(
      owner, address(this), address(depositVault), address(wrappedShare), address(usdc), address(oracle)
    );
    fund = MidasFund(fundAddress);

    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);

    vm.prank(owner);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);

    vm.prank(owner);
    fund.grantRoles(paymentOperator, PAYMENT_ROLE);

    vm.prank(owner);
    fund.grantRoles(vaultManager, VAULT_MANAGER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_Success() public view {
    assertEq(fund.owner(), owner, "owner");
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.mToken(), address(mGlobal), "mToken");
    assertEq(fund.depositVault(), address(depositVault), "deposit vault");
    // No redemption vault at initialization: Midas deploys a dedicated one per redemption.
    assertEq(fund.redemptionVault(), address(0), "no redemption vault");
    assertEq(fund.activeRequestId(), 0, "active request id");
    assertEq(fund.referrerId(), bytes32(0), "referrer id");
    assertEq(fund.rolesOf(address(this)), DEPOSITOR_ROLE, "depositor role");
    assertEq(uint256(fund.state(_depositOrder(ONE_USDC, ONE_MTOKEN))), uint256(State.EMPTY), "initial state");
  }

  function test_Initialize_RevertsInvalidOwner() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(CommonErrors.AddressZero.selector);
    MidasFund(fundProxy)
      .initialize(
        address(0), address(this), address(depositVault), address(wrappedShare), address(usdc), address(oracle)
      );
  }

  function test_Initialize_RevertsInvalidDepositor() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(owner, address(0xBEEF), address(depositVault), address(wrappedShare), address(usdc), address(oracle));
  }

  function test_Initialize_RevertsInvalidDepositVault() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(0xBEEF), address(wrappedShare), address(usdc), address(oracle));
  }

  function test_Initialize_RevertsInvalidWrappedShare() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(depositVault), address(0xBEEF), address(usdc), address(oracle));
  }

  function test_Initialize_RevertsInvalidAsset() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(depositVault), address(wrappedShare), address(0xBEEF), address(oracle));
  }

  function test_Initialize_RevertsInvalidOracleContract() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(depositVault), address(wrappedShare), address(usdc), address(0xBEEF));
  }

  function test_Initialize_RevertsInvalidOracleDecimals() public {
    MockChainlinkOracle invalidOracle = new MockChainlinkOracle(18);
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOracle.selector, address(invalidOracle)));
    MidasFund(fundProxy)
      .initialize(
        owner, address(this), address(depositVault), address(wrappedShare), address(usdc), address(invalidOracle)
      );
  }

  function test_Initialize_RevertsWrappedShareMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    WrappedAsset badWrappedShare = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    badWrappedShare.initialize(owner, owner, address(otherToken), "bad", "Bad");

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(depositVault), address(badWrappedShare), address(usdc), address(oracle));
  }

  function test_Initialize_RevertsMTokenDecimalsMismatch() public {
    MockERC20 mToken8 = new MockERC20("Midas 8", "M8", 8);
    MockMidasDepositVault depositVault8 =
      new MockMidasDepositVault(address(mToken8), address(depositMTokenFeed), address(midasAcl));
    WrappedAsset wrappedShare8 = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    wrappedShare8.initialize(owner, owner, address(mToken8), "wM8", "Wrapped M8");

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.DecimalsMismatch.selector, 8, 18));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(depositVault8), address(wrappedShare8), address(usdc), address(oracle));
  }

  function test_Initialize_RevertsAssetDecimalsTooHigh() public {
    MockERC20 asset20 = new MockERC20("Asset 20", "A20", 20);

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.DecimalsMismatch.selector, 20, 18));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(depositVault), address(wrappedShare), address(asset20), address(oracle));
  }

  function test_Initialize_RevertsTokenNotSupportedOnDepositVault() public {
    MockMidasDepositVault bareDepositVault =
      new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.TokenNotSupported.selector, address(usdc)));
    MidasFund(fundProxy)
      .initialize(
        owner, address(this), address(bareDepositVault), address(wrappedShare), address(usdc), address(oracle)
      );
  }

  function test_Initialize_OnlyOnce() public {
    vm.expectRevert(InvalidInitialization.selector);
    fund.initialize(owner, address(this), address(depositVault), address(wrappedShare), address(usdc), address(oracle));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           CREATE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Create_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    State state = fund.create(order);

    assertEq(uint256(state), uint256(State.ACCEPTED), "state");
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "order state");
  }

  function test_Create_RedeemSuccess() public {
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit OrderCreated(orderId, order.mode, order.owner, order.receiver, order.input, order.output);
    State state = fund.create(order);

    assertEq(uint256(state), uint256(State.ACCEPTED), "state");
    // Every redeem follows the bond flow: locked until unlockInstantRedeem().
    assertFalse(fund.instantRedeemUnlocked(), "redeem locked at create");
  }

  function test_Create_ResetsRedemptionVault() public {
    // A previously configured redemption vault is dropped on create: each redemption settles
    // through a fresh vault set via setRedemptionVault() while the redeem is live.
    _setRedemptionVault();
    assertEq(fund.redemptionVault(), address(redemptionVault), "vault set");

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    vm.expectEmit(true, true, true, true);
    emit RedemptionVaultUpdated(address(0), address(this));
    fund.create(order);
    assertEq(fund.redemptionVault(), address(0), "vault reset by create");

    // Deposit creates reset it too.
    fund.cancel(order);
    _setRedemptionVault();
    Order memory depositOrder = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(depositOrder);
    assertEq(fund.redemptionVault(), address(0), "vault reset by deposit create");
  }

  function test_Create_RevertsAmountZero() public {
    Order memory order = _depositOrder(0, ONE_MTOKEN);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    order.owner = outsider;
    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidReceiver() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    order.receiver = outsider;
    vm.expectRevert(LibFundsErrors.InvalidReceiver.selector);
    fund.create(order);
  }

  function test_Create_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.create(order);
  }

  function test_Create_RevertsPendingOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    // Already ACCEPTED
    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(order);

    // Commit to PROCESSING
    _commitDeposit(order);

    vm.expectRevert(LibFundsErrors.PendingOrder.selector);
    fund.create(order);
  }

  function test_Create_RevertsOrderAlreadyExists() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);
    _approveDepositRequest();
    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");

    // Create a different order to trigger archiving of the ended order
    Order memory nextOrder = _depositOrder(ONE_USDC * 2, ONE_MTOKEN * 2);
    fund.create(nextOrder);
    _commitDeposit(nextOrder);
    _approveDepositRequest();
    fund.unlock(nextOrder);

    // Now try to create a new order with the same params as the first (already archived) order
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.OrderAlreadyExists.selector, order.toId(address(fund))));
    fund.create(order);
  }

  function test_Create_AfterEndedOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);
    _approveDepositRequest();
    fund.unlock(order);

    Order memory nextOrder = _depositOrder(ONE_USDC * 2, ONE_MTOKEN * 2);
    State state = fund.create(nextOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  function test_Create_RevertsDepositVaultPaused() public {
    depositVault.setPaused(true);
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    vm.expectRevert(LibFundsErrors.MidasVaultPaused.selector);
    fund.create(order);

    // Redeem creates are not gated on the deposit vault's pause state: still accepted.
    Order memory redeemOrder = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    State state = fund.create(redeemOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "redeem accepted");
  }

  function test_Create_RevertsDepositRequestPaused() public {
    depositVault.setFnPaused(SEL_DEPOSIT_REQUEST, true);
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.MidasVaultFunctionPaused.selector, SEL_DEPOSIT_REQUEST));
    fund.create(order);

    // Redeem creates are not pre-checked (their vault does not exist yet): still accepted.
    Order memory redeemOrder = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    State state = fund.create(redeemOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "redeem accepted");
  }

  function test_Create_RedeemNotGatedOnRedemptionVault() public {
    // Redeems cannot be pre-checked at create: their dedicated vault does not exist yet.
    // Even a paused previously-configured vault does not block create (it is dropped anyway).
    _setRedemptionVault();
    redemptionVault.setPaused(true);
    redemptionVault.setFnPaused(SEL_REDEEM_INSTANT, true);

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "redeem accepted");
    assertEq(fund.redemptionVault(), address(0), "stale vault dropped");
  }

  function test_Create_Greenlist_RevertsFundNotGreenlisted() public {
    depositVault.setGreenlistEnabled(true);
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    vm.expectRevert(LibFundsErrors.NotAllowedByFund.selector);
    fund.create(order);
  }

  function test_Create_Greenlist_RevertsWrappedShareNotGreenlisted() public {
    depositVault.setGreenlistEnabled(true);
    midasAcl.setRole(depositVault.greenlistedRole(), address(fund), true);

    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    vm.expectRevert(LibFundsErrors.WrappedShareNotPermissioned.selector);
    fund.create(order);
  }

  function test_Create_Greenlist_SucceedsWhenBothGreenlisted() public {
    depositVault.setGreenlistEnabled(true);
    midasAcl.setRole(depositVault.greenlistedRole(), address(fund), true);
    midasAcl.setRole(depositVault.greenlistedRole(), address(wrappedShare), true);

    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  function test_Create_RevertsInvalidOutput_Deposit() public {
    // At 1:1 rates, depositing ONE_USDC should yield ONE_MTOKEN.
    // Setting output to ONE_MTOKEN / 2 is a 50% deviation — well beyond the 10% max.
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN / 2);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  function test_Create_Redeem_OutputNotFeedValidated() public {
    // Redeem outputs are not oracle-validated at create: the per-redemption vault (and its
    // redemption-side pricing) does not exist yet. The output is the minimum payout enforced
    // on-chain by redeemInstant when the redeem leg commits.
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC / 2);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "low output accepted");
  }

  function test_Create_AcceptsOutputWithinDeviation() public {
    // 90% of ONE_MTOKEN is within the 10% max deviation.
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN * 90 / 100);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted within deviation");
  }

  function test_Create_AcceptsOutputAboveRate() public {
    // Output above the expected rate should always succeed (no upper bound check).
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN * 2);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted above rate");
  }

  function test_Create_Deposit_UsesOracleAndIgnoresVaultFeeds() public {
    // Vault-side mToken rates do not affect the fund's create-time sanity check.
    depositMTokenFeed.setRate(100e18);
    redemptionMTokenFeed.setRate(100e18);
    // Oracle price 2 USD: expected output = 0.5e18 mToken per USDC.
    oracle.setRoundData(2, int256(2e8), block.timestamp, 2);
    oracle.setLatestRound(2);

    Order memory tooLow = _depositOrder(ONE_USDC, 0.4e18);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(tooLow);

    Order memory withinDeviation = _depositOrder(ONE_USDC, 0.45e18); // 90% of 0.5e18
    State state = fund.create(withinDeviation);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  function test_Create_Redeem_IgnoresAllFeeds() public {
    // Redeem creation reads no data feed: absurd rates on either side change nothing (the
    // deposit-side check only applies to DEPOSIT orders).
    depositMTokenFeed.setRate(100e18);
    redemptionMTokenFeed.setRate(100e18);

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted regardless of feeds");
  }

  function test_Create_AssumesPaymentAssetIsOneUsd() public {
    // Vault payment-token pricing is ignored even when the token is flagged as non-stable.
    depositVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, false);
    depositAssetFeed.setRate(2e18);

    Order memory tooLow = _depositOrder(ONE_USDC, ONE_MTOKEN * 89 / 100);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(tooLow);

    Order memory matching = _depositOrder(ONE_USDC, ONE_MTOKEN);
    State state = fund.create(matching);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  function test_Create_RevertsChainlinkInvalidAnswer() public {
    oracle.setRoundData(2, 0, block.timestamp, 2);
    oracle.setLatestRound(2);
    vm.expectRevert(LibFundsErrors.ChainlinkInvalidAnswer.selector);
    fund.create(_depositOrder(ONE_USDC, ONE_MTOKEN));
  }

  function test_Create_RevertsChainlinkIncompleteRound() public {
    oracle.setRoundData(2, int256(1e8), 0, 2);
    oracle.setLatestRound(2);
    vm.expectRevert(LibFundsErrors.ChainlinkIncompleteRound.selector);
    fund.create(_depositOrder(ONE_USDC, ONE_MTOKEN));
  }

  function test_Create_RevertsChainlinkStaleRound() public {
    oracle.setRoundData(2, int256(1e8), block.timestamp, 1);
    oracle.setLatestRound(2);
    vm.expectRevert(LibFundsErrors.ChainlinkStaleRound.selector);
    fund.create(_depositOrder(ONE_USDC, ONE_MTOKEN));
  }

  function test_Create_AcceptsOldCompletedOracleRound() public {
    oracle.setRoundData(2, int256(1e8), 1, 2);
    oracle.setLatestRound(2);
    assertEq(uint256(fund.create(_depositOrder(ONE_USDC, ONE_MTOKEN))), uint256(State.ACCEPTED), "accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           CANCEL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Cancel_Success() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    bytes32 orderId = order.toId(address(fund));
    fund.create(order);

    vm.expectEmit(true, true, true, true);
    emit OrderCanceled(orderId, order.mode, order.owner);
    State state = fund.cancel(order);
    assertEq(uint256(state), uint256(State.EMPTY), "state");
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "order state");

    // Can create again after cancel
    State next = fund.create(order);
    assertEq(uint256(next), uint256(State.ACCEPTED), "accepted");
  }

  function test_Cancel_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.cancel(wrongOrder);
  }

  function test_Cancel_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.cancel(order);
  }

  function test_Cancel_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.cancel(order);
  }

  function test_Cancel_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.cancel(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           COMMIT                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Commit_DepositRequestSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderCommitted(orderId, order.mode, order.input, 1);
    (State state, uint256 amount) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(amount, order.input, "amount");
    assertEq(fund.activeRequestId(), 1, "request id stored");
    // USDC pulled into the deposit vault (native decimals)...
    assertEq(usdc.balanceOf(address(depositVault)), order.input, "vault has usdc");
    // ...but no mToken is minted until the Midas admin approves the request.
    assertEq(mGlobal.balanceOf(address(fund)), 0, "no mToken yet");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing while request pending");
  }

  function test_Commit_DepositBlocksReentrantCommit() public {
    ReentrantMidasDepositVault reentrantVault =
      new ReentrantMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    reentrantVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);

    vm.prank(vaultManager);
    fund.setDepositVault(address(reentrantVault));
    vm.prank(owner);
    fund.grantRoles(address(reentrantVault), DEPOSITOR_ROLE);

    Order memory order = Order({
      mode: Mode.DEPOSIT,
      owner: address(reentrantVault),
      receiver: address(reentrantVault),
      input: ONE_USDC,
      output: ONE_MTOKEN,
      salt: keccak256("reentrant-deposit")
    });

    vm.prank(address(reentrantVault));
    fund.create(order);

    usdc.mint(address(reentrantVault), order.input * 2);
    vm.prank(address(reentrantVault));
    usdc.approve(address(fund), type(uint256).max);
    reentrantVault.setReentrantCommit(fund, order);

    vm.prank(address(reentrantVault));
    fund.commit(order);

    assertFalse(reentrantVault.reenterSucceeded(), "reentrant commit blocked");
    assertEq(reentrantVault.reenterRevertSelector(), LibFundsErrors.InvalidState.selector, "blocked by state");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "outer commit processing");
    assertEq(fund.activeRequestId(), 1, "single request stored");
  }

  function test_Commit_RedeemInstantSuccess() public {
    _depositAndUnlock(ONE_USDC);

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    // Skip the bond leg (nothing required for this redemption) and point the fund at the
    // vault deployed for this redemption.
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    wrappedShare.approve(address(fund), order.input);

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderCommitted(orderId, order.mode, order.input, 0);
    (State state, uint256 amount) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "state");
    assertEq(amount, order.input, "amount");
    // Wrapped shares burned from the depositor
    assertEq(wrappedShare.balanceOf(address(this)), 0, "wrapper burned");
    // mToken redeemed (burned) by the vault
    assertEq(mGlobal.balanceOf(address(fund)), 0, "mToken redeemed");
    // Asset delivered synchronously to the fund...
    assertEq(usdc.balanceOf(address(fund)), ONE_USDC, "fund has usdc");
    // ...and immediately claimable in full.
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable right away");
  }

  function test_Commit_RedeemBlocksReentrantCommit() public {
    _depositAndUnlock(ONE_USDC);

    ReentrantMidasRedemptionVault reentrantVault =
      new ReentrantMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    reentrantVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);

    vm.prank(owner);
    fund.grantRoles(address(reentrantVault), DEPOSITOR_ROLE);
    wrappedShare.transfer(address(reentrantVault), ONE_MTOKEN);

    Order memory order = Order({
      mode: Mode.REDEEM,
      owner: address(reentrantVault),
      receiver: address(reentrantVault),
      input: ONE_MTOKEN,
      output: ONE_USDC,
      salt: keccak256("reentrant-redeem")
    });

    vm.prank(address(reentrantVault));
    fund.create(order);
    _unlockInstantRedeem(order);
    vm.prank(vaultManager);
    fund.setRedemptionVault(address(reentrantVault));

    vm.prank(address(reentrantVault));
    wrappedShare.approve(address(fund), type(uint256).max);
    reentrantVault.setReentrantCommit(fund, order);

    vm.prank(address(reentrantVault));
    fund.commit(order);

    assertFalse(reentrantVault.reenterSucceeded(), "reentrant commit blocked");
    assertEq(reentrantVault.reenterRevertSelector(), LibFundsErrors.InvalidState.selector, "blocked by state");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "outer commit settled");
  }

  function test_Commit_RedeemLeg_RevertsWhenVaultNotSet() public {
    _depositAndUnlock(ONE_USDC);

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    _unlockInstantRedeem(order);

    // create() reset the redemption vault and nobody configured this redemption's vault yet.
    wrappedShare.approve(address(fund), order.input);
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0)));
    fund.commit(order);

    // Configuring the vault releases the redeem leg.
    _setRedemptionVault();
    fund.commit(order);
    assertEq(usdc.balanceOf(address(fund)), ONE_USDC, "settled once the vault is set");
  }

  function test_Commit_RedeemLeg_RevertsWhenVaultUnderpays() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);
    _setRedemptionVault();

    // The vault claims success but pays less than the order's minimum scaled to the non-bond
    // remainder: the fund's own received-balance check catches it.
    uint256 redeemAmount = ONE_MTOKEN - ONE_MTOKEN * BOND_BPS / BPS;
    uint256 minOutput = ONE_USDC * redeemAmount / ONE_MTOKEN;
    redemptionVault.setPayoutOverride(minOutput - 1);
    wrappedShare.approve(address(fund), order.input);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InsufficientRedeemOutput.selector, minOutput - 1, minOutput));
    fund.commit(order);
  }

  function test_Commit_RedeemLeg_AcceptsExactMinimumPayout() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);
    _setRedemptionVault();

    // Exactly the scaled minimum passes the fund-side check.
    uint256 redeemAmount = ONE_MTOKEN - ONE_MTOKEN * BOND_BPS / BPS;
    uint256 minOutput = ONE_USDC * redeemAmount / ONE_MTOKEN;
    redemptionVault.setPayoutOverride(minOutput);
    _commitRedeem(order);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "settled at the exact minimum");
    assertEq(usdc.balanceOf(address(fund)), minOutput, "minimum payout held");
  }

  function test_Commit_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.commit(wrongOrder);
  }

  function test_Commit_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    // Not created yet
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, order.toId(address(fund))));
    fund.commit(order);

    fund.create(order);
    _commitDeposit(order);

    // Already PROCESSING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.commit(order);
  }

  function test_Commit_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsWhenVaultPausedAfterCreate() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    depositVault.setPaused(true);

    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);
    vm.expectRevert(LibFundsErrors.MidasVaultPaused.selector);
    fund.commit(order);
  }

  function test_Commit_RevertsWhenDepositRequestPausedAfterCreate() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    depositVault.setFnPaused(SEL_DEPOSIT_REQUEST, true);

    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.MidasVaultFunctionPaused.selector, SEL_DEPOSIT_REQUEST));
    fund.commit(order);
  }

  function test_Commit_RevertsWhenRedeemInstantPausedAfterVaultSet() public {
    _depositAndUnlock(ONE_USDC);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    _unlockInstantRedeem(order);
    _setRedemptionVault();

    redemptionVault.setFnPaused(SEL_REDEEM_INSTANT, true);

    wrappedShare.approve(address(fund), order.input);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.MidasVaultFunctionPaused.selector, SEL_REDEEM_INSTANT));
    fund.commit(order);
  }

  function test_Commit_Greenlist_RevertsWhenRevokedAfterCreate() public {
    depositVault.setGreenlistEnabled(true);
    midasAcl.setRole(depositVault.greenlistedRole(), address(fund), true);
    midasAcl.setRole(depositVault.greenlistedRole(), address(wrappedShare), true);

    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    midasAcl.setRole(depositVault.greenlistedRole(), address(fund), false);
    vm.expectRevert(LibFundsErrors.NotAllowedByFund.selector);
    fund.commit(order);

    midasAcl.setRole(depositVault.greenlistedRole(), address(fund), true);
    midasAcl.setRole(depositVault.greenlistedRole(), address(wrappedShare), false);
    vm.expectRevert(LibFundsErrors.WrappedShareNotPermissioned.selector);
    fund.commit(order);
  }

  function test_Commit_DepositClearsApproval() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);

    assertEq(usdc.allowance(address(fund), address(depositVault)), 0, "approval cleared");
  }

  function test_Commit_RedeemClearsApproval() public {
    _commitRedeemOrder();

    assertEq(mGlobal.allowance(address(fund), address(redemptionVault)), 0, "approval cleared");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       DEPOSIT REQUEST                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_State_DepositRequest_ApprovedBecomesUnlocking() public {
    Order memory order = _createAndCommitDeposit();

    depositVault.approveDepositRequest(fund.activeRequestId());

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after approval");
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_MTOKEN, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), ONE_MTOKEN, "wrapper minted");
  }

  function test_State_DepositRequest_ApprovalBelowOutputStaysProcessing() public {
    Order memory order = _createAndCommitDeposit();

    // Approval at a worse NAV rate delivers less than the order output threshold.
    depositVault.approveDepositRequestWithAmount(fund.activeRequestId(), ONE_MTOKEN / 2);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing below threshold");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);

    // The operator resolves the delivered amount, releasing the order.
    vm.prank(owner);
    fund.resolve(order, ONE_USDC, ONE_MTOKEN / 2);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after resolve");
    (, uint256 amount) = fund.unlock(order);
    assertEq(amount, ONE_MTOKEN / 2, "delivered amount unlocked");
  }

  function test_State_DepositRequest_RejectedThenRefund() public {
    Order memory order = _createAndCommitDeposit();

    depositVault.rejectDepositRequest(fund.activeRequestId());

    // Rejected but no refund received yet → still PROCESSING
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing before refund");

    // Midas admin refunds the input off-band
    depositVault.withdrawToken(address(usdc), address(fund), ONE_USDC);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering after refund");

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderRecovered(orderId, order.mode, ONE_USDC, address(this));
    (State state, uint256 amount) = fund.recover(order);

    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_USDC, "amount");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "usdc returned");
  }

  function test_ActiveRequestId_TracksRequests() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    assertEq(fund.activeRequestId(), 0, "zero after create");

    _commitDeposit(order);
    assertEq(fund.activeRequestId(), 1, "first request");

    depositVault.approveDepositRequest(1);
    fund.unlock(order);
    assertEq(fund.activeRequestId(), 1, "kept after unlock");

    // The next create resets the request id; the next commit stores a fresh one.
    Order memory nextOrder = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("second"));
    fund.create(nextOrder);
    assertEq(fund.activeRequestId(), 0, "reset by next create");

    usdc.mint(address(this), nextOrder.input);
    usdc.approve(address(fund), nextOrder.input);
    fund.commit(nextOrder);
    assertEq(fund.activeRequestId(), 2, "second request");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           UNLOCK                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Unlock_DepositSuccess() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);
    _approveDepositRequest();

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, ONE_MTOKEN, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, ONE_MTOKEN, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), ONE_MTOKEN, "wrapper minted");
    assertEq(mGlobal.balanceOf(address(wrappedShare)), ONE_MTOKEN, "mToken wrapped");
    assertEq(mGlobal.balanceOf(address(fund)), 0, "fund holds no mToken");
  }

  function test_Unlock_RedeemSuccess() public {
    Order memory order = _commitRedeemOrder();

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, ONE_USDC, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, ONE_USDC, "amount");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "usdc received");
  }

  function test_Unlock_UnlocksFullBalance() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);

    // An off-band mToken airdrop arrives at the fund; unlock sweeps the full balance.
    uint256 extra = ONE_MTOKEN / 2;
    mGlobal.mint(address(fund), extra);

    // Still gated: the balance alone does not release the order while the request is pending.
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing despite balance");
    _approveDepositRequest();

    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "state");
    assertEq(amount, ONE_MTOKEN + extra, "full balance unlocked");
    assertEq(wrappedShare.balanceOf(address(this)), ONE_MTOKEN + extra, "wrapper covers full balance");
  }

  function test_Unlock_DepositClearsApproval() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);
    _approveDepositRequest();
    fund.unlock(order);

    assertEq(mGlobal.allowance(address(fund), address(wrappedShare)), 0, "approval consumed");
  }

  function test_Unlock_RevertsWhileRequestPending() public {
    Order memory order = _createAndCommitDeposit();

    // PROCESSING (request still PENDING), not UNLOCKING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);
  }

  function test_Unlock_RevertsInvalidOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.unlock(wrongOrder);
  }

  function test_Unlock_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    // ACCEPTED, not UNLOCKING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.unlock(order);
  }

  function test_Unlock_OnlyDepositorRole() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.unlock(order);
  }

  function test_Unlock_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.unlock(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          RECOVER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Recover_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    // ACCEPTED, not RECOVERING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.recover(order);

    _commitDeposit(order);

    // PROCESSING (request pending), not RECOVERING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.recover(order);

    _approveDepositRequest();

    // UNLOCKING (request approved), not RECOVERING
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.UNLOCKING));
    fund.recover(order);
  }

  function test_Recover_RevertsInvalidOrder() public {
    Order memory order = _createAndCommitDeposit();

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.recover(wrongOrder);
  }

  function test_Recover_OnlyDepositorRole() public {
    Order memory order = _createAndCommitDeposit();

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.recover(order);
  }

  function test_Recover_RevertsInvalidOwner() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    order.owner = outsider;

    vm.expectRevert(LibFundsErrors.InvalidOwner.selector);
    fund.recover(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 RECOVERING / CANCEL RECOVERING             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Recovering_Success() public {
    Order memory order = _createAndCommitDeposit();
    bytes32 orderId = order.toId(address(fund));

    // Input returned off-band while the request is still PENDING (never rejected on-chain).
    depositVault.withdrawToken(address(usdc), address(fund), ONE_USDC);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "still processing");

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderRecovering(orderId);
    fund.recovering(order);

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering");

    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_USDC, "amount");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "usdc returned");
  }

  function test_Recovering_FallsBackToProcessingWithoutBalance() public {
    Order memory order = _createAndCommitDeposit();

    vm.prank(owner);
    fund.recovering(order);

    // No refund received: the dynamic state falls back to PROCESSING.
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing without balance");
  }

  function test_Recovering_RevertsInvalidOrder() public {
    Order memory order = _createAndCommitDeposit();

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.recovering(wrongOrder);
  }

  function test_Recovering_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.recovering(order);
  }

  function test_Recovering_RevertsForSettledDeposit() public {
    // A settled deposit (mint request approved, mTokens claimable) completes forward via
    // unlock(): flagging it would only park the payout.
    Order memory order = _createAndCommitDeposit();
    _approveDepositRequest();
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "claimable");

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.UNLOCKING));
    fund.recovering(order);

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_MTOKEN, "payout claimed");
  }

  function test_Recovering_ApprovedWhileRecovering_CancelRestoresUnlock() public {
    // The guard cannot see an approval that lands after flagging: the order then reports
    // PROCESSING (asset balance short of the input) and parks until cancelRecovering().
    Order memory order = _createAndCommitDeposit();
    vm.prank(owner);
    fund.recovering(order);
    _approveDepositRequest();

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "parked");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);

    // cancelRecovering() restores the stored PROCESSING state and the claimable payout.
    vm.prank(owner);
    fund.cancelRecovering(order.toId(address(fund)));
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "claimable again");
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_MTOKEN, "payout claimed");
  }

  function test_Recovering_RevertsForSettledRedeem() public {
    // A settled redeem already received its payout irreversibly via redeemInstant: it must
    // be completed via the terminal unlock().
    Order memory order = _commitRedeemOrder();

    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recovering(order);

    // The order completes forward: the proceeds stay claimable.
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable");
    (State state,) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
  }

  function test_Recovering_OnlyOwnerOrOperator() public {
    Order memory order = _createAndCommitDeposit();

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.recovering(order);

    // Depositor (address(this)) cannot either
    vm.expectRevert(Unauthorized.selector);
    fund.recovering(order);

    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    fund.recovering(order);
  }

  function test_CancelRecovering_Success() public {
    Order memory order = _createAndCommitDeposit();
    bytes32 orderId = order.toId(address(fund));

    vm.prank(owner);
    fund.recovering(order);

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderProcessing(orderId);
    fund.cancelRecovering(orderId);

    // Back to PROCESSING; the request can still be approved and unlocked.
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing after cancel");
    _approveDepositRequest();
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after approval");
  }

  function test_CancelRecovering_RevertsInvalidOrder() public {
    Order memory order = _createAndCommitDeposit();

    vm.prank(owner);
    fund.recovering(order);

    bytes32 wrongOrderId = keccak256("wrong");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrderId));
    fund.cancelRecovering(wrongOrderId);
  }

  function test_CancelRecovering_RevertsInvalidState() public {
    Order memory order = _createAndCommitDeposit();
    bytes32 orderId = order.toId(address(fund));

    // Internal state is PROCESSING, not RECOVERING
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.cancelRecovering(orderId);
  }

  function test_CancelRecovering_OnlyOwnerOrOperator() public {
    Order memory order = _createAndCommitDeposit();
    bytes32 orderId = order.toId(address(fund));

    vm.prank(owner);
    fund.recovering(order);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.cancelRecovering(orderId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          RESOLVE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Resolve_Success() public {
    Order memory order = _createAndCommitDeposit();
    bytes32 orderId = order.toId(address(fund));

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderResolved(orderId, ONE_USDC / 2, ONE_MTOKEN / 2, owner);
    fund.resolve(order, ONE_USDC / 2, ONE_MTOKEN / 2);
  }

  function test_Resolve_RevertsInvalidState() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    // ACCEPTED, not PROCESSING/RECOVERING
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.resolve(order, ONE_USDC, ONE_MTOKEN);
  }

  function test_Resolve_RevertsInvalidOrder() public {
    Order memory order = _createAndCommitDeposit();

    Order memory wrongOrder = order;
    wrongOrder.salt = keccak256("wrong");

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrder.toId(address(fund))));
    fund.resolve(wrongOrder, ONE_USDC, ONE_MTOKEN);
  }

  function test_Resolve_RevertsZeroInput() public {
    Order memory order = _createAndCommitDeposit();

    vm.prank(owner);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    fund.resolve(order, 0, ONE_MTOKEN);
  }

  function test_Resolve_OnlyOwnerOrOperator() public {
    Order memory order = _createAndCommitDeposit();

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.resolve(order, ONE_USDC, ONE_MTOKEN);

    // Depositor (address(this)) cannot resolve either
    vm.expectRevert(Unauthorized.selector);
    fund.resolve(order, ONE_USDC, ONE_MTOKEN);

    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    fund.resolve(order, ONE_USDC, ONE_MTOKEN);
  }

  function test_Resolve_RaisedThresholdKeepsProcessing() public {
    Order memory order = _createAndCommitDeposit();
    _approveDepositRequest();
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking before resolve");

    // Raising the output threshold above the delivered balance parks the order in PROCESSING.
    vm.prank(owner);
    fund.resolve(order, ONE_USDC, ONE_MTOKEN * 2);

    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing after resolve");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);
  }

  function test_Resolve_MultipleTimesOverrides() public {
    Order memory order = _createAndCommitDeposit();
    _approveDepositRequest();

    // First resolution keeps the order stuck (threshold above balance)
    vm.prank(owner);
    fund.resolve(order, ONE_USDC, ONE_MTOKEN * 3);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "still processing");

    // Second resolution overrides the first
    vm.prank(owner);
    fund.resolve(order, ONE_USDC, ONE_MTOKEN);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    (, uint256 amount) = fund.unlock(order);
    assertEq(amount, ONE_MTOKEN, "delivered amount unlocked");
  }

  function test_Resolve_PartialRefundRecovery() public {
    Order memory order = _createAndCommitDeposit();

    vm.prank(owner);
    fund.recovering(order);

    // Partial off-band refund: half the input
    depositVault.withdrawToken(address(usdc), address(fund), ONE_USDC / 2);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing on partial refund");

    vm.prank(owner);
    fund.resolve(order, ONE_USDC / 2, 0);

    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering after resolve");
    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_USDC / 2, "partial amount recovered");
  }

  function test_Resolve_AllowedInRecoveringState() public {
    Order memory order = _createAndCommitDeposit();

    vm.prank(owner);
    fund.recovering(order);

    vm.prank(owner);
    fund.resolve(order, ONE_USDC / 2, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REDEEM SETTLEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Unlock_Redeem_SingleShot() public {
    Order memory order = _commitRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    // The instant redemption already delivered the output; it is claimable right away.
    assertEq(usdc.balanceOf(address(fund)), ONE_USDC, "fund has usdc");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "claimable");

    // The unlock sweeps the full balance and ends the order.
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, ONE_USDC, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_USDC, "proceeds swept");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "usdc received");

    // Single-shot: a second unlock fails on the state guard.
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ENDED));
    fund.unlock(order);
  }

  function test_Unlock_Redeem_SweepsDonationWithProceeds() public {
    Order memory order = _commitRedeemOrder();

    // Extra payment tokens landing before the unlock are swept together with the proceeds.
    uint256 extra = ONE_USDC * 7 / 100;
    usdc.mint(address(fund), extra);

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_USDC + extra, "full balance swept");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC + extra, "proceeds + extra received");
  }

  function test_Unlock_Redeem_ZeroProceedsFinalizes() public {
    _depositAndUnlock(ONE_USDC);

    // A dust redeem whose proceeds floor to zero in native decimals (999 wei of mToken
    // < 1e12, the USDC scale): the order is still UNLOCKING and the terminal unlock
    // finalizes with a zero amount (no transfer).
    Order memory order = _redeemOrder(999, 0);
    fund.create(order);
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order);

    assertEq(usdc.balanceOf(address(fund)), 0, "zero proceeds");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking at zero balance");

    bytes32 orderId = order.toId(address(fund));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, 0, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "ended by the terminal unlock");
    assertEq(amount, 0, "zero-amount finalization");
    assertEq(usdc.balanceOf(address(this)), 0, "no transfer");
  }

  function test_Create_SucceedsAfterRedeemEnded() public {
    Order memory order = _commitRedeemOrder();
    fund.unlock(order);

    Order memory nextOrder = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("after-redeem"));
    fund.create(nextOrder);

    // Old order was archived — state() returns ENDED
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "old order ENDED (archived)");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  function test_Resolve_DoesNotAffectRedeemState() public {
    Order memory order = _commitRedeemOrder();

    // Resolved amounts do not gate redeems: even an output threshold above the balance
    // leaves the full proceeds claimable.
    vm.prank(owner);
    fund.resolve(order, ONE_MTOKEN, ONE_USDC * 2);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "claimable despite resolved output");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_USDC, "available balance swept");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        VAULT ADMIN                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_SetDepositVault_Success() public {
    MockMidasDepositVault newVault =
      new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);

    vm.prank(vaultManager);
    vm.expectEmit(true, true, true, true);
    emit DepositVaultUpdated(address(newVault), vaultManager);
    fund.setDepositVault(address(newVault));

    assertEq(fund.depositVault(), address(newVault), "deposit vault updated");
  }

  function test_SetDepositVault_RevertsWhenVaultPaused() public {
    MockMidasDepositVault newVault =
      new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);
    newVault.setPaused(true);

    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.MidasVaultPaused.selector);
    fund.setDepositVault(address(newVault));
  }

  function test_SetDepositVault_RevertsWhenDepositRequestPaused() public {
    MockMidasDepositVault newVault =
      new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);
    newVault.setFnPaused(SEL_DEPOSIT_REQUEST, true);

    vm.prank(vaultManager);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.MidasVaultFunctionPaused.selector, SEL_DEPOSIT_REQUEST));
    fund.setDepositVault(address(newVault));
  }

  function test_SetDepositVault_RevertsWhenNotGreenlisted() public {
    MockMidasDepositVault newVault =
      new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);
    newVault.setGreenlistEnabled(true);

    // Neither the fund nor the wrapper is greenlisted for the new vault's role
    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.NotAllowedByFund.selector);
    fund.setDepositVault(address(newVault));

    // Fund greenlisted but the wrapper is not
    midasAcl.setRole(newVault.greenlistedRole(), address(fund), true);
    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.WrappedShareNotPermissioned.selector);
    fund.setDepositVault(address(newVault));

    // Both greenlisted succeeds
    midasAcl.setRole(newVault.greenlistedRole(), address(wrappedShare), true);
    vm.prank(vaultManager);
    fund.setDepositVault(address(newVault));
    assertEq(fund.depositVault(), address(newVault), "deposit vault updated");
  }

  function test_SetDepositVault_RevertsMTokenMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    MockMidasDepositVault badVault =
      new MockMidasDepositVault(address(otherToken), address(depositMTokenFeed), address(midasAcl));
    badVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);

    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    fund.setDepositVault(address(badVault));
  }

  function test_SetDepositVault_RevertsTokenNotSupported() public {
    MockMidasDepositVault bareVault =
      new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));

    vm.prank(vaultManager);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.TokenNotSupported.selector, address(usdc)));
    fund.setDepositVault(address(bareVault));
  }

  function test_SetDepositVault_RevertsWhenOrderLive() public {
    MockMidasDepositVault newVault =
      new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);

    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(vaultManager);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.setDepositVault(address(newVault));
  }

  function test_SetDepositVault_RevertsNonContract() public {
    vm.prank(vaultManager);
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    fund.setDepositVault(address(0xBEEF));
  }

  function test_SetDepositVault_OnlyOwnerOrVaultManager() public {
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.setDepositVault(address(depositVault));

    // Depositor (address(this)) cannot either
    vm.expectRevert(Unauthorized.selector);
    fund.setDepositVault(address(depositVault));

    // The operator role does not grant vault management
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    vm.expectRevert(Unauthorized.selector);
    fund.setDepositVault(address(depositVault));

    // The payment role does not either
    vm.prank(paymentOperator);
    vm.expectRevert(Unauthorized.selector);
    fund.setDepositVault(address(depositVault));

    // The owner can always set the vault
    vm.prank(owner);
    fund.setDepositVault(address(depositVault));
    assertEq(fund.depositVault(), address(depositVault), "owner can set vault");
  }

  function test_SetRedemptionVault_Success() public {
    MockMidasRedemptionVault newVault =
      new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);

    vm.prank(vaultManager);
    vm.expectEmit(true, true, true, true);
    emit RedemptionVaultUpdated(address(newVault), vaultManager);
    fund.setRedemptionVault(address(newVault));

    assertEq(fund.redemptionVault(), address(newVault), "redemption vault updated");
  }

  function test_SetRedemptionVault_RevertsWhenVaultPaused() public {
    MockMidasRedemptionVault newVault =
      new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);
    newVault.setPaused(true);

    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.MidasVaultPaused.selector);
    fund.setRedemptionVault(address(newVault));
  }

  function test_SetRedemptionVault_RevertsWhenRedeemInstantPaused() public {
    MockMidasRedemptionVault newVault =
      new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);
    newVault.setFnPaused(SEL_REDEEM_INSTANT, true);

    vm.prank(vaultManager);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.MidasVaultFunctionPaused.selector, SEL_REDEEM_INSTANT));
    fund.setRedemptionVault(address(newVault));
  }

  function test_SetRedemptionVault_RevertsWhenNotGreenlisted() public {
    MockMidasRedemptionVault newVault =
      new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);
    newVault.setGreenlistEnabled(true);

    // Neither the fund nor the wrapper is greenlisted for the new vault's role
    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.NotAllowedByFund.selector);
    fund.setRedemptionVault(address(newVault));

    // Fund greenlisted but the wrapper is not
    midasAcl.setRole(newVault.greenlistedRole(), address(fund), true);
    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.WrappedShareNotPermissioned.selector);
    fund.setRedemptionVault(address(newVault));

    // Both greenlisted succeeds
    midasAcl.setRole(newVault.greenlistedRole(), address(wrappedShare), true);
    vm.prank(vaultManager);
    fund.setRedemptionVault(address(newVault));
    assertEq(fund.redemptionVault(), address(newVault), "redemption vault updated");
  }

  function test_SetRedemptionVault_RevertsMTokenMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    MockMidasRedemptionVault badVault =
      new MockMidasRedemptionVault(address(otherToken), address(redemptionMTokenFeed), address(midasAcl));
    badVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);

    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    fund.setRedemptionVault(address(badVault));
  }

  function test_SetRedemptionVault_RevertsTokenNotSupported() public {
    MockMidasRedemptionVault bareVault =
      new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));

    vm.prank(vaultManager);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.TokenNotSupported.selector, address(usdc)));
    fund.setRedemptionVault(address(bareVault));
  }

  function test_SetRedemptionVault_SucceedsWithLiveDeposit() public {
    // Deposits never touch the redemption vault: the swap is allowed at any point of their
    // lifecycle and the pending mint request settles unaffected.
    MockMidasRedemptionVault newVault = _newRedemptionVault();

    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(vaultManager);
    fund.setRedemptionVault(address(newVault));
    assertEq(fund.redemptionVault(), address(newVault), "swapped while ACCEPTED");

    _commitDeposit(order);
    vm.prank(vaultManager);
    fund.setRedemptionVault(address(redemptionVault));
    assertEq(fund.redemptionVault(), address(redemptionVault), "swapped while PROCESSING");

    _approveDepositRequest();
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "deposit lifecycle unaffected");
    assertEq(amount, ONE_MTOKEN, "full mint unlocked");
  }

  function test_SetRedemptionVault_AcceptedRedeem_Succeeds() public {
    // A redeem settles through the vault configured at commit time; its min-out is carried
    // by the order and enforced by the new vault.
    _depositAndUnlock(ONE_USDC);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    _unlockInstantRedeem(order);

    MockMidasRedemptionVault newVault = _newRedemptionVault();
    vm.prank(vaultManager);
    fund.setRedemptionVault(address(newVault));

    vm.expectCall(
      address(newVault), abi.encodeWithSelector(SEL_REDEEM_INSTANT, address(usdc), ONE_MTOKEN, ONE_USDC * ASSET_SCALE)
    );
    _commitRedeem(order);
    assertEq(usdc.balanceOf(address(fund)), ONE_USDC, "settled through the new vault");
  }

  function test_SetRedemptionVault_BondPhaseRedeem_Succeeds() public {
    // The Repay-and-Redeem flow: Midas deploys the dedicated redemption vault only once the
    // bond is received, so the swap lands between the two legs.
    Order memory order = _commitBondedRedeemOrder();
    uint256 bondAmount = ONE_MTOKEN * BOND_BPS / BPS;
    uint256 redeemAmount = ONE_MTOKEN - bondAmount;

    MockMidasRedemptionVault newVault = _newRedemptionVault();
    vm.prank(vaultManager);
    fund.setRedemptionVault(address(newVault));
    assertEq(fund.redemptionVault(), address(newVault), "swapped during the bond phase");

    _unlockInstantRedeem(order);
    vm.expectCall(
      address(newVault),
      abi.encodeWithSelector(SEL_REDEEM_INSTANT, address(usdc), redeemAmount, redeemAmount / ASSET_SCALE * ASSET_SCALE)
    );
    _commitRedeem(order);

    // The lifecycle completes through the new vault's proceeds.
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, redeemAmount / ASSET_SCALE, "remainder proceeds");
  }

  function test_SetRedemptionVault_ReAcceptedBondedRedeem_Succeeds() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);

    MockMidasRedemptionVault newVault = _newRedemptionVault();
    vm.prank(vaultManager);
    fund.setRedemptionVault(address(newVault));

    uint256 redeemAmount = ONE_MTOKEN - ONE_MTOKEN * BOND_BPS / BPS;
    vm.expectCall(address(newVault), abi.encodeWithSelector(SEL_REDEEM_INSTANT), 1);
    _commitRedeem(order);
    assertEq(usdc.balanceOf(address(fund)), redeemAmount / ASSET_SCALE, "settled through the new vault");
  }

  function test_SetRedemptionVault_SettledRedeem_Succeeds() public {
    // After redeemInstant executed the vault is never read again for this order: the swap is
    // harmless and the terminal unlock completes unchanged.
    Order memory order = _commitRedeemOrder();

    MockMidasRedemptionVault newVault = _newRedemptionVault();
    vm.prank(vaultManager);
    fund.setRedemptionVault(address(newVault));

    (State state,) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "settlement unaffected");
  }

  function test_SetRedemptionVault_MidOrderStillValidates() public {
    // The vault-validity checks are not relaxed by the live order.
    _commitBondedRedeemOrder();

    MockMidasRedemptionVault pausedVault = _newRedemptionVault();
    pausedVault.setPaused(true);
    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.MidasVaultPaused.selector);
    fund.setRedemptionVault(address(pausedVault));

    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    MockMidasRedemptionVault badVault =
      new MockMidasRedemptionVault(address(otherToken), address(redemptionMTokenFeed), address(midasAcl));
    vm.prank(vaultManager);
    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    fund.setRedemptionVault(address(badVault));
  }

  function test_SetRedemptionVault_RevertsNonContract() public {
    vm.prank(vaultManager);
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    fund.setRedemptionVault(address(0xBEEF));
  }

  function test_SetRedemptionVault_OnlyOwnerOrVaultManager() public {
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.setRedemptionVault(address(redemptionVault));

    // Depositor (address(this)) cannot either
    vm.expectRevert(Unauthorized.selector);
    fund.setRedemptionVault(address(redemptionVault));

    // The operator role does not grant vault management
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    vm.expectRevert(Unauthorized.selector);
    fund.setRedemptionVault(address(redemptionVault));

    // The owner can always set the vault
    vm.prank(owner);
    fund.setRedemptionVault(address(redemptionVault));
    assertEq(fund.redemptionVault(), address(redemptionVault), "owner can set vault");
  }

  function test_SetReferrerId_Success() public {
    bytes32 newReferrerId = keccak256("referrer");

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit ReferrerIdUpdated(newReferrerId, owner);
    fund.setReferrerId(newReferrerId);

    assertEq(fund.referrerId(), newReferrerId, "referrer id");

    // Forwarded to the deposit vault on commit
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);
    assertEq(depositVault.lastReferrerId(), newReferrerId, "referrer forwarded");
  }

  function test_SetReferrerId_AllowedDuringLiveOrder() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(owner);
    fund.setReferrerId(keccak256("mid-order"));
    assertEq(fund.referrerId(), keccak256("mid-order"), "referrer id");
  }

  function test_SetReferrerId_OnlyOwnerOrOperator() public {
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.setReferrerId(bytes32(0));
  }

  function test_SetOracle_OwnerSuccess() public {
    MockChainlinkOracle newOracle = new MockChainlinkOracle(8);
    newOracle.setRoundData(1, int256(2e8), block.timestamp, 1);
    newOracle.setLatestRound(1);

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OracleUpdated(address(newOracle), owner);
    fund.setOracle(address(newOracle));

    // The new 2 USD price is used immediately.
    fund.create(_depositOrder(ONE_USDC, 0.5e18));
  }

  function test_SetOracle_OperatorSuccessDuringLiveOrder() public {
    fund.create(_redeemOrder(ONE_MTOKEN, ONE_USDC));
    MockChainlinkOracle newOracle = new MockChainlinkOracle(8);

    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    fund.setOracle(address(newOracle));
  }

  function test_SetOracle_RevertsInvalidContract() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    fund.setOracle(address(0xBEEF));
  }

  function test_SetOracle_RevertsInvalidDecimals() public {
    MockChainlinkOracle invalidOracle = new MockChainlinkOracle(18);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOracle.selector, address(invalidOracle)));
    fund.setOracle(address(invalidOracle));
  }

  function test_SetOracle_OnlyOwnerOrOperator() public {
    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.setOracle(address(oracle));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Views_ReturnAddresses() public {
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.mToken(), address(mGlobal), "mToken");
    assertEq(fund.depositVault(), address(depositVault), "deposit vault");
    assertEq(fund.redemptionVault(), address(0), "no redemption vault configured");

    _setRedemptionVault();
    assertEq(fund.redemptionVault(), address(redemptionVault), "redemption vault");
  }

  function test_TotalAssets_ZeroSupply() public view {
    assertEq(fund.totalAssets(), 0, "zero supply");
  }

  function test_TotalAssets_UsesOracleAndIgnoresVaultFeeds() public {
    _depositAndUnlock(ONE_USDC);

    // supply (1e18) * oracle price (1e8) / 1e8 / 1e12 = 1e6
    assertEq(fund.totalAssets(), ONE_USDC, "totalAssets at 1:1");

    oracle.setRoundData(2, int256(1.5e8), block.timestamp, 2);
    oracle.setLatestRound(2);
    assertEq(fund.totalAssets(), ONE_USDC * 15 / 10, "totalAssets at 1.5x");

    // Both vault mToken feeds are ignored.
    depositMTokenFeed.setRate(4e18);
    redemptionMTokenFeed.setRate(3e18);
    assertEq(fund.totalAssets(), ONE_USDC * 15 / 10, "mToken vault feeds ignored");

    // The payment asset is assumed to be worth 1 USD, regardless of its vault configuration.
    depositVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, false);
    depositAssetFeed.setRate(2e18);
    assertEq(fund.totalAssets(), ONE_USDC * 15 / 10, "payment-token feed ignored");
  }

  function test_TotalAssets_RevertsInvalidOracleRound() public {
    _depositAndUnlock(ONE_USDC);
    oracle.setRoundData(2, -1, block.timestamp, 2);
    oracle.setLatestRound(2);

    vm.expectRevert(LibFundsErrors.ChainlinkInvalidAnswer.selector);
    fund.totalAssets();
  }

  function test_MaxDeposit_ReturnsDepositorBalance() public {
    assertEq(fund.maxDeposit(address(this)), 0, "no balance");

    usdc.mint(address(this), 5 * ONE_USDC);
    assertEq(fund.maxDeposit(address(this)), 5 * ONE_USDC, "depositor balance");
    assertEq(fund.maxDeposit(outsider), 0, "non-depositor");
  }

  function test_MaxRedeem_ReturnsWrapperBalance() public {
    assertEq(fund.maxRedeem(address(this)), 0, "no balance");

    _depositAndUnlock(ONE_USDC);

    assertEq(fund.maxRedeem(address(this)), ONE_MTOKEN, "wrapper balance");
    assertEq(fund.maxRedeem(outsider), 0, "non-depositor");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        STATE MACHINE                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_StateMachine_FullDepositLifecycle() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "empty");

    fund.create(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "accepted");

    _commitDeposit(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing until request approved");

    _approveDepositRequest();
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");

    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
    assertEq(wrappedShare.balanceOf(address(this)), ONE_MTOKEN, "wrapper minted");
  }

  function test_StateMachine_FullRedeemLifecycle() public {
    _depositAndUnlock(ONE_USDC);

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    assertEq(uint256(fund.state(order)), uint256(State.EMPTY), "empty");

    fund.create(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "accepted");

    // Bond leg (empty config: nothing moves), waiting for the bond confirmation.
    _commitRedeem(order);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "bond phase");

    // Midas deploys the per-redemption vault; the fund is pointed at it and re-armed.
    _setRedemptionVault();
    _unlockInstantRedeem(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "re-accepted");

    // Redeem leg settles synchronously.
    _commitRedeem(order);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable");

    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "usdc received");
  }

  function test_StateMachine_ConsecutiveOrders() public {
    // Cycle 1: async deposit (request approved before unlock)
    Order memory deposit1 = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("deposit1"));
    fund.create(deposit1);
    usdc.mint(address(this), deposit1.input);
    usdc.approve(address(fund), deposit1.input);
    fund.commit(deposit1);
    _approveDepositRequest();
    fund.unlock(deposit1);

    // Cycle 2: instant redeem (bond leg skipped, per-redemption vault set)
    Order memory redeem1 = _orderWithSalt(Mode.REDEEM, ONE_MTOKEN, ONE_USDC, keccak256("redeem1"));
    fund.create(redeem1);
    _unlockInstantRedeem(redeem1);
    _setRedemptionVault();
    wrappedShare.approve(address(fund), redeem1.input);
    fund.commit(redeem1);
    fund.unlock(redeem1);
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "cycle 2: usdc back");

    // Cycle 3: deposit again
    Order memory deposit2 = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("deposit2"));
    fund.create(deposit2);
    usdc.approve(address(fund), deposit2.input);
    fund.commit(deposit2);
    _approveDepositRequest();
    fund.unlock(deposit2);
    assertEq(wrappedShare.balanceOf(address(this)), ONE_MTOKEN, "cycle 3: wrapper minted");
  }

  function test_State_NonCurrentOrderReturnsEmpty() public {
    Order memory order1 = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order1);
    _commitDeposit(order1);

    Order memory order2 = _depositOrder(2 * ONE_USDC, 2 * ONE_MTOKEN);
    assertEq(uint256(fund.state(order2)), uint256(State.EMPTY), "non-current order is EMPTY");
  }

  function test_Edge_ArchivedOrderReturnsEnded() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);
    _approveDepositRequest();
    fund.unlock(order);
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "ended");

    Order memory nextOrder = _orderWithSalt(Mode.DEPOSIT, ONE_USDC * 2, ONE_MTOKEN * 2, keccak256("second-order"));
    fund.create(nextOrder);

    // Old order was archived — state() returns ENDED
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "old order ENDED (archived)");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        BOND CONFIG                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_SetBondConfig_Success() public {
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);

    vm.prank(operator);
    vm.expectEmit(true, true, true, true);
    emit BondConfigUpdated(BOND_BPS, bondRecipient, operator);
    fund.setBondConfig(BondConfig({amount: BOND_BPS, recipient: bondRecipient}));

    BondConfig memory config = fund.bondConfig();
    assertEq(config.amount, BOND_BPS, "amount");
    assertEq(config.recipient, bondRecipient, "recipient");
  }

  function test_SetBondConfig_OwnerCanSet() public {
    vm.prank(owner);
    fund.setBondConfig(BondConfig({amount: BOND_BPS, recipient: bondRecipient}));
    assertEq(fund.bondConfig().amount, BOND_BPS, "amount");
  }

  function test_SetBondConfig_OnlyOwnerOrOperator() public {
    BondConfig memory config = BondConfig({amount: BOND_BPS, recipient: bondRecipient});

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.setBondConfig(config);

    // Depositor (address(this)) cannot set
    vm.expectRevert(Unauthorized.selector);
    fund.setBondConfig(config);

    // The vault manager role does not include bond management: the recipient is the only
    // guardrail on bond payments, so it is defined by the most-trusted role.
    vm.prank(vaultManager);
    vm.expectRevert(Unauthorized.selector);
    fund.setBondConfig(config);

    // The payment role does not either
    vm.prank(paymentOperator);
    vm.expectRevert(Unauthorized.selector);
    fund.setBondConfig(config);

    // The operator can set
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    fund.setBondConfig(config);
    assertEq(fund.bondConfig().amount, BOND_BPS, "set by operator");
  }

  function test_SetBondConfig_RevertsInvalidAmount() public {
    uint256 overCap = fund.MAX_BOND_AMOUNT() + 1;

    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.InvalidBondConfig.selector);
    fund.setBondConfig(BondConfig({amount: overCap, recipient: bondRecipient}));

    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.InvalidBondConfig.selector);
    fund.setBondConfig(BondConfig({amount: BPS, recipient: bondRecipient}));
  }

  function test_SetBondConfig_MaxAmountSucceeds() public {
    uint256 maxBond = fund.MAX_BOND_AMOUNT();

    vm.prank(owner);
    fund.setBondConfig(BondConfig({amount: maxBond, recipient: bondRecipient}));
    assertEq(fund.bondConfig().amount, maxBond, "amount");
  }

  function test_SetBondConfig_RevertsZeroRecipient() public {
    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.InvalidBondConfig.selector);
    fund.setBondConfig(BondConfig({amount: 1, recipient: address(0)}));
  }

  function test_SetBondConfig_RevertsZeroAmount() public {
    // Disabling the bond flow goes through removeBondConfig, not a zero-amount set.
    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.InvalidBondConfig.selector);
    fund.setBondConfig(BondConfig({amount: 0, recipient: bondRecipient}));

    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.InvalidBondConfig.selector);
    fund.setBondConfig(BondConfig({amount: 0, recipient: address(0)}));
  }

  function test_RemoveBondConfig_Success() public {
    _setBondConfig(BOND_BPS);

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit BondConfigUpdated(0, address(0), owner);
    fund.removeBondConfig();

    BondConfig memory config = fund.bondConfig();
    assertEq(config.amount, 0, "amount cleared");
    assertEq(config.recipient, address(0), "recipient cleared");

    // Subsequent redeems still follow the bond flow; only the payment is gone.
    _depositAndUnlock(ONE_USDC);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    assertFalse(fund.instantRedeemUnlocked(), "redeem still bond-locked after removal");
    _commitRedeem(order);
    assertEq(fund.bondPaid(), 0, "no bond payment");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "waiting for unlockInstantRedeem");
  }

  function test_RemoveBondConfig_Idempotent() public {
    // Removing an already-zero config succeeds.
    vm.prank(owner);
    fund.removeBondConfig();
    assertEq(fund.bondConfig().amount, 0, "still disabled");
  }

  function test_RemoveBondConfig_OnlyOwnerOrOperator() public {
    _setBondConfig(BOND_BPS);

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.removeBondConfig();

    // Depositor (address(this)) cannot remove
    vm.expectRevert(Unauthorized.selector);
    fund.removeBondConfig();

    // The vault manager role does not include bond management
    vm.prank(vaultManager);
    vm.expectRevert(Unauthorized.selector);
    fund.removeBondConfig();

    // The payment role does not either
    vm.prank(paymentOperator);
    vm.expectRevert(Unauthorized.selector);
    fund.removeBondConfig();

    // The operator can remove
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    fund.removeBondConfig();
    assertEq(fund.bondConfig().amount, 0, "removed by operator");

    // The owner can always remove (idempotent)
    vm.prank(owner);
    fund.removeBondConfig();
    assertEq(fund.bondConfig().amount, 0, "removed by owner");
  }

  function test_RemoveBondConfig_RevertsWhenOrderLive() public {
    _setBondConfig(BOND_BPS);
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.removeBondConfig();

    _commitDeposit(order);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.removeBondConfig();
  }

  function test_SetBondConfig_RevertsWhenOrderLive() public {
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.setBondConfig(BondConfig({amount: BOND_BPS, recipient: bondRecipient}));

    _commitDeposit(order);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.setBondConfig(BondConfig({amount: BOND_BPS, recipient: bondRecipient}));
  }

  function test_SetBondConfig_AllowedAfterEnded() public {
    _depositAndUnlock(ONE_USDC);
    _setBondConfig(BOND_BPS);
    assertEq(fund.bondConfig().amount, BOND_BPS, "set after ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         BOND FLOW                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Create_BondedRedeem_LocksInstantRedeem() public {
    _depositAndUnlock(ONE_USDC);
    _setBondConfig(BOND_BPS);

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    assertFalse(fund.instantRedeemUnlocked(), "bonded redeem locked at create");
    assertEq(fund.bondPaid(), 0, "no bond paid yet");
  }

  function test_Create_BondedDeposit_StaysUnlocked() public {
    _setBondConfig(BOND_BPS);
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    assertTrue(fund.instantRedeemUnlocked(), "deposits never bond-locked");
  }

  function test_Create_ZeroBondConfig_StillLocked() public {
    // The bond flow always applies: an empty bond config only zeroes the payment.
    _depositAndUnlock(ONE_USDC);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    assertFalse(fund.instantRedeemUnlocked(), "redeem locked even with no bond config");
  }

  function test_Commit_ZeroBondConfig_BondLegPaysNothing() public {
    // With no bond config the first commit still runs the bond leg: nothing moves, but the
    // order waits in PROCESSING for the unlockInstantRedeem() confirmation.
    _depositAndUnlock(ONE_USDC);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);

    uint256 sharesBefore = wrappedShare.balanceOf(address(this));
    _commitRedeem(order);
    assertEq(fund.bondPaid(), 0, "no bond paid");
    assertEq(wrappedShare.balanceOf(address(this)), sharesBefore, "no shares burned");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "waiting for confirmation");

    // The redeem leg completes once confirmed and the vault is set.
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order);
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_USDC, "full proceeds");
  }

  function test_Commit_BondLeg_Success() public {
    _depositAndUnlock(ONE_USDC);
    _setBondConfig(BOND_BPS);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    bytes32 orderId = order.toId(address(fund));
    uint256 bondAmount = ONE_MTOKEN * BOND_BPS / BPS;
    uint256 sharesBefore = wrappedShare.balanceOf(address(this));

    wrappedShare.approve(address(fund), order.input);
    vm.expectEmit(true, true, true, true);
    emit BondPaid(orderId, bondAmount, bondRecipient);
    vm.expectEmit(true, true, true, true);
    emit OrderCommitted(orderId, Mode.REDEEM, bondAmount, 0);
    (State state, uint256 committed) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "processing");
    assertEq(committed, order.input, "full input reported (depositor-compatible)");
    assertEq(mGlobal.balanceOf(bondRecipient), bondAmount, "bond paid in mTokens");
    assertEq(sharesBefore - wrappedShare.balanceOf(address(this)), bondAmount, "only the bond shares burned");
    assertEq(mGlobal.balanceOf(address(fund)), 0, "no mTokens retained");
    assertEq(usdc.balanceOf(address(fund)), 0, "redemption vault not touched");
    assertEq(fund.bondPaid(), bondAmount, "bondPaid stored");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "state processing");
  }

  function test_Commit_BondLeg_ZeroRoundingSkipsTransfers() public {
    _depositAndUnlock(ONE_USDC);
    _setBondConfig(1); // 1 bps

    // 9_999 wei of mToken: the bond floors to zero (9_999 * 1 / 10_000).
    Order memory order = _redeemOrder(9_999, 0);
    fund.create(order);
    assertFalse(fund.instantRedeemUnlocked(), "still bond-locked");

    _commitRedeem(order);
    assertEq(fund.bondPaid(), 0, "no bond paid");
    assertEq(mGlobal.balanceOf(bondRecipient), 0, "no transfer");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "still gated");

    // The flow still completes through unlockInstantRedeem.
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order);
    (State state,) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
  }

  function test_UnlockInstantRedeem_FromProcessing() public {
    Order memory order = _commitBondedRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    vm.expectEmit(true, true, true, true);
    emit InstantRedeemUnlocked(orderId, paymentOperator);
    vm.prank(paymentOperator);
    fund.unlockInstantRedeem(orderId);

    assertTrue(fund.instantRedeemUnlocked(), "unlocked");
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "back to accepted");
  }

  function test_UnlockInstantRedeem_FromAccepted_WaivesBond() public {
    _depositAndUnlock(ONE_USDC);
    _setBondConfig(BOND_BPS);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);

    _unlockInstantRedeem(order);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "still accepted");

    // The single commit burns the full input; no bond is paid.
    _setRedemptionVault();
    _commitRedeem(order);
    assertEq(fund.bondPaid(), 0, "bond waived");
    assertEq(mGlobal.balanceOf(bondRecipient), 0, "no bond transfer");
    assertEq(usdc.balanceOf(address(fund)), ONE_USDC, "full proceeds received");
  }

  function test_UnlockInstantRedeem_OnlyOwnerOrPaymentRole() public {
    Order memory order = _commitBondedRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.unlockInstantRedeem(orderId);

    // Depositor (address(this)) cannot unlock
    vm.expectRevert(Unauthorized.selector);
    fund.unlockInstantRedeem(orderId);

    // The operator role does not include payment management
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    vm.expectRevert(Unauthorized.selector);
    fund.unlockInstantRedeem(orderId);

    // The vault manager role does not either
    vm.prank(vaultManager);
    vm.expectRevert(Unauthorized.selector);
    fund.unlockInstantRedeem(orderId);

    // The owner can always unlock
    vm.prank(owner);
    fund.unlockInstantRedeem(orderId);
    assertTrue(fund.instantRedeemUnlocked(), "owner can unlock");
  }

  function test_UnlockInstantRedeem_RevertsInvalidOrder() public {
    _commitBondedRedeemOrder();

    vm.prank(paymentOperator);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, bytes32("wrong")));
    fund.unlockInstantRedeem(bytes32("wrong"));
  }

  function test_UnlockInstantRedeem_RevertsForDeposit() public {
    _setBondConfig(BOND_BPS);
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(paymentOperator);
    vm.expectRevert(LibFundsErrors.InstantRedeemAlreadyUnlocked.selector);
    fund.unlockInstantRedeem(order.toId(address(fund)));
  }

  function test_UnlockInstantRedeem_RevertsWhenAlreadyUnlocked() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);

    vm.prank(paymentOperator);
    vm.expectRevert(LibFundsErrors.InstantRedeemAlreadyUnlocked.selector);
    fund.unlockInstantRedeem(order.toId(address(fund)));
  }

  function test_UnlockInstantRedeem_RevertsAfterRedeemExecuted() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order); // redeem leg executed → PROCESSING with the flag set

    vm.prank(paymentOperator);
    vm.expectRevert(LibFundsErrors.InstantRedeemAlreadyUnlocked.selector);
    fund.unlockInstantRedeem(order.toId(address(fund)));
  }

  function test_Commit_RedeemLeg_BurnsRemainderAndScalesMinOut() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    bytes32 orderId = order.toId(address(fund));
    uint256 bondAmount = ONE_MTOKEN * BOND_BPS / BPS;
    uint256 remainder = ONE_MTOKEN - bondAmount;

    wrappedShare.approve(address(fund), order.input);
    vm.expectEmit(true, true, true, true);
    emit OrderCommitted(orderId, Mode.REDEEM, remainder, 0);
    (State state, uint256 committed) = fund.commit(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "processing");
    assertEq(committed, order.input, "full input reported (depositor-compatible)");
    assertEq(wrappedShare.totalSupply(), 0, "all shares burned across both legs");
    assertEq(usdc.balanceOf(address(fund)), remainder / ASSET_SCALE, "proceeds on the remainder");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "claimable");
  }

  function test_Commit_RedeemLeg_MinOutEnforced() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);
    _setRedemptionVault();

    // Rate drop after create: the proportionally scaled min-out is forwarded and enforced.
    redemptionMTokenFeed.setRate(0.9e18);
    wrappedShare.approve(address(fund), order.input);
    vm.expectRevert("MockRedemptionVault: slippage");
    fund.commit(order);
  }

  function test_BondFlow_FullLifecycle() public {
    Order memory order = _commitBondedRedeemOrder(); // bond leg
    uint256 bondAmount = ONE_MTOKEN * BOND_BPS / BPS;
    uint256 expectedProceeds = (ONE_MTOKEN - bondAmount) / ASSET_SCALE;

    _setRedemptionVault(); // Midas deployed the per-redemption vault after the bond
    _unlockInstantRedeem(order);
    _commitRedeem(order); // redeem leg

    // The terminal unlock sweeps the full proceeds and ends the order.
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, expectedProceeds, "proceeds swept");

    assertEq(usdc.balanceOf(address(this)), expectedProceeds, "total proceeds");
    assertEq(mGlobal.balanceOf(bondRecipient), bondAmount, "bond kept by the recipient");
    assertEq(wrappedShare.totalSupply(), 0, "all shares burned");

    // A new order can be created after the bonded lifecycle.
    Order memory next = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("post-bond"));
    fund.create(next);
    assertEq(uint256(fund.state(next)), uint256(State.ACCEPTED), "next order accepted");
  }

  function test_Cancel_RevertsAfterBondPaid() public {
    Order memory order = _commitBondedRedeemOrder();

    // Bond-phase PROCESSING is rejected by the state check.
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.cancel(order);

    // Re-ACCEPTED window after unlockInstantRedeem: the paid bond blocks cancellation.
    _unlockInstantRedeem(order);
    vm.expectRevert(LibFundsErrors.BondAlreadyPaid.selector);
    fund.cancel(order);
  }

  function test_Cancel_AllowedBeforeBondPaid() public {
    _depositAndUnlock(ONE_USDC);
    _setBondConfig(BOND_BPS);

    // No commit yet: cancel is free.
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    fund.cancel(order);

    // Waive path: unlockInstantRedeem before any commit leaves bondPaid at zero.
    Order memory waived = _orderWithSalt(Mode.REDEEM, ONE_MTOKEN, ONE_USDC, keccak256("waived"));
    fund.create(waived);
    _unlockInstantRedeem(waived);
    fund.cancel(waived);
    assertEq(uint256(fund.state(waived)), uint256(State.EMPTY), "canceled");
  }

  function test_State_BondPhase_DonationStaysProcessing() public {
    Order memory order = _commitBondedRedeemOrder();

    usdc.mint(address(fund), ONE_USDC);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "donation ignored in bond phase");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);

    // The donation becomes claimable together with the proceeds once the redemption executes.
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order);
    (, uint256 amount) = fund.unlock(order);
    uint256 remainder = ONE_MTOKEN - ONE_MTOKEN * BOND_BPS / BPS;
    assertEq(amount, ONE_USDC + remainder / ASSET_SCALE, "donation swept with the proceeds");
  }

  function test_Resolve_DuringBondPhase_NoEffect() public {
    Order memory order = _commitBondedRedeemOrder();

    // Callable (state gate is PROCESSING), but redeem state ignores resolved amounts.
    vm.prank(owner);
    fund.resolve(order, ONE_MTOKEN, 1);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "still processing");
  }

  function test_Recovering_BondPhaseRedeem_Succeeds() public {
    Order memory order = _commitBondedRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit OrderRecovering(orderId);
    fund.recovering(order);

    // Nothing is owed back: recoverable even at zero balance.
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recoverable at zero balance");

    // Zero-amount terminal recover: no transfer, only ends the order.
    vm.expectEmit(true, true, true, true);
    emit OrderRecovered(orderId, Mode.REDEEM, 0, address(this));
    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, 0, "zero-amount finalization");
    assertEq(usdc.balanceOf(address(this)), 0, "no transfer");

    // The bond stays forfeited; the remainder shares never left the depositor.
    uint256 bondAmount = ONE_MTOKEN * BOND_BPS / BPS;
    assertEq(mGlobal.balanceOf(bondRecipient), bondAmount, "bond kept by the recipient");
    assertEq(wrappedShare.balanceOf(address(this)), ONE_MTOKEN - bondAmount, "remainder shares intact");

    // The instance is freed.
    Order memory next = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("post-abort"));
    fund.create(next);
    assertEq(uint256(fund.state(next)), uint256(State.ACCEPTED), "next order accepted");
  }

  function test_Recovering_ReAcceptedBondedRedeem_Succeeds() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order); // ACCEPTED with the bond paid, redeem leg not committed

    vm.prank(owner);
    fund.recovering(order);

    // The instant redemption is re-locked so cancelRecovering() lands in the bond phase.
    assertFalse(fund.instantRedeemUnlocked(), "re-locked");
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recoverable");

    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, 0, "zero-amount finalization");
  }

  function test_Recovering_RevertsForSettledBondedRedeem() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order); // redeem leg executed: the payout must complete forward

    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recovering(order);
  }

  function test_Recovering_RevertsForAcceptedRedeemWithoutBond() public {
    _depositAndUnlock(ONE_USDC);
    _setBondConfig(BOND_BPS);

    // Bonded redeem created but not committed: cancel() is the tool, not recovery.
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recovering(order);
    fund.cancel(order);

    // Same for the waive path with no bond paid (bondPaid == 0).
    Order memory waived = _orderWithSalt(Mode.REDEEM, ONE_MTOKEN, ONE_USDC, keccak256("waived-no-bond"));
    fund.create(waived);
    _unlockInstantRedeem(waived);
    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recovering(waived);
  }

  function test_Recover_RedeemRewrapsReturnedBond() public {
    Order memory order = _commitBondedRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    vm.prank(owner);
    fund.recovering(order);

    // Midas returns the bond off-band in mTokens: recover() re-wraps it 1:1 into shares.
    uint256 refund = ONE_MTOKEN * BOND_BPS / BPS;
    mGlobal.mint(address(fund), refund);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recoverable with refund");

    uint256 sharesBefore = wrappedShare.balanceOf(address(this));
    vm.expectEmit(true, true, true, true);
    emit OrderRecovered(orderId, Mode.REDEEM, refund, address(this));
    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, refund, "refund re-wrapped");
    assertEq(wrappedShare.balanceOf(address(this)) - sharesBefore, refund, "shares minted to the receiver");
    assertEq(mGlobal.balanceOf(address(fund)), 0, "no mTokens left in the fund");
    assertEq(mGlobal.balanceOf(address(wrappedShare)), wrappedShare.totalSupply(), "wrapper fully backed");
    assertEq(usdc.balanceOf(address(this)), 0, "payment token not involved");
  }

  function test_Recover_RedeemIgnoresAssetBalance() public {
    Order memory order = _commitBondedRedeemOrder();
    vm.prank(owner);
    fund.recovering(order);

    // A payment-token balance (donation or mistaken USDC refund) is not part of a redeem
    // recovery: only the mToken balance is reported and swept.
    usdc.mint(address(fund), ONE_USDC);
    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, 0, "usdc ignored");
    assertEq(usdc.balanceOf(address(fund)), ONE_USDC, "usdc stays in the fund");
    assertEq(usdc.balanceOf(address(this)), 0, "nothing transferred");
  }

  function test_CancelRecovering_AfterBondReturn_StrandsRefundUntilNextDepositUnlock() public {
    Order memory order = _commitBondedRedeemOrder();
    vm.prank(owner);
    fund.recovering(order);

    // The bond comes back while RECOVERING, but the recovery is (mistakenly) canceled and the
    // order completes forward: the resumed completion never sweeps the mTokens.
    uint256 refund = ONE_MTOKEN * BOND_BPS / BPS;
    mGlobal.mint(address(fund), refund);
    vm.prank(owner);
    fund.cancelRecovering(order.toId(address(fund)));
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order);
    fund.unlock(order);
    assertEq(mGlobal.balanceOf(address(fund)), refund, "refund stranded after the redeem ends");

    // The stranded mTokens surface as the next deposit's balance sweep (wrapped with its output).
    Order memory next = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("post-strand"));
    fund.create(next);
    _commitDeposit(next);
    _approveDepositRequest();
    (, uint256 unlocked) = fund.unlock(next);
    assertEq(unlocked, ONE_MTOKEN + refund, "refund swept with the deposit output");
    assertEq(mGlobal.balanceOf(address(fund)), 0, "fund drained");
  }

  function test_CancelRecovering_BondedRedeem_LandsInBondPhase() public {
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);
    bytes32 orderId = order.toId(address(fund));

    // Flag from the re-ACCEPTED state, then cancel the recovery.
    vm.prank(owner);
    fund.recovering(order);
    vm.prank(owner);
    fund.cancelRecovering(orderId);

    // The order lands in the bond phase (PROCESSING, instant redemption locked)...
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "bond phase");
    assertFalse(fund.instantRedeemUnlocked(), "locked again");

    // ...and the full completion path still works: unlock the redeem, settle, end.
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order);
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, (ONE_MTOKEN - ONE_MTOKEN * BOND_BPS / BPS) / ASSET_SCALE, "proceeds on the remainder");
  }

  function test_Resolve_DoesNotAffectRecoveringRedeem() public {
    Order memory order = _commitBondedRedeemOrder();
    vm.prank(owner);
    fund.recovering(order);

    // Redeem recovery ignores resolved amounts: recoverable even with a huge input threshold.
    vm.prank(owner);
    fund.resolve(order, type(uint128).max, 0);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "still recoverable");
  }

  function test_BondAbort_ThenReissueRedeem() public {
    // Abort a stuck bonded redeem...
    Order memory order = _commitBondedRedeemOrder();
    vm.prank(owner);
    fund.recovering(order);
    fund.recover(order);

    // ...then reissue the remaining shares as a fresh redeem (bond payment removed) through
    // the usual two-phase flow.
    vm.prank(owner);
    fund.removeBondConfig();

    uint256 remainder = ONE_MTOKEN - ONE_MTOKEN * BOND_BPS / BPS;
    Order memory reissued = _orderWithSalt(Mode.REDEEM, remainder, remainder / ASSET_SCALE, keccak256("reissue"));
    fund.create(reissued);
    _unlockInstantRedeem(reissued);
    _setRedemptionVault();
    wrappedShare.approve(address(fund), remainder);
    fund.commit(reissued);
    (State state, uint256 amount) = fund.unlock(reissued);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, remainder / ASSET_SCALE, "remainder redeemed");
    assertEq(wrappedShare.totalSupply(), 0, "all shares settled");
  }

  function test_BondFields_ResetOnNextOrder() public {
    // Complete a bonded redeem lifecycle.
    Order memory order = _commitBondedRedeemOrder();
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order);
    fund.unlock(order);

    // The next deposit is unlocked and carries no bond.
    Order memory nextDeposit = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("reset-deposit"));
    fund.create(nextDeposit);
    assertTrue(fund.instantRedeemUnlocked(), "deposit unlocked");
    assertEq(fund.bondPaid(), 0, "bond reset");
    fund.cancel(nextDeposit);

    // The next redeem is bond-locked afresh (config still set).
    Order memory nextRedeem = _orderWithSalt(Mode.REDEEM, ONE_MTOKEN, ONE_USDC, keccak256("reset-redeem"));
    fund.create(nextRedeem);
    assertFalse(fund.instantRedeemUnlocked(), "redeem locked afresh");
    assertEq(fund.bondPaid(), 0, "bond reset (redeem)");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Roles_OperatorGrantable() public {
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    assertEq(fund.rolesOf(operator), OPERATOR_ROLE, "operator role");
  }

  function test_Roles_PaymentAndVaultManagerGranted() public view {
    assertEq(fund.rolesOf(paymentOperator), PAYMENT_ROLE, "payment role");
    assertEq(fund.rolesOf(vaultManager), VAULT_MANAGER_ROLE, "vault manager role");
  }

  function test_Roles_OwnershipTransfer() public {
    vm.prank(owner);
    fund.transferOwnership(operator);
    assertEq(fund.owner(), operator, "new owner");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         EDGE CASES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Edge_OrderIdCollision() public view {
    Order memory orderA = _depositOrder(ONE_USDC, ONE_MTOKEN);
    Order memory orderB = Order({
      mode: orderA.mode,
      owner: orderA.owner,
      receiver: orderA.receiver,
      input: orderA.input,
      output: orderA.output,
      salt: keccak256("different")
    });
    assertFalse(orderA.toId(address(fund)) == orderB.toId(address(fund)), "different ids");
  }

  function test_Edge_18DecimalAssetFullCycle() public {
    // assetScale = 10 ** (18 - 18) = 1: base-18 amounts equal native amounts.
    MockERC20 dai = new MockERC20("Dai", "DAI", 18);
    MockMidasDataFeed daiDepositFeed = new MockMidasDataFeed();
    MockMidasDataFeed daiRedemptionFeed = new MockMidasDataFeed();
    depositVault.setTokenConfig(address(dai), address(daiDepositFeed), 0, type(uint256).max, true);
    redemptionVault.setTokenConfig(address(dai), address(daiRedemptionFeed), 0, type(uint256).max, true);

    MidasFund daiFund = MidasFund(
      factory.createFund(
        owner, address(this), address(depositVault), address(wrappedShare), address(dai), address(oracle)
      )
    );
    vm.prank(owner);
    wrappedShare.grantRoles(address(daiFund), ISSUER_ROLE);

    uint256 amount = 100e18;

    // Deposit cycle
    Order memory depositOrder = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: amount,
      salt: keccak256("dai-deposit")
    });
    daiFund.create(depositOrder);
    dai.mint(address(this), amount);
    dai.approve(address(daiFund), amount);
    daiFund.commit(depositOrder);
    depositVault.approveDepositRequest(daiFund.activeRequestId());
    (, uint256 unlocked) = daiFund.unlock(depositOrder);
    assertEq(unlocked, amount, "mToken unlocked 1:1");
    assertEq(wrappedShare.balanceOf(address(this)), amount, "wrapper minted");

    // Redeem cycle (bond leg skipped and the redemption vault set by the owner)
    Order memory redeemOrder = Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: amount,
      salt: keccak256("dai-redeem")
    });
    daiFund.create(redeemOrder);
    vm.prank(owner);
    daiFund.unlockInstantRedeem(redeemOrder.toId(address(daiFund)));
    vm.prank(owner);
    daiFund.setRedemptionVault(address(redemptionVault));
    wrappedShare.approve(address(daiFund), amount);
    daiFund.commit(redeemOrder);
    (, uint256 redeemed) = daiFund.unlock(redeemOrder);
    assertEq(redeemed, amount, "dai redeemed 1:1");
    assertEq(dai.balanceOf(address(this)), amount, "dai received");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _depositOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return _orderWithSalt(Mode.DEPOSIT, input, output, keccak256("deposit"));
  }

  function _redeemOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return _orderWithSalt(Mode.REDEEM, input, output, keccak256("redeem"));
  }

  function _orderWithSalt(Mode mode, uint256 input, uint256 output, bytes32 salt) internal view returns (Order memory) {
    return Order({mode: mode, owner: address(this), receiver: address(this), input: input, output: output, salt: salt});
  }

  function _commitDeposit(Order memory order) internal {
    usdc.mint(address(this), order.input);
    usdc.approve(address(fund), order.input);
    fund.commit(order);
  }

  function _commitRedeem(Order memory order) internal {
    wrappedShare.approve(address(fund), order.input);
    fund.commit(order);
  }

  /// @dev Sets the default mock redemption vault as the current redemption's vault (the
  ///      stored vault is reset to address(0) on every create).
  function _setRedemptionVault() internal {
    vm.prank(vaultManager);
    fund.setRedemptionVault(address(redemptionVault));
  }

  /// @dev Approves the fund's active Midas mint request (mints the mToken to the fund).
  function _approveDepositRequest() internal {
    depositVault.approveDepositRequest(fund.activeRequestId());
  }

  /// @dev Creates and commits a DEPOSIT order (PROCESSING while the mint request is pending).
  function _createAndCommitDeposit() internal returns (Order memory order) {
    order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);
    _commitDeposit(order);
  }

  /// @dev Full deposit + request approval + unlock cycle to get wrapped shares.
  function _depositAndUnlock(uint256 usdcAmount) internal {
    Order memory order =
      _orderWithSalt(Mode.DEPOSIT, usdcAmount, usdcAmount * ASSET_SCALE, keccak256("bootstrap-deposit"));
    fund.create(order);
    _commitDeposit(order);
    _approveDepositRequest();
    fund.unlock(order);
  }

  /// @dev Bootstraps wrapped shares and settles a REDEEM order with no bond payment: the bond
  ///      leg is skipped via unlockInstantRedeem() before any commit, the default redemption
  ///      vault is configured, and the redeem leg settles (order UNLOCKING, proceeds held).
  function _commitRedeemOrder() internal returns (Order memory order) {
    _depositAndUnlock(ONE_USDC);
    order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    _unlockInstantRedeem(order);
    _setRedemptionVault();
    _commitRedeem(order);
  }

  /// @dev Deploys a fresh mock redemption vault sharing the mToken, feeds and ACL of the
  ///      default one (the mock mints the payout, so no funding is needed).
  function _newRedemptionVault() internal returns (MockMidasRedemptionVault newVault) {
    newVault = new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);
  }

  /// @dev Sets the bond config as the owner (bondRecipient as recipient).
  function _setBondConfig(uint256 amountBps) internal {
    vm.prank(owner);
    fund.setBondConfig(BondConfig({amount: amountBps, recipient: bondRecipient}));
  }

  /// @dev Unlocks the instant redemption of the given order as the payment operator.
  function _unlockInstantRedeem(Order memory order) internal {
    vm.prank(paymentOperator);
    fund.unlockInstantRedeem(order.toId(address(fund)));
  }

  /// @dev Bootstraps wrapped shares, sets a 2% bond config, creates a REDEEM order and commits
  ///      the bond leg (order PROCESSING, awaiting unlockInstantRedeem()).
  function _commitBondedRedeemOrder() internal returns (Order memory order) {
    _depositAndUnlock(ONE_USDC);
    _setBondConfig(BOND_BPS);
    order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    _commitRedeem(order);
  }
}
