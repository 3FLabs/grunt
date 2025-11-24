// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Lib128Fields} from "../../../src/request/libraries/Lib128Fields.sol";

contract Lib128FieldsTest is Test {
  using Lib128Fields for uint256;

  function testFuzz_readWrite(uint256 slot, uint128 pt, uint128 yt) public {
    slot.write(pt, yt);
    (uint128 ptRead, uint128 ytRead) = slot.fromSlot();
    assertEq(ptRead, pt);
    assertEq(ytRead, yt);
  }
}
