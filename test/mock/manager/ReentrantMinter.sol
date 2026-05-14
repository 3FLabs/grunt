// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManager} from "../../../src/manager/PositionManager.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";

/// @title ReentrantMinter
/// @notice Contract that receives tokens and attempts reentrancy during callbacks
contract ReentrantMinter {
  PositionManager public immutable pm;

  enum AttackType {
    NONE,
    DEPOSIT,
    WITHDRAW,
    BURN,
    READ_VIEWS
  }

  AttackType public attackType;
  bool public attackTriggered;
  bytes public lastRevertReason;
  bytes public lastTotalSupplyRevertReason;
  bytes public lastTotalAssetsRevertReason;

  constructor(PositionManager pm_) {
    pm = pm_;
  }

  function setAttackType(AttackType type_) external {
    attackType = type_;
    attackTriggered = false;
    lastRevertReason = "";
    lastTotalSupplyRevertReason = "";
    lastTotalAssetsRevertReason = "";
  }

  function deposit(uint256 collateralAmt, uint256 debtAmt) external returns (int256) {
    return pm.deposit(collateralAmt, debtAmt);
  }

  function withdraw(uint256 collateralAmt, uint256 debtAmt, WithdrawalStrategy strategy) external returns (int256) {
    return pm.withdraw(collateralAmt, debtAmt, strategy);
  }

  function burn(uint256 shares, WithdrawalStrategy strategy) external returns (uint256, uint256) {
    return pm.burn(shares, strategy);
  }

  /// @notice Called by ReentrantCollateral during transfer
  function onTokenReceived() external {
    _attemptReentrantAttack();
  }

  function _attemptReentrantAttack() internal {
    if (attackType == AttackType.NONE || attackTriggered) return;

    attackTriggered = true;

    if (attackType == AttackType.DEPOSIT) {
      try pm.deposit(1e18, 0) {}
      catch (bytes memory reason) {
        lastRevertReason = reason;
      }
    } else if (attackType == AttackType.WITHDRAW) {
      try pm.withdraw(1e18, 0, WithdrawalStrategy.SEQUENTIAL) {}
      catch (bytes memory reason) {
        lastRevertReason = reason;
      }
    } else if (attackType == AttackType.BURN) {
      try pm.burn(1e18, WithdrawalStrategy.PROPORTIONAL) {}
      catch (bytes memory reason) {
        lastRevertReason = reason;
      }
    } else if (attackType == AttackType.READ_VIEWS) {
      try pm.totalSupply() returns (uint256) {}
      catch (bytes memory reason) {
        lastTotalSupplyRevertReason = reason;
      }
      try pm.totalAssets() returns (uint256) {}
      catch (bytes memory reason) {
        lastTotalAssetsRevertReason = reason;
      }
    }
  }

  function _isReentrancyRevert(bytes memory reason) internal pure returns (bool) {
    if (reason.length < 4) return false;
    bytes4 selector;
    assembly {
      selector := mload(add(reason, 32))
    }
    return selector == ReentrancyGuardTransient.Reentrancy.selector;
  }

  function totalSupplyReadReverted() external view returns (bool) {
    return _isReentrancyRevert(lastTotalSupplyRevertReason);
  }

  function totalAssetsReadReverted() external view returns (bool) {
    return _isReentrancyRevert(lastTotalAssetsRevertReason);
  }

  /// @notice Helper to check if last revert was Reentrancy error
  function wasReentrancyError() external view returns (bool) {
    bytes memory reason = lastRevertReason;
    if (reason.length < 4) return false;
    bytes4 selector;
    assembly {
      selector := mload(add(reason, 32))
    }
    return selector == ReentrancyGuardTransient.Reentrancy.selector;
  }
}
