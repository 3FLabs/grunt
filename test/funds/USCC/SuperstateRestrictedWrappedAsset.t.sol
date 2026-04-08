// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SuperstateRestrictedWrappedAsset} from "src/funds/USCC/SuperstateRestrictedWrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibCommonErrors as CommonErrors} from "src/libs/common/LibCommonErrors.sol";

import {MockSuperstateToken} from "test/mock/funds/MockSuperstateToken.sol";
import {MockAllowlist} from "test/mock/funds/MockAllowlist.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title SuperstateRestrictedWrappedAssetTest
/// @notice Tests for SuperstateRestrictedWrappedAsset — ensures Superstate allowlist is enforced
///         on all transfers in addition to the base WrappedAsset SENDER_ROLE / RECEIVER_ROLE checks.
contract SuperstateRestrictedWrappedAssetTest is Test {
  error InvalidInitialization();
  error Unauthorized();
  error TransferFailed();
  error TransferFromFailed();

  // WrappedAsset roles (matching internal constants)
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;
  uint256 private constant RECEIVER_ROLE = 1 << 2;

  MockAllowlist public allowlist;
  MockSuperstateToken public uscc;
  MockERC20 public usdc;

  address public owner;
  address public issuer;
  address public user;
  address public recipient;

  function setUp() public {
    owner = makeAddr("owner");
    issuer = makeAddr("issuer");
    user = makeAddr("user");
    recipient = makeAddr("recipient");

    usdc = new MockERC20("USDC", "USDC", 6);
    allowlist = new MockAllowlist();
    uscc = new MockSuperstateToken("USCC", "USCC", address(allowlist), address(usdc));

    // By default, allow key addresses on Superstate's allowlist
    allowlist.setAllowed(address(this), "USCC", true);
    allowlist.setAllowed(owner, "USCC", true);
    allowlist.setAllowed(issuer, "USCC", true);
    allowlist.setAllowed(user, "USCC", true);
    allowlist.setAllowed(recipient, "USCC", true);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_Success() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    assertEq(token.name(), "Wrapped USCC", "name");
    assertEq(token.symbol(), "wUSCC", "symbol");
    assertEq(token.owner(), owner, "owner");
    assertEq(token.rolesOf(issuer), ISSUER_ROLE | SENDER_ROLE, "issuer roles");
    assertEq(token.underlying(), address(uscc), "underlying");
  }

  function test_Initialize_OnlyOnce() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    vm.expectRevert(InvalidInitialization.selector);
    token.initialize(owner, issuer, address(uscc), "wUSCC", "Wrapped USCC");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      MINT WITH ALLOWLIST                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Mint_ToSelf_Allowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintUscc(user, 100);

    vm.startPrank(user);
    uscc.approve(address(token), 100);
    token.mint(user, 100);
    vm.stopPrank();

    assertEq(token.balanceOf(user), 100, "balance");
  }

  function test_Mint_ToSelf_RevertsWhenNotAllowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintUscc(user, 100);

    // Remove user from Superstate allowlist — underlying USCC safeTransferFrom reverts
    // (the underlying enforces its own allowlist on the transfer)
    allowlist.setAllowed(user, "USCC", false);

    vm.startPrank(user);
    uscc.approve(address(token), 100);
    vm.expectRevert(TransferFromFailed.selector);
    token.mint(user, 100);
    vm.stopPrank();
  }

  function test_Mint_ToOther_Allowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintUscc(issuer, 100);

    vm.startPrank(issuer);
    uscc.approve(address(token), 100);
    token.mint(user, 100);
    vm.stopPrank();

    assertEq(token.balanceOf(user), 100, "balance");
  }

  function test_Mint_ToOther_RevertsWhenIssuerNotAllowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintUscc(issuer, 100);

    // Remove issuer from Superstate allowlist — underlying USCC safeTransferFrom reverts
    allowlist.setAllowed(issuer, "USCC", false);

    vm.startPrank(issuer);
    uscc.approve(address(token), 100);
    vm.expectRevert(TransferFromFailed.selector);
    token.mint(user, 100);
    vm.stopPrank();
  }

  function test_Mint_ToOther_RevertsWhenRecipientNotAllowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintUscc(issuer, 100);

    // Remove recipient from Superstate allowlist
    allowlist.setAllowed(user, "USCC", false);

    vm.startPrank(issuer);
    uscc.approve(address(token), 100);
    vm.expectRevert(Unauthorized.selector);
    token.mint(user, 100);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      BURN WITH ALLOWLIST                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Burn_Allowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    vm.prank(user);
    token.burn(user, user, 50);

    assertEq(token.balanceOf(user), 50, "balance after burn");
  }

  function test_Burn_RevertsWhenRecipientNotAllowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    // Remove burn recipient from Superstate allowlist — underlying USCC safeTransfer reverts
    allowlist.setAllowed(recipient, "USCC", false);

    vm.prank(user);
    vm.expectRevert(TransferFailed.selector);
    token.burn(user, recipient, 50);
  }

  function test_Burn_RevertsWhenFromNotAllowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    // Remove user from Superstate allowlist after mint
    allowlist.setAllowed(user, "USCC", false);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    token.burn(user, user, 50);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    TRANSFER WITH ALLOWLIST                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Transfer_Allowed_BothOnAllowlist() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    // Grant SENDER_ROLE to user
    vm.prank(owner);
    token.grantRoles(user, SENDER_ROLE);

    vm.prank(user);
    token.transfer(recipient, 50);

    assertEq(token.balanceOf(recipient), 50, "recipient balance");
    assertEq(token.balanceOf(user), 50, "user balance");
  }

  function test_Transfer_RevertsWhenSenderNotAllowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    // Grant SENDER_ROLE
    vm.prank(owner);
    token.grantRoles(user, SENDER_ROLE);

    // Remove sender from Superstate allowlist
    allowlist.setAllowed(user, "USCC", false);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    token.transfer(recipient, 50);
  }

  function test_Transfer_RevertsWhenReceiverNotAllowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    // Grant SENDER_ROLE
    vm.prank(owner);
    token.grantRoles(user, SENDER_ROLE);

    // Remove recipient from Superstate allowlist
    allowlist.setAllowed(recipient, "USCC", false);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    token.transfer(recipient, 50);
  }

  function test_Transfer_RevertsWithoutSenderRole_EvenIfAllowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    // Both on allowlist but user has no SENDER_ROLE (and recipient no RECEIVER_ROLE)
    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    token.transfer(recipient, 50);
  }

  function test_Transfer_ViaReceiverRole_Allowed() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    // Grant RECEIVER_ROLE to recipient (user has no SENDER_ROLE)
    vm.prank(owner);
    token.grantRoles(recipient, RECEIVER_ROLE);

    vm.prank(user);
    token.transfer(recipient, 50);

    assertEq(token.balanceOf(recipient), 50, "recipient balance");
  }

  function test_Transfer_ViaReceiverRole_RevertsWhenReceiverNotOnAllowlist() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();
    _mintWrapped(token, user, 100);

    // Grant RECEIVER_ROLE but remove from Superstate allowlist
    vm.prank(owner);
    token.grantRoles(recipient, RECEIVER_ROLE);
    allowlist.setAllowed(recipient, "USCC", false);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    token.transfer(recipient, 50);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    isAllowed VIEW TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_IsAllowed_DelegatesToSuperstate() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();

    // User is on Superstate allowlist
    assertTrue(token.isAllowed(user, 100), "allowed user");

    // Remove from allowlist
    allowlist.setAllowed(user, "USCC", false);
    assertFalse(token.isAllowed(user, 100), "disallowed user");
  }

  function test_IsAllowed_AmountIgnored() public {
    SuperstateRestrictedWrappedAsset token = _deployProxy();

    // isAllowed should return the same result regardless of amount
    assertTrue(token.isAllowed(user, 0), "zero amount");
    assertTrue(token.isAllowed(user, type(uint256).max), "max amount");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PROXY ISOLATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Proxy_StorageIsolation() public {
    SuperstateRestrictedWrappedAsset implementation = new SuperstateRestrictedWrappedAsset();

    address proxyOne = LibClone.deployERC1967(address(implementation));
    address proxyTwo = LibClone.deployERC1967(address(implementation));

    SuperstateRestrictedWrappedAsset tokenOne = SuperstateRestrictedWrappedAsset(proxyOne);
    SuperstateRestrictedWrappedAsset tokenTwo = SuperstateRestrictedWrappedAsset(proxyTwo);

    MockAllowlist allowlistTwo = new MockAllowlist();
    MockSuperstateToken usccTwo = new MockSuperstateToken("USCC2", "USCC2", address(allowlistTwo), address(usdc));

    vm.prank(owner);
    tokenOne.initialize(owner, issuer, address(uscc), "wUSCC1", "Wrapped USCC 1");
    vm.prank(owner);
    tokenTwo.initialize(owner, issuer, address(usccTwo), "wUSCC2", "Wrapped USCC 2");

    assertEq(tokenOne.underlying(), address(uscc), "proxy1 underlying");
    assertEq(tokenTwo.underlying(), address(usccTwo), "proxy2 underlying");
    assertEq(tokenOne.symbol(), "wUSCC1", "proxy1 symbol");
    assertEq(tokenTwo.symbol(), "wUSCC2", "proxy2 symbol");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _deployProxy() internal returns (SuperstateRestrictedWrappedAsset) {
    SuperstateRestrictedWrappedAsset implementation = new SuperstateRestrictedWrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    SuperstateRestrictedWrappedAsset token = SuperstateRestrictedWrappedAsset(proxy);
    vm.prank(owner);
    token.initialize(owner, issuer, address(uscc), "wUSCC", "Wrapped USCC");

    // Allow the wrapped asset contract itself on the allowlist
    allowlist.setAllowed(address(token), "USCC", true);

    return token;
  }

  function _mintUscc(address to, uint256 amount) internal {
    uscc.mint(to, amount);
  }

  function _mintWrapped(SuperstateRestrictedWrappedAsset token, address to, uint256 amount) internal {
    _mintUscc(to, amount);
    vm.startPrank(to);
    uscc.approve(address(token), amount);
    token.mint(to, amount);
    vm.stopPrank();
  }
}
