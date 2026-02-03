// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title WrappedAssetHandler
/// @notice Invariant-test handler that drives state transitions on a WrappedAsset
///         instance and maintains ghost state for verification.
contract WrappedAssetHandler is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  WrappedAsset public wrappedAsset;
  MockERC20 public underlyingToken;
  address public owner;

  bool public initialized;

  /// @notice Fixed set of addresses used across all handler actions.
  address[] public accounts;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        GHOST STATE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mirror of on-chain SENDER_ROLE grants.
  mapping(address => bool) public ghostHasSenderRole;

  /// @notice Mirror of on-chain RECEIVER_ROLE grants.
  mapping(address => bool) public ghostHasReceiverRole;

  /// @notice WA-2: Set to true if an unauthorized transfer succeeded.
  bool public unauthorizedTransferSucceeded;

  /// @notice WA-3: Set to true if an unauthorized mint-to-other succeeded.
  bool public unauthorizedMintToOtherSucceeded;

  /// @notice WA-4: Set to true if burn was blocked by a role check.
  bool public burnBlockedByRole;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant SENDER_ROLE = 1 << 1;
  uint256 constant RECEIVER_ROLE = 1 << 2;
  uint256 constant ISSUER_ROLE = 1 << 0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the handler with a WrappedAsset instance and its owner.
  /// @param wrappedAsset_ The WrappedAsset contract under test.
  /// @param underlyingToken_ The MockERC20 underlying asset.
  /// @param owner_ The owner address that manages roles.
  function initialize(WrappedAsset wrappedAsset_, MockERC20 underlyingToken_, address owner_) external {
    require(!initialized, "already initialized");
    initialized = true;

    wrappedAsset = wrappedAsset_;
    underlyingToken = underlyingToken_;
    owner = owner_;

    // 5 fixed accounts
    accounts.push(makeAddr("wa_account0"));
    accounts.push(makeAddr("wa_account1"));
    accounts.push(makeAddr("wa_account2"));
    accounts.push(makeAddr("wa_account3"));
    accounts.push(makeAddr("wa_account4"));

    // Accounts 0-1 start with SENDER_ROLE, account 2 starts with RECEIVER_ROLE.
    vm.startPrank(owner_);
    wrappedAsset_.grantRoles(accounts[0], SENDER_ROLE);
    wrappedAsset_.grantRoles(accounts[1], SENDER_ROLE);
    wrappedAsset_.grantRoles(accounts[2], RECEIVER_ROLE);
    vm.stopPrank();

    ghostHasSenderRole[accounts[0]] = true;
    ghostHasSenderRole[accounts[1]] = true;
    ghostHasReceiverRole[accounts[2]] = true;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       VIEW HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the full array of test accounts.
  function getAccounts() external view returns (address[] memory) {
    return accounts;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      HANDLER ACTIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mints (wraps) underlying to a randomly-selected account.
  /// @param accountSeed Seed for selecting an account.
  /// @param amountSeed Seed for fuzzing the amount.
  function act_mint(uint256 accountSeed, uint256 amountSeed) external {
    address account = accounts[accountSeed % accounts.length];
    uint256 amount = _bound(amountSeed, 1e18, 50_000e18);

    underlyingToken.mint(account, amount);
    vm.startPrank(account);
    underlyingToken.approve(address(wrappedAsset), amount);
    wrappedAsset.mint(account, amount);
    vm.stopPrank();
  }

  /// @notice Burns (unwraps) WrappedAsset from a randomly-selected account.
  /// @dev Burns should always succeed regardless of roles (bypasses _beforeTokenTransfer).
  ///      If it fails, sets burnBlockedByRole.
  /// @param accountSeed Seed for selecting an account.
  /// @param amountSeed Seed for fuzzing the amount.
  function act_burn(uint256 accountSeed, uint256 amountSeed) external {
    address account = accounts[accountSeed % accounts.length];
    uint256 balance = wrappedAsset.balanceOf(account);
    if (balance == 0) return;

    uint256 amount = _bound(amountSeed, 1, balance);
    vm.prank(account);
    try wrappedAsset.burn(account, account, amount) {
    // Success -- expected
    }
    catch {
      burnBlockedByRole = true;
    }
  }

  /// @notice Transfers WrappedAsset between randomly-selected accounts.
  /// @dev If sender lacks SENDER_ROLE and receiver lacks RECEIVER_ROLE, it should revert.
  ///      If it succeeds unexpectedly, sets unauthorizedTransferSucceeded.
  /// @param fromSeed Seed for selecting sender.
  /// @param toSeed Seed for selecting receiver.
  /// @param amountSeed Seed for fuzzing the amount.
  function act_transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
    address from = accounts[fromSeed % accounts.length];
    address to = accounts[toSeed % accounts.length];
    if (from == to) to = accounts[(toSeed + 1) % accounts.length];

    uint256 balance = wrappedAsset.balanceOf(from);
    if (balance == 0) return;

    uint256 amount = _bound(amountSeed, 1, balance);
    bool senderHasRole = wrappedAsset.hasAnyRole(from, SENDER_ROLE);
    bool receiverHasRole = wrappedAsset.hasAnyRole(to, RECEIVER_ROLE);
    bool shouldSucceed = senderHasRole || receiverHasRole;

    vm.prank(from);
    try wrappedAsset.transfer(to, amount) {
      if (!shouldSucceed) {
        unauthorizedTransferSucceeded = true;
      }
    } catch {
      // Expected if unauthorized
    }
  }

  /// @notice Executes transferFrom with allowance between accounts.
  /// @dev Same role logic as transfer. Spender must have allowance from sender.
  /// @param fromSeed Seed for selecting sender.
  /// @param spenderSeed Seed for selecting spender.
  /// @param toSeed Seed for selecting receiver.
  /// @param amountSeed Seed for fuzzing the amount.
  function act_transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
    address from = accounts[fromSeed % accounts.length];
    address spender = accounts[spenderSeed % accounts.length];
    address to = accounts[toSeed % accounts.length];
    if (from == to) to = accounts[(toSeed + 1) % accounts.length];

    uint256 balance = wrappedAsset.balanceOf(from);
    if (balance == 0) return;

    uint256 amount = _bound(amountSeed, 1, balance);

    // Grant allowance from `from` to `spender`
    vm.prank(from);
    wrappedAsset.approve(spender, amount);

    bool senderHasRole = wrappedAsset.hasAnyRole(from, SENDER_ROLE);
    bool receiverHasRole = wrappedAsset.hasAnyRole(to, RECEIVER_ROLE);
    bool shouldSucceed = senderHasRole || receiverHasRole;

    vm.prank(spender);
    try wrappedAsset.transferFrom(from, to, amount) {
      if (!shouldSucceed) {
        unauthorizedTransferSucceeded = true;
      }
    } catch {
      // Expected if unauthorized
    }
  }

  /// @notice Approves a spender for WrappedAsset spending (no role restriction).
  /// @param fromSeed Seed for selecting the owner.
  /// @param toSeed Seed for selecting the spender.
  /// @param amountSeed Seed for fuzzing the approval amount.
  function act_approve(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
    address from = accounts[fromSeed % accounts.length];
    address to = accounts[toSeed % accounts.length];
    uint256 amount = _bound(amountSeed, 0, type(uint128).max);
    vm.prank(from);
    wrappedAsset.approve(to, amount);
  }

  /// @notice Attempts to mint WrappedAsset to a different address (requires ISSUER_ROLE).
  /// @dev If the caller lacks ISSUER_ROLE and to != msg.sender, should revert.
  ///      Sets unauthorizedMintToOtherSucceeded if it succeeds unexpectedly.
  /// @param fromSeed Seed for selecting the caller.
  /// @param toSeed Seed for selecting the recipient.
  /// @param amountSeed Seed for fuzzing the amount.
  function act_mintToOther(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
    address from = accounts[fromSeed % accounts.length];
    address to = accounts[toSeed % accounts.length];
    if (from == to) to = accounts[(toSeed + 1) % accounts.length];

    uint256 amount = _bound(amountSeed, 1e18, 10_000e18);

    underlyingToken.mint(from, amount);
    vm.startPrank(from);
    underlyingToken.approve(address(wrappedAsset), amount);
    try wrappedAsset.mint(to, amount) {
      // Succeeded -- caller must have ISSUER_ROLE
      if (!wrappedAsset.hasAnyRole(from, ISSUER_ROLE)) {
        unauthorizedMintToOtherSucceeded = true;
      }
    } catch {
      // Expected if from lacks ISSUER_ROLE
    }
    vm.stopPrank();
  }

  /// @notice Grants SENDER_ROLE to a randomly-selected account.
  /// @param accountSeed Seed for selecting an account.
  function act_grantSenderRole(uint256 accountSeed) external {
    address account = accounts[accountSeed % accounts.length];
    vm.prank(owner);
    wrappedAsset.grantRoles(account, SENDER_ROLE);
    ghostHasSenderRole[account] = true;
  }

  /// @notice Grants RECEIVER_ROLE to a randomly-selected account.
  /// @param accountSeed Seed for selecting an account.
  function act_grantReceiverRole(uint256 accountSeed) external {
    address account = accounts[accountSeed % accounts.length];
    vm.prank(owner);
    wrappedAsset.grantRoles(account, RECEIVER_ROLE);
    ghostHasReceiverRole[account] = true;
  }

  /// @notice Revokes SENDER or RECEIVER role from a randomly-selected account.
  /// @param accountSeed Seed for selecting an account.
  /// @param roleSeed Seed for choosing which role to revoke (even=SENDER, odd=RECEIVER).
  function act_revokeRoles(uint256 accountSeed, uint256 roleSeed) external {
    address account = accounts[accountSeed % accounts.length];
    uint256 role = roleSeed % 2 == 0 ? SENDER_ROLE : RECEIVER_ROLE;

    vm.prank(owner);
    wrappedAsset.revokeRoles(account, role);

    if (role == SENDER_ROLE) {
      ghostHasSenderRole[account] = false;
    } else {
      ghostHasReceiverRole[account] = false;
    }
  }
}
