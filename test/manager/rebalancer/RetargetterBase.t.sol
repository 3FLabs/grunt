// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {PositionManagerBaseTest} from "../PositionManagerBase.t.sol";
import {Retargetter} from "src/manager/rebalancer/Retargetter.sol";
import {RetargetterFactory} from "src/manager/rebalancer/RetargetterFactory.sol";
import {RetargetterQuoter} from "src/manager/rebalancer/RetargetterQuoter.sol";
import {MorphoFlashLoanAdapter} from "src/manager/rebalancer/MorphoFlashLoanAdapter.sol";
import {RetargetterConfig, YieldEstimates} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {RequestFactory} from "src/request/RequestFactory.sol";
import {IRequest} from "src/interfaces/request/IRequest.sol";
import {Offer} from "src/interfaces/request/IOfferReceiver.sol";
import {Order, Mode} from "src/libs/funds/Order.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {MockRetargetterFund} from "test/mock/manager/rebalancer/MockRetargetterFund.sol";

/// @title RetargetterBaseTest
/// @notice Shared fixture for the Retargetter test suites: full PositionManager + Morpho stack
///         from PositionManagerBaseTest, plus the Retargetter stack (quoter, request factory,
///         beacon factory, instance), a mock fund with settable settlement and the Morpho
///         flash-loan adapter, all wired per the factory checklist.
contract RetargetterBaseTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST CONTRACTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  Retargetter public retargetter;
  RetargetterFactory public retargetterFactory;
  RetargetterQuoter public retargetterQuoter;
  RequestFactory public requestFactory;
  MorphoFlashLoanAdapter public flashLoanAdapter;
  MockRetargetterFund public fund;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST ADDRESSES                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public consumer;
  address public broker;
  Vm.Wallet internal maker;
  uint256 internal makerNonce;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 internal constant RETARGETTER_REBALANCER_ROLE = 1 << 0;
  uint256 internal constant RETARGETTER_CONSUMER_ROLE = 1 << 1;

  uint32 internal constant DEFAULT_HORIZON = 365 days;
  uint24 internal constant DEFAULT_TICK_DURATION = 1 days;
  uint24 internal constant DEFAULT_TICK_THRESHOLD = 10 hours;
  uint16 internal constant DEFAULT_MAX_YIELD_BPS = 1000;
  uint16 internal constant DEFAULT_PRINCIPAL_BUFFER_BPS = 100;

  string internal constant REQUEST_NAME = "Retarget Bridge";
  string internal constant REQUEST_SYMBOL = "RTG";

  uint256 internal constant MAX_SENTINEL = type(uint256).max;

  /// @dev keccak256("Offer(address maker,uint256 amount,uint256 expectedReturn,uint256 nonce,uint256 expiration,bool useCallback)")
  bytes32 internal constant OFFER_TYPEHASH = 0x3ded0c963332962cf2d273c8fb4f3e69f4ef33407ca72484fcebb56263ad0664;

  bytes32 internal constant DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public virtual override {
    super.setUp();

    consumer = makeAddr("consumer");
    broker = makeAddr("broker");
    maker = vm.createWallet("maker");

    requestFactory = new RequestFactory(owner);
    retargetterQuoter = new RetargetterQuoter();
    retargetterFactory = new RetargetterFactory(owner, address(retargetterQuoter), address(requestFactory));
    // The instance is bound to its position manager at creation; the pair is derived from it
    retargetter = Retargetter(retargetterFactory.createRetargetter(owner, address(positionManager), _defaultConfig()));
    fund = new MockRetargetterFund(address(debtToken), address(collateralToken));
    flashLoanAdapter = new MorphoFlashLoanAdapter(address(morpho));

    vm.startPrank(owner);
    retargetter.grantRoles(rebalancer, RETARGETTER_REBALANCER_ROLE);
    retargetter.grantRoles(consumer, RETARGETTER_CONSUMER_ROLE);
    retargetter.setFund(address(fund), true);
    retargetter.setFlashLoanModule(address(flashLoanAdapter), true);
    positionManager.grantRoles(address(retargetter), _ROLE_REBALANCER);
    // One basis point absorbs the Morpho rounding dust, no cooldown between steps
    positionManager.setRebalanceConfig(1, 0);
    vm.stopPrank();

    // Fund the maker so consumed offers can transfer the principal to the Request
    _mintDebt(maker.addr, 1_000_000e18);

    vm.label(address(retargetter), "Retargetter");
    vm.label(address(fund), "MockRetargetterFund");
    vm.label(address(flashLoanAdapter), "MorphoFlashLoanAdapter");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _defaultConfig() internal pure returns (RetargetterConfig memory) {
    return RetargetterConfig({
      horizon: DEFAULT_HORIZON,
      tickDuration: DEFAULT_TICK_DURATION,
      tickThreshold: DEFAULT_TICK_THRESHOLD,
      maxYieldBps: DEFAULT_MAX_YIELD_BPS,
      principalBufferBps: DEFAULT_PRINCIPAL_BUFFER_BPS,
      collateralResidualExponent: 0,
      debtResidualExponent: 0,
      estimates: _zeroEstimates()
    });
  }

  /// @dev Sets the residual tolerance exponents on the live config (owner action).
  function _setResidualExponents(uint8 collateralExponent, uint8 debtExponent) internal {
    RetargetterConfig memory config_ = retargetter.config();
    config_.collateralResidualExponent = collateralExponent;
    config_.debtResidualExponent = debtExponent;
    vm.prank(owner);
    retargetter.setConfig(config_);
  }

  function _zeroEstimates() internal pure returns (YieldEstimates memory) {
    return YieldEstimates({
      requestYieldRate: 0, borrowRate: 0, collateralYieldRate: 0, subscriptionDuration: 0, redemptionDuration: 0
    });
  }

  /// @dev Seeds the position manager with a leveraged position through the LP surface.
  function _seedPosition(uint256 collateral, uint256 debt) internal {
    _mintCollateral(minter, collateral);
    vm.prank(minter);
    positionManager.deposit(collateral, debt);
  }

  /// @dev Moves the position manager's target LTV (owner action on the position manager).
  function _setTargetLtv(uint256 ltv) internal {
    vm.prank(owner);
    positionManager.setLtv(ltv);
  }

  /// @dev Starts a default ASYNC operation as the rebalancer.
  function _startAsync(uint256 principal, uint16 maxYieldBps) internal returns (address request) {
    vm.prank(rebalancer);
    request = retargetter.startRetargetting(principal, maxYieldBps, address(fund), REQUEST_NAME, REQUEST_SYMBOL);
  }

  /// @dev Builds a fresh offer from the maker wallet with a one-shot nonce.
  function _createOffer(uint256 amount, uint256 expectedReturn) internal returns (Offer memory) {
    return Offer({
      maker: maker.addr,
      amount: amount,
      expectedReturn: expectedReturn,
      nonce: ++makerNonce,
      expiration: block.timestamp + 1 days,
      useCallback: false
    });
  }

  /// @dev Signs an offer against a Request's EIP-712 domain (name from the operation, version 0.0.1).
  function _signOffer(Offer memory offer, address request) internal returns (bytes memory) {
    bytes32 structHash = keccak256(
      abi.encode(
        OFFER_TYPEHASH,
        offer.maker,
        offer.amount,
        offer.expectedReturn,
        offer.nonce,
        offer.expiration,
        offer.useCallback
      )
    );
    bytes32 domainSeparator = keccak256(
      abi.encode(DOMAIN_TYPE_HASH, keccak256(bytes(REQUEST_NAME)), keccak256(bytes("0.0.1")), block.chainid, request)
    );
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(maker, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @dev Consumes a fresh offer for `ptAmount` with `expectedReturn` on the full offer amount.
  function _consume(address request, uint256 offerAmount, uint256 expectedReturn, uint256 ptAmount)
    internal
    returns (uint256 ytAmount)
  {
    Offer memory offer = _createOffer(offerAmount, expectedReturn);
    bytes memory signature = _signOffer(offer, request);
    vm.prank(maker.addr);
    debtToken.approve(request, offerAmount);
    vm.prank(consumer);
    ytAmount = retargetter.consume(offer, signature, ptAmount);
  }

  /// @dev Sets (or revokes) a mint authorization on the active operation as the consumer role.
  function _authorize(address to, uint128 ptAmount, uint128 ytAmount) internal {
    vm.prank(consumer);
    retargetter.authorizeMinting(to, ptAmount, ytAmount);
  }

  /// @dev Funds the broker and mints its outstanding authorization on the Request.
  function _mintAsBroker(address request, uint256 amount) internal {
    _mintDebt(broker, amount);
    vm.startPrank(broker);
    debtToken.approve(request, amount);
    IRequest(request).mint(type(uint128).max, 0);
    vm.stopPrank();
  }

  /// @dev Sums the still-unminted authorized principal over the registered accounts, the same
  ///      derivation the gates use.
  function _outstandingAuthorizedPt(address request) internal view returns (uint256 total) {
    address[] memory accounts = retargetter.authorizedAccounts();
    for (uint256 i; i < accounts.length; ++i) {
      (uint128 ptAmount,) = IRequest(request).mintAuthorization(accounts[i]);
      total += ptAmount;
    }
  }

  /// @dev Builds a Retargetter-owned order.
  function _order(Mode mode, uint256 input, uint256 output, bytes32 salt) internal view returns (Order memory) {
    return Order({
      mode: mode, owner: address(retargetter), receiver: address(retargetter), input: input, output: output, salt: salt
    });
  }

  /// @dev Builds rebalancing data with a single operation leg.
  function _rebalancingData(uint256 collateral, uint256 debt, RebalancingOperationType operationType, uint256 amount)
    internal
    view
    returns (RebalancingData memory data)
  {
    data.collateral = collateral;
    data.debt = debt;
    data.operations = new RebalancingOperation[](1);
    data.operations[0] =
      RebalancingOperation({position: address(borrowPosition1), operationType: operationType, amount: amount});
  }

  /// @dev Builds rebalancing data with two operation legs against borrowPosition1.
  function _rebalancingData2(
    uint256 collateral,
    uint256 debt,
    RebalancingOperationType firstType,
    uint256 firstAmount,
    RebalancingOperationType secondType,
    uint256 secondAmount
  ) internal view returns (RebalancingData memory data) {
    data.collateral = collateral;
    data.debt = debt;
    data.operations = new RebalancingOperation[](2);
    data.operations[0] =
      RebalancingOperation({position: address(borrowPosition1), operationType: firstType, amount: firstAmount});
    data.operations[1] =
      RebalancingOperation({position: address(borrowPosition1), operationType: secondType, amount: secondAmount});
  }

  /// @dev The gate-side principal cap for an operation carrying `yieldCapBps`, on the
  ///      fixture's zero estimates: the buffered ideal capped by the quoter's one-trip
  ///      repayment bound, the same min Retargetter._maxPrincipal computes.
  function _gateCap(uint16 yieldCapBps) internal view returns (uint256) {
    uint256 collateralQuoted = positionManager.collateralAmountQuoted();
    uint256 debt = positionManager.debtAmount();
    (uint256 target,) = positionManager.config();
    uint256 buffered = retargetterQuoter.retargetPrincipal(collateralQuoted, debt, target, 0, 0, 0, 0, 0)
      * (10_000 + DEFAULT_PRINCIPAL_BUFFER_BPS) / 10_000;
    uint256 oneTrip = retargetterQuoter.ltvUpOneTripPrincipal(collateralQuoted, debt, target, yieldCapBps, 0, 0, 0);
    return buffered < oneTrip ? buffered : oneTrip;
  }

  /// @dev Current aggregate LTV of the position manager (WAD; 0 when debt is 0).
  function _currentLtv() internal view returns (uint256) {
    uint256 debt = positionManager.debtAmount();
    if (debt == 0) return 0;
    return debt * WAD / positionManager.collateralAmountQuoted();
  }
}
