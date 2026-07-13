// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {MidasFund} from "src/funds/midas/MidasFund.sol";
import {MidasFundFactory} from "src/funds/midas/MidasFundFactory.sol";
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
  event HoldbackConfirmed(bytes32 indexed orderId, address indexed confirmer);
  event DepositVaultUpdated(address indexed depositVault, address indexed operator);
  event RedemptionVaultUpdated(address indexed redemptionVault, address indexed operator);
  event ReferrerIdUpdated(bytes32 referrerId, address indexed operator);

  uint256 private constant ONE_USDC = 1e6;
  uint256 private constant ONE_MTOKEN = 1e18;
  uint256 private constant ASSET_SCALE = 1e12; // 10 ** (18 - 6)
  bytes4 private constant SEL_DEPOSIT_REQUEST = bytes4(keccak256("depositRequest(address,uint256,bytes32)"));
  bytes4 private constant SEL_REDEEM_INSTANT = bytes4(keccak256("redeemInstant(address,uint256,uint256)"));

  // MidasFund roles
  uint256 private constant OPERATOR_ROLE = 1 << 0;
  uint256 private constant DEPOSITOR_ROLE = 1 << 1;
  uint256 private constant HOLDBACK_ROLE = 1 << 2;
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

  address public owner;
  address public operator;
  address public holdbackConfirmer;
  address public vaultManager;
  address public outsider;

  function setUp() public {
    owner = makeAddr("owner");
    operator = makeAddr("operator");
    holdbackConfirmer = makeAddr("holdbackConfirmer");
    vaultManager = makeAddr("vaultManager");
    outsider = makeAddr("outsider");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    mGlobal = new MockERC20("Midas Global", "mGLOBAL", 18);
    midasAcl = new MockMidasAccessControl();
    depositMTokenFeed = new MockMidasDataFeed();
    depositAssetFeed = new MockMidasDataFeed();
    redemptionMTokenFeed = new MockMidasDataFeed();
    redemptionAssetFeed = new MockMidasDataFeed();

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
      owner, address(this), address(depositVault), address(redemptionVault), address(wrappedShare), address(usdc)
    );
    fund = MidasFund(fundAddress);

    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);

    vm.prank(owner);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);

    vm.prank(owner);
    fund.grantRoles(holdbackConfirmer, HOLDBACK_ROLE);

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
    assertEq(fund.redemptionVault(), address(redemptionVault), "redemption vault");
    assertFalse(fund.holdbackPending(), "no holdback pending");
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
        address(0), address(this), address(depositVault), address(redemptionVault), address(wrappedShare), address(usdc)
      );
  }

  function test_Initialize_RevertsInvalidDepositor() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(
        owner, address(0xBEEF), address(depositVault), address(redemptionVault), address(wrappedShare), address(usdc)
      );
  }

  function test_Initialize_RevertsInvalidDepositVault() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(0xBEEF), address(redemptionVault), address(wrappedShare), address(usdc));
  }

  function test_Initialize_RevertsInvalidRedemptionVault() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(depositVault), address(0xBEEF), address(wrappedShare), address(usdc));
  }

  function test_Initialize_RevertsInvalidWrappedShare() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(owner, address(this), address(depositVault), address(redemptionVault), address(0xBEEF), address(usdc));
  }

  function test_Initialize_RevertsInvalidAsset() public {
    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidContract.selector, address(0xBEEF)));
    MidasFund(fundProxy)
      .initialize(
        owner, address(this), address(depositVault), address(redemptionVault), address(wrappedShare), address(0xBEEF)
      );
  }

  function test_Initialize_RevertsRedemptionVaultMTokenMismatch() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
    MockMidasRedemptionVault otherRedemptionVault =
      new MockMidasRedemptionVault(address(otherToken), address(redemptionMTokenFeed), address(midasAcl));

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(LibFundsErrors.InvalidUnderlyingAsset.selector);
    MidasFund(fundProxy)
      .initialize(
        owner, address(this), address(depositVault), address(otherRedemptionVault), address(wrappedShare), address(usdc)
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
      .initialize(
        owner, address(this), address(depositVault), address(redemptionVault), address(badWrappedShare), address(usdc)
      );
  }

  function test_Initialize_RevertsMTokenDecimalsMismatch() public {
    MockERC20 mToken8 = new MockERC20("Midas 8", "M8", 8);
    MockMidasDepositVault depositVault8 =
      new MockMidasDepositVault(address(mToken8), address(depositMTokenFeed), address(midasAcl));
    MockMidasRedemptionVault redemptionVault8 =
      new MockMidasRedemptionVault(address(mToken8), address(redemptionMTokenFeed), address(midasAcl));
    WrappedAsset wrappedShare8 = WrappedAsset(LibClone.deployERC1967(address(new WrappedAsset())));
    vm.prank(owner);
    wrappedShare8.initialize(owner, owner, address(mToken8), "wM8", "Wrapped M8");

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.DecimalsMismatch.selector, 8, 18));
    MidasFund(fundProxy)
      .initialize(
        owner, address(this), address(depositVault8), address(redemptionVault8), address(wrappedShare8), address(usdc)
      );
  }

  function test_Initialize_RevertsAssetDecimalsTooHigh() public {
    MockERC20 asset20 = new MockERC20("Asset 20", "A20", 20);

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.DecimalsMismatch.selector, 20, 18));
    MidasFund(fundProxy)
      .initialize(
        owner, address(this), address(depositVault), address(redemptionVault), address(wrappedShare), address(asset20)
      );
  }

  function test_Initialize_RevertsTokenNotSupportedOnDepositVault() public {
    MockMidasDepositVault bareDepositVault =
      new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.TokenNotSupported.selector, address(usdc)));
    MidasFund(fundProxy)
      .initialize(
        owner, address(this), address(bareDepositVault), address(redemptionVault), address(wrappedShare), address(usdc)
      );
  }

  function test_Initialize_RevertsTokenNotSupportedOnRedemptionVault() public {
    MockMidasRedemptionVault bareRedemptionVault =
      new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));

    address fundProxy = LibClone.deployERC1967BeaconProxy(factory.MIDAS_FUND_BEACON());
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.TokenNotSupported.selector, address(usdc)));
    MidasFund(fundProxy)
      .initialize(
        owner, address(this), address(depositVault), address(bareRedemptionVault), address(wrappedShare), address(usdc)
      );
  }

  function test_Initialize_OnlyOnce() public {
    vm.expectRevert(InvalidInitialization.selector);
    fund.initialize(
      owner, address(this), address(depositVault), address(redemptionVault), address(wrappedShare), address(usdc)
    );
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

    // The redemption vault is unaffected: a redeem order is still accepted.
    Order memory redeemOrder = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    State state = fund.create(redeemOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "redeem accepted");
  }

  function test_Create_RevertsRedemptionVaultPaused() public {
    redemptionVault.setPaused(true);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    vm.expectRevert(LibFundsErrors.MidasVaultPaused.selector);
    fund.create(order);

    // The deposit vault is unaffected: a deposit order is still accepted.
    Order memory depositOrder = _depositOrder(ONE_USDC, ONE_MTOKEN);
    State state = fund.create(depositOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "deposit accepted");
  }

  function test_Create_RevertsDepositRequestPaused() public {
    depositVault.setFnPaused(SEL_DEPOSIT_REQUEST, true);
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.MidasVaultFunctionPaused.selector, SEL_DEPOSIT_REQUEST));
    fund.create(order);

    // The redemption vault is unaffected: a redeem order is still accepted.
    Order memory redeemOrder = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    State state = fund.create(redeemOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "redeem accepted");
  }

  function test_Create_RevertsRedeemInstantPaused() public {
    redemptionVault.setFnPaused(SEL_REDEEM_INSTANT, true);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.MidasVaultFunctionPaused.selector, SEL_REDEEM_INSTANT));
    fund.create(order);

    // The deposit vault is unaffected: a deposit order is still accepted.
    Order memory depositOrder = _depositOrder(ONE_USDC, ONE_MTOKEN);
    State state = fund.create(depositOrder);
    assertEq(uint256(state), uint256(State.ACCEPTED), "deposit accepted");
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
    // Setting output to ONE_MTOKEN / 2 is a 50% deviation — well beyond the 5% max.
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN / 2);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  function test_Create_RevertsInvalidOutput_Redeem() public {
    // At 1:1 rates, redeeming ONE_MTOKEN should yield ONE_USDC.
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC / 2);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  function test_Create_AcceptsOutputWithinDeviation() public {
    // 96% of ONE_MTOKEN is within the 5% max deviation.
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN * 96 / 100);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted within deviation");
  }

  function test_Create_AcceptsOutputAboveRate() public {
    // Output above the expected rate should always succeed (no upper bound check).
    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN * 2);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted above rate");
  }

  function test_Create_Deposit_UsesDepositVaultFeeds() public {
    // Absurd redemption-side rate must not affect DEPOSIT validation.
    redemptionMTokenFeed.setRate(100e18);
    // Deposit mToken rate 2e18: expected output = 1e18 * 1e18 / 2e18 = 0.5e18 per USDC.
    depositMTokenFeed.setRate(2e18);

    Order memory tooLow = _depositOrder(ONE_USDC, 0.4e18);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(tooLow);

    Order memory withinDeviation = _depositOrder(ONE_USDC, 0.475e18); // 95% of 0.5e18
    State state = fund.create(withinDeviation);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
  }

  function test_Create_Redeem_UsesRedemptionVaultFeeds() public {
    // Absurd deposit-side rate must not affect REDEEM validation.
    depositMTokenFeed.setRate(100e18);

    // Redemption rates 1:1 — expected output = 1e6 per mToken.
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");

    fund.cancel(order);

    // Redemption mToken rate 2e18: expected output doubles to 2e6.
    redemptionMTokenFeed.setRate(2e18);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  function test_Create_NonStableAssetUsesAssetFeed() public {
    // Flag the asset as non-stable, worth 2 USD: expected output = 2e18 per USDC.
    depositVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, false);
    depositAssetFeed.setRate(2e18);

    Order memory tooLow = _depositOrder(ONE_USDC, ONE_MTOKEN);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(tooLow);

    Order memory matching = _depositOrder(ONE_USDC, 2e18);
    State state = fund.create(matching);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted");
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
    // Deposits carry no holdback gate.
    assertFalse(fund.holdbackPending(), "no holdback pending");
  }

  function test_Commit_RedeemInstantSuccess() public {
    _depositAndUnlock(ONE_USDC);

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
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
    // ...and immediately claimable, while the holdback confirmation stays pending.
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable right away");
    assertTrue(fund.holdbackPending(), "holdback pending");
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

  function test_Commit_RevertsWhenRedeemInstantPausedAfterCreate() public {
    _depositAndUnlock(ONE_USDC);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);

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
    _depositAndUnlock(ONE_USDC);

    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    _commitRedeem(order);

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
    _confirmHoldback(order);

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

  function test_Recovering_RevertsForRedeemOrder() public {
    // A committed redeem already settled irreversibly via redeemInstant: recovery is
    // deposit-only and the order must be completed via unlock() and confirmHoldback().
    Order memory order = _commitRedeemOrder();

    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recovering(order);

    // The order completes forward: the proceeds stay claimable and the holdback confirmable.
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable");
    vm.prank(holdbackConfirmer);
    fund.confirmHoldback(order.toId(address(fund)));
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "still claimable after confirmation");
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
  /*                       HOLDBACK FLOW                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Holdback_PartialUnlockBeforeConfirm() public {
    Order memory order = _commitRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    // The instant redemption already delivered the output; it is claimable right away...
    assertEq(usdc.balanceOf(address(fund)), ONE_USDC, "fund has usdc");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "claimable while holdback pending");
    assertTrue(fund.holdbackPending(), "holdback pending");

    // ...but the unlock is partial: the order returns to PROCESSING until the confirmation.
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, ONE_USDC, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.PROCESSING), "back to processing");
    assertEq(amount, ONE_USDC, "instant proceeds swept");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC, "usdc received");
    assertTrue(fund.holdbackPending(), "holdback still pending");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "nothing left to claim");

    // Nothing to sweep until more funds arrive.
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);
  }

  function test_Unlock_RedeemMultiplePartials() public {
    Order memory order = _commitRedeemOrder();

    // First partial sweep: the instant proceeds.
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "processing after first sweep");
    assertEq(amount, ONE_USDC, "instant proceeds swept");

    // A first holdback tranche arrives and is sweepable on its own.
    uint256 tranche = ONE_USDC * 3 / 100;
    usdc.mint(address(fund), tranche);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "tranche claimable");

    (state, amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "processing after second sweep");
    assertEq(amount, tranche, "tranche swept");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC + tranche, "cumulative proceeds received");
    assertTrue(fund.holdbackPending(), "holdback still pending");
  }

  function test_Holdback_UnlockSweepsHoldbackPayment() public {
    Order memory order = _commitRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    // The off-band holdback payment (e.g. the 7% true-up) arrives at the fund.
    uint256 holdbackAmount = ONE_USDC * 7 / 100;
    usdc.mint(address(fund), holdbackAmount);

    // The full balance (instant proceeds + holdback) is claimable even before confirmation.
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "full balance claimable");

    vm.prank(holdbackConfirmer);
    fund.confirmHoldback(orderId);

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, ONE_USDC + holdbackAmount, "full balance swept");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC + holdbackAmount, "instant proceeds + holdback received");
  }

  function test_Unlock_ZeroAmountTerminalAfterConfirm() public {
    Order memory order = _commitRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    // Sweep everything first, then write off the holdback: confirming only flips the flag...
    fund.unlock(order);

    vm.prank(holdbackConfirmer);
    vm.expectEmit(true, true, true, true);
    emit HoldbackConfirmed(orderId, holdbackConfirmer);
    fund.confirmHoldback(orderId);

    assertFalse(fund.holdbackPending(), "holdback settled");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking at zero balance");

    // ...and the terminal unlock finalizes with a zero amount (no transfer).
    uint256 usdcBefore = usdc.balanceOf(address(this));
    vm.expectEmit(true, true, true, true);
    emit OrderUnlocked(orderId, order.mode, 0, address(this));
    (State state, uint256 amount) = fund.unlock(order);

    assertEq(uint256(state), uint256(State.ENDED), "ended by the terminal unlock");
    assertEq(amount, 0, "zero-amount finalization");
    assertEq(usdc.balanceOf(address(this)), usdcBefore, "no transfer");

    // Re-confirming an ended order fails on the state guard.
    vm.prank(holdbackConfirmer);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ENDED));
    fund.confirmHoldback(orderId);
  }

  function test_Create_SucceedsAfterZeroAmountTerminalUnlock() public {
    Order memory order = _commitRedeemOrder();
    fund.unlock(order);
    _confirmHoldback(order);
    fund.unlock(order); // zero-amount terminal unlock

    Order memory nextOrder = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("after-terminal-unlock"));
    fund.create(nextOrder);

    // Old order was archived — state() returns ENDED
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "old order ENDED (archived)");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  function test_ConfirmHoldback_ThenFinalUnlockSweepsRemainder() public {
    Order memory order = _commitRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    // Partial sweep of the instant proceeds, then the holdback payment arrives.
    fund.unlock(order);
    uint256 holdbackAmount = ONE_USDC * 7 / 100;
    usdc.mint(address(fund), holdbackAmount);

    // A positive balance at confirmation time leaves the final sweep to unlock().
    vm.prank(holdbackConfirmer);
    fund.confirmHoldback(orderId);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "holdback claimable");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, holdbackAmount, "holdback swept");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC + holdbackAmount, "instant proceeds + holdback received");
  }

  function test_ConfirmHoldback_LateArrivalSweptByTerminalUnlock() public {
    Order memory order = _commitRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    fund.unlock(order);
    vm.prank(holdbackConfirmer);
    fund.confirmHoldback(orderId);

    // A holdback payment landing between the confirmation and the terminal unlock is
    // automatically included in the final sweep.
    uint256 lateAmount = ONE_USDC * 7 / 100;
    usdc.mint(address(fund), lateAmount);

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, lateAmount, "late holdback swept");
    assertEq(usdc.balanceOf(address(this)), ONE_USDC + lateAmount, "instant proceeds + late holdback received");
  }

  function test_ConfirmHoldback_RevertsInvalidOrder() public {
    _commitRedeemOrder();

    bytes32 wrongOrderId = keccak256("wrong");
    vm.prank(holdbackConfirmer);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidOrder.selector, wrongOrderId));
    fund.confirmHoldback(wrongOrderId);
  }

  function test_ConfirmHoldback_RevertsInvalidState() public {
    // ACCEPTED (not committed yet)
    _depositAndUnlock(ONE_USDC);
    Order memory order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    bytes32 orderId = order.toId(address(fund));

    vm.prank(holdbackConfirmer);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.confirmHoldback(orderId);
  }

  function test_ConfirmHoldback_RevertsForDepositOrder() public {
    // Deposit orders carry no holdback (marked paid at creation): confirming always reverts.
    Order memory order = _createAndCommitDeposit();
    bytes32 orderId = order.toId(address(fund));

    assertFalse(fund.holdbackPending(), "no holdback pending");

    vm.prank(holdbackConfirmer);
    vm.expectRevert(LibFundsErrors.HoldbackNotPending.selector);
    fund.confirmHoldback(orderId);
  }

  function test_ConfirmHoldback_RevertsWhenAlreadyConfirmed() public {
    Order memory order = _commitRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    vm.prank(holdbackConfirmer);
    fund.confirmHoldback(orderId);

    vm.prank(holdbackConfirmer);
    vm.expectRevert(LibFundsErrors.HoldbackNotPending.selector);
    fund.confirmHoldback(orderId);
  }

  function test_ConfirmHoldback_OnlyOwnerOrHoldbackRole() public {
    Order memory order = _commitRedeemOrder();
    bytes32 orderId = order.toId(address(fund));

    vm.prank(outsider);
    vm.expectRevert(Unauthorized.selector);
    fund.confirmHoldback(orderId);

    // Depositor (address(this)) cannot confirm
    vm.expectRevert(Unauthorized.selector);
    fund.confirmHoldback(orderId);

    // The operator role does not include holdback confirmation
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    vm.prank(operator);
    vm.expectRevert(Unauthorized.selector);
    fund.confirmHoldback(orderId);

    // The vault manager role does not either
    vm.prank(vaultManager);
    vm.expectRevert(Unauthorized.selector);
    fund.confirmHoldback(orderId);

    // The owner can always confirm
    vm.prank(owner);
    fund.confirmHoldback(orderId);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after owner confirmation");
  }

  function test_Holdback_FlagsResetOnNextOrder() public {
    // Complete a holdback-gated redeem
    Order memory order = _commitRedeemOrder();
    _confirmHoldback(order);
    fund.unlock(order);

    // The next order (a deposit) carries no holdback gate.
    usdc.approve(address(fund), 0);
    Order memory nextDeposit = _orderWithSalt(Mode.DEPOSIT, ONE_USDC, ONE_MTOKEN, keccak256("next-deposit"));
    fund.create(nextDeposit);
    assertFalse(fund.holdbackPending(), "flags reset on create");
    usdc.approve(address(fund), nextDeposit.input);
    fund.commit(nextDeposit);
    assertFalse(fund.holdbackPending(), "deposits never gated");
    assertEq(uint256(fund.state(nextDeposit)), uint256(State.PROCESSING), "processing until request approved");
    _approveDepositRequest();
    fund.unlock(nextDeposit);

    // The next redeem is gated afresh.
    Order memory nextRedeem = _orderWithSalt(Mode.REDEEM, ONE_MTOKEN, ONE_USDC, keccak256("next-redeem"));
    fund.create(nextRedeem);
    assertFalse(fund.holdbackPending(), "flags reset on create (redeem)");
    wrappedShare.approve(address(fund), nextRedeem.input);
    fund.commit(nextRedeem);

    assertTrue(fund.holdbackPending(), "next redeem gated afresh");
    assertEq(uint256(fund.state(nextRedeem)), uint256(State.UNLOCKING), "next redeem proceeds claimable");
  }

  function test_Resolve_DoesNotAffectRedeemState() public {
    Order memory order = _commitRedeemOrder();

    // Resolved amounts do not gate redeems: even an output threshold above the balance leaves
    // it claimable, and the unlock stays partial until the holdback confirmation.
    vm.prank(owner);
    fund.resolve(order, ONE_MTOKEN, ONE_USDC * 2);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "claimable despite resolved output");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "partial until confirmed");
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

    // The holdback role does not either
    vm.prank(holdbackConfirmer);
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

  function test_SetRedemptionVault_RevertsWhenOrderLive() public {
    MockMidasRedemptionVault newVault =
      new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    newVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);

    Order memory order = _depositOrder(ONE_USDC, ONE_MTOKEN);
    fund.create(order);

    vm.prank(vaultManager);
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.ACCEPTED));
    fund.setRedemptionVault(address(newVault));
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Views_ReturnAddresses() public view {
    assertEq(fund.asset(), address(usdc), "asset");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(fund.mToken(), address(mGlobal), "mToken");
    assertEq(fund.depositVault(), address(depositVault), "deposit vault");
    assertEq(fund.redemptionVault(), address(redemptionVault), "redemption vault");
  }

  function test_TotalAssets_ZeroSupply() public view {
    assertEq(fund.totalAssets(), 0, "zero supply");
  }

  function test_TotalAssets_UsesRedemptionFeeds() public {
    _depositAndUnlock(ONE_USDC);

    // supply (1e18) * mTokenRate (1e18) / assetRate (1e18, stable) / 1e12 = 1e6
    assertEq(fund.totalAssets(), ONE_USDC, "totalAssets at 1:1");

    // Redemption-side mToken rate drives the valuation
    redemptionMTokenFeed.setRate(1.5e18);
    assertEq(fund.totalAssets(), ONE_USDC * 15 / 10, "totalAssets at 1.5x");

    // Deposit-side rates are ignored
    depositMTokenFeed.setRate(3e18);
    assertEq(fund.totalAssets(), ONE_USDC * 15 / 10, "deposit feed ignored");

    // Non-stable asset: the redemption-side asset feed is used
    redemptionVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, false);
    redemptionAssetFeed.setRate(2e18);
    assertEq(fund.totalAssets(), ONE_USDC * 15 / 20, "totalAssets with asset at 2 USD");
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

    _commitRedeem(order);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable while holdback pending");

    _confirmHoldback(order);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "still claimable after confirmation");

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

    // Cycle 2: instant redeem (holdback confirmed before unlock)
    Order memory redeem1 = _orderWithSalt(Mode.REDEEM, ONE_MTOKEN, ONE_USDC, keccak256("redeem1"));
    fund.create(redeem1);
    wrappedShare.approve(address(fund), redeem1.input);
    fund.commit(redeem1);
    _confirmHoldback(redeem1);
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
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Roles_OperatorGrantable() public {
    vm.prank(owner);
    fund.grantRoles(operator, OPERATOR_ROLE);
    assertEq(fund.rolesOf(operator), OPERATOR_ROLE, "operator role");
  }

  function test_Roles_HoldbackAndVaultManagerGranted() public view {
    assertEq(fund.rolesOf(holdbackConfirmer), HOLDBACK_ROLE, "holdback role");
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
        owner, address(this), address(depositVault), address(redemptionVault), address(wrappedShare), address(dai)
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

    // Redeem cycle (holdback confirmed by the owner before unlock)
    Order memory redeemOrder = Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: amount,
      salt: keccak256("dai-redeem")
    });
    daiFund.create(redeemOrder);
    wrappedShare.approve(address(daiFund), amount);
    daiFund.commit(redeemOrder);
    vm.prank(owner);
    daiFund.confirmHoldback(redeemOrder.toId(address(daiFund)));
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

  /// @dev Confirms the holdback of the given committed REDEEM order.
  function _confirmHoldback(Order memory order) internal {
    vm.prank(holdbackConfirmer);
    fund.confirmHoldback(order.toId(address(fund)));
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

  /// @dev Bootstraps wrapped shares and commits a REDEEM order (holdback confirmation
  ///      pending, like every redeem).
  function _commitRedeemOrder() internal returns (Order memory order) {
    _depositAndUnlock(ONE_USDC);
    order = _redeemOrder(ONE_MTOKEN, ONE_USDC);
    fund.create(order);
    _commitRedeem(order);
  }
}
