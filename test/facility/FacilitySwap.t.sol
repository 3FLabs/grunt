// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

import {Facility} from "src/facility/Facility.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {SwapParams} from "src/interfaces/facility/base/IFacilitySwap.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";

contract FacilityEIP712Harness is Facility {
  function hashTypedData(bytes32 structHash) external view returns (bytes32) {
    return _hashTypedData(structHash);
  }
}

contract MockEIP1271Guardian {
  // EIP-1271 magic value.
  bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

  address internal immutable SIGNER;

  constructor(address signer_) {
    SIGNER = signer_;
  }

  function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
    if (SignatureCheckerLib.isValidSignatureNowCalldata(SIGNER, hash, signature)) {
      return MAGIC_VALUE;
    }
    return bytes4(0xffffffff);
  }
}

contract FacilitySwapTest is Test {
  /// @dev GUARDIAN_ROLE from FacilityRoles (_ROLE_1 = 1 << 1 = 2)
  uint256 internal constant GUARDIAN_ROLE = 2;

  FacilityEIP712Harness internal facility;
  PositionManager internal pm;
  MockERC20 internal collateral;
  MockERC20 internal debt;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");

  function setUp() public {
    facility = new FacilityEIP712Harness();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    collateral = new MockERC20("Collateral", "COL", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    pm = new PositionManager();
    pm.initialize(address(this), "PM", "PM", 6, address(collateral), address(debt), 0.8e18, address(0));
  }

  function _createIntent(uint8 quorum) internal returns (uint256 id) {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    id = facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(pm),
        depositCap: type(uint256).max,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: quorum,
        transferableIntent: true
      })
    );
  }

  function _deposit(address depositor, uint256 id, uint256 amount) internal {
    debt.mint(depositor, amount);
    vm.startPrank(depositor);
    debt.approve(address(facility), amount);
    facility.deposit(id, amount);
    vm.stopPrank();
  }

  function _digest(SwapParams memory params) internal view returns (bytes32) {
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256(
          "SwapParams(uint256 id1,address token1,uint256 id2,address token2,uint256 amount1,uint256 amount2,uint256 deadline)"
        ),
        params.id1,
        params.token1,
        params.id2,
        params.token2,
        params.amount1,
        params.amount2,
        params.deadline
      )
    );
    return facility.hashTypedData(structHash);
  }

  function _sign(bytes32 digest, Vm.Wallet memory wallet) internal returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
    return abi.encodePacked(r, s, v);
  }

  function test_Swap_QuorumZero_WorksAndReplaysBlocked() public {
    uint256 id1 = _createIntent(0);
    uint256 id2 = _createIntent(0);

    _deposit(alice, id1, 100);
    _deposit(bob, id2, 200);

    facility.lock(id1);
    facility.lock(id2);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(debt),
      id2: id2,
      token2: address(debt),
      amount1: 40,
      amount2: 10,
      deadline: block.timestamp + 1
    });

    facility.swap(params, new address[](0), new bytes[](0));

    bytes32 digest = _digest(params);
    vm.expectRevert(abi.encodeWithSelector(LibErrors.SwapDigestUsed.selector, digest));
    facility.swap(params, new address[](0), new bytes[](0));

    facility.resolve(id1);
    facility.resolve(id2);

    uint256 aliceShares = facility.balanceOf(alice, id1);
    uint256 bobShares = facility.balanceOf(bob, id2);

    vm.prank(alice);
    facility.claim(id1, alice, alice, aliceShares);
    vm.prank(bob);
    facility.claim(id2, bob, bob, bobShares);

    assertEq(debt.balanceOf(alice), 70, "alice output");
    assertEq(debt.balanceOf(bob), 230, "bob output");
  }

  function test_RevertWhen_Swap_DeadlineExpired() public {
    uint256 id1 = _createIntent(0);
    uint256 id2 = _createIntent(0);

    _deposit(alice, id1, 1);
    _deposit(bob, id2, 1);

    facility.lock(id1);
    facility.lock(id2);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(debt),
      id2: id2,
      token2: address(debt),
      amount1: 1,
      amount2: 1,
      deadline: block.timestamp - 1
    });

    vm.expectRevert(LibErrors.SwapExpired.selector);
    facility.swap(params, new address[](0), new bytes[](0));
  }

  function test_Swap_QuorumEOA_Works() public {
    Vm.Wallet memory guardian1 = vm.createWallet("guardian1");
    Vm.Wallet memory guardian2 = vm.createWallet("guardian2");

    // Grant guardian roles.
    facility.grantRoles(guardian1.addr, GUARDIAN_ROLE);
    facility.grantRoles(guardian2.addr, GUARDIAN_ROLE);

    uint256 id1 = _createIntent(1);
    uint256 id2 = _createIntent(2);

    _deposit(alice, id1, 100);
    _deposit(bob, id2, 200);

    facility.lock(id1);
    facility.lock(id2);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(debt),
      id2: id2,
      token2: address(debt),
      amount1: 5,
      amount2: 8,
      deadline: block.timestamp + 1
    });

    bytes32 digest = _digest(params);

    address[] memory signers = new address[](2);
    bytes[] memory signatures = new bytes[](2);

    // Signers must be strictly increasing.
    if (guardian1.addr < guardian2.addr) {
      signers[0] = guardian1.addr;
      signers[1] = guardian2.addr;
      signatures[0] = _sign(digest, guardian1);
      signatures[1] = _sign(digest, guardian2);
    } else {
      signers[0] = guardian2.addr;
      signers[1] = guardian1.addr;
      signatures[0] = _sign(digest, guardian2);
      signatures[1] = _sign(digest, guardian1);
    }

    facility.swap(params, signers, signatures);

    facility.resolve(id1);
    facility.resolve(id2);

    uint256 aliceShares = facility.balanceOf(alice, id1);
    uint256 bobShares = facility.balanceOf(bob, id2);

    vm.prank(alice);
    facility.claim(id1, alice, alice, aliceShares);
    vm.prank(bob);
    facility.claim(id2, bob, bob, bobShares);

    assertEq(debt.balanceOf(alice), 103, "alice output");
    assertEq(debt.balanceOf(bob), 197, "bob output");
  }

  function test_Swap_QuorumEIP1271_Works() public {
    Vm.Wallet memory eoa = vm.createWallet("eoaGuardian");
    MockEIP1271Guardian guardian = new MockEIP1271Guardian(eoa.addr);

    facility.grantRoles(address(guardian), GUARDIAN_ROLE);

    uint256 id1 = _createIntent(1);
    uint256 id2 = _createIntent(0);

    _deposit(alice, id1, 10);
    _deposit(bob, id2, 10);

    facility.lock(id1);
    facility.lock(id2);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(debt),
      id2: id2,
      token2: address(debt),
      amount1: 2,
      amount2: 1,
      deadline: block.timestamp + 1
    });

    bytes32 digest = _digest(params);

    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);
    signers[0] = address(guardian);
    signatures[0] = _sign(digest, eoa);

    facility.swap(params, signers, signatures);

    facility.resolve(id1);
    facility.resolve(id2);

    uint256 aliceShares = facility.balanceOf(alice, id1);
    uint256 bobShares = facility.balanceOf(bob, id2);

    vm.prank(alice);
    facility.claim(id1, alice, alice, aliceShares);
    vm.prank(bob);
    facility.claim(id2, bob, bob, bobShares);

    assertEq(debt.balanceOf(alice), 9, "alice output");
    assertEq(debt.balanceOf(bob), 11, "bob output");
  }

  function test_RevertWhen_Swap_SignersNotSortedOrUnique() public {
    Vm.Wallet memory guardian1 = vm.createWallet("guardian1");
    Vm.Wallet memory guardian2 = vm.createWallet("guardian2");

    facility.grantRoles(guardian1.addr, GUARDIAN_ROLE);
    facility.grantRoles(guardian2.addr, GUARDIAN_ROLE);

    uint256 id1 = _createIntent(2);
    uint256 id2 = _createIntent(2);

    _deposit(alice, id1, 10);
    _deposit(bob, id2, 10);

    facility.lock(id1);
    facility.lock(id2);

    SwapParams memory params = SwapParams({
      id1: id1,
      token1: address(debt),
      id2: id2,
      token2: address(debt),
      amount1: 1,
      amount2: 1,
      deadline: block.timestamp + 1
    });

    bytes32 digest = _digest(params);

    address[] memory signers = new address[](2);
    bytes[] memory signatures = new bytes[](2);

    // Intentionally unsorted.
    signers[0] = guardian1.addr > guardian2.addr ? guardian1.addr : guardian2.addr;
    signers[1] = guardian1.addr > guardian2.addr ? guardian2.addr : guardian1.addr;

    signatures[0] = _sign(digest, signers[0] == guardian1.addr ? guardian1 : guardian2);
    signatures[1] = _sign(digest, signers[1] == guardian1.addr ? guardian1 : guardian2);

    vm.expectRevert(LibErrors.InvalidSignerOrder.selector);
    facility.swap(params, signers, signatures);
  }
}
