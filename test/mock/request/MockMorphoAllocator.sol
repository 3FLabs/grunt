// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IMorphoAllocator} from "../../../src/interfaces/request/IMorphoAllocator.sol";
import {IFacilityFunds} from "../../../src/interfaces/facility/base/IFacilityFunds.sol";
import {IFacilityPositionManager} from "../../../src/interfaces/facility/base/IFacilityPositionManager.sol";
import {MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";

/// @notice Test double for the externally-deployed MorphoAllocator. Implements IMorphoAllocator,
///         enforces EXECUTOR_ROLE, and mirrors the facility side of the real `run` (unlock +
///         depositManager). Vault V2 rebalancing is not modeled (grunt has no Vault V2 mocks); the
///         rebalance params are recorded instead so tests can assert the script routed them through.
contract MockMorphoAllocator is IMorphoAllocator, OwnableRoles {
  uint256 internal constant EXECUTOR_ROLE = _ROLE_0;

  address public immutable facility;

  uint256 public lastDeallocationsLength;
  address public lastAllocateAdapter;
  uint256 public lastDepositAmount;
  uint256 public lastBorrowAmount;
  bool public lastUseTarget;
  uint256 public lastMinSharesUnlocked;

  constructor(address owner_, address facility_) {
    _initializeOwner(owner_);
    facility = facility_;
  }

  function run(
    uint256 intentId,
    Deallocation[] calldata deallocations,
    address allocateAdapter,
    MarketParams calldata, // allocateMarket — vault rebalancing not modeled in grunt
    uint256 depositAmount,
    uint256 borrowAmount,
    bool useTarget,
    uint256 minSharesUnlocked
  ) external onlyRoles(EXECUTOR_ROLE) {
    lastDeallocationsLength = deallocations.length;
    lastAllocateAdapter = allocateAdapter;
    lastDepositAmount = depositAmount;
    lastBorrowAmount = borrowAmount;
    lastUseTarget = useTarget;
    lastMinSharesUnlocked = minSharesUnlocked;

    // Mirror the real allocator: unlock the matured order, then deposit + borrow via the PM.
    IFacilityFunds(facility).unlock(intentId);
    IFacilityPositionManager(facility).depositManager(intentId, depositAmount, borrowAmount, useTarget);
  }
}
