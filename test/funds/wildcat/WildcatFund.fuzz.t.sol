// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WildcatFund} from "src/funds/wildcat/WildcatFund.sol";
import {WildcatFundFactory} from "src/funds/wildcat/WildcatFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {RAY} from "src/libs/Constants.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockWildcatMarket} from "../../mock/funds/wildcat/MockWildcatMarket.sol";
import {MockWildcat4626Wrapper} from "../../mock/funds/wildcat/MockWildcat4626Wrapper.sol";

contract WildcatFundFuzzTest is Test {
  using LibOrder for Order;

  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  WildcatFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockWildcatMarket public market;
  MockWildcat4626Wrapper public wrapper;

  address public owner;

  function setUp() public {
    owner = makeAddr("owner");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    market = new MockWildcatMarket(address(usdc));
    wrapper = new MockWildcat4626Wrapper(address(market));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(wrapper), "wv-WMT", "Wrapped v-WMT");

    WildcatFundFactory factory = new WildcatFundFactory(owner);
    fund = WildcatFund(factory.createFund(owner, address(this), address(wrapper), address(wrappedShare)));

    vm.startPrank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
    vm.stopPrank();
  }

  /// @dev Deposit then immediately redeem at the same scale factor: the receiver gets back the
  ///      deposited amount within rounding dust (half-up ray conversions round-trip within 1 wei
  ///      per conversion step).
  function testFuzz_DepositRedeemRoundtrip(uint256 amount, uint256 scaleFactor) public {
    amount = bound(amount, 1e6, 1e13); // 1 USDC .. 10M USDC
    scaleFactor = bound(scaleFactor, RAY, 3 * RAY); // up to 3x accrued interest
    market.setScaleFactor(scaleFactor);

    usdc.mint(address(this), amount);

    // Deposit
    uint256 expectedShares = amount * RAY / scaleFactor;
    Order memory depositOrder = _order(Mode.DEPOSIT, amount, expectedShares, bytes32(uint256(1)));
    fund.create(depositOrder);
    usdc.approve(address(fund), amount);
    fund.commit(depositOrder);
    (, uint256 shares) = fund.unlock(depositOrder);

    assertApproxEqAbs(shares, expectedShares, 1, "shares within rounding of expected");
    assertEq(wrappedShare.balanceOf(address(this)), shares, "wrapped shares received");

    // Redeem everything
    uint256 expectedAssets = shares * scaleFactor / RAY;
    Order memory redeemOrder = _order(Mode.REDEEM, shares, expectedAssets, bytes32(uint256(2)));
    fund.create(redeemOrder);
    wrappedShare.approve(address(fund), shares);
    fund.commit(redeemOrder);

    uint32 expiry = fund.currentBatchExpiry();
    vm.warp(expiry + 1);
    market.payBatch(expiry, type(uint256).max);

    uint256 balanceBefore = usdc.balanceOf(address(this));
    (State finalState, uint256 assetsOut) = fund.unlock(redeemOrder);

    assertEq(uint256(finalState), uint256(State.ENDED), "ended");
    assertEq(usdc.balanceOf(address(this)) - balanceBefore, assetsOut, "receiver got unlocked amount");
    assertApproxEqAbs(assetsOut, amount, 2, "roundtrip within rounding dust");
  }

  /// @dev Partial batch payments always sum to the full owed amount, regardless of split.
  function testFuzz_PartialPaymentsSumToTotal(uint256 amount, uint256 firstShare) public {
    amount = bound(amount, 10e6, 1e13);
    firstShare = bound(firstShare, 1, 99);

    usdc.mint(address(this), amount);

    Order memory depositOrder = _order(Mode.DEPOSIT, amount, amount, bytes32(uint256(1)));
    fund.create(depositOrder);
    usdc.approve(address(fund), amount);
    fund.commit(depositOrder);
    (, uint256 shares) = fund.unlock(depositOrder);

    Order memory redeemOrder = _order(Mode.REDEEM, shares, amount, bytes32(uint256(2)));
    fund.create(redeemOrder);
    wrappedShare.approve(address(fund), shares);
    fund.commit(redeemOrder);

    uint32 expiry = fund.currentBatchExpiry();
    vm.warp(expiry + 1);

    uint256 balanceBefore = usdc.balanceOf(address(this));

    market.payBatch(expiry, shares * firstShare / 100);
    (State midState, uint256 firstOut) = fund.unlock(redeemOrder);
    assertEq(uint256(midState), uint256(State.PROCESSING), "processing after partial");

    market.payBatch(expiry, type(uint256).max);
    (State finalState, uint256 secondOut) = fund.unlock(redeemOrder);
    assertEq(uint256(finalState), uint256(State.ENDED), "ended after full payment");

    assertApproxEqAbs(
      usdc.balanceOf(address(this)) - balanceBefore, amount, 2, "partial payments sum to deposited amount"
    );
    assertEq(usdc.balanceOf(address(this)) - balanceBefore, firstOut + secondOut, "returned amounts consistent");
  }

  function _order(Mode mode, uint256 input, uint256 output, bytes32 salt) internal view returns (Order memory) {
    return Order({mode: mode, owner: address(this), receiver: address(this), input: input, output: output, salt: salt});
  }
}
