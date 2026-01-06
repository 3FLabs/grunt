// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {Test} from "forge-std/Test.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

contract WrappedAssetTest is Test {
  error InvalidInitialization();
  error Unauthorized();

  bytes32 private constant _MAIN_STORAGE_SLOT = 0x17335d0a3e97e0293c2bb91805cb7279c336f9ba807e8dbe36cf5097172d3300;
  uint256 private constant EXTRA_ROLE = 1 << 1;

  address public owner;
  address public issuer;
  address public user;

  function setUp() public {
    owner = makeAddr("owner");
    issuer = makeAddr("issuer");
    user = makeAddr("user");
  }

  function test_Initialize_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(token.name(), "Wrapped USCC", "name");
    assertEq(token.symbol(), "wUSCC", "symbol");
    assertEq(token.owner(), owner, "owner");
    assertEq(token.rolesOf(issuer), token.ISSUER_ROLE(), "issuer role");
  }

  function test_Initialize_OnlyOnce() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.expectRevert(InvalidInitialization.selector);
    token.initialize(owner, issuer, "wUSCC", "Wrapped USCC", 18);
  }

  function test_Initialize_ThroughProxy() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    assertEq(token.name(), "Wrapped USCC", "proxy init");
  }

  function test_Mint_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.prank(issuer);
    token.mint(user, 100);
    assertEq(token.balanceOf(user), 100, "balance");
    assertEq(token.totalSupply(), 100, "total supply");
  }

  function test_Mint_OnlyIssuerRole() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.expectRevert(Unauthorized.selector);
    token.mint(user, 100);
  }

  function test_Mint_ToZeroAddress() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.prank(issuer);
    vm.expectRevert();
    token.mint(address(0), 100);
  }

  function test_Mint_MultipleIssuers() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    address issuerTwo = makeAddr("issuerTwo");
    uint256 issuerRole = token.ISSUER_ROLE();
    vm.prank(owner);
    token.grantRoles(issuerTwo, issuerRole);

    vm.prank(issuer);
    token.mint(user, 100);
    vm.prank(issuerTwo);
    token.mint(user, 50);

    assertEq(token.balanceOf(user), 150, "balance");
  }

  function test_Burn_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.prank(issuer);
    token.mint(user, 100);

    vm.prank(issuer);
    token.burn(user, 40);
    assertEq(token.balanceOf(user), 60, "balance");
    assertEq(token.totalSupply(), 60, "total supply");
  }

  function test_Burn_OnlyIssuerRole() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.expectRevert(Unauthorized.selector);
    token.burn(user, 10);
  }

  function test_Burn_InsufficientBalance() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.prank(issuer);
    vm.expectRevert();
    token.burn(user, 10);
  }

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

  function test_Transfer_Success() public {
    WrappedAsset token = _deployProxy("wUSCC", "Wrapped USCC");
    vm.prank(issuer);
    token.mint(user, 100);

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
    vm.prank(issuer);
    token.mint(user, 100);

    vm.prank(user);
    token.approve(owner, 80);

    vm.prank(owner);
    token.transferFrom(user, owner, 80);
    assertEq(token.balanceOf(owner), 80, "owner");
  }

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

  function test_Proxy_ImplementationStorage() public {
    WrappedAsset implementation = new WrappedAsset();
    address proxyAddress = LibClone.deployERC1967(address(implementation));
    WrappedAsset proxy = WrappedAsset(proxyAddress);
    vm.prank(owner);
    proxy.initialize(owner, issuer, "wUSCC", "Wrapped USCC", 18);

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

    vm.prank(owner);
    tokenOne.initialize(owner, issuer, "wUSCC1", "Wrapped USCC 1", 18);
    vm.prank(owner);
    tokenTwo.initialize(owner, issuer, "wUSCC2", "Wrapped USCC 2", 18);

    assertEq(tokenOne.symbol(), "wUSCC1", "symbol one");
    assertEq(tokenTwo.symbol(), "wUSCC2", "symbol two");
  }

  function _deployProxy(string memory symbol, string memory name) internal returns (WrappedAsset) {
    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    WrappedAsset token = WrappedAsset(proxy);
    vm.prank(owner);
    token.initialize(owner, issuer, symbol, name, 18);
    return token;
  }
}
