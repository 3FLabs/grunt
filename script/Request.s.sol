// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
// import {Request} from "../src/request/Request.sol";

contract RequestScript is Script {
  // Request public request;

  function setUp() public {}

  function run() public {
    vm.startBroadcast();

    // request = new Request();

    vm.stopBroadcast();
  }
}
