// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Facility} from "src/facility/Facility.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

/// @notice ERC20 with a transfer callback that tries to call Facility.intentBalances during transfer.
/// @dev Used to test read-only reentrancy protection in FacilityLP.
contract CallbackToken is ERC20 {
  address public callTarget;
  uint256 public callIntentId;
  bool public attackEnabled;
  bool public callbackTriggered;
  bool public callbackReverted;

  function name() public pure override returns (string memory) {
    return "Callback Token";
  }

  function symbol() public pure override returns (string memory) {
    return "CBT";
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function setBalance(address account, uint256 amount) public {
    uint256 current = balanceOf(account);
    if (amount > current) _mint(account, amount - current);
    else if (amount < current) _burn(account, current - amount);
  }

  function enableAttack(address facility_, uint256 intentId_) external {
    callTarget = facility_;
    callIntentId = intentId_;
    attackEnabled = true;
  }

  function disableAttack() external {
    attackEnabled = false;
  }

  /// @dev Solady ERC20 has _afterTokenTransfer hook (from, to, amount)
  function _afterTokenTransfer(address, address to, uint256) internal override {
    if (!attackEnabled) return;
    if (to == address(0) || to == callTarget) return;

    callbackTriggered = true;
    try Facility(callTarget).intentBalances(callIntentId) {
      callbackReverted = false;
    } catch {
      callbackReverted = true;
    }
  }

  function offchainRedeem(uint256) external pure {
    // No-op for compatibility
  }
}
