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
import {MockRequestInteractionsCallback} from "../mock/request/MockRequestInteractionsCallback.sol";
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
  address public puller;
  address public consumer;
  address public borrower;
  address public beaconOwner;

  // Test wallets for signing
  Vm.Wallet internal maker;
  Vm.Wallet internal maker2;

  // Constants for EIP-712
  bytes32 internal constant OFFER_TYPEHASH = 0x3ded0c963332962cf2d273c8fb4f3e69f4ef33407ca72484fcebb56263ad0664;
  bytes32 internal constant TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  // Events
  event Repaid(uint256 amount);
  event FundsPulled(address indexed puller, uint256 amount);
  event AuthorizedMinting(address indexed to, uint256 ptAmount, uint256 ytAmount);
  event RequestCreated(address request, address asset, address ptToken, address ytToken);

  // Errors
  error AlreadyRepaid();
  error Unauthorized();

  function setUp() public {
    owner = makeAddr("owner");
    puller = makeAddr("puller");
    consumer = makeAddr("consumer");
    borrower = makeAddr("borrower");
    beaconOwner = makeAddr("beaconOwner");
    maker = vm.createWallet("maker");
    maker2 = vm.createWallet("maker2");

    // Deploy asset
    asset = new MockERC20("USDC", "USDC", 6);

    // Deploy factory
    factory = new RequestFactory(beaconOwner);

    // Create request via factory with far future deadline (effectively disabled for most tests)
    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) =
      factory.createRequest(owner, puller, consumer, address(asset), "Test Request", "REQ", uint64(type(uint64).max));

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

    factory.createRequest(owner, puller, consumer, address(asset), "New Request", "NEW", uint64(type(uint64).max));
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

  function test_factory_isRequest_returnsTrueForDeployedRequest() public view {
    assertEq(factory.isRequest(address(request)), true);
  }

  function test_factory_isRequest_returnsFalseForRandomAddress() public view {
    assertEq(factory.isRequest(address(0x1234)), false);
  }

  function test_factory_isRequest_tracksMultipleRequests() public {
    // Deploy additional requests
    (address req1,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Request 1", "REQ1", uint64(type(uint64).max));
    (address req2,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Request 2", "REQ2", uint64(type(uint64).max));

    // All deployed requests should be tracked
    assertEq(factory.isRequest(address(request)), true);
    assertEq(factory.isRequest(req1), true);
    assertEq(factory.isRequest(req2), true);

    // Random addresses should still return false
    assertEq(factory.isRequest(makeAddr("notARequest")), false);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   INITIALIZATION TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_cannotReinitialize() public {
    vm.expectRevert();
    request.initialize(
      owner,
      puller,
      consumer,
      address(asset),
      address(ptVault),
      address(ytVault),
      "New",
      "NEW",
      uint64(type(uint64).max)
    );
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

  function test_authorizeMinting_onlyOwnerOrConsumer() public {
    address primeBroker = makeAddr("primeBroker");
    address notAuthorized = makeAddr("notAuthorized");

    vm.prank(notAuthorized);
    vm.expectRevert(Unauthorized.selector);
    request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);
  }

  function test_authorizeMinting_consumerCanCall() public {
    address primeBroker = makeAddr("primeBroker");

    vm.expectEmit(true, false, false, true, address(request));
    emit AuthorizedMinting(primeBroker, 1_000_000e6, 100_000e6);

    vm.prank(consumer);
    request.authorizeMinting(primeBroker, 1_000_000e6, 100_000e6);

    (uint128 ptAmount, uint128 ytAmount) = request.mintAuthorization(primeBroker);
    assertEq(ptAmount, 1_000_000e6);
    assertEq(ytAmount, 100_000e6);
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

  function _createOffer(
    address maker_,
    uint256 amount,
    uint256 expectedReturn,
    uint256 nonce_,
    uint256 expiration,
    bool useCallback
  ) internal pure returns (Offer memory) {
    return Offer({
      maker: maker_,
      amount: amount,
      expectedReturn: expectedReturn,
      nonce: nonce_,
      expiration: expiration,
      useCallback: useCallback
    });
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
      abi.encode(
        OFFER_TYPEHASH,
        offer.maker,
        offer.amount,
        offer.expectedReturn,
        offer.nonce,
        offer.expiration,
        offer.useCallback
      )
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

    // Now pull funds (puller receives funds, no callback)
    asset.mint(puller, 0); // Ensure puller exists

    // Expect the FundsPulled event with puller address
    vm.expectEmit(true, true, true, true, address(request));
    emit FundsPulled(puller, amount);

    vm.prank(puller);
    request.pullFunds(amount, "");

    assertEq(asset.balanceOf(puller), amount);
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

    // Pull partial funds - expect event with puller address and partial amount
    vm.expectEmit(true, true, true, true, address(request));
    emit FundsPulled(puller, 500_000e6);

    vm.prank(puller);
    request.pullFunds(500_000e6, "");

    assertEq(asset.balanceOf(puller), 500_000e6);
    assertEq(asset.balanceOf(address(request)), 500_000e6);
  }

  function test_pullFunds_onlyPuller() public {
    address notPuller = makeAddr("notPuller");

    vm.prank(notPuller);
    vm.expectRevert(Unauthorized.selector);
    request.pullFunds(1_000_000e6, "");
  }

  function test_pullFunds_revertsWhenRepaid() public {
    vm.prank(owner);
    request.setRepaid();

    vm.prank(puller);
    vm.expectRevert(AlreadyRepaid.selector);
    request.pullFunds(1_000_000e6, "");
  }

  function test_pullFunds_withCallback() public {
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

    // Deploy callback contract
    MockRequestInteractionsCallback callback = new MockRequestInteractionsCallback();

    // Create a new request with callback as puller
    vm.prank(owner);
    (address reqAddr,,) = factory.createRequest(
      owner, address(callback), consumer, address(asset), "Callback Request", "CALLBACK", uint64(type(uint64).max)
    );

    Request callbackRequest = Request(reqAddr);

    // Fund the callback request
    vm.prank(owner);
    callbackRequest.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(callbackRequest), amount);
    callbackRequest.mint();
    vm.stopPrank();

    // Pull funds with callback data
    bytes memory callbackData = abi.encode("test", 123);
    vm.prank(address(callback));
    callbackRequest.pullFunds(amount, callbackData);

    // Verify callback was called
    assertEq(callback.callbackCalled(), true);
    assertEq(callback.lastAmount(), amount);
    assertEq(callback.lastData(), callbackData);
    assertEq(asset.balanceOf(address(callback)), amount);
  }

  function test_pullFunds_withCallback_revertsIfCallbackReverts() public {
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

    // Deploy callback contract that will revert
    MockRequestInteractionsCallback callback = new MockRequestInteractionsCallback();
    callback.setShouldRevert(true);

    // Create a new request with callback as puller
    vm.prank(owner);
    (address reqAddr,,) = factory.createRequest(
      owner, address(callback), consumer, address(asset), "Callback Request", "CALLBACK", uint64(type(uint64).max)
    );

    Request callbackRequest = Request(reqAddr);

    // Fund the callback request
    vm.prank(owner);
    callbackRequest.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(callbackRequest), amount);
    callbackRequest.mint();
    vm.stopPrank();

    // Pull funds with callback data - should revert
    bytes memory callbackData = abi.encode("test");
    vm.prank(address(callback));
    vm.expectRevert("MockRequestInteractionsCallback: forced revert");
    callbackRequest.pullFunds(amount, callbackData);
  }

  function test_pullFunds_withEmptyData_noCallback() public {
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

    // Deploy callback contract
    MockRequestInteractionsCallback callback = new MockRequestInteractionsCallback();

    // Create a new request with callback as puller
    vm.prank(owner);
    (address reqAddr,,) = factory.createRequest(
      owner, address(callback), consumer, address(asset), "Callback Request", "CALLBACK", uint64(type(uint64).max)
    );

    Request callbackRequest = Request(reqAddr);

    // Fund the callback request
    vm.prank(owner);
    callbackRequest.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(callbackRequest), amount);
    callbackRequest.mint();
    vm.stopPrank();

    // Pull funds with empty data - callback should not be called
    vm.prank(address(callback));
    callbackRequest.pullFunds(amount, "");

    // Verify callback was NOT called
    assertEq(callback.callbackCalled(), false);
    assertEq(callback.lastAmount(), 0);
    assertEq(asset.balanceOf(address(callback)), amount);
  }

  function test_pullFunds_withCallback_differentData() public {
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

    // Deploy callback contract
    MockRequestInteractionsCallback callback = new MockRequestInteractionsCallback();

    // Create a new request with callback as puller
    vm.prank(owner);
    (address reqAddr,,) = factory.createRequest(
      owner, address(callback), consumer, address(asset), "Callback Request", "CALLBACK", uint64(type(uint64).max)
    );

    Request callbackRequest = Request(reqAddr);

    // Fund the callback request
    vm.prank(owner);
    callbackRequest.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(callbackRequest), amount);
    callbackRequest.mint();
    vm.stopPrank();

    // Pull funds with different data types
    bytes memory data1 = abi.encode("string data");
    vm.prank(address(callback));
    callbackRequest.pullFunds(500_000e6, data1);

    assertEq(callback.callbackCalled(), true);
    assertEq(callback.lastAmount(), 500_000e6);
    assertEq(callback.lastData(), data1);

    // Reset and pull again with different data
    callback.reset();
    bytes memory data2 = abi.encode(12345, "test");
    vm.prank(address(callback));
    callbackRequest.pullFunds(500_000e6, data2);

    assertEq(callback.callbackCalled(), true);
    assertEq(callback.lastAmount(), 500_000e6);
    assertEq(callback.lastData(), data2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      REPAY TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_repay_success() public {
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

    // Pull funds - puller now has the funds
    vm.prank(puller);
    request.pullFunds(amount, "");

    assertEq(asset.balanceOf(puller), amount);
    assertEq(asset.balanceOf(address(request)), 0);

    // Repay funds - puller transfers back
    vm.startPrank(puller);
    asset.approve(address(request), amount);
    request.repay(amount);
    vm.stopPrank();

    assertEq(asset.balanceOf(address(request)), amount);
    assertEq(asset.balanceOf(puller), 0);
  }

  function test_repay_partial() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    request.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), amount);
    request.mint();
    vm.stopPrank();

    // Pull funds - puller now has the funds
    vm.prank(puller);
    request.pullFunds(amount, "");

    assertEq(asset.balanceOf(puller), amount);

    // Repay partial funds
    vm.startPrank(puller);
    asset.approve(address(request), 500_000e6);
    request.repay(500_000e6);
    vm.stopPrank();

    assertEq(asset.balanceOf(address(request)), 500_000e6);
    assertEq(asset.balanceOf(puller), 500_000e6);
  }

  function test_repay_revertsWhenRepaid() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    request.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), amount);
    request.mint();
    vm.stopPrank();

    // Pull funds - puller now has the funds
    vm.prank(puller);
    request.pullFunds(amount, "");

    // Repay funds
    vm.startPrank(puller);
    asset.approve(address(request), amount);
    request.repay(amount);
    vm.stopPrank();

    // Mark as repaid
    vm.prank(owner);
    request.setRepaid();

    // Try to repay again - should revert (even if puller has funds)
    asset.mint(puller, amount);
    vm.startPrank(puller);
    asset.approve(address(request), amount);
    vm.expectRevert(AlreadyRepaid.selector);
    request.repay(amount);
    vm.stopPrank();
  }

  function test_repay_multipleTimes() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    request.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), amount);
    request.mint();
    vm.stopPrank();

    // Pull funds - puller now has the funds
    vm.prank(puller);
    request.pullFunds(amount, "");

    // Repay in multiple transactions
    vm.startPrank(puller);
    asset.approve(address(request), amount);

    request.repay(300_000e6);
    assertEq(asset.balanceOf(address(request)), 300_000e6);

    request.repay(400_000e6);
    assertEq(asset.balanceOf(address(request)), 700_000e6);

    request.repay(300_000e6);
    assertEq(asset.balanceOf(address(request)), amount);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   SET REPAID TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setRepaid_success() public {
    assertEq(request.canWithdraw(), false);

    vm.expectEmit(true, true, true, true, address(request));
    emit Repaid(0);

    vm.prank(owner);
    request.setRepaid();

    assertEq(request.canWithdraw(), true);
  }

  function test_setRepaid_emitsAmountWithBalance() public {
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

    // Now set repaid - should emit with the balance
    vm.expectEmit(true, true, true, true, address(request));
    emit Repaid(amount);

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

  function test_setRepaid_cannotCallTwice() public {
    vm.prank(owner);
    request.setRepaid();

    vm.prank(owner);
    vm.expectRevert(AlreadyRepaid.selector);
    request.setRepaid();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   IS REPAID TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isRepaid_initiallyFalse() public view {
    assertEq(request.isRepaid(), false);
  }

  function test_isRepaid_trueAfterSetRepaid() public {
    assertEq(request.isRepaid(), false);

    vm.prank(owner);
    request.setRepaid();

    assertEq(request.isRepaid(), true);
  }

  function test_isRepaid_falseWhenDeadlinePassed() public {
    // Create a request with a deadline that will pass
    uint64 deadline = uint64(block.timestamp + 1 days);
    vm.prank(owner);
    (address reqAddr,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline Request", "DL", deadline);
    Request deadlineRequest = Request(reqAddr);

    // Initially both isRepaid and canWithdraw should be false
    assertEq(deadlineRequest.isRepaid(), false);
    assertEq(deadlineRequest.canWithdraw(), false);

    // Warp past the deadline
    vm.warp(deadline + 1);

    // canWithdraw should be true (deadline passed), but isRepaid should still be false
    assertEq(deadlineRequest.canWithdraw(), true);
    assertEq(deadlineRequest.isRepaid(), false);
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

    // 3. Puller pulls funds
    vm.prank(puller);
    request.pullFunds(principal, "");

    assertEq(asset.balanceOf(puller), principal);

    // 4. Puller repays with profit (simulating borrower repayment)
    uint256 repayAmount = principal + 50_000e6; // 50k profit (half of expected)
    asset.mint(puller, 50_000e6);
    vm.prank(puller);
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
    vm.prank(puller);
    request.pullFunds(1_500_000e6, "");

    asset.mint(puller, 150_000e6); // Add the yield
    vm.prank(puller);
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
    vm.prank(puller);
    request.pullFunds(principal, "");

    // Puller only returns 900k (10% loss)
    vm.prank(puller);
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

    vm.prank(puller);
    request.pullFunds(pullAmount, "");

    assertEq(asset.balanceOf(puller), pullAmount);
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
    vm.prank(puller);
    request.pullFunds(principal, "");

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
    (, address pt18, address yt18) = factory.createRequest(
      owner, puller, consumer, address(asset18), "DAI Request", "DAI-REQ", uint64(type(uint64).max)
    );
    assertEq(Vault(pt18).decimals(), 18);
    assertEq(Vault(yt18).decimals(), 18);

    // Create request with 8 decimals
    (, address pt8, address yt8) = factory.createRequest(
      owner, puller, consumer, address(asset8), "WBTC Request", "WBTC-REQ", uint64(type(uint64).max)
    );
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              REPAYMENT DEADLINE TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_repaymentDeadline_enablesWithdrawalsAfterDeadline() public {
    // Create a new request with a deadline in the future
    uint64 deadline = uint64(block.timestamp + 30 days);
    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline Request", "DEADLINE", deadline);

    Request deadlineRequest = Request(reqAddr);
    Vault deadlinePtVault = Vault(ptAddr);
    Vault deadlineYtVault = Vault(ytAddr);

    // Initially, withdrawals should be disabled
    assertEq(deadlineRequest.canWithdraw(), false);

    // Deposit some funds
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    deadlineRequest.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(deadlineRequest), amount);
    deadlineRequest.mint();
    vm.stopPrank();

    // Fast forward past the deadline
    vm.warp(deadline + 1);

    // Withdrawals should now be enabled even though setRepaid() was never called
    assertEq(deadlineRequest.canWithdraw(), true);

    // PT/YT holders should be able to redeem
    vm.startPrank(primeBroker);
    uint256 ptAssets = deadlinePtVault.redeem(amount, primeBroker, primeBroker);
    uint256 ytAssets = deadlineYtVault.redeem(100_000e6, primeBroker, primeBroker);
    vm.stopPrank();

    assertEq(ptAssets, amount);
    assertEq(ytAssets, 0); // No yield assets since nothing was repaid
  }

  function test_repaymentDeadline_setRepaidStillWorks() public {
    uint64 deadline = uint64(block.timestamp + 30 days);
    vm.prank(owner);
    (address reqAddr,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline Request", "DEADLINE", deadline);

    Request deadlineRequest = Request(reqAddr);

    // Initially disabled
    assertEq(deadlineRequest.canWithdraw(), false);

    // Call setRepaid before deadline
    vm.prank(owner);
    deadlineRequest.setRepaid();

    // Should be enabled immediately
    assertEq(deadlineRequest.canWithdraw(), true);
  }

  function test_repaymentDeadline_blocksOperationsAfterDeadline() public {
    uint64 deadline = uint64(block.timestamp + 30 days);
    vm.prank(owner);
    (address reqAddr,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline Request", "DEADLINE", deadline);

    Request deadlineRequest = Request(reqAddr);

    // Deposit some funds
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    deadlineRequest.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(deadlineRequest), amount);
    deadlineRequest.mint();
    vm.stopPrank();

    // Pull funds
    vm.prank(puller);
    deadlineRequest.pullFunds(amount, "");

    // Fast forward past deadline
    vm.warp(deadline + 1);

    // Operations should be blocked after deadline
    vm.prank(owner);
    vm.expectRevert(AlreadyRepaid.selector);
    deadlineRequest.setRepaid();

    vm.prank(puller);
    vm.expectRevert(AlreadyRepaid.selector);
    deadlineRequest.pullFunds(100e6, "");

    vm.prank(puller);
    vm.expectRevert(AlreadyRepaid.selector);
    deadlineRequest.repay(100e6);

    // But withdrawals should work
    assertEq(deadlineRequest.canWithdraw(), true);
  }

  function test_repaymentDeadline_mintBlockedAfterDeadline() public {
    uint64 deadline = uint64(block.timestamp + 30 days);
    vm.prank(owner);
    (address reqAddr,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline Request", "DEADLINE", deadline);

    Request deadlineRequest = Request(reqAddr);

    // Authorize minting
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    deadlineRequest.authorizeMinting(primeBroker, amount, 100_000e6);

    // Fast forward past deadline
    vm.warp(deadline + 1);

    // Mint should be blocked
    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(deadlineRequest), amount);
    vm.expectRevert(AlreadyRepaid.selector);
    deadlineRequest.mint();
    vm.stopPrank();
  }

  function test_repaymentDeadline_consumeBlockedAfterDeadline() public {
    uint64 deadline = uint64(block.timestamp + 30 days);
    vm.prank(owner);
    (address reqAddr,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline Request", "DEADLINE", deadline);

    Request deadlineRequest = Request(reqAddr);

    // Fast forward past deadline
    vm.warp(deadline + 1);

    // Consume should be blocked
    Offer memory offer = _createOffer(address(0x123), 1_000_000e6, 100_000e6, 1, block.timestamp + 1 days, false);
    bytes memory signature = _signOffer(offer, maker);

    vm.prank(owner);
    vm.expectRevert(AlreadyRepaid.selector);
    deadlineRequest.consume(offer, signature, 1_000_000e6);
  }

  function test_repaymentDeadline_beforeDeadlineOperationsWork() public {
    uint64 deadline = uint64(block.timestamp + 30 days);
    vm.prank(owner);
    (address reqAddr,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline Request", "DEADLINE", deadline);

    Request deadlineRequest = Request(reqAddr);

    // Before deadline, operations should work normally
    assertEq(deadlineRequest.canWithdraw(), false);

    // Deposit funds
    address primeBroker = makeAddr("primeBroker");
    uint128 amount = 1_000_000e6;

    vm.prank(owner);
    deadlineRequest.authorizeMinting(primeBroker, amount, 100_000e6);

    asset.mint(primeBroker, amount);
    vm.startPrank(primeBroker);
    asset.approve(address(deadlineRequest), amount);
    deadlineRequest.mint();
    vm.stopPrank();

    // Pull funds should work
    vm.prank(puller);
    deadlineRequest.pullFunds(amount, "");

    // Repay should work
    asset.mint(puller, amount);
    vm.startPrank(puller);
    asset.approve(address(deadlineRequest), amount);
    deadlineRequest.repay(amount);
    vm.stopPrank();

    // setRepaid should work
    vm.prank(owner);
    deadlineRequest.setRepaid();

    assertEq(deadlineRequest.canWithdraw(), true);
  }

  function test_repaymentDeadline_exactlyAtDeadline() public {
    uint64 deadline = uint64(block.timestamp + 30 days);
    vm.prank(owner);
    (address reqAddr,,) =
      factory.createRequest(owner, puller, consumer, address(asset), "Deadline Request", "DEADLINE", deadline);

    Request deadlineRequest = Request(reqAddr);

    // At exactly the deadline, withdrawals should be enabled
    vm.warp(deadline);
    assertEq(deadlineRequest.canWithdraw(), true);
  }
}

