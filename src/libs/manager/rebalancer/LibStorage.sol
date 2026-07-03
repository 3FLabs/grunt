// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {RetargetterConfig} from "../../../interfaces/manager/rebalancer/IRetargetter.sol";
import {IFund} from "../../../interfaces/funds/IFund.sol";
import {IRequest} from "../../../interfaces/request/IRequest.sol";
import {ITokenController} from "../../../interfaces/request/ITokenController.sol";
import {Order, Mode, State} from "../../funds/Order.sol";
import {LibRetargetterErrors} from "./LibRetargetterErrors.sol";
import {BPS} from "../../Constants.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {
  ASSETS_STORAGE_SLOT,
  CONFIG_STORAGE_SLOT,
  WHITELISTS_STORAGE_SLOT,
  OPERATION_STORAGE_SLOT
} from "./LibRetargetterConstants.sol";

/// @notice The Retargetter's bound asset pair (namespace "retargetter.assets").
/// @dev Written once at initialize, never mutated afterwards.
/// @param collateralAsset The collateral asset every position manager and fund must match
/// @param debtAsset The debt asset every position manager, fund and Request must match
struct RetargetterAssets {
  address collateralAsset;
  address debtAsset;
}

/// @notice The Retargetter's whitelists (namespace "retargetter.whitelists").
/// @dev Plain mappings without enumeration; indexers use the add/remove events.
/// @param funds The owner-approved venues
/// @param flashLoanModules The owner-approved flash-loan adapters
struct RetargetterWhitelists {
  mapping(address fund => bool) funds;
  mapping(address module => bool) flashLoanModules;
}

/// @notice The one in-flight operation (namespace "retargetter.operation").
/// @dev `positionManager != address(0)` is the operation-active flag. An ASYNC operation uses
///      every field and is zeroed at resolve; a SYNC flash-loan window populates only the
///      addresses the steps need (`positionManager`, `fund`) and zeroes them at window close,
///      so `request == address(0)` inside a window is what gates the ASYNC-only steps. The
///      stored order is partial: `owner` and `receiver` are always the Retargetter (enforced
///      at create) so {LibStorage.order} rebuilds the full Order in memory.
/// @param positionManager The operation's position manager
/// @param startedAt The loan clock origin, set at the first consume or nonzero mint
///        authorization (0 until then)
/// @param operationMaxYieldBps The effective yield cap, fixed at start
/// @param consumptionClosed Whether capital entry is shut for good; set by the first pull of
///        funds, which also revokes every pending mint authorization
/// @param request The Request deployed for the operation
/// @param fund The operation's venue, owner-whitelisted at start
/// @param orderMode The stored order's mode
/// @param orderLive Whether an order is stored
/// @param orderInput The stored order's input amount
/// @param orderOutput The stored order's output amount
/// @param orderSalt The stored order's salt
/// @param authorizedAccounts The accounts holding a registered mint authorization; the live
///        amounts are re-read from the Request per account, revocation removes its account
///        eagerly, a completed mint is pruned lazily by the next write-path computation, and
///        resolve empties the set
struct RetargetterOperation {
  address positionManager;
  uint40 startedAt;
  uint16 operationMaxYieldBps;
  bool consumptionClosed;
  address request;
  address fund;
  Mode orderMode;
  bool orderLive;
  uint256 orderInput;
  uint256 orderOutput;
  bytes32 orderSalt;
  EnumerableSetLib.AddressSet authorizedAccounts;
}

/// @title LibStorage
/// @author 3F Protocol
/// @notice Library providing the ERC-7201 storage accessors and the storage-only operations
///         for the Retargetter.
library LibStorage {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       STORAGE ACCESS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the ERC-7201 storage pointer for the bound asset pair.
  function assetsStorage() internal pure returns (RetargetterAssets storage $) {
    assembly ("memory-safe") {
      $.slot := ASSETS_STORAGE_SLOT
    }
  }

  /// @dev Returns the ERC-7201 storage pointer for the configuration.
  function configStorage() internal pure returns (RetargetterConfig storage $) {
    assembly ("memory-safe") {
      $.slot := CONFIG_STORAGE_SLOT
    }
  }

  /// @dev Returns the ERC-7201 storage pointer for the whitelists.
  function whitelistsStorage() internal pure returns (RetargetterWhitelists storage $) {
    assembly ("memory-safe") {
      $.slot := WHITELISTS_STORAGE_SLOT
    }
  }

  /// @dev Returns the ERC-7201 storage pointer for the in-flight operation.
  function operationStorage() internal pure returns (RetargetterOperation storage $) {
    assembly ("memory-safe") {
      $.slot := OPERATION_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      OPERATION GATES                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts unless an operation is active (ASYNC or SYNC window); returns its position
  ///      manager.
  /// @param self The storage pointer to the operation
  function checkActive(RetargetterOperation storage self) internal view returns (address positionManager) {
    positionManager = self.positionManager;
    if (positionManager == address(0)) revert LibRetargetterErrors.NoActiveOperation();
  }

  /// @dev Reverts unless an ASYNC operation is active (SYNC windows carry no Request);
  ///      returns its Request.
  /// @param self The storage pointer to the operation
  function checkRequest(RetargetterOperation storage self) internal view returns (address request) {
    request = self.request;
    if (request == address(0)) revert LibRetargetterErrors.NoActiveOperation();
  }

  /// @dev Settlement gate: with a stored order, an ENDED (or fund-side force-ended, reading
  ///      EMPTY) order is cleared, anything else reverts OrderPending.
  /// @param self The storage pointer to the operation
  /// @param fund The fund holding the order
  function checkNoPendingOrder(RetargetterOperation storage self, address fund) internal {
    if (!self.orderLive) return;
    State state_ = IFund(fund).state(order(self));
    if (state_ != State.ENDED && state_ != State.EMPTY) revert LibRetargetterErrors.OrderPending();
    clearOrder(self);
  }

  /// @dev Capital gates shared by consume and authorizeMinting. Reverts YieldTooHigh when the
  ///      offered yield-to-principal ratio exceeds the operation's cap (division-free, so
  ///      partial fills keep the offer's ratio) and PrincipalCapExceeded when the committed
  ///      principal (the PT supply, the outstanding authorizations after pruning, and the new
  ///      amount) exceeds the live cap, then runs {checkConsumptionWindow}.
  /// @param self The storage pointer to the operation
  /// @param request The operation's Request
  /// @param amount The offered principal the yield ratio is quoted on
  /// @param expectedReturn The offered yield on that principal
  /// @param ptAmount The principal actually being committed
  /// @param principalCap The live principal cap
  function checkOffer(
    RetargetterOperation storage self,
    address request,
    uint256 amount,
    uint256 expectedReturn,
    uint256 ptAmount,
    uint256 principalCap
  ) internal {
    if (expectedReturn * BPS > amount * self.operationMaxYieldBps) {
      revert LibRetargetterErrors.YieldTooHigh();
    }
    (uint128 ptSupply,) = ITokenController(request).totalSupplies();
    if (ptSupply + pruneNullAuthorizations(self, request) + ptAmount > principalCap) {
      revert LibRetargetterErrors.PrincipalCapExceeded();
    }
    checkConsumptionWindow(self);
  }

  /// @dev Consumption-window gate and loan clock: reverts once the window has closed (funds
  ///      were pulled, or the tick threshold elapsed since the origin); otherwise the first
  ///      capital commitment (consume or nonzero mint authorization) starts the clock. The
  ///      window exists because repayment prices every yield token from the origin: capital
  ///      arriving later would be overpaid for time it never covered and, on a default, would
  ///      dilute the earlier lenders' recovery. It binds everyone, owner included, and a zero
  ///      threshold collapses the window to the origin timestamp itself.
  /// @param self The storage pointer to the operation
  function checkConsumptionWindow(RetargetterOperation storage self) internal {
    if (self.consumptionClosed) revert LibRetargetterErrors.ConsumptionWindowClosed();
    uint256 startedAt = self.startedAt;
    if (startedAt == 0) {
      // Safe: block.timestamp fits in uint40 for ~35,000 years
      // forge-lint: disable-next-line(unsafe-typecast)
      self.startedAt = uint40(block.timestamp);
    } else if (block.timestamp > startedAt + configStorage().tickThreshold) {
      revert LibRetargetterErrors.ConsumptionWindowClosed();
    }
  }

  /// @dev Ends the funding round: consume and new authorizations reject from here on, and
  ///      every pending mint authorization is revoked on the Request while the set empties
  ///      (back to front, each removal a plain pop). Runs on every pull of funds and is
  ///      idempotent; once capital is being deployed it can no longer be diluted.
  /// @param self The storage pointer to the operation
  /// @param request The operation's Request
  function closeConsumption(RetargetterOperation storage self, address request) internal {
    self.consumptionClosed = true;
    EnumerableSetLib.AddressSet storage accounts = self.authorizedAccounts;
    for (uint256 remaining = accounts.length(); remaining > 0; --remaining) {
      address account = accounts.at(remaining - 1);
      IRequest(request).authorizeMinting(account, 0, 0);
      accounts.remove(account);
    }
  }

  /// @dev Removes authorizations that read all-zero on the Request (minted, their amount now
  ///      sits in the PT supply) while summing the live ones. Iterates back to front so the
  ///      swap-pop removal only moves accounts that were already counted.
  /// @param self The storage pointer to the operation
  /// @param request The operation's Request
  /// @return outstanding The outstanding authorized principal after pruning
  function pruneNullAuthorizations(RetargetterOperation storage self, address request)
    internal
    returns (uint256 outstanding)
  {
    EnumerableSetLib.AddressSet storage accounts = self.authorizedAccounts;
    for (uint256 i = accounts.length(); i > 0; --i) {
      address account = accounts.at(i - 1);
      (uint128 ptAmount, uint128 ytAmount) = IRequest(request).mintAuthorization(account);
      if (ptAmount == 0 && ytAmount == 0) accounts.remove(account);
      else outstanding += ptAmount;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          SETTERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Stores the non-derivable order fields and marks the order live.
  /// @param self The storage pointer to the operation
  /// @param order_ The order to store
  function setOrder(RetargetterOperation storage self, Order calldata order_) internal {
    self.orderMode = order_.mode;
    self.orderLive = true;
    self.orderInput = order_.input;
    self.orderOutput = order_.output;
    self.orderSalt = order_.salt;
  }

  /// @dev Clears the stored order fields and the liveness flag.
  /// @param self The storage pointer to the operation
  function clearOrder(RetargetterOperation storage self) internal {
    self.orderMode = Mode.DEPOSIT;
    self.orderLive = false;
    self.orderInput = 0;
    self.orderOutput = 0;
    self.orderSalt = bytes32(0);
  }

  /// @dev Clears the operation addresses, the loan clock, the yield cap and the
  ///      mint-authorization account set (emptied back to front, each removal a plain pop);
  ///      the order fields are cleared separately as orders end.
  /// @param self The storage pointer to the operation
  function clearOperation(RetargetterOperation storage self) internal {
    self.positionManager = address(0);
    self.startedAt = 0;
    self.operationMaxYieldBps = 0;
    self.consumptionClosed = false;
    self.request = address(0);
    self.fund = address(0);
    EnumerableSetLib.AddressSet storage accounts = self.authorizedAccounts;
    for (uint256 remaining = accounts.length(); remaining > 0; --remaining) {
      accounts.remove(accounts.at(remaining - 1));
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Rebuilds the full stored order in memory; owner and receiver are always the
  ///      Retargetter (enforced at create), so they are never stored.
  /// @param self The storage pointer to the operation
  function order(RetargetterOperation storage self) internal view returns (Order memory) {
    return Order({
      mode: self.orderMode,
      owner: address(this),
      receiver: address(this),
      input: self.orderInput,
      output: self.orderOutput,
      salt: self.orderSalt
    });
  }
}
