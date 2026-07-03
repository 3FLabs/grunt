// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Retargetter} from "src/manager/rebalancer/Retargetter.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {MockRetargetterFund} from "test/mock/manager/rebalancer/MockRetargetterFund.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {Offer} from "src/interfaces/request/IOfferReceiver.sol";
import {Order, Mode} from "src/libs/funds/Order.sol";
import {IRequest} from "src/interfaces/request/IRequest.sol";
import {ITokenController} from "src/interfaces/request/ITokenController.sol";
import {YieldEstimates} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";

/// @title RetargetterHandler
/// @notice Foundry invariant-test handler driving the Retargetter through bounded, fuzz-driven
///         actions: ASYNC operation lifecycle (start, consume, authorize, pull, repay,
///         resolve), the mock fund order lifecycle (create, commit, settle, unlock, cancel,
///         recover), guarded rebalances, SYNC flash-loan windows, and owner/environment
///         perturbations (force repay, warp, share price, estimates, target LTV).
/// @dev Every action bounds its inputs, early-returns on unmet preconditions and wraps the
///      target call in try/catch so the fuzzer explores freely (fail_on_revert = false).
///      Ghost variables record cross-call facts the invariant suite asserts afterwards.
contract RetargetterHandler is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 internal constant WAD = 1e18;
  uint256 internal constant BPS = 10_000;
  uint256 internal constant SENTINEL = type(uint256).max;

  string internal constant REQUEST_NAME = "Retarget Bridge";
  string internal constant REQUEST_SYMBOL = "RTG";

  /// @dev keccak256("Offer(address maker,uint256 amount,uint256 expectedReturn,uint256 nonce,uint256 expiration,bool useCallback)")
  bytes32 internal constant OFFER_TYPEHASH = 0x3ded0c963332962cf2d273c8fb4f3e69f4ef33407ca72484fcebb56263ad0664;

  bytes32 internal constant DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       EXTERNAL REFS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  Retargetter public retargetter;
  PositionManager public positionManager;
  IBorrowPosition public borrowPosition1;
  MockRetargetterFund public fund;
  address public flashLoanAdapter;
  MockERC20 public collateralToken;
  MockERC20 public debtToken;
  address public owner;
  address public rebalancer;
  address public consumer;

  /// @notice The handler-owned offer maker (lender) wallet.
  address public makerAddr;
  uint256 internal makerKey;

  /// @notice The handler-owned broker receiving mint authorizations.
  address public brokerAddr;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      GHOST VARIABLES                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Number of successfully started ASYNC operations.
  uint256 public operationCount;

  /// @notice Number of successfully resolved ASYNC operations.
  uint256 public resolveCount;

  /// @notice Number of successful consumes.
  uint256 public consumeCount;

  /// @notice Number of SYNC windows that completed successfully.
  uint256 public syncSuccessCount;

  /// @notice The Request of the last successfully started ASYNC operation.
  address public lastRequest;

  /// @notice True once at least one resolve succeeded.
  bool public sawResolve;

  /// @notice Set if a resolve succeeded while the Request reported itself unrepaid.
  bool public resolvedRequestUnrepaid;

  /// @notice Set if a resolve succeeded with a nonzero bound-asset balance left behind.
  bool public residualAtSettlementViolated;

  /// @notice Set if a successful consume left the PT supply above the live principal cap.
  bool public capViolatedAtConsume;

  /// @notice Set if a successful authorization left the committed principal (PT supply plus
  ///         outstanding authorizations) above the live principal cap.
  bool public capViolatedAtAuthorize;

  /// @notice Set if the active operation's startedAt changed after being recorded nonzero.
  bool public startedAtMutated;

  /// @notice Set if a successful rebalancer-driven rebalance ended above target without
  ///         strictly improving on its before snapshot.
  bool public directionViolated;

  /// @notice Set if any SYNC attempt (successful or reverted) left persistent state behind.
  bool public syncStatePersisted;

  /// @dev The recorded startedAt of the current operation (0 while unset or inactive).
  uint40 internal ghostStartedAt;

  /// @dev Fresh-salt counter (funds archive ended order ids, so salts are never reused).
  uint256 internal saltCounter;

  /// @dev Strictly increasing maker nonce (Request nonces are one-shot per maker).
  uint256 internal makerNonce;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  bool public initialized;

  /// @notice One-time setup, called by the invariant test's setUp().
  function initialize(
    Retargetter retargetter_,
    PositionManager positionManager_,
    IBorrowPosition borrowPosition1_,
    MockRetargetterFund fund_,
    address flashLoanAdapter_,
    MockERC20 collateralToken_,
    MockERC20 debtToken_,
    address owner_,
    address rebalancer_,
    address consumer_
  ) external {
    require(!initialized, "already initialized");
    initialized = true;

    retargetter = retargetter_;
    positionManager = positionManager_;
    borrowPosition1 = borrowPosition1_;
    fund = fund_;
    flashLoanAdapter = flashLoanAdapter_;
    collateralToken = collateralToken_;
    debtToken = debtToken_;
    owner = owner_;
    rebalancer = rebalancer_;
    consumer = consumer_;

    Vm.Wallet memory wallet = vm.createWallet("invariantMaker");
    makerAddr = wallet.addr;
    makerKey = wallet.privateKey;
    brokerAddr = makeAddr("invariantBroker");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      GHOST TRACKING                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Checks before and after every action that the active operation's startedAt never
  ///      changes once recorded nonzero; resets the recording when the operation resolves.
  modifier trackStartedAt() {
    _checkStartedAt();
    _;
    _checkStartedAt();
  }

  function _checkStartedAt() internal {
    if (!initialized) return;
    if (!retargetter.isActive()) {
      ghostStartedAt = 0;
      return;
    }
    (,,, uint40 startedAt,,,) = retargetter.operation();
    if (ghostStartedAt == 0) {
      ghostStartedAt = startedAt;
    } else if (startedAt != ghostStartedAt) {
      startedAtMutated = true;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ASYNC FLOW ACTIONS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Starts an ASYNC operation with a principal bounded to the live cap.
  function act_startAsync(uint256 principalSeed, uint256 yieldCapSeed) external trackStartedAt {
    if (retargetter.isActive()) return;
    uint256 cap;
    try retargetter.maxPrincipal(address(positionManager)) returns (uint256 cap_) {
      cap = cap_;
    } catch {
      return;
    }
    uint256 principal = _bound(principalSeed, 0, cap);
    // Above the 1000 bps config ceiling half the time so the min() clamp gets exercised
    uint16 yieldCap = uint16(_bound(yieldCapSeed, 0, 2000));
    vm.prank(rebalancer);
    try retargetter.startRetargetting(
      address(positionManager), principal, yieldCap, address(fund), REQUEST_NAME, REQUEST_SYMBOL
    ) returns (
      address request
    ) {
      lastRequest = request;
      operationCount++;
    } catch {}
  }

  /// @notice Consumes a freshly signed offer with a yield ratio spread around the cap so both
  ///         YieldTooHigh and success paths get exercised, and a partial or full fill.
  function act_consume(uint256 amountSeed, uint256 yieldSeed) external trackStartedAt {
    if (!retargetter.isActive()) return;
    (, address request,,, uint16 operationCap,,) = retargetter.operation();

    uint256 offerAmount = _bound(amountSeed, 1e18, 10_000e18);
    uint256 ratioBps = _bound(yieldSeed, 0, uint256(operationCap) * 2 + 100);
    uint256 expectedReturn = offerAmount * ratioBps / BPS;
    uint256 ptAmount = _bound(amountSeed >> 128, offerAmount / 2 + 1, offerAmount);

    Offer memory offer = Offer({
      maker: makerAddr,
      amount: offerAmount,
      expectedReturn: expectedReturn,
      nonce: ++makerNonce,
      expiration: block.timestamp + 1 days,
      useCallback: false
    });
    bytes memory signature = _signOffer(offer, request);

    debtToken.mint(makerAddr, offerAmount);
    vm.prank(makerAddr);
    debtToken.approve(request, offerAmount);

    vm.prank(consumer);
    try retargetter.consume(offer, signature, ptAmount) {
      consumeCount++;
      // The position manager state did not move during consume, so the live cap must still
      // cover the whole PT supply the gate just admitted
      (uint128 ptSupply,) = ITokenController(request).totalSupplies();
      try retargetter.maxPrincipal(address(positionManager)) returns (uint256 capNow) {
        if (uint256(ptSupply) > capNow) capViolatedAtConsume = true;
      } catch {}
    } catch {}
  }

  /// @notice Sets, replaces or revokes the broker's mint authorization with amounts spread
  ///         around both caps so every gate and the revocation path get exercised.
  function act_authorizeMinting(uint256 amountSeed, uint256 yieldSeed) external trackStartedAt {
    if (!retargetter.isActive()) return;
    (, address request,,, uint16 operationCap,,) = retargetter.operation();
    if (request == address(0)) return;

    uint128 ptAmount = uint128(_bound(amountSeed, 0, 10_000e18));
    uint256 ratioBps = _bound(yieldSeed, 0, uint256(operationCap) * 2 + 100);
    uint128 ytAmount = uint128(uint256(ptAmount) * ratioBps / BPS);

    vm.prank(consumer);
    try retargetter.authorizeMinting(brokerAddr, ptAmount, ytAmount) {
      if (ptAmount == 0 && ytAmount == 0) return;
      // The position did not move during the call, so the committed principal the gate just
      // admitted must still fit under the live cap
      (uint128 ptSupply,) = ITokenController(request).totalSupplies();
      try retargetter.maxPrincipal(address(positionManager)) returns (uint256 capNow) {
        if (uint256(ptSupply) + _outstandingAuthorizedPt(request) > capNow) capViolatedAtAuthorize = true;
      } catch {}
    } catch {}
  }

  /// @notice The broker funds and mints whatever authorization it currently holds.
  function act_mintAuthorized() external trackStartedAt {
    if (!retargetter.isActive()) return;
    (, address request,,,,,) = retargetter.operation();
    if (request == address(0)) return;
    (uint128 ptAuth,) = IRequest(request).mintAuthorization(brokerAddr);
    if (ptAuth == 0) return;

    debtToken.mint(brokerAddr, ptAuth);
    vm.startPrank(brokerAddr);
    debtToken.approve(request, ptAuth);
    try IRequest(request).mint(type(uint128).max, 0) {} catch {}
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

  /// @notice Pulls consumed funds from the Request, bounded by its balance.
  function act_pull(uint256 amountSeed) external trackStartedAt {
    if (!retargetter.isActive()) return;
    (, address request,,,,,) = retargetter.operation();
    uint256 requestBalance = debtToken.balanceOf(request);
    if (requestBalance == 0) return;
    uint256 amount = _bound(amountSeed, 1, requestBalance);
    vm.prank(rebalancer);
    try retargetter.pullRequestFunds(amount) {} catch {}
  }

  /// @notice Trustlessly repays the Request from the Retargetter's balance.
  function act_repay() external trackStartedAt {
    if (!retargetter.isActive()) return;
    vm.prank(rebalancer);
    try retargetter.repay() {} catch {}
  }

  /// @notice Resolves the operation; on success records the settlement-gate ghosts.
  function act_resolve() external trackStartedAt {
    if (!retargetter.isActive()) return;
    (, address request,,,,,) = retargetter.operation();
    vm.prank(rebalancer);
    try retargetter.resolve() {
      sawResolve = true;
      resolveCount++;
      if (!IRequest(request).isRepaid()) resolvedRequestUnrepaid = true;
      if (debtToken.balanceOf(address(retargetter)) != 0 || collateralToken.balanceOf(address(retargetter)) != 0) {
        residualAtSettlementViolated = true;
      }
    } catch {}
  }

  /// @notice Owner override settling the Request with an amount bounded by the Retargetter's
  ///         balance and open bounds, so a missing shortfall never wedges the operation.
  function act_forceRepay(uint256 amountSeed) external trackStartedAt {
    if (!retargetter.isActive()) return;
    uint256 amount = _bound(amountSeed, 0, debtToken.balanceOf(address(retargetter)));
    vm.prank(owner);
    try retargetter.forceRepay(amount, 0, type(uint256).max) {} catch {}
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   ORDER LIFECYCLE ACTIONS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a fund order with a fresh salt, sized by the Retargetter's balance of the
  ///         input token when it holds any (otherwise an arbitrary size that will fail commit).
  function act_createOrder(bool redeem, uint256 inputSeed) external trackStartedAt {
    if (!retargetter.isActive()) return;
    (,,,,,, bool orderLive) = retargetter.operation();
    if (orderLive) return;
    Mode mode = redeem ? Mode.REDEEM : Mode.DEPOSIT;
    uint256 available =
      redeem ? collateralToken.balanceOf(address(retargetter)) : debtToken.balanceOf(address(retargetter));
    uint256 input = available > 0 ? _bound(inputSeed, 1, available) : _bound(inputSeed, 1, 10_000e18);
    Order memory order_ = _retargetterOrder(mode, input);
    vm.prank(rebalancer);
    try retargetter.create(order_) {} catch {}
  }

  /// @notice Commits the stored order (pulls the input from the Retargetter).
  function act_commit() external trackStartedAt {
    if (!_orderLive()) return;
    vm.prank(rebalancer);
    try retargetter.commit() {} catch {}
  }

  /// @notice Completes the mock fund's asynchronous settlement for the committed order.
  function act_settle() external trackStartedAt {
    if (fund.currentOrderId() == bytes32(0)) return;
    fund.settle();
  }

  /// @notice Unlocks the settled order's output to the Retargetter.
  function act_unlock() external trackStartedAt {
    if (!_orderLive()) return;
    vm.prank(rebalancer);
    try retargetter.unlock() {} catch {}
  }

  /// @notice Cancels the stored order (only ACCEPTED or PENDING orders can be canceled).
  function act_cancel() external trackStartedAt {
    if (!_orderLive()) return;
    vm.prank(rebalancer);
    try retargetter.cancelOrder() {} catch {}
  }

  /// @notice Fails the fund's processing and recovers the committed input.
  function act_failAndRecover() external trackStartedAt {
    if (!_orderLive()) return;
    fund.failProcessing();
    vm.prank(rebalancer);
    try retargetter.recoverOrder() {} catch {}
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REBALANCE ACTIONS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Drives one of four canned rebalance shapes as the rebalancer: SUPPLY sentinel,
  ///         REPAY sentinel, bounded BORROW (paired with a SUPPLY sentinel when collateral is
  ///         held, since a standalone borrow trips the position manager's rebalance-loss cap;
  ///         half the time snapped to the owed amount, the canonical repayment sizing), or
  ///         REPAY plus WITHDRAW. Records the direction ghost: a successful non-owner
  ///         rebalance ending above target must have strictly improved on its before snapshot.
  function act_rebalance(uint8 shapeSeed, uint256 amountSeed) external trackStartedAt {
    if (!retargetter.isActive()) return;
    uint256 shape = _bound(uint256(shapeSeed), 0, 3);
    RebalancingData memory data;
    if (shape == 0) {
      if (collateralToken.balanceOf(address(retargetter)) == 0) return;
      data = _singleLeg(SENTINEL, 0, RebalancingOperationType.SUPPLY, SENTINEL);
    } else if (shape == 1) {
      if (debtToken.balanceOf(address(retargetter)) == 0) return;
      if (borrowPosition1.totalBorrowed() == 0) return;
      data = _singleLeg(0, SENTINEL, RebalancingOperationType.REPAY, SENTINEL);
    } else if (shape == 2) {
      // The supplied collateral counts toward the borrow headroom (the oracle stays 1:1)
      uint256 collateralBalance = collateralToken.balanceOf(address(retargetter));
      uint256 headroom = _borrowHeadroom(collateralBalance);
      if (headroom == 0) return;
      uint256 owedNow = _owedOrZero();
      uint256 amount =
        (amountSeed % 2 == 0 && owedNow > 0 && owedNow <= headroom) ? owedNow : _bound(amountSeed, 1, headroom);
      if (collateralBalance > 0) {
        data = _twoLegs(SENTINEL, 0, RebalancingOperationType.SUPPLY, SENTINEL, RebalancingOperationType.BORROW, amount);
      } else {
        data = _singleLeg(0, 0, RebalancingOperationType.BORROW, amount);
      }
    } else {
      uint256 debtBalance = debtToken.balanceOf(address(retargetter));
      uint256 moduleDebt = borrowPosition1.totalBorrowed();
      uint256 repayAmount = debtBalance < moduleDebt ? debtBalance : moduleDebt;
      if (repayAmount < 2) return;
      uint256 withdrawAmount = _bound(amountSeed, 1, repayAmount / 2);
      data = _twoLegs(
        0, repayAmount, RebalancingOperationType.REPAY, repayAmount, RebalancingOperationType.WITHDRAW, withdrawAmount
      );
    }

    (uint256 target,) = positionManager.config();
    uint256 ltvBefore = _positionManagerLtv();
    vm.prank(rebalancer);
    try retargetter.rebalance(data) {
      uint256 ltvAfter = _positionManagerLtv();
      if (ltvAfter > target && ltvAfter >= ltvBefore) directionViolated = true;
    } catch {}
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        SYNC ACTIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Runs a SYNC window with one of three canned payloads: the LTV-up happy shape,
  ///         an empty payload, or an order-left-open payload (which must revert at the window
  ///         close). Either way no persistent state may survive the attempt.
  function act_syncRetarget(uint8 shapeSeed, uint256 amountSeed) external trackStartedAt {
    if (retargetter.isActive()) return;
    uint256 shape = _bound(uint256(shapeSeed), 0, 2);
    uint256 cap;
    try retargetter.maxPrincipal(address(positionManager)) returns (uint256 cap_) {
      cap = cap_;
    } catch {
      return;
    }
    if (cap == 0) return;

    bytes[] memory calls;
    uint256 amount;
    if (shape == 0) {
      amount = _syncUpAmount(amountSeed, cap);
      if (amount == 0) return;
      fund.setSyncSettlement(true);
      calls = new bytes[](4);
      calls[0] = abi.encodeCall(retargetter.create, (_retargetterOrder(Mode.DEPOSIT, amount)));
      calls[1] = abi.encodeCall(retargetter.commit, ());
      calls[2] = abi.encodeCall(retargetter.unlock, ());
      calls[3] = abi.encodeCall(
        retargetter.rebalance,
        (_twoLegs(SENTINEL, 0, RebalancingOperationType.SUPPLY, SENTINEL, RebalancingOperationType.BORROW, amount))
      );
    } else if (shape == 1) {
      amount = _bound(amountSeed, 1, cap);
      calls = new bytes[](0);
    } else {
      amount = _bound(amountSeed, 1, cap);
      calls = new bytes[](1);
      calls[0] = abi.encodeCall(retargetter.create, (_retargetterOrder(Mode.DEPOSIT, amount)));
    }

    vm.prank(rebalancer);
    try retargetter.startSyncRetargetting(address(positionManager), flashLoanAdapter, amount, address(fund), calls) {
      syncSuccessCount++;
    } catch {}

    // Windows never leak state across transactions, whether they landed or reverted
    if (retargetter.isActive()) syncStatePersisted = true;
    if (_orderLive()) syncStatePersisted = true;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   ENVIRONMENT ACTIONS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Warps time forward so interest accrues and repayment ticks promote.
  function act_warp(uint256 secondsSeed) external trackStartedAt {
    vm.warp(block.timestamp + _bound(secondsSeed, 1 hours, 10 days));
  }

  /// @notice Drifts the mock fund's share price within a 5% band.
  function act_setSharePrice(uint256 priceSeed) external trackStartedAt {
    fund.setSharePrice(_bound(priceSeed, 0.95e18, 1.05e18));
  }

  /// @notice Owner update of the yield estimates with small bounded rates and durations.
  function act_setEstimates(
    uint256 requestYieldSeed,
    uint256 borrowRateSeed,
    uint256 collateralYieldSeed,
    uint256 durationSeed
  ) external trackStartedAt {
    YieldEstimates memory estimates = YieldEstimates({
      requestYieldRate: uint64(_bound(requestYieldSeed, 0, 0.1e18)),
      borrowRate: uint64(_bound(borrowRateSeed, 0, 0.1e18)),
      collateralYieldRate: uint64(_bound(collateralYieldSeed, 0, 0.1e18)),
      subscriptionDuration: uint32(_bound(durationSeed, 0, 14 days)),
      redemptionDuration: uint32(_bound(durationSeed >> 128, 0, 14 days))
    });
    vm.prank(owner);
    try retargetter.setEstimates(estimates) {} catch {}
  }

  /// @notice Moves the position manager's target LTV, flipping the operation direction.
  /// @dev Upper bound stays at the modules' 0.72e18 safe LTV (setLtv enforces it).
  function act_setTargetLtv(uint256 ltvSeed) external trackStartedAt {
    uint256 newLtv = _bound(ltvSeed, 0.3e18, 0.72e18);
    vm.prank(owner);
    try positionManager.setLtv(newLtv) {} catch {}
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Whether the Retargetter currently stores a live order.
  function _orderLive() internal view returns (bool orderLive) {
    (,,,,,, orderLive) = retargetter.operation();
  }

  /// @dev Current owed amount of the active operation, zero when the view reverts.
  function _owedOrZero() internal view returns (uint256) {
    try retargetter.owed() returns (uint256 owedNow) {
      return owedNow;
    } catch {
      return 0;
    }
  }

  /// @dev Aggregate position manager LTV under the Retargetter's snapshot convention.
  function _positionManagerLtv() internal view returns (uint256) {
    uint256 debt = positionManager.debtAmount();
    if (debt == 0) return 0;
    uint256 collateralQuoted = positionManager.collateralAmountQuoted();
    if (collateralQuoted == 0) return type(uint256).max;
    return debt * WAD / collateralQuoted;
  }

  /// @dev Largest BORROW that keeps both the aggregate and borrowPosition1 at or below
  ///      target, counting collateral about to be supplied to borrowPosition1 in the same
  ///      rebalance (quoted one-to-one, matching the fixture oracle).
  function _borrowHeadroom(uint256 incomingCollateral) internal view returns (uint256) {
    (uint256 target,) = positionManager.config();
    uint256 aggregateMax = (positionManager.collateralAmountQuoted() + incomingCollateral) * target / WAD;
    uint256 debt = positionManager.debtAmount();
    if (aggregateMax <= debt) return 0;
    uint256 headroom = aggregateMax - debt;
    uint256 moduleMax = (borrowPosition1.totalCollateralQuoted() + incomingCollateral) * target / WAD;
    uint256 moduleDebt = borrowPosition1.totalBorrowed();
    if (moduleMax <= moduleDebt) return 0;
    uint256 moduleHeadroom = moduleMax - moduleDebt;
    return headroom < moduleHeadroom ? headroom : moduleHeadroom;
  }

  /// @dev Flash-loan size for the LTV-up SYNC payload: bounded by both the live cap and the
  ///      zero-rate ideal principal, so the post-window LTV lands at or below target at a
  ///      share price of one (price drift above one may still revert, which is caught).
  function _syncUpAmount(uint256 seed, uint256 cap) internal view returns (uint256) {
    (uint256 target,) = positionManager.config();
    uint256 debt = positionManager.debtAmount();
    uint256 targetDebt = positionManager.collateralAmountQuoted() * target / WAD;
    if (targetDebt <= debt) return 0;
    uint256 ideal = (targetDebt - debt) * WAD / (WAD - target);
    uint256 max = ideal < cap ? ideal : cap;
    if (max == 0) return 0;
    return _bound(seed, 1, max);
  }

  /// @dev Builds a Retargetter-owned order with a fresh salt and a one-to-one output.
  function _retargetterOrder(Mode mode, uint256 input) internal returns (Order memory) {
    return Order({
      mode: mode,
      owner: address(retargetter),
      receiver: address(retargetter),
      input: input,
      output: input,
      salt: bytes32(++saltCounter)
    });
  }

  /// @dev Builds rebalancing data with a single leg against borrowPosition1.
  function _singleLeg(uint256 collateral, uint256 debt, RebalancingOperationType operationType, uint256 amount)
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

  /// @dev Builds rebalancing data with two legs against borrowPosition1.
  function _twoLegs(
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

  /// @dev Signs an offer against a Request's EIP-712 domain (operation name, version 0.0.1).
  function _signOffer(Offer memory offer, address request) internal view returns (bytes memory) {
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
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
    return abi.encodePacked(r, s, v);
  }
}
