// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {CentrifugeFundFactory} from "src/funds/centrifuge/CentrifugeFundFactory.sol";
import {CentrifugeFund} from "src/funds/centrifuge/CentrifugeFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {Order, Mode} from "src/libs/funds/Order.sol";
import {MockCentrifugeVault} from "test/mock/funds/centrifuge/MockCentrifugeVault.sol";

contract FacilityCentrifugeFundsTest is FacilityBaseTest {
  using LibClone for address;

  CentrifugeFundFactory public centrifugeFundFactory;
  CentrifugeFund public realFund;
  WrappedAsset public wrappedShare;
  MockCentrifugeVault public centrifugeVault;
  PositionManager public wrappedPositionManager;

  uint256 private constant ISSUER_ROLE = 1 << 0;

  function setUp() public override {
    super.setUp();

    // Build a real Centrifuge fund stack (vault + wrapped share + fund)
    centrifugeVault = new MockCentrifugeVault(address(debtToken), address(collateralToken));

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);

    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(collateralToken), "wCollateral", "WrappedCollateral");

    centrifugeFundFactory = new CentrifugeFundFactory(owner);
    address realFundAddress =
      centrifugeFundFactory.createFund(owner, address(facility), address(centrifugeVault), address(wrappedShare));
    realFund = CentrifugeFund(realFundAddress);

    // The fund and wrapped share must be permissioned on the vault
    centrifugeVault.setPermissioned(address(realFund), true);
    centrifugeVault.setPermissioned(address(wrappedShare), true);
    vm.label(address(wrappedShare), "WrappedCollateral");

    vm.prank(owner);
    wrappedShare.grantRoles(address(realFund), ISSUER_ROLE);

    wrappedPositionManager = PositionManager(address(new PositionManager()).clone());
    wrappedPositionManager.initialize(
      owner,
      PositionManagerMetadata({
        name: "Wrapped Collateral Position Manager",
        symbol: "wPM",
        collateralAsset: address(wrappedShare),
        debtAsset: address(debtToken)
      }),
      PM_LTV,
      address(transferGuard),
      0,
      0
    );
    vm.label(address(wrappedPositionManager), "WrappedCollateralPositionManager");

    vm.startPrank(owner);
    wrappedPositionManager.grantRoles(address(facility), PM_MINTER_ROLE);
    vm.stopPrank();
  }

  function _createIntentWithRealFund(uint256 depositAmount) internal returns (uint256 intentId) {
    IntentProperties memory intentParams = _defaultIntentProperties();
    intentParams.depositAsset = Asset({asset: address(debtToken), isPositionManager: false});
    intentParams.targetAsset = Asset({asset: address(wrappedPositionManager), isPositionManager: true});
    intentParams.guardKey = address(wrappedPositionManager);

    vm.prank(owner);
    intentId = facility.createIntent(intentParams);
    _mintDebt(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    vm.warp(block.timestamp + 1 days + 1);

    vm.prank(facilitator);
    _setFund(intentId, address(realFund));
  }

  function test_forceEnd_thenResolve() public {
    uint256 intentId = _createIntentWithRealFund(500e18);
    uint256 orderInput = 500e18;

    // Fund must be the depositor and hold enough asset to commit the order
    assertEq(debtToken.balanceOf(address(facility)), orderInput, "Facility should hold deposited debt tokens");

    vm.prank(facilitator);
    facility.create(intentId, orderInput, orderInput, Mode.DEPOSIT);
    vm.prank(facilitator);
    facility.commit(intentId);

    (Order memory order,) = facility.getOrder(intentId);

    // Simulate external force-end after processing has started
    vm.prank(owner);
    realFund.forceEnd(order);

    // Auto-sync inside resolve clears the stale ended order and fund binding
    vm.prank(facilitator);
    facility.resolve(intentId);

    assertTrue(_isResolved(intentId), "Intent should be resolved after forceEnd");

    (order,) = facility.getOrder(intentId);
    assertEq(order.owner, address(0), "Order should be cleared after auto-sync");

    (,, address fund,) = facility.getIntent(intentId);
    assertEq(fund, address(0), "Fund should be cleared after auto-sync");
  }

  function test_forceEnd_thenSetFundAndCreate() public {
    uint256 firstOrderInput = 500e18;
    uint256 secondOrderInput = 300e18;

    uint256 intentId = _createIntentWithRealFund(firstOrderInput + secondOrderInput);

    assertEq(
      debtToken.balanceOf(address(facility)),
      firstOrderInput + secondOrderInput,
      "Facility should hold deposited debt tokens"
    );

    vm.prank(facilitator);
    facility.create(intentId, firstOrderInput, firstOrderInput, Mode.DEPOSIT);
    vm.prank(facilitator);
    facility.commit(intentId);

    (Order memory order,) = facility.getOrder(intentId);

    // Simulate external force-end and then immediately rebind the same fund
    vm.prank(owner);
    realFund.forceEnd(order);

    // use a fresh deadline so the swap digest has not been consumed
    uint256 deadline = block.timestamp + 1 hours + 1;
    vm.prank(facilitator);
    {
      address[] memory signers = new address[](1);
      bytes[] memory signatures = new bytes[](1);
      signers[0] = guardian;
      signatures[0] = _signSetFund(intentId, address(realFund), deadline, GUARDIAN_PK);
      facility.setFund(intentId, address(realFund), deadline, signers, signatures);
    }

    // Fund is rebinding-capable after auto-sync, so new create succeeds
    vm.prank(facilitator);
    facility.create(intentId, secondOrderInput, secondOrderInput, Mode.DEPOSIT);

    (order,) = facility.getOrder(intentId);
    assertEq(order.input, secondOrderInput, "A new order should be creatable after rebind");
  }
}
