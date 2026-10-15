// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibCaps, CapType} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {IFacilityCapsWhitelist} from "src/interfaces/facility/IFacilityCapsWhitelist.sol";

contract LibCapsSymbolicHarness {
  uint256 word;

  function validate(uint256 word_, IFacilityCapsWhitelist whitelist) external view {
    LibCaps.validate(word_, whitelist);
  }

  function setWord(uint256 word_) external {
    word = word_;
  }

  function consume(uint256 capId, uint256 amount) external returns (uint256) {
    return LibCaps.consume(word, capId, amount);
  }

  function release(uint256 amount) external {
    LibCaps.release(word, amount);
  }
}

contract SymbolicWhitelistStub {
  address allowed;

  function setAllowed(address caps) external {
    allowed = caps;
  }

  function isAllowed(address caps) external view returns (bool) {
    return caps == allowed;
  }
}

contract SymbolicCapsStub {
  error UnexpectedCall();

  uint64 expectedId;
  int24 expectedMultiplier;
  bool rejecting;
  uint64 public lastId;
  uint256 public lastAmount;
  int24 public lastMultiplier;
  uint256 public calls;

  function expectValidate(uint64 id, int24 multiplier, bool reject) external {
    expectedId = id;
    expectedMultiplier = multiplier;
    rejecting = reject;
  }

  function validate(uint64 id, int24 multiplier) external view {
    if (id != expectedId || multiplier != expectedMultiplier) revert UnexpectedCall();
    if (rejecting) revert();
  }

  function consume(uint64 id, uint256 amount, int24 multiplier) external {
    lastId = id;
    lastAmount = amount;
    lastMultiplier = multiplier;
    calls++;
  }

  function isAllowed(address) external pure returns (bool) {
    revert UnexpectedCall();
  }
}

contract LibCapsSymbolicTest is Test {
  LibCapsSymbolicHarness harness;
  SymbolicWhitelistStub whitelist;
  SymbolicCapsStub caps;

  function setUp() public {
    harness = new LibCapsSymbolicHarness();
    whitelist = new SymbolicWhitelistStub();
    caps = new SymbolicCapsStub();
  }

  function check_encodeExternal_matchesLayout(address capsAddress, uint64 id, int24 multiplier) public pure {
    uint256 word = LibCaps.encodeExternal(capsAddress, id, multiplier);
    assert(
      word == (1 << 248) | (uint256(uint24(multiplier)) << 224) | (uint256(id) << 160) | uint256(uint160(capsAddress))
    );
    assert(LibCaps.capType(word) == CapType.EXTERNAL);
  }

  function check_decodeExternal_invertsEncode(uint256 word) public pure {
    vm.assume(word >> 248 == 1);
    (IFacilityCaps capsAddress, uint64 id, int24 multiplier) = LibCaps.decodeExternal(word);
    assert(LibCaps.encodeExternal(address(capsAddress), id, multiplier) == word);
  }

  function check_maxAbsolute_boundsTypeZero(uint256 word) public pure {
    assert((word <= LibCaps.MAX_ABSOLUTE) == (word >> 248 == 0));
  }

  function check_validate_rejectsUnknownType(uint256 word) public view {
    vm.assume(word >> 248 > 1);
    (bool ok, bytes memory ret) =
      address(harness).staticcall(abi.encodeCall(harness.validate, (word, IFacilityCapsWhitelist(address(caps)))));
    assert(!ok);
    assert(keccak256(ret) == keccak256(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, word)));
  }

  function check_validate_absoluteNeverCallsOut(uint256 word) public view {
    vm.assume(word <= LibCaps.MAX_ABSOLUTE);
    (bool ok,) =
      address(harness).staticcall(abi.encodeCall(harness.validate, (word, IFacilityCapsWhitelist(address(caps)))));
    assert(ok);
  }

  function check_validate_externalForwardsToAllowedCaps(uint64 id, int24 multiplier, bool reject) public {
    whitelist.setAllowed(address(caps));
    caps.expectValidate(id, multiplier, reject);
    uint256 word = LibCaps.encodeExternal(address(caps), id, multiplier);
    (bool ok, bytes memory ret) =
      address(harness).staticcall(abi.encodeCall(harness.validate, (word, IFacilityCapsWhitelist(address(whitelist)))));
    assert(ok == !reject);
    assert(ret.length == 0);
  }

  function check_validate_externalRejectsDisallowedCaps(address capsAddress, uint64 id, int24 multiplier) public {
    vm.assume(capsAddress != address(caps));
    whitelist.setAllowed(address(caps));
    uint256 word = LibCaps.encodeExternal(capsAddress, id, multiplier);
    (bool ok, bytes memory ret) =
      address(harness).staticcall(abi.encodeCall(harness.validate, (word, IFacilityCapsWhitelist(address(whitelist)))));
    assert(!ok);
    assert(keccak256(ret) == keccak256(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, capsAddress)));
  }

  function check_consume_absolute(uint256 word, uint256 capId, uint256 amount) public {
    vm.assume(word <= LibCaps.MAX_ABSOLUTE);
    harness.setWord(word);
    (bool ok, bytes memory ret) = address(harness).call(abi.encodeCall(harness.consume, (capId, amount)));
    if (amount <= word) {
      assert(ok);
      assert(abi.decode(ret, (uint256)) == word - amount);
    } else {
      assert(!ok);
      assert(
        keccak256(ret) == keccak256(abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, capId, word, amount))
      );
    }
  }

  function check_consume_externalForwardsAndKeepsWord(uint64 id, int24 multiplier, uint256 amount) public {
    uint256 word = LibCaps.encodeExternal(address(caps), id, multiplier);
    harness.setWord(word);
    (bool ok, bytes memory ret) = address(harness).call(abi.encodeCall(harness.consume, (0, amount)));
    assert(ok);
    assert(abi.decode(ret, (uint256)) == word);
    assert(caps.calls() == 1);
    assert(caps.lastId() == id);
    assert(caps.lastAmount() == amount);
    assert(caps.lastMultiplier() == multiplier);
  }

  function check_release_externalNegatesMultiplier(uint64 id, int24 multiplier, uint256 amount) public {
    vm.assume(multiplier != type(int24).min);
    harness.setWord(LibCaps.encodeExternal(address(caps), id, multiplier));
    (bool ok,) = address(harness).call(abi.encodeCall(harness.release, (amount)));
    assert(ok);
    assert(caps.calls() == 1);
    assert(caps.lastId() == id);
    assert(caps.lastAmount() == amount);
    assert(caps.lastMultiplier() == -multiplier);
  }

  function check_release_absoluteNeverCallsOut(uint256 word, uint256 amount) public {
    vm.assume(word <= LibCaps.MAX_ABSOLUTE);
    harness.setWord(word);
    (bool ok,) = address(harness).call(abi.encodeCall(harness.release, (amount)));
    assert(ok);
    assert(caps.calls() == 0);
  }
}
