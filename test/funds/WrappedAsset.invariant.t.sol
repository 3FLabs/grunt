// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {WrappedAssetHandler} from "test/mock/funds/WrappedAssetHandler.sol";

/// @title WrappedAssetInvariantTest
/// @notice Invariant test suite for the WrappedAsset contract.
/// @dev Uses a handler-based approach: WrappedAssetHandler drives random state
///      transitions (mint, burn, transfer, role grants/revokes) while the invariant
///      functions verify that the WrappedAsset's core properties hold.
contract WrappedAssetInvariantTest is StdInvariant, Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  WrappedAsset public wrappedAsset;
  MockERC20 public underlyingToken;
  WrappedAssetHandler public handler;
  address public owner;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    owner = makeAddr("owner");

    // Deploy underlying token
    underlyingToken = new MockERC20("Underlying Token", "UNDL", 18);
    vm.label(address(underlyingToken), "UnderlyingToken");

    // Deploy WrappedAsset via ERC1967 proxy
    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedAsset = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedAsset.initialize(owner, address(0), address(underlyingToken), "wUNDL", "Wrapped Underlying", 18);
    vm.label(address(wrappedAsset), "WrappedAsset");

    // Deploy and initialize handler
    handler = new WrappedAssetHandler();
    handler.initialize(wrappedAsset, underlyingToken, owner);

    // Register handler action selectors
    bytes4[] memory selectors = new bytes4[](9);
    selectors[0] = handler.act_mint.selector;
    selectors[1] = handler.act_burn.selector;
    selectors[2] = handler.act_transfer.selector;
    selectors[3] = handler.act_transferFrom.selector;
    selectors[4] = handler.act_approve.selector;
    selectors[5] = handler.act_mintToOther.selector;
    selectors[6] = handler.act_grantSenderRole.selector;
    selectors[7] = handler.act_grantReceiverRole.selector;
    selectors[8] = handler.act_revokeRoles.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));

    // Labels
    vm.label(address(handler), "Handler");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INVARIANTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice WA-1: 1:1 backing -- totalSupply of WrappedAsset equals the underlying balance held.
  /// @dev The WrappedAsset mints 1:1 on wrap and burns 1:1 on unwrap. At all times the
  ///      underlying token balance of the WrappedAsset contract must equal its totalSupply.
  function invariant_oneToOneBacking() public view {
    assertEq(
      wrappedAsset.totalSupply(),
      underlyingToken.balanceOf(address(wrappedAsset)),
      "WA-1: totalSupply != underlying balance (1:1 backing broken)"
    );
  }

  /// @notice WA-2: Transfer restriction enforcement -- unauthorized transfers never succeed.
  /// @dev Transfers between addresses where the sender lacks SENDER_ROLE and the receiver
  ///      lacks RECEIVER_ROLE must always revert. The handler sets unauthorizedTransferSucceeded
  ///      if this property is violated.
  function invariant_transferRestrictions() public view {
    assertFalse(handler.unauthorizedTransferSucceeded(), "WA-2: unauthorized transfer succeeded");
  }

  /// @notice WA-3: ISSUER_ROLE enforcement -- mint-to-other requires ISSUER_ROLE.
  /// @dev When calling mint(to, amount) with to != msg.sender, the caller must have ISSUER_ROLE.
  ///      The handler sets unauthorizedMintToOtherSucceeded if this is violated.
  function invariant_issuerRoleEnforcement() public view {
    assertFalse(handler.unauthorizedMintToOtherSucceeded(), "WA-3: unauthorized mint-to-other succeeded");
  }

  /// @notice WA-4: Burn is never blocked by role restrictions.
  /// @dev Burns bypass _beforeTokenTransfer (from or to is address(0)). Any account holding
  ///      WrappedAsset should be able to burn (unwrap) regardless of SENDER_ROLE / RECEIVER_ROLE.
  function invariant_burnNeverBlockedByRole() public view {
    assertFalse(handler.burnBlockedByRole(), "WA-4: burn was blocked by role restriction");
  }
}
