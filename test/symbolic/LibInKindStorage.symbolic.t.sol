// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibInKindStorage, InKindStorageData} from "src/libs/facility/inkind/LibInKindStorage.sol";
import {Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";

contract LibInKindStorageSymbolicHarness {
  using LibInKindStorage for InKindStorageData;

  function setAuth(address asset, address user, uint128 amount, uint40 expiry) external {
    LibInKindStorage.inKindStorage().auths[asset][user] = Auth(amount, expiry);
  }

  function setSecurityCap(address asset, uint256 word) external {
    LibInKindStorage.inKindStorage().securityCaps[asset] = word;
  }

  function consumeSecurity(address asset, address user, uint256 debt) external {
    LibInKindStorage.inKindStorage().consumeSecurity(asset, user, debt);
  }

  function securityLimit(address asset, address user) external view returns (uint256) {
    return LibInKindStorage.inKindStorage().securityLimit(asset, user);
  }

  function auth(address asset, address user) external view returns (uint128, uint40) {
    Auth memory a = LibInKindStorage.inKindStorage().auths[asset][user];
    return (a.amount, a.expiry);
  }

  function securityCap(address asset) external view returns (uint256) {
    return LibInKindStorage.inKindStorage().securityCaps[asset];
  }
}

contract SymbolicSecurityCapsStub {
  uint64 public lastId;
  uint256 public lastAmount;
  int24 public lastMultiplier;
  uint256 public calls;

  function consume(uint64 id, uint256 amount, int24 multiplier) external {
    lastId = id;
    lastAmount = amount;
    lastMultiplier = multiplier;
    calls++;
  }
}

/// @custom:halmos --solver-timeout-assertion 110000
contract LibInKindStorageSymbolicTest is Test {
  LibInKindStorageSymbolicHarness harness;
  SymbolicSecurityCapsStub caps;

  address constant ASSET = address(0xA55E7);
  address constant USER = address(0xB0B);
  address constant OTHER = address(0xCAFE);

  function setUp() public {
    harness = new LibInKindStorageSymbolicHarness();
    caps = new SymbolicSecurityCapsStub();
  }

  function check_securityLimit_isLiveAuthPlusCap(uint128 amount, uint40 expiry, uint40 time, uint256 cap) public {
    vm.assume(cap <= LibCaps.MAX_ABSOLUTE);
    uint256 live = _setUpLeg(amount, expiry, time, cap);
    assert(harness.securityLimit(ASSET, USER) == live + cap);
  }

  function check_consumeSecurity_revertsIffDebtAboveLimit(
    uint128 amount,
    uint40 expiry,
    uint40 time,
    uint256 cap,
    uint256 debt
  ) public {
    vm.assume(cap <= LibCaps.MAX_ABSOLUTE);
    uint256 live = _setUpLeg(amount, expiry, time, cap);
    (bool ok, bytes memory ret) = address(harness).call(abi.encodeCall(harness.consumeSecurity, (ASSET, USER, debt)));
    if (debt <= live + cap) {
      assert(ok);
    } else {
      assert(!ok);
      assert(
        keccak256(ret)
          == keccak256(abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, uint160(ASSET), cap, debt - live))
      );
    }
  }

  function check_consumeSecurity_drainsAuthFirst(uint128 amount, uint40 expiry, uint40 time, uint256 cap, uint256 debt)
    public
  {
    vm.assume(cap <= LibCaps.MAX_ABSOLUTE);
    uint256 live = _setUpLeg(amount, expiry, time, cap);
    vm.assume(debt <= live + cap);
    harness.consumeSecurity(ASSET, USER, debt);
    uint256 fromAuth = debt < live ? debt : live;
    (uint128 amountAfter, uint40 expiryAfter) = harness.auth(ASSET, USER);
    assert(amountAfter == amount - fromAuth);
    assert(expiryAfter == expiry);
    assert(harness.securityCap(ASSET) == cap - (debt - fromAuth));
    (uint128 otherAmount, uint40 otherExpiry) = harness.auth(ASSET, OTHER);
    assert(otherAmount == 5 && otherExpiry == type(uint40).max);
  }

  function check_consumeSecurity_externalChargesOnlyTheRemainder(
    uint128 amount,
    uint40 expiry,
    uint40 time,
    uint64 id,
    int24 multiplier,
    uint128 debt
  ) public {
    uint256 word = LibCaps.encodeExternal(address(caps), id, multiplier);
    uint256 live = _setUpLeg(amount, expiry, time, word);
    (bool ok,) = address(harness).call(abi.encodeCall(harness.consumeSecurity, (ASSET, USER, debt)));
    assert(ok);
    uint256 fromAuth = debt < live ? debt : live;
    (uint128 amountAfter,) = harness.auth(ASSET, USER);
    assert(amountAfter == amount - fromAuth);
    assert(harness.securityCap(ASSET) == word);
    if (debt > live) {
      assert(caps.calls() == 1);
      assert(caps.lastId() == id);
      assert(caps.lastAmount() == debt - live);
      assert(caps.lastMultiplier() == multiplier);
    } else {
      assert(caps.calls() == 0);
    }
  }

  function _setUpLeg(uint128 amount, uint40 expiry, uint40 time, uint256 word) internal returns (uint256 live) {
    vm.warp(time);
    harness.setAuth(ASSET, USER, amount, expiry);
    harness.setAuth(ASSET, OTHER, 5, type(uint40).max);
    harness.setSecurityCap(ASSET, word);
    return time < expiry ? amount : 0;
  }
}
