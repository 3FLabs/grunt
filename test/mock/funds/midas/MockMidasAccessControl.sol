// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IMidasAccessControl} from "src/interfaces/integrations/midas/IMidasAccessControl.sol";

/// @dev Mock MidasAccessControl with settable roles.
contract MockMidasAccessControl is IMidasAccessControl {
  mapping(bytes32 => mapping(address => bool)) internal _roles;

  function setRole(bytes32 role, address account, bool granted) external {
    _roles[role][account] = granted;
  }

  function hasRole(bytes32 role, address account) external view override returns (bool) {
    return _roles[role][account];
  }
}
