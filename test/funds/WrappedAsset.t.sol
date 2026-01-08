// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract WrappedAssetTest is Test {
  error InvalidInitialization();
  error Unauthorized();
  error MintToZeroAddress();
  error BurnToZeroAddress();

  bytes32 private constant _MAIN_STORAGE_SLOT = 0x17335d0a3e97e0293c2bb91805cb7279c336f9ba807e8dbe36cf5097172d3300;
  uint256 private constant EXTRA_ROLE = 1 << 1;

  MockERC20 public underlying;
  address public owner;
  address public issuer;
  address public user;

  function setUp() public {
    owner = makeAddr("owner");
    issuer = makeAddr("issuer");
    user = makeAddr("user");
    underlying = new MockERC20("USCC", "USCC", 6);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Initialize_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(token.name(), "Wrapped USCC", "name");
    assertEq(token.symbol(), "wUSCC", "symbol");
    assertEq(token.owner(), owner, "owner");
    assertEq(token.rolesOf(issuer), token.ISSUER_ROLE(), "issuer role");
    assertEq(token.underlying(), address(underlying), "underlying");
  }

  function test_Initialize_OnlyOnce() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.expectRevert(InvalidInitialization.selector);
    token.initialize(owner, issuer, address(underlying), "wUSCC", "Wrapped USCC", 18);
  }

  function test_Initialize_ThroughProxy() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(token.name(), "Wrapped USCC", "proxy init");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           MINT                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Mint_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // Give issuer underlying tokens and approve
    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);

    // Mint wrapper tokens
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    assertEq(token.balanceOf(user), 100, "wrapper balance");
    assertEq(token.totalSupply(), 100, "total supply");
    assertEq(underlying.balanceOf(address(token)), 100, "underlying held by wrapper");
    assertEq(underlying.balanceOf(issuer), 0, "issuer underlying spent");
  }

  function test_Mint_OnlyIssuerRole() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    underlying.mint(user, 100);
    vm.prank(user);
    underlying.approve(address(token), 100);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    token.mint(user, user, 100);
  }

  function test_Mint_ToZeroAddress() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);

    vm.prank(issuer);
    vm.expectRevert(MintToZeroAddress.selector);
    token.mint(issuer, address(0), 100);
  }

  function test_Mint_MultipleIssuers() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    address issuerTwo = makeAddr("issuerTwo");
    uint256 issuerRole = token.ISSUER_ROLE();
    vm.prank(owner);
    token.grantRoles(issuerTwo, issuerRole);

    // Setup issuer one
    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);

    // Setup issuer two
    underlying.mint(issuerTwo, 50);
    vm.prank(issuerTwo);
    underlying.approve(address(token), 50);

    vm.prank(issuer);
    token.mint(issuer, user, 100);
    vm.prank(issuerTwo);
    token.mint(issuerTwo, user, 50);

    assertEq(token.balanceOf(user), 150, "balance");
    assertEq(underlying.balanceOf(address(token)), 150, "underlying held");
  }

  function test_Mint_FromDifferentAddress() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // Give user underlying tokens and approve the wrapper
    underlying.mint(user, 100);
    vm.prank(user);
    underlying.approve(address(token), 100);

    // Issuer mints wrapper to user, pulling underlying from user
    vm.prank(issuer);
    token.mint(user, user, 100);

    assertEq(token.balanceOf(user), 100, "wrapper balance");
    assertEq(underlying.balanceOf(user), 0, "user underlying spent");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           BURN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Burn_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // Mint first
    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    // User burns their own tokens
    vm.prank(user);
    token.burn(user, user, 40);

    assertEq(token.balanceOf(user), 60, "wrapper balance");
    assertEq(token.totalSupply(), 60, "total supply");
    assertEq(underlying.balanceOf(user), 40, "underlying returned to user");
    assertEq(underlying.balanceOf(address(token)), 60, "underlying held by wrapper");
  }

  function test_Burn_AnyoneCanBurnOwnTokens() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // Mint to user
    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    // User (non-issuer) can burn their own tokens
    vm.prank(user);
    token.burn(user, user, 50);

    assertEq(token.balanceOf(user), 50, "balance after burn");
    assertEq(underlying.balanceOf(user), 50, "underlying received");
  }

  function test_Burn_ToZeroAddress() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // Mint first
    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    vm.prank(user);
    vm.expectRevert(BurnToZeroAddress.selector);
    token.burn(user, address(0), 50);
  }

  function test_Burn_InsufficientBalance() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // User has no tokens
    vm.prank(user);
    vm.expectRevert();
    token.burn(user, user, 10);
  }

  function test_Burn_RequiresAllowanceForOtherAddress() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // Mint to user
    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    // Third party tries to burn user's tokens without approval
    address thirdParty = makeAddr("thirdParty");
    vm.prank(thirdParty);
    vm.expectRevert();
    token.burn(user, thirdParty, 50);
  }

  function test_Burn_WithAllowance() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // Mint to user
    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    // User approves third party
    address thirdParty = makeAddr("thirdParty");
    vm.prank(user);
    token.approve(thirdParty, 50);

    // Third party burns user's tokens
    vm.prank(thirdParty);
    token.burn(user, thirdParty, 50);

    assertEq(token.balanceOf(user), 50, "user balance");
    assertEq(underlying.balanceOf(thirdParty), 50, "thirdParty received underlying");
  }

  function test_Burn_ToDifferentAddress() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    // Mint to user
    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    // User burns and sends underlying to owner
    vm.prank(user);
    token.burn(user, owner, 40);

    assertEq(token.balanceOf(user), 60, "user wrapper balance");
    assertEq(underlying.balanceOf(owner), 40, "owner received underlying");
    assertEq(underlying.balanceOf(user), 0, "user no underlying");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ERC20 METADATA                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Name_ReturnsStoredValue() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(token.name(), "Wrapped USCC", "name");
  }

  function test_Symbol_ReturnsStoredValue() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(token.symbol(), "wUSCC", "symbol");
  }

  function test_Decimals_Returns18() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(token.decimals(), 18, "decimals");
  }

  function test_Underlying_ReturnsStoredValue() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(token.underlying(), address(underlying), "underlying");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ERC20 TRANSFERS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Transfer_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    vm.prank(user);
    token.transfer(owner, 40);
    assertEq(token.balanceOf(owner), 40, "owner");
  }

  function test_Approve_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.prank(user);
    token.approve(owner, 100);
    assertEq(token.allowance(user, owner), 100, "allowance");
  }

  function test_TransferFrom_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");

    underlying.mint(issuer, 100);
    vm.prank(issuer);
    underlying.approve(address(token), 100);
    vm.prank(issuer);
    token.mint(issuer, user, 100);

    vm.prank(user);
    token.approve(owner, 80);

    vm.prank(owner);
    token.transferFrom(user, owner, 80);
    assertEq(token.balanceOf(owner), 80, "owner");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Roles_GrantIssuerRole() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    address newIssuer = makeAddr("newIssuer");
    uint256 issuerRole = token.ISSUER_ROLE();
    vm.prank(owner);
    token.grantRoles(newIssuer, issuerRole);
    assertEq(token.rolesOf(newIssuer), issuerRole, "issuer role");
  }

  function test_Roles_RevokeIssuerRole() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    uint256 issuerRole = token.ISSUER_ROLE();
    vm.prank(owner);
    token.revokeRoles(issuer, issuerRole);
    assertEq(token.rolesOf(issuer), 0, "revoked");
  }

  function test_Roles_MultipleRoles() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    uint256 issuerRole = token.ISSUER_ROLE();
    uint256 combined = issuerRole | EXTRA_ROLE;
    vm.prank(owner);
    token.grantRoles(issuer, EXTRA_ROLE);
    assertEq(token.rolesOf(issuer), combined, "combined");
  }

  function test_Roles_OwnershipTransfer() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.prank(owner);
    token.transferOwnership(user);
    assertEq(token.owner(), user, "new owner");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           PROXY                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Proxy_ImplementationStorage() public {
    WrappedAsset implementation = new WrappedAsset();
    address proxyAddress = LibClone.deployERC1967(address(implementation));
    WrappedAsset proxy = WrappedAsset(proxyAddress);
    vm.prank(owner);
    proxy.initialize(owner, issuer, address(underlying), "wUSCC", "Wrapped USCC", 18);

    assertEq(bytes(implementation.name()).length, 0, "impl name");
    assertEq(bytes(implementation.symbol()).length, 0, "impl symbol");
    assertTrue(vm.load(address(proxy), _MAIN_STORAGE_SLOT) != bytes32(0), "proxy slot nonzero");
    assertEq(vm.load(address(implementation), _MAIN_STORAGE_SLOT), bytes32(0), "impl slot empty");
  }

  function test_Proxy_NameAndSymbolStorage() public {
    WrappedAsset proxy = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(proxy.name(), "Wrapped USCC", "name");
    assertEq(proxy.symbol(), "wUSCC", "symbol");
  }

  function test_Proxy_MultipleProxies() public {
    WrappedAsset implementation = new WrappedAsset();
    address proxyOne = LibClone.deployERC1967(address(implementation));
    address proxyTwo = LibClone.deployERC1967(address(implementation));

    WrappedAsset tokenOne = WrappedAsset(proxyOne);
    WrappedAsset tokenTwo = WrappedAsset(proxyTwo);

    MockERC20 underlyingOne = new MockERC20("USCC1", "USCC1", 6);
    MockERC20 underlyingTwo = new MockERC20("USCC2", "USCC2", 6);

    vm.prank(owner);
    tokenOne.initialize(owner, issuer, address(underlyingOne), "wUSCC1", "Wrapped USCC 1", 18);
    vm.prank(owner);
    tokenTwo.initialize(owner, issuer, address(underlyingTwo), "wUSCC2", "Wrapped USCC 2", 18);

    assertEq(tokenOne.symbol(), "wUSCC1", "symbol one");
    assertEq(tokenTwo.symbol(), "wUSCC2", "symbol two");
    assertEq(tokenOne.underlying(), address(underlyingOne), "underlying one");
    assertEq(tokenTwo.underlying(), address(underlyingTwo), "underlying two");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _deployProxy(string memory symbol, string memory name) internal returns (WrappedAsset) {
    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    WrappedAsset token = WrappedAsset(proxy);
    vm.prank(owner);
    token.initialize(owner, issuer, address(underlying), symbol, name, 18);
    return token;
  }
}
