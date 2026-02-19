// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/facility/Facility.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {SwapParams} from "src/interfaces/facility/base/IFacilitySwap.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {IMorpho, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {MockRequest} from "test/mock/facility/MockRequest.sol";

/// @title FacilityHandler
/// @notice Handler contract for Facility invariant tests.
/// @dev Provides fuzzed action functions that exercise the Facility lifecycle:
///      creating intents, depositing, withdrawing, locking, resolving, claiming,
///      swapping, and transferring intent tokens. Ghost state is maintained for
///      invariant verification by the invariant test contract.
contract FacilityHandler is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONTRACTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  Facility public facility;
  PositionManager public positionManager;
  WrappedAsset public collateralToken;
  MockERC20 public underlyingToken;
  MockERC20 public debtToken;

  // Dependency-graph refs (set via initializeDependencies)
  OracleMock public oracle;
  IMorpho public morpho;
  MarketParams public facilityMarketParams;
  bool public dependenciesInitialized;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ADDRESSES                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public facilitator;
  address public minter;
  address public guardian;
  uint256 public guardianPk;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       GHOST STATE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice All created intent IDs.
  uint256[] public intentIds;

  /// @notice Depositors per intent (may contain duplicates, but that is acceptable for iteration).
  mapping(uint256 => address[]) public intentDepositors;

  /// @notice Tracked intent states: 0 = DEPOSITING, 1 = RESOLVING, 2 = RESOLVED.
  mapping(uint256 => uint8) public intentStates;

  /// @notice Total deposits per user per intent (ghost tracking for claim verification).
  mapping(uint256 => mapping(address => uint256)) public userDeposits;

  /// @notice Tracks whether an intent uses debtToken (true) or PM shares (false) as deposit asset.
  mapping(uint256 => bool) public intentIsDebtToken;

  /// @notice Fixed users array used by the fuzzer.
  address[] public users;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  PER-ACTION INVARIANT GHOSTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice FAC-3: Set to true if deposit mints != amount LP tokens.
  bool public depositNotOneToOne;

  /// @notice FAC-3: Set to true if withdraw burns != amount LP tokens.
  bool public withdrawNotOneToOne;

  /// @notice FAC-6: Set to true if claim does not distribute tokens proportionally.
  bool public claimProportionalityViolated;

  /// @notice FAC-7: Set to true if a swap is not zero-sum between intents.
  bool public swapNotZeroSum;

  /// @notice FAC-8: Set to true if a swap digest replay succeeds.
  bool public swapReplaySucceeded;

  /// @notice FAC-4: Set to true if a deposit results in totalSupply exceeding depositCap.
  bool public depositExceededCap;

  /// @notice FAC-10: Tracks whether the facility is currently paused by this handler.
  bool public facilityCurrentlyPaused;

  /// @notice FAC-11: Set to true if repay succeeds before the repay timelock expires.
  bool public timelockBypassed;

  /// @notice Mock request used for setRequest actions.
  MockRequest public mockRequest;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev EIP-712 typehash for SwapParams struct.
  bytes32 internal constant SWAP_PARAMS_TYPEHASH = 0x8b4e182587850acdf21dcf7a0f61b2fd7267c2cdf71d4692b57fb97237a29be3;

  /// @dev EIP-712 typehash for setRequest params.
  ///      Type string: "SetRequestParams(uint256 id,address newRequest,uint256 deadline)"
  bytes32 internal constant SET_REQUEST_PARAMS_TYPEHASH =
    0x3fab97cdfeba7b67ca42aeebb63ab14ea67e6637d1e42acb3a06b721f7d72438;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INIT FLAG                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  bool public initialized;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CONSTRUCTOR                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  constructor() {
    // Create 3 fixed users for the fuzzer to pick from.
    users.push(makeAddr("inv_user0"));
    users.push(makeAddr("inv_user1"));
    users.push(makeAddr("inv_user2"));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZE                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the handler with all required contract references.
  /// @dev Must be called exactly once after deployment.
  function initialize(
    Facility facility_,
    PositionManager positionManager_,
    WrappedAsset collateralToken_,
    MockERC20 underlyingToken_,
    MockERC20 debtToken_,
    address owner_,
    address facilitator_,
    address minter_,
    uint256 guardianPk_
  ) external {
    require(!initialized, "FacilityHandler: already initialized");
    initialized = true;

    facility = facility_;
    positionManager = positionManager_;
    collateralToken = collateralToken_;
    underlyingToken = underlyingToken_;
    debtToken = debtToken_;
    owner = owner_;
    facilitator = facilitator_;
    minter = minter_;
    guardianPk = guardianPk_;
    guardian = vm.addr(guardianPk_);

    // Deploy mock request for setRequest actions
    mockRequest = new MockRequest(address(debtToken_));
  }

  /// @notice Builds the EIP-712 domain separator used by the Facility.
  function _domainSeparator() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("3Facility"),
        keccak256("1.0.0"),
        block.chainid,
        address(facility)
      )
    );
  }

  /// @notice Computes the digest for setRequest approval.
  function _getSetRequestDigest(uint256 id, address newRequest, uint256 deadline) internal view returns (bytes32) {
    return keccak256(
      abi.encodePacked(
        "\x19\x01", _domainSeparator(), keccak256(abi.encode(SET_REQUEST_PARAMS_TYPEHASH, id, newRequest, deadline))
      )
    );
  }

  /// @notice Signs setRequest data with the provided key.
  function _signSetRequest(uint256 id, address newRequest, uint256 deadline, uint256 privateKey)
    internal
    view
    returns (bytes memory)
  {
    bytes32 digest = _getSetRequestDigest(id, newRequest, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @notice Sets request through facilitator + guardian signature path.
  function _setRequest(uint256 id, address newRequest) external {
    uint256 deadline = block.timestamp + 1 hours;
    address[] memory signers = new address[](1);
    bytes[] memory signatures = new bytes[](1);
    signers[0] = guardian;
    signatures[0] = _signSetRequest(id, newRequest, deadline, guardianPk);

    vm.prank(facilitator);
    facility.setRequest(id, newRequest, deadline, signers, signatures);
  }

  /// @notice Initializes dependency-graph references (oracle, morpho, marketParams).
  /// @dev Must be called after initialize(). Separated to avoid stack-too-deep.
  function initializeDependencies(OracleMock oracle_, IMorpho morpho_, MarketParams memory marketParams_) external {
    require(initialized, "FacilityHandler: not initialized");
    require(!dependenciesInitialized, "FacilityHandler: dependencies already initialized");
    dependenciesInitialized = true;

    oracle = oracle_;
    morpho = morpho_;
    facilityMarketParams = marketParams_;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        VIEW HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns all created intent IDs.
  function getIntentIds() external view returns (uint256[] memory) {
    return intentIds;
  }

  /// @notice Returns all tracked users.
  function getUsers() external view returns (address[] memory) {
    return users;
  }

  /// @notice Returns the depositors for a given intent.
  function getIntentDepositors(uint256 id) external view returns (address[] memory) {
    return intentDepositors[id];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      HANDLER ACTIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new intent, randomly choosing PM shares or debtToken as deposit asset.
  /// @dev Bounds depositCap to [1e18, 1_000_000e18] and resolveDelay to [1 hour, 30 days].
  ///      The typeSeed determines whether the intent uses PM shares (odd) or debtToken (even).
  /// @param depositCapSeed Seed for fuzzing the deposit cap.
  /// @param resolveDelaySeed Seed for fuzzing the resolve delay.
  /// @param typeSeed Seed for choosing deposit asset type (even = debtToken, odd = PM shares).
  function act_createIntent(uint256 depositCapSeed, uint256 resolveDelaySeed, uint256 typeSeed) external {
    uint256 depositCap = bound(depositCapSeed, 1e18, 1_000_000e18);
    uint256 resolveDelay = bound(resolveDelaySeed, 1 hours, 30 days);

    bool isDebt = typeSeed % 2 == 0;

    Asset memory depositAsset;
    Asset memory targetAsset;
    if (isDebt) {
      depositAsset = Asset({asset: address(debtToken), isPositionManager: false});
      targetAsset = Asset({asset: address(positionManager), isPositionManager: true});
    } else {
      depositAsset = Asset({asset: address(positionManager), isPositionManager: true});
      targetAsset = Asset({asset: address(debtToken), isPositionManager: false});
    }

    IntentProperties memory props = IntentProperties({
      depositAsset: depositAsset,
      targetAsset: targetAsset,
      depositCap: depositCap,
      guardKey: address(positionManager),
      resolveStart: uint40(block.timestamp + resolveDelay),
      quorum: 1,
      transferableIntent: true
    });

    vm.prank(owner);
    uint256 id = facility.createIntent(props);

    intentIds.push(id);
    intentStates[id] = 0; // DEPOSITING
    intentIsDebtToken[id] = isDebt;
  }

  /// @notice Deposits into a DEPOSITING intent on behalf of a fuzzed user.
  /// @dev Handles both PM-share and debtToken intents. Verifies 1:1 LP minting (FAC-3).
  ///      Early-returns if no depositing intents or deposit cap already reached.
  /// @param intentSeed Seed for selecting an intent.
  /// @param amountSeed Seed for fuzzing the deposit amount.
  /// @param userSeed Seed for selecting a user.
  function act_deposit(uint256 intentSeed, uint256 amountSeed, uint256 userSeed) external {
    uint256[] memory depositingIds = _getIntentsByState(0);
    if (depositingIds.length == 0) return;

    uint256 id = depositingIds[intentSeed % depositingIds.length];

    (IntentProperties memory props,,,,) = facility.getIntent(id);
    uint256 currentSupply = facility.totalSupply(id);
    if (currentSupply >= props.depositCap) return;

    uint256 remaining = props.depositCap - currentSupply;
    uint256 maxDeposit = remaining < 1_000_000e18 ? remaining : 1_000_000e18;
    if (maxDeposit < 1e18) return;

    uint256 amount = bound(amountSeed, 1e18, maxDeposit);
    address depositor = users[userSeed % users.length];

    if (intentIsDebtToken[id]) {
      // Mint debtToken directly to depositor
      debtToken.setBalance(depositor, debtToken.balanceOf(depositor) + amount);
      vm.prank(depositor);
      debtToken.approve(address(facility), type(uint256).max);
    } else {
      // Mint PM shares to user via minter
      _mintPmSharesToUser(depositor, amount);
      vm.prank(depositor);
      positionManager.approve(address(facility), type(uint256).max);
    }

    // FAC-3: Capture balance before deposit
    uint256 balBefore = facility.balanceOf(depositor, id);

    vm.prank(depositor);
    try facility.deposit(id, amount) {
      // FAC-3: Verify 1:1 minting
      uint256 balAfter = facility.balanceOf(depositor, id);
      if (balAfter - balBefore != amount) {
        depositNotOneToOne = true;
      }

      // FAC-4: Verify deposit did not push supply above cap
      (IntentProperties memory propsAfter,,,,) = facility.getIntent(id);
      if (facility.totalSupply(id) > propsAfter.depositCap) {
        depositExceededCap = true;
      }

      userDeposits[id][depositor] += amount;
      intentDepositors[id].push(depositor);
    } catch {
      return;
    }
  }

  /// @notice Withdraws from a DEPOSITING intent on behalf of a user who has balance.
  /// @dev Verifies 1:1 LP burning (FAC-3).
  ///      Early-returns if no depositing intents or no user has balance on selected intent.
  /// @param intentSeed Seed for selecting an intent.
  /// @param amountSeed Seed for fuzzing the withdrawal amount.
  /// @param userSeed Seed for selecting a user.
  function act_withdraw(uint256 intentSeed, uint256 amountSeed, uint256 userSeed) external {
    uint256[] memory depositingIds = _getIntentsByState(0);
    if (depositingIds.length == 0) return;

    uint256 id = depositingIds[intentSeed % depositingIds.length];

    (address from, uint256 balance) = _findUserWithBalance(id, userSeed);
    if (balance == 0) return;

    uint256 amount = bound(amountSeed, 1, balance);

    // FAC-3: Capture balance before withdraw
    uint256 balBefore = facility.balanceOf(from, id);

    vm.prank(from);
    try facility.withdraw(id, from, from, amount) {
      // FAC-3: Verify 1:1 burning
      uint256 balAfter = facility.balanceOf(from, id);
      if (balBefore - balAfter != amount) {
        withdrawNotOneToOne = true;
      }

      userDeposits[id][from] -= amount;
    } catch {
      return;
    }
  }

  /// @notice Locks a DEPOSITING intent, transitioning it to RESOLVING.
  /// @dev Sets resolveStart to current timestamp via the facilitator role.
  ///      Early-returns if no depositing intents exist.
  /// @param intentSeed Seed for selecting an intent.
  function act_lock(uint256 intentSeed) external {
    uint256[] memory depositingIds = _getIntentsByState(0);
    if (depositingIds.length == 0) return;

    uint256 id = depositingIds[intentSeed % depositingIds.length];

    vm.prank(facilitator);
    try facility.lock(id) {
      intentStates[id] = 1; // RESOLVING
    } catch {
      return;
    }
  }

  /// @notice Warps time past a DEPOSITING intent's resolveStart, moving it to RESOLVING.
  /// @dev Uses vm.warp to advance block.timestamp. Updates ghost state.
  ///      Early-returns if no depositing intents exist.
  /// @param intentSeed Seed for selecting an intent.
  function act_warpToResolving(uint256 intentSeed) external {
    uint256[] memory depositingIds = _getIntentsByState(0);
    if (depositingIds.length == 0) return;

    uint256 id = depositingIds[intentSeed % depositingIds.length];

    (IntentProperties memory props,,,,) = facility.getIntent(id);

    // Warp to just past resolveStart
    if (block.timestamp < props.resolveStart) {
      vm.warp(props.resolveStart + 1);
    }

    intentStates[id] = 1; // RESOLVING
  }

  /// @notice Resolves a RESOLVING intent, transitioning it to RESOLVED.
  /// @dev Calls facility.resolve via the facilitator. Early-returns if no resolving intents
  ///      or if the intent has an active order or unrepaid request.
  /// @param intentSeed Seed for selecting an intent.
  function act_resolve(uint256 intentSeed) external {
    uint256[] memory resolvingIds = _getIntentsByState(1);
    if (resolvingIds.length == 0) return;

    uint256 id = resolvingIds[intentSeed % resolvingIds.length];

    vm.prank(facilitator);
    try facility.resolve(id) {
      intentStates[id] = 2; // RESOLVED
    } catch {
      // May fail if intent has active order or unrepaid request; skip.
      return;
    }
  }

  /// @notice Claims tokens from a RESOLVED intent on behalf of a user.
  /// @dev Burns the user's intent shares and transfers proportional tokens (FAC-6).
  ///      Verifies that the claim distribution matches the proportional formula.
  ///      Early-returns if no resolved intents or no user has balance.
  /// @param intentSeed Seed for selecting an intent.
  /// @param sharesSeed Seed for fuzzing the number of shares to claim.
  /// @param userSeed Seed for selecting a user.
  function act_claim(uint256 intentSeed, uint256 sharesSeed, uint256 userSeed) external {
    uint256[] memory resolvedIds = _getIntentsByState(2);
    if (resolvedIds.length == 0) return;

    uint256 id = resolvedIds[intentSeed % resolvedIds.length];

    (address from, uint256 balance) = _findUserWithBalance(id, userSeed);
    if (balance == 0) return;

    uint256 shares = bound(sharesSeed, 1, balance);

    // FAC-6: Capture intent state before claim for proportionality check.
    // totalSupplyBefore is the supply including the shares that will be burned.
    uint256 totalSupplyBefore = facility.totalSupply(id);
    (address[] memory tokensBefore, uint256[] memory amountsBefore) = facility.intentBalances(id);

    vm.prank(from);
    try facility.claim(id, from, from, shares) returns (address[] memory claimTokens, uint256[] memory claimAmounts) {
      // FAC-6: Verify proportional distribution.
      // Claim formula: userBalance = tokenBalance * shares / totalSupplyBefore (floor division).
      for (uint256 i = 0; i < tokensBefore.length; i++) {
        uint256 expected = FixedPointMathLib.mulDiv(amountsBefore[i], shares, totalSupplyBefore);
        // Find the matching token in claim results
        for (uint256 j = 0; j < claimTokens.length; j++) {
          if (tokensBefore[i] == claimTokens[j]) {
            if (claimAmounts[j] != expected) {
              claimProportionalityViolated = true;
            }
          }
        }
      }

      if (userDeposits[id][from] >= shares) {
        userDeposits[id][from] -= shares;
      } else {
        userDeposits[id][from] = 0;
      }
    } catch {
      return;
    }
  }

  /// @notice Swaps tokens between two RESOLVING intents with different deposit assets.
  /// @dev Finds one PM-share intent and one debtToken intent, both in RESOLVING state,
  ///      computes the EIP-712 digest, signs with the guardian key, and executes the swap.
  ///      Verifies zero-sum (FAC-7) and replay prevention (FAC-8).
  /// @param intentSeed1 Seed for selecting intents.
  /// @param amountSeed Seed for fuzzing swap amounts.
  function act_swap(uint256 intentSeed1, uint256 amountSeed) external {
    // Find two resolving intents with different deposit assets
    (uint256 pmId, uint256 debtId, bool found) = _findSwapPair(intentSeed1);
    if (!found) return;

    // Build swap params and sign
    SwapParams memory params = _buildSwapParams(pmId, debtId, amountSeed);
    if (params.amount1 == 0 || params.amount2 == 0) return;

    (address[] memory signers, bytes[] memory signatures) = _signSwap(params);

    // FAC-7: Capture total token amounts across both intents before swap
    uint256[2] memory totalsBefore = _captureSwapTotals(pmId, debtId);

    vm.prank(facilitator);
    try facility.swap(params, signers, signatures) {
      // FAC-7: Verify zero-sum
      _verifySwapZeroSum(pmId, debtId, totalsBefore);

      // FAC-8: Verify replay prevention
      _verifySwapReplay(params);
    } catch {
      return;
    }
  }

  /// @notice Transfers intent tokens between users.
  /// @dev Picks a user with balance and transfers to another user.
  ///      Early-returns if no intents or no user has balance.
  /// @param intentSeed Seed for selecting an intent.
  /// @param amountSeed Seed for fuzzing the transfer amount.
  /// @param fromSeed Seed for selecting the sender.
  /// @param toSeed Seed for selecting the receiver.
  function act_transfer(uint256 intentSeed, uint256 amountSeed, uint256 fromSeed, uint256 toSeed) external {
    if (intentIds.length == 0) return;

    uint256 id = intentIds[intentSeed % intentIds.length];

    // Find a sender with balance
    (address from, uint256 balance) = _findUserWithBalance(id, fromSeed);
    if (balance == 0) return;

    // Pick a receiver (different from sender to avoid self-transfer edge cases)
    address to = users[toSeed % users.length];
    if (to == from) {
      to = users[(toSeed + 1) % users.length];
    }
    // Ensure we don't transfer to address(0)
    if (to == address(0)) return;

    uint256 amount = bound(amountSeed, 1, balance);

    vm.prank(from);
    try facility.transfer(to, id, amount) {
      // Update ghost state for transfers
      if (userDeposits[id][from] >= amount) {
        userDeposits[id][from] -= amount;
      } else {
        userDeposits[id][from] = 0;
      }
      userDeposits[id][to] += amount;
    } catch {
      return;
    }
  }

  /*                 REQUEST TIMELOCK ACTIONS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets a request on a RESOLVING intent.
  /// @dev Exercises the setRequest → requestSetAt tracking for FAC-11.
  /// @param intentSeed Seed for selecting an intent.
  function act_setRequest(uint256 intentSeed) external {
    uint256[] memory resolvingIds = _getIntentsByState(1);
    if (resolvingIds.length == 0) return;

    uint256 id = resolvingIds[intentSeed % resolvingIds.length];

    // Mark any existing request as repaid so replacement is allowed
    mockRequest.setRepaid(true);

    try this._setRequest(id, address(mockRequest)) {}
    catch {
      return;
    }
  }

  /// @notice Attempts to repay immediately after setRequest to verify timelock enforcement (FAC-11).
  /// @dev Sets a request and tries to repay in the same block. If the repay succeeds,
  ///      timelockBypassed is set to true (indicating invariant violation).
  /// @param intentSeed Seed for selecting an intent.
  function act_attemptRepayBeforeTimelock(uint256 intentSeed) external {
    uint256[] memory resolvingIds = _getIntentsByState(1);
    if (resolvingIds.length == 0) return;

    // Skip when timelock is zero — repay succeeding immediately is expected behaviour
    if (facility.repayTimelock() == 0) return;

    uint256 id = resolvingIds[intentSeed % resolvingIds.length];

    // Mark existing request as repaid for replacement
    mockRequest.setRepaid(true);

    // Set a fresh request
    try this._setRequest(id, address(mockRequest)) {}
    catch {
      return;
    }

    // Try to repay immediately — should fail due to timelock
    vm.prank(facilitator);
    try facility.repay(id, 1e18) {
      // If this succeeds, the timelock was bypassed
      timelockBypassed = true;
    } catch {
      // Expected: timelock prevents immediate repay
    }
  }

  /// @notice Fuzz-sets the repay timelock via the owner.
  /// @dev Exercises setRepayTimelock to vary the timelock duration during invariant runs.
  /// @param timelockSeed Seed for fuzzing the timelock duration.
  function act_setTimelock(uint256 timelockSeed) external {
    uint40 newTimelock = uint40(bound(timelockSeed, 0, 7 days));
    vm.prank(owner);
    try facility.setRepayTimelock(newTimelock) {}
    catch {
      return;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FACILITATOR ACTIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Updates the deposit cap of a DEPOSITING intent.
  /// @dev Allows setting cap below current totalSupply (which is valid on-chain).
  ///      This exercises the scenario where totalSupply > depositCap after a cap reduction.
  /// @param intentSeed Seed for selecting an intent.
  /// @param capSeed Seed for fuzzing the new deposit cap.
  function act_updateDepositCap(uint256 intentSeed, uint256 capSeed) external {
    uint256[] memory depositingIds = _getIntentsByState(0);
    if (depositingIds.length == 0) return;

    uint256 id = depositingIds[intentSeed % depositingIds.length];
    uint256 newCap = bound(capSeed, 0, 10_000_000e18);

    vm.prank(facilitator);
    try facility.setDepositCap(id, newCap) {}
    catch {
      return;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 DEPENDENCY-GRAPH ACTIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Pauses the Facility (permanent or timed).
  /// @dev 50/50 chance of permanent vs timed pause. Uses owner (who has PAUSER_ROLE equiv).
  /// @param durationSeed Seed for choosing pause type and duration.
  function act_pauseFacility(uint256 durationSeed) external {
    bool permanent = durationSeed % 2 == 0;
    if (permanent) {
      vm.prank(owner);
      try facility.pause() {
        facilityCurrentlyPaused = true;
      } catch {}
    } else {
      uint256 duration = _bound(durationSeed, 1, 30 days);
      vm.prank(owner);
      try facility.pauseFor(duration) {
        facilityCurrentlyPaused = true;
      } catch {}
    }
  }

  /// @notice Unpauses the Facility to allow operations to resume.
  function act_unpauseFacility() external {
    vm.prank(owner);
    try facility.unpause() {
      facilityCurrentlyPaused = false;
    } catch {}
  }

  /// @notice Changes the oracle price, affecting PM share price and intent token values.
  /// @dev Bounds price to [0.1e36, 10e36]. Stresses FAC-5 solvency under price volatility.
  /// @param priceSeed Raw fuzz input for the new price.
  function act_changeOraclePrice(uint256 priceSeed) external {
    if (!dependenciesInitialized) return;
    uint256 newPrice = _bound(priceSeed, 0.1e36, 10e36);
    oracle.setPrice(newPrice);
  }

  /// @notice Accrues interest on the underlying Morpho market, increasing PM debt.
  /// @dev Lowers PM share value over time, stressing solvency invariants.
  function act_accrueInterest() external {
    if (!dependenciesInitialized) return;
    morpho.accrueInterest(facilityMarketParams);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTERNAL HELPERS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Finds a PM-share intent and a debtToken intent, both in RESOLVING state.
  function _findSwapPair(uint256 seed) internal view returns (uint256 pmId, uint256 debtId, bool found) {
    uint256[] memory resolvingIds = _getIntentsByState(1);
    if (resolvingIds.length < 2) return (0, 0, false);

    bool foundPm;
    bool foundDebt;
    for (uint256 i = 0; i < resolvingIds.length; i++) {
      uint256 idx = (seed + i) % resolvingIds.length;
      if (!intentIsDebtToken[resolvingIds[idx]] && !foundPm) {
        pmId = resolvingIds[idx];
        foundPm = true;
      }
      if (intentIsDebtToken[resolvingIds[idx]] && !foundDebt) {
        debtId = resolvingIds[idx];
        foundDebt = true;
      }
      if (foundPm && foundDebt) return (pmId, debtId, true);
    }
    return (0, 0, false);
  }

  /// @dev Builds SwapParams from the two intent IDs and bounded amounts.
  function _buildSwapParams(uint256 pmId, uint256 debtId, uint256 amountSeed)
    internal
    view
    returns (SwapParams memory)
  {
    uint256 pmSharesAvailable = _getIntentTokenAmount(pmId, address(positionManager));
    uint256 debtTokenAvailable = _getIntentTokenAmount(debtId, address(debtToken));

    if (pmSharesAvailable == 0 || debtTokenAvailable == 0) {
      return SwapParams(0, address(0), 0, address(0), 0, 0, 0);
    }

    return SwapParams({
      id1: pmId,
      token1: address(positionManager),
      id2: debtId,
      token2: address(debtToken),
      amount1: bound(amountSeed, 1, pmSharesAvailable),
      amount2: bound(amountSeed, 1, debtTokenAvailable),
      deadline: block.timestamp + 1 hours
    });
  }

  /// @dev Signs swap params with the guardian key.
  function _signSwap(SwapParams memory params)
    internal
    view
    returns (address[] memory signers, bytes[] memory signatures)
  {
    bytes32 digest = _computeSwapDigest(params);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianPk, digest);

    signers = new address[](1);
    signers[0] = guardian;
    signatures = new bytes[](1);
    signatures[0] = abi.encodePacked(r, s, v);
  }

  /// @dev Captures total PM and debt token amounts across two intents.
  function _captureSwapTotals(uint256 pmId, uint256 debtId) internal view returns (uint256[2] memory totals) {
    totals[0] =
      _getIntentTokenAmount(pmId, address(positionManager)) + _getIntentTokenAmount(debtId, address(positionManager));
    totals[1] = _getIntentTokenAmount(pmId, address(debtToken)) + _getIntentTokenAmount(debtId, address(debtToken));
  }

  /// @dev Verifies zero-sum after swap (FAC-7).
  function _verifySwapZeroSum(uint256 pmId, uint256 debtId, uint256[2] memory totalsBefore) internal {
    uint256[2] memory totalsAfter = _captureSwapTotals(pmId, debtId);
    if (totalsBefore[0] != totalsAfter[0] || totalsBefore[1] != totalsAfter[1]) {
      swapNotZeroSum = true;
    }
  }

  /// @dev Verifies replay prevention (FAC-8).
  function _verifySwapReplay(SwapParams memory params) internal {
    (address[] memory signers, bytes[] memory signatures) = _signSwap(params);
    vm.prank(facilitator);
    try facility.swap(params, signers, signatures) {
      swapReplaySucceeded = true;
    } catch {
      // Expected: replay should fail
    }
  }

  /// @dev Returns intent IDs that are in the given state (0=DEPOSITING, 1=RESOLVING, 2=RESOLVED).
  function _getIntentsByState(uint8 state) internal view returns (uint256[] memory) {
    uint256 count;
    for (uint256 i = 0; i < intentIds.length; i++) {
      if (intentStates[intentIds[i]] == state) {
        count++;
      }
    }

    uint256[] memory result = new uint256[](count);
    uint256 idx;
    for (uint256 i = 0; i < intentIds.length; i++) {
      if (intentStates[intentIds[i]] == state) {
        result[idx++] = intentIds[i];
      }
    }
    return result;
  }

  /// @dev Finds a user with a non-zero facility balance for a given intent.
  ///      Uses the userSeed as a starting offset to cycle through the users array.
  /// @return user_ The address of the user found, or address(0) if none.
  /// @return balance The user's balance for the intent.
  function _findUserWithBalance(uint256 id, uint256 userSeed) internal view returns (address user_, uint256 balance) {
    for (uint256 i = 0; i < users.length; i++) {
      address candidate = users[(userSeed + i) % users.length];
      uint256 bal = facility.balanceOf(candidate, id);
      if (bal > 0) {
        return (candidate, bal);
      }
    }
    return (address(0), 0);
  }

  /// @dev Mints PM shares to a target user via the minter.
  ///      Flow: mint underlying → wrap to WrappedAsset → minter deposits to PM → transfer shares to user.
  function _mintPmSharesToUser(address to, uint256 amount) internal {
    // 1. Mint underlying and wrap to WrappedAsset
    underlyingToken.mint(minter, amount);

    vm.startPrank(minter);
    underlyingToken.approve(address(collateralToken), amount);
    collateralToken.mint(minter, amount);

    // 2. Minter approves PM and deposits collateral to get shares
    collateralToken.approve(address(positionManager), amount);
    int256 sharesSigned = positionManager.deposit(amount, 0);
    uint256 shares = uint256(sharesSigned);

    // 3. Transfer shares to user
    positionManager.transfer(to, shares);
    vm.stopPrank();
  }

  /// @dev Returns the amount of a specific token tracked in an intent's balances.
  function _getIntentTokenAmount(uint256 id, address token) internal view returns (uint256) {
    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(id);
    for (uint256 i = 0; i < tokens.length; i++) {
      if (tokens[i] == token) return amounts[i];
    }
    return 0;
  }

  /// @dev Computes the EIP-712 domain separator for the Facility contract.
  function _computeDomainSeparator() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("3Facility"),
        keccak256("1.0.0"),
        block.chainid,
        address(facility)
      )
    );
  }

  /// @dev Computes the full EIP-712 digest for a SwapParams struct.
  function _computeSwapDigest(SwapParams memory params) internal view returns (bytes32) {
    bytes32 structHash = keccak256(abi.encode(SWAP_PARAMS_TYPEHASH, params));
    return keccak256(abi.encodePacked("\x19\x01", _computeDomainSeparator(), structHash));
  }
}
