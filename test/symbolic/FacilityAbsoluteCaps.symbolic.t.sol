// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

// Run with `halmos --match-contract SymbolicTest` or `forge test --symbolic --match-path 'test/symbolic/*'`.

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";

contract FacilityAbsoluteCapsSymbolicHarness is FacilityAbsoluteCaps {
  constructor() {
    _initializeOwner(msg.sender);
    _grantRoles(msg.sender, CAPS_MANAGER_ROLE | CAPS_CONSUMER_ROLE);
  }
}

// forge's engine drops paths of the pool walks below --loop 256
/// @custom:halmos --loop 256 --solver-timeout-assertion 110000
contract FacilityAbsoluteCapsSymbolicTest is Test {
  FacilityAbsoluteCapsSymbolicHarness caps;

  uint64 constant ID = 1 | (2 << 16) | (3 << 32) | (4 << 48);
  uint16 constant OUTSIDE_POOL = 5;
  uint256 constant AMOUNT = 1001;

  struct Pools {
    uint64[4] cap;
    uint64[4] headroom;
  }

  function setUp() public {
    caps = new FacilityAbsoluteCapsSymbolicHarness();
  }

  function check_validate_matchesSpec(uint64 id, int24 multiplier) public view {
    uint256 p0 = id % 2 ** 16;
    uint256 p1 = (id / 2 ** 16) % 2 ** 16;
    uint256 p2 = (id / 2 ** 32) % 2 ** 16;
    uint256 p3 = id / 2 ** 48;
    bool contiguous = (p1 == 0 || p0 != 0) && (p2 == 0 || p1 != 0) && (p3 == 0 || p2 != 0);
    bool distinct =
      (p1 == 0 || p1 != p0) && (p2 == 0 || (p2 != p0 && p2 != p1)) && (p3 == 0 || (p3 != p0 && p3 != p1 && p3 != p2));
    (bool ok, bytes memory ret) = address(caps).staticcall(abi.encodeCall(caps.validate, (id, multiplier)));
    if (multiplier == type(int24).min) {
      assert(!ok);
      assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IFacilityCaps.InvalidMultiplier.selector)));
    } else if (p0 != 0 && contiguous && distinct) {
      assert(ok);
    } else {
      assert(!ok);
      assert(keccak256(ret) == keccak256(abi.encodeWithSelector(FacilityAbsoluteCaps.InvalidCapId.selector)));
    }
  }

  function check_available_zeroIdIsZero(int24 multiplier) public view {
    assert(caps.available(0, multiplier) == 0);
  }

  function check_adjustCap_keepsConsumption(uint128 cap, uint128 hardCap, int256 delta) public {
    vm.assume(cap <= hardCap);
    caps.setCap(1, cap, hardCap);
    (bool ok, bytes memory ret) = address(caps).call(abi.encodeCall(caps.adjustCap, (1, delta)));
    uint256 expectedCap;
    if (delta < 0) {
      uint256 shrink = uint256(-(delta + 1)) + 1;
      expectedCap = shrink >= cap ? 0 : cap - shrink;
    } else if (uint256(hardCap) + uint256(delta) > type(uint128).max) {
      assert(!ok);
      assert(keccak256(ret) == keccak256(abi.encodeWithSelector(SafeCastLib.Overflow.selector)));
      return;
    } else {
      expectedCap = cap + uint256(delta);
    }
    assert(ok);
    (uint128 newCap, uint128 newHardCap) = abi.decode(ret, (uint128, uint128));
    assert(newCap == expectedCap);
    assert(newHardCap == expectedCap + (hardCap - cap));
    (uint128 storedCap, uint128 storedHardCap) = caps.getCap(1);
    assert(storedCap == newCap && storedHardCap == newHardCap);
  }

  function check_consume_walk1x(Pools memory pools) public {
    _checkConsumeWalk(pools, 4096, AMOUNT);
  }

  function check_consume_walk2x(Pools memory pools) public {
    _checkConsumeWalk(pools, 8192, 2 * AMOUNT);
  }

  function check_consume_walk1_5xRoundsUp(Pools memory pools) public {
    _checkConsumeWalk(pools, 6144, 1502);
  }

  function check_consume_walkRelease1x(Pools memory pools) public {
    _checkReleaseWalk(pools, -4096, AMOUNT);
  }

  function check_consume_walkRelease1_5xRoundsDown(Pools memory pools) public {
    _checkReleaseWalk(pools, -6144, 1501);
  }

  function _checkConsumeWalk(Pools memory pools, int24 multiplier, uint256 charge) internal {
    uint256 total = _setUpPools(pools, false);
    (bool ok, bytes memory ret) = address(caps).call(abi.encodeCall(caps.consume, (ID, AMOUNT, multiplier)));
    if (total < charge) {
      assert(!ok);
      assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID)));
    } else {
      assert(ok);
      _assertGreedy(pools, false, charge);
    }
    _assertOutsideUntouched();
  }

  // releases above the summed headroom revert HardCapExceeded, see FacilityAbsoluteCaps.t.sol
  function _checkReleaseWalk(Pools memory pools, int24 multiplier, uint256 charge) internal {
    vm.assume(_setUpPools(pools, true) >= charge);
    (bool ok,) = address(caps).call(abi.encodeCall(caps.consume, (ID, AMOUNT, multiplier)));
    assert(ok);
    _assertGreedy(pools, true, charge);
    _assertOutsideUntouched();
  }

  function _setUpPools(Pools memory pools, bool releasing) internal returns (uint256 total) {
    for (uint256 k = 0; k < 4; k++) {
      caps.setCap(uint16(k + 1), pools.cap[k], uint128(pools.cap[k]) + pools.headroom[k]);
      total += releasing ? pools.headroom[k] : pools.cap[k];
    }
    caps.setCap(OUTSIDE_POOL, 7, 11);
  }

  function _assertGreedy(Pools memory pools, bool releasing, uint256 charge) internal view {
    uint256 left = charge;
    uint256 movedSum;
    for (uint256 k = 0; k < 4; k++) {
      uint256 moved = FixedPointMathLib.min(left, releasing ? pools.headroom[k] : pools.cap[k]);
      left -= moved;
      (uint128 cap, uint128 hardCap) = caps.getCap(uint16(k + 1));
      assert(hardCap == uint128(pools.cap[k]) + pools.headroom[k]);
      assert(cap == (releasing ? pools.cap[k] + moved : pools.cap[k] - moved));
      assert(cap <= hardCap);
      movedSum += releasing ? cap - pools.cap[k] : pools.cap[k] - cap;
    }
    assert(movedSum == charge);
  }

  function _assertOutsideUntouched() internal view {
    (uint128 cap, uint128 hardCap) = caps.getCap(OUTSIDE_POOL);
    assert(cap == 7 && hardCap == 11);
  }
}
