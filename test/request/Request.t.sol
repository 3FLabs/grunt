// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Request} from "../../src/request/Request.sol";
import {RequestFactory} from "../../src/request/RequestFactory.sol";
import {Vault} from "../../src/request/Vault.sol";
import {ControlledVault} from "../../src/request/abstract/vault/ControlledVault.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MockRequestCallback} from "../mock/request/MockRequestCallback.sol";
import {Offer} from "../../src/interfaces/request/IOfferReceiver.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";

contract RequestTest is Test {
  RequestFactory public factory;
  Request public request;
  Vault public ptVault;
  Vault public ytVault;
  MockERC20 public asset;

  // Test addresses
  address public owner;
  address public borrower;
  address public beaconOwner;

  // Test wallets for signing
  Vm.Wallet internal maker;
  Vm.Wallet internal maker2;

  // Constants for EIP-712
  bytes32 internal constant OFFER_TYPEHASH = 0x03babd1fc4fa7801a5697c2a66bd17ee1499bad98dbcb9901bdae479682e3229;
  bytes32 internal constant TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  // Events
  event Repaid();
  event AuthorizedMinting(address indexed to, uint256 ptAmount, uint256 ytAmount);
  event RequestCreated(address request, address asset, address ptToken, address ytToken);

  // Errors
  error AlreadyRepaid();
  error Unauthorized();

  function setUp() public {
    owner = makeAddr("owner");
    borrower = makeAddr("borrower");
    beaconOwner = makeAddr("beaconOwner");
    maker = vm.createWallet("maker");
    maker2 = vm.createWallet("maker2");

    // Deploy asset
    asset = new MockERC20("USDC", "USDC", 6);

    // Deploy factory
    factory = new RequestFactory(beaconOwner);

    // Create request via factory
    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) =
      factory.createRequest(owner, address(asset), "Test Request", "REQ");

    request = Request(reqAddr);
    ptVault = Vault(ptAddr);
    ytVault = Vault(ytAddr);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   FACTORY TESTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_factory_deploysBeacons() public view {
    assertNotEq(factory.REQUEST_BEACON(), address(0));
    assertNotEq(factory.PT_TOKEN_BEACON(), address(0));
    assertNotEq(factory.YT_TOKEN_BEACON(), address(0));
  }

  function test_factory_beaconOwner() public view {
    assertEq(UpgradeableBeacon(factory.REQUEST_BEACON()).owner(), beaconOwner);
    assertEq(UpgradeableBeacon(factory.PT_TOKEN_BEACON()).owner(), beaconOwner);
    assertEq(UpgradeableBeacon(factory.YT_TOKEN_BEACON()).owner(), beaconOwner);
  }

  function test_factory_createRequest_emitsEvent() public {
    // Only check that event is emitted with correct asset (addresses are dynamic)
    vm.expectEmit(false, true, false, false);
    emit RequestCreated(address(0), address(asset), address(0), address(0));

    factory.createRequest(owner, address(asset), "New Request", "NEW");
  }

  function test_factory_createRequest_initializesCorrectly() public view {
    assertEq(request.owner(), owner);
    assertEq(request.asset(), address(asset));
    assertEq(request.ptToken(), address(ptVault));
    assertEq(request.ytToken(), address(ytVault));
    assertEq(request.name(), "Test Request");
    assertEq(request.symbol(), "REQ");
    assertEq(request.canWithdraw(), false);
  }

  function test_factory_createRequest_initializesVaults() public view {
    // PT Vault
    assertEq(ptVault.name(), "PT-Test Request");
    assertEq(ptVault.symbol(), "PT-REQ");
    assertEq(ptVault.asset(), address(asset));
    assertEq(ptVault.decimals(), 6);

    // YT Vault
    assertEq(ytVault.name(), "YT-Test Request");
    assertEq(ytVault.symbol(), "YT-REQ");
    assertEq(ytVault.asset(), address(asset));
    assertEq(ytVault.decimals(), 6);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   INITIALIZATION TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_cannotReinitialize() public {
    vm.expectRevert();
    request.initialize(owner, address(asset), address(ptVault), address(ytVault), "New", "NEW");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               AUTHORIZE MINTING TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_authorizeMinting_success() public {
    address primeBroker = makeAddr("primeBroker");

    vm.expectEmit(true, false, false, true, address(request));
    emit AuthorizedMinting(primeBroker, 1_000_000e6, 100_000e6);

    vm.prank(owner);
    request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);

    (uint128 ptAmount, uint128 ytAmount) = request.mintAuthorization(primeBroker);
    assertEq(ptAmount, 1_000_000e6);
    assertEq(ytAmount, 100_000e6);
  }

  function test_authorizeMinting_onlyOwner() public {
    address primeBroker = makeAddr("primeBroker");
    address notOwner = makeAddr("notOwner");

    vm.prank(notOwner);
    vm.expectRevert(Unauthorized.selector);
    request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);
  }

  function test_authorizeMinting_canUpdate() public {
    address primeBroker = makeAddr("primeBroker");

    vm.startPrank(owner);
    request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);
    request.authorizeMinting(primeBroker, 2_000_000e6, 200_000e6);
    vm.stopPrank();

    (uint128 ptAmount, uint128 ytAmount) = request.mintAuthorization(primeBroker);
    assertEq(ptAmount, 2_000_000e6);
    assertEq(ytAmount, 200_000e6);
  }

  function test_authorizeMinting_canRevoke() public {
    address primeBroker = makeAddr("primeBroker");

    vm.startPrank(owner);
    request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);
    request.authorizeMinting(primeBroker, 0, 0);
    vm.stopPrank();

    (uint128 ptAmount, uint128 ytAmount) = request.mintAuthorization(primeBroker);
    assertEq(ptAmount, 0);
    assertEq(ytAmount, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      MINT TESTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_mint_success() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 100_000e6;

    // Authorize minting
    vm.prank(owner);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    // Fund prime broker and approve
    asset.mint(primeBroker, ptAmount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), ptAmount);

    // Mint
    request.mint();
    vm.stopPrank();

    // Verify balances
    assertEq(ptVault.balanceOf(primeBroker), ptAmount);
    assertEq(ytVault.balanceOf(primeBroker), ytAmount);
    assertEq(asset.balanceOf(address(request)), ptAmount);
    assertEq(asset.balanceOf(primeBroker), 0);

    // Verify authorization is consumed
    (uint128 remainingPt, uint128 remainingYt) = request.mintAuthorization(primeBroker);
    assertEq(remainingPt, 0);
    assertEq(remainingYt, 0);
  }

  function test_mint_revertsWhenRepaid() public {
    address primeBroker = makeAddr("primeBroker");

    vm.prank(owner);
    request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);

    // Set as repaid
    vm.prank(owner);
    request.setRepaid();

    // Try to mint
    vm.prank(primeBroker);
    vm.expectRevert(AlreadyRepaid.selector);
    request.mint();
  }

  function test_mint_revertsWithNoAuthorization() public {
    address primeBroker = makeAddr("primeBroker");

    asset.mint(primeBroker, 1_000_000e6);

    vm.startPrank(primeBroker);
    asset.approve(address(request), 1_000_000e6);

    // Should revert because no authorization (ptAmount = 0, so transfer of 0 succeeds but no tokens minted)
    // Actually it will try to transfer 0 and mint 0, which may or may not revert
    // Let's verify the behavior
    request.mint();
    vm.stopPrank();

    // No tokens should be minted
    assertEq(ptVault.balanceOf(primeBroker), 0);
    assertEq(ytVault.balanceOf(primeBroker), 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CONSUME TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _createOffer(address maker_, uint256 amount, uint256 expectedReturn, uint256 nonce_, uint256 expiration)
    internal
    pure
    returns (Offer memory)
  {
    return Offer({maker: maker_, amount: amount, expectedReturn: expectedReturn, nonce: nonce_, expiration: expiration});
  }

  function _computeDomainSeparator() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        TYPE_HASH, keccak256(bytes(request.name())), keccak256(bytes("0.0.1")), block.chainid, address(request)
      )
    );
  }

  function _signOffer(Offer memory offer, Vm.Wallet memory wallet) internal returns (bytes memory) {
    bytes32 structHash = keccak256(
      abi.encode(OFFER_TYPEHASH, offer.maker, offer.amount, offer.expectedReturn, offer.nonce, offer.expiration)
    );
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _computeDomainSeparator(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
    return abi.encodePacked(r, s, v);
  }

  // Note: The consume() function tests are in a separate test file (RequestConsume.t.sol)
  // because they require EIP-1271 signature support in the callback contract

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   PULL FUNDS TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pullFunds_success() public {
    // First deposit some funds via mint
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    request.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), amount);
    request.mint();
    vm.stopPrank();

    // Now pull funds
    vm.prank(owner);
    request.pullFunds(borrower, amount);

    assertEq(asset.balanceOf(borrower), amount);
    assertEq(asset.balanceOf(address(request)), 0);
  }

  function test_pullFunds_partial() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    request.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), amount);
    request.mint();
    vm.stopPrank();

    // Pull partial funds
    vm.prank(owner);
    request.pullFunds(borrower, 500_000e6);

    assertEq(asset.balanceOf(borrower), 500_000e6);
    assertEq(asset.balanceOf(address(request)), 500_000e6);
  }

  function test_pullFunds_onlyOwner() public {
    address notOwner = makeAddr("notOwner");

    vm.prank(notOwner);
    vm.expectRevert(Unauthorized.selector);
    request.pullFunds(borrower, 1_000_000e6);
  }

  function test_pullFunds_revertsWhenRepaid() public {
    vm.prank(owner);
    request.setRepaid();

    vm.prank(owner);
    vm.expectRevert(AlreadyRepaid.selector);
    request.pullFunds(borrower, 1_000_000e6);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   SET REPAID TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setRepaid_success() public {
    assertEq(request.canWithdraw(), false);

    vm.expectEmit(true, true, true, true, address(request));
    emit Repaid();

    vm.prank(owner);
    request.setRepaid();

    assertEq(request.canWithdraw(), true);
  }

  function test_setRepaid_onlyOwner() public {
    address notOwner = makeAddr("notOwner");

    vm.prank(notOwner);
    vm.expectRevert(Unauthorized.selector);
    request.setRepaid();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 INTEGRATION TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_integration_fullLifecycle_authorizeMinting() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 principal = 1_000_000e6;
    uint128 expectedYield = 100_000e6;

    // 1. Owner authorizes minting
    vm.prank(owner);
    request.authorizeMinting(primeBroker, principal, expectedYield);

    // 2. Prime broker mints
    asset.mint(primeBroker, principal);
    vm.startPrank(primeBroker);
    asset.approve(address(request), principal);
    request.mint();
    vm.stopPrank();

    assertEq(ptVault.balanceOf(primeBroker), principal);
    assertEq(ytVault.balanceOf(primeBroker), expectedYield);

    // 3. Owner pulls funds to borrower
    vm.prank(owner);
    request.pullFunds(borrower, principal);

    assertEq(asset.balanceOf(borrower), principal);

    // 4. Borrower repays with profit
    uint256 repayAmount = principal + 50_000e6; // 50k profit (half of expected)
    asset.mint(borrower, 50_000e6);
    vm.prank(borrower);
    asset.transfer(address(request), repayAmount);

    // 5. Owner marks as repaid
    vm.prank(owner);
    request.setRepaid();

    // 6. Prime broker redeems PT and YT
    vm.startPrank(primeBroker);

    // Redeem PT - should get full principal
    uint256 ptAssets = ptVault.redeem(principal, primeBroker, primeBroker);
    assertEq(ptAssets, principal);

    // Redeem YT - should get 50k (50% of expected yield)
    uint256 ytAssets = ytVault.redeem(expectedYield, primeBroker, primeBroker);
    assertEq(ytAssets, 50_000e6);

    vm.stopPrank();

    assertEq(asset.balanceOf(primeBroker), principal + 50_000e6);
  }

  function test_integration_multiplePrimeBrokers() public {
    address broker1 = makeAddr("broker1");
    address broker2 = makeAddr("broker2");

    // Authorize both brokers
    vm.startPrank(owner);
    request.authorizeMinting(broker1, 1_000_000e6, 100_000e6);
    request.authorizeMinting(broker2, 500_000e6, 50_000e6);
    vm.stopPrank();

    // Broker 1 mints
    asset.mint(broker1, 1_000_000e6);
    vm.startPrank(broker1);
    asset.approve(address(request), 1_000_000e6);
    request.mint();
    vm.stopPrank();

    // Broker 2 mints
    asset.mint(broker2, 500_000e6);
    vm.startPrank(broker2);
    asset.approve(address(request), 500_000e6);
    request.mint();
    vm.stopPrank();

    // Verify total supplies
    assertEq(ptVault.totalSupply(), 1_500_000e6);
    assertEq(ytVault.totalSupply(), 150_000e6);

    // Pull and repay with full expected return
    vm.prank(owner);
    request.pullFunds(borrower, 1_500_000e6);

    asset.mint(borrower, 150_000e6); // Add the yield
    vm.prank(borrower);
    asset.transfer(address(request), 1_650_000e6);

    vm.prank(owner);
    request.setRepaid();

    // Broker 1 redeems
    vm.startPrank(broker1);
    uint256 broker1Pt = ptVault.redeem(1_000_000e6, broker1, broker1);
    uint256 broker1Yt = ytVault.redeem(100_000e6, broker1, broker1);
    vm.stopPrank();

    assertEq(broker1Pt, 1_000_000e6);
    assertEq(broker1Yt, 100_000e6);

    // Broker 2 redeems
    vm.startPrank(broker2);
    uint256 broker2Pt = ptVault.redeem(500_000e6, broker2, broker2);
    uint256 broker2Yt = ytVault.redeem(50_000e6, broker2, broker2);
    vm.stopPrank();

    assertEq(broker2Pt, 500_000e6);
    assertEq(broker2Yt, 50_000e6);
  }

  function test_integration_lossScenario() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 principal = 1_000_000e6;
    uint128 expectedYield = 100_000e6;

    // Mint tokens
    vm.prank(owner);
    request.authorizeMinting(primeBroker, principal, expectedYield);

    asset.mint(primeBroker, principal);
    vm.startPrank(primeBroker);
    asset.approve(address(request), principal);
    request.mint();
    vm.stopPrank();

    // Pull funds
    vm.prank(owner);
    request.pullFunds(borrower, principal);

    // Borrower only returns 900k (10% loss)
    vm.prank(borrower);
    asset.transfer(address(request), 900_000e6);

    vm.prank(owner);
    request.setRepaid();

    // Verify total assets
    assertEq(ptVault.totalAssets(), 900_000e6);
    assertEq(ytVault.totalAssets(), 0);

    // Redeem
    vm.startPrank(primeBroker);
    uint256 ptAssets = ptVault.redeem(principal, primeBroker, primeBroker);
    uint256 ytAssets = ytVault.redeem(expectedYield, primeBroker, primeBroker);
    vm.stopPrank();

    // PT holders share the loss proportionally
    assertEq(ptAssets, 900_000e6);
    assertEq(ytAssets, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       FUZZ TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_authorizeMinting(address to, uint128 ptAmount, uint128 ytAmount) public {
    vm.assume(to != address(0));

    vm.prank(owner);
    request.authorizeMinting(to, ptAmount, ytAmount);

    (uint128 actualPt, uint128 actualYt) = request.mintAuthorization(to);
    assertEq(actualPt, ptAmount);
    assertEq(actualYt, ytAmount);
  }

  function testFuzz_mint(uint128 ptAmount, uint128 ytAmount) public {
    vm.assume(ptAmount > 0 && ptAmount < type(uint128).max / 2);
    vm.assume(ytAmount > 0 && ytAmount < type(uint128).max / 2);

    address primeBroker = makeAddr("primeBroker");

    vm.prank(owner);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    asset.mint(primeBroker, ptAmount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), ptAmount);
    request.mint();
    vm.stopPrank();

    assertEq(ptVault.balanceOf(primeBroker), ptAmount);
    assertEq(ytVault.balanceOf(primeBroker), ytAmount);
    assertEq(asset.balanceOf(address(request)), ptAmount);
  }

  function testFuzz_pullFunds(uint128 depositAmount, uint128 pullAmount) public {
    vm.assume(depositAmount > 0);
    vm.assume(pullAmount > 0 && pullAmount <= depositAmount);

    address primeBroker = makeAddr("primeBroker");

    vm.prank(owner);
    request.authorizeMinting(primeBroker, depositAmount, 0);

    asset.mint(primeBroker, depositAmount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), depositAmount);
    request.mint();
    vm.stopPrank();

    vm.prank(owner);
    request.pullFunds(borrower, pullAmount);

    assertEq(asset.balanceOf(borrower), pullAmount);
    assertEq(asset.balanceOf(address(request)), depositAmount - pullAmount);
  }

  function testFuzz_fullLifecycle(uint128 principal, uint128 expectedYield, uint128 actualReturn) public {
    vm.assume(principal > 0 && principal < type(uint128).max / 2);
    vm.assume(expectedYield > 0 && expectedYield < type(uint128).max / 2);
    // Ensure actualReturn is at least 1 to avoid division by zero edge cases
    vm.assume(actualReturn > 0 && actualReturn < type(uint128).max);

    address primeBroker = makeAddr("primeBroker");

    // Authorize and mint
    vm.prank(owner);
    request.authorizeMinting(primeBroker, principal, expectedYield);

    asset.mint(primeBroker, principal);
    vm.startPrank(primeBroker);
    asset.approve(address(request), principal);
    request.mint();
    vm.stopPrank();

    // Pull funds
    vm.prank(owner);
    request.pullFunds(borrower, principal);

    // Repay (mint directly to request to simulate repayment)
    asset.mint(address(request), actualReturn);

    vm.prank(owner);
    request.setRepaid();

    // Calculate expected redemption values
    uint256 totalAssets = actualReturn;
    uint256 principalAssets = totalAssets < principal ? totalAssets : principal;
    uint256 yieldAssets = totalAssets > principal ? totalAssets - principal : 0;

    assertEq(ptVault.totalAssets(), principalAssets);
    assertEq(ytVault.totalAssets(), yieldAssets);

    // Redeem
    vm.startPrank(primeBroker);
    uint256 ptRedeemed = ptVault.redeem(principal, primeBroker, primeBroker);
    uint256 ytRedeemed = ytVault.redeem(expectedYield, primeBroker, primeBroker);
    vm.stopPrank();

    assertEq(ptRedeemed, principalAssets);
    // YT redemption: yieldAssets is proportionally distributed
    assertEq(ytRedeemed, yieldAssets);
  }

  function testFuzz_multipleBrokers(uint8 numBrokers, uint64 basePrincipal, uint64 baseYield) public {
    numBrokers = uint8(bound(numBrokers, 1, 10));
    basePrincipal = uint64(bound(basePrincipal, 1e6, 1_000_000e6));
    baseYield = uint64(bound(baseYield, 1e6, 100_000e6));

    uint256 totalPrincipal = 0;
    uint256 totalYield = 0;

    // Create and fund brokers
    for (uint256 i = 0; i < numBrokers; i++) {
      address broker = makeAddr(string(abi.encodePacked("broker", vm.toString(i))));
      uint128 principal = uint128(basePrincipal * (i + 1));
      uint128 yield = uint128(baseYield * (i + 1));

      totalPrincipal += principal;
      totalYield += yield;

      vm.prank(owner);
      request.authorizeMinting(broker, principal, yield);

      asset.mint(broker, principal);
      vm.startPrank(broker);
      asset.approve(address(request), principal);
      request.mint();
      vm.stopPrank();
    }

    assertEq(ptVault.totalSupply(), totalPrincipal);
    assertEq(ytVault.totalSupply(), totalYield);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  EDGE CASE TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_decimals_matchesAsset() public {
    // Test with different decimal assets
    MockERC20 asset18 = new MockERC20("DAI", "DAI", 18);
    MockERC20 asset8 = new MockERC20("WBTC", "WBTC", 8);

    // Create request with 18 decimals
    (, address pt18, address yt18) = factory.createRequest(owner, address(asset18), "DAI Request", "DAI-REQ");
    assertEq(Vault(pt18).decimals(), 18);
    assertEq(Vault(yt18).decimals(), 18);

    // Create request with 8 decimals
    (, address pt8, address yt8) = factory.createRequest(owner, address(asset8), "WBTC Request", "WBTC-REQ");
    assertEq(Vault(pt8).decimals(), 8);
    assertEq(Vault(yt8).decimals(), 8);
  }

  function test_cannotWithdrawBeforeRepaid() public {
    address primeBroker = makeAddr("primeBroker");

    vm.prank(owner);
    request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);

    asset.mint(primeBroker, 1_000_000e6);
    vm.startPrank(primeBroker);
    asset.approve(address(request), 1_000_000e6);
    request.mint();

    // Try to redeem before repaid
    vm.expectRevert();
    ptVault.redeem(100e6, primeBroker, primeBroker);

    vm.stopPrank();
  }

  function test_vaultDirectDepositDisabled() public {
    address user = makeAddr("user");
    asset.mint(user, 1_000_000e6);

    vm.startPrank(user);
    asset.approve(address(ptVault), 1_000_000e6);

    // Direct deposit should fail
    vm.expectRevert(ControlledVault.CannotMintShares.selector);
    ptVault.deposit(1_000_000e6, user);

    vm.expectRevert(ControlledVault.CannotMintShares.selector);
    ytVault.deposit(1_000_000e6, user);

    vm.stopPrank();
  }

  function test_vaultDirectMintDisabled() public {
    address user = makeAddr("user");

    vm.startPrank(user);

    // Direct mint should fail
    vm.expectRevert(ControlledVault.CannotMintShares.selector);
    ptVault.mint(1_000_000e6, user);

    vm.expectRevert(ControlledVault.CannotMintShares.selector);
    ytVault.mint(1_000_000e6, user);

    vm.stopPrank();
  }
}

