// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {IAllowlist} from "src/interfaces/integrations/superstate/IAllowlist.sol";

contract MockAllowlist is IAllowlist {
  mapping(address => bool) private publicAllowed;
  mapping(bytes32 => mapping(address => bool)) private privateAllowed;

  function setAllowed(address addr, string memory instrument, bool allowed) external {
    privateAllowed[keccak256(bytes(instrument))][addr] = allowed;
  }

  function setPublicAllowed(address addr, bool allowed) external {
    publicAllowed[addr] = allowed;
  }

  function addressEntityIds(address) external pure returns (uint256) {
    return 0;
  }

  function isAddressAllowedForPrivateInstrument(address addr, string calldata instrument) external view returns (bool) {
    return privateAllowed[keccak256(bytes(instrument))][addr];
  }

  function isAddressAllowedForPublicInstrument(address addr) external view returns (bool) {
    return publicAllowed[addr];
  }
}
