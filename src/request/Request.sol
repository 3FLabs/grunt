// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {OfferReceiver} from "./abstract/OfferReceiver.sol";
import {VaultController} from "./abstract/vault/VaultController.sol";
import {TokenController} from "./abstract/tokens/TokenController.sol";
import {LibMintAuth} from "../libs/request/LibMintAuth.sol";
import {LibRequestErrors} from "../libs/request/LibRequestErrors.sol";
import {LibChecks} from "../libs/common/LibChecks.sol";
import {IERC20} from "../interfaces/integrations/IERC20.sol";
import {IRequest} from "../interfaces/request/IRequest.sol";
import {IRequestInteractions} from "../interfaces/request/IRequestInteractions.sol";
import {IHasAsset} from "../interfaces/request/IHasAsset.sol";
import {IRequestCallback} from "../interfaces/request/IRequestCallback.sol";
import {IRequestInteractionsCallback} from "../interfaces/request/IRequestInteractionsCallback.sol";
import {ITokenController} from "../interfaces/request/ITokenController.sol";
import {Offer} from "../interfaces/request/IOfferReceiver.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {EIP712} from "lib/solady/src/utils/EIP712.sol";

/// @title Request
/// @author 3F Protocol
/// @notice Contract for managing funding requests with dual-token (PT/YT) issuance.
/// @dev This contract combines multiple functionalities:
///      - **OfferReceiver**: Validates and processes signed offers using EIP-712 signatures
///      - **VaultController**: Manages PT/YT tokens with ERC4626-style redemptions
///      - **Initializable**: Supports initialization for proxy deployments
///      - **OwnableRoles**: Restricts admin functions to the contract owner and allows for the "puller" role to pull funds from the contract.
///      - **ReentrancyGuard**: Prevents reentrancy attacks during offer consumption
///
///      Deployment Options:
///      - **Immutable**: Deploy directly and call `initialize()` in the constructor or immediately after
///      - **Beacon Proxy**: Deploy as implementation behind an UpgradeableBeacon for upgradeable instances
///      - **Minimal Proxy (Clone)**: Deploy as implementation for gas-efficient clones via ERC-1167
///
///      Lifecycle:
///      1. Contract is deployed and initialized with asset, PT/YT tokens, and metadata
///      2. Owner can authorize minting for specific addresses or consume signed offers
///      3. Authorized addresses can mint PT/YT tokens by depositing the underlying asset
///      4. Once offers are consumed, the Facility (holding `_ROLE_PULLER`) pulls funds via `pullFunds()`
///      5. The borrower repays by transferring the asset back to the contract
///      6. Once fully repaid, the owner calls `setRepaid(uint256)` to enable withdrawals for PT/YT holders
///
///      Offer Consumption Flow:
///      1. A maker creates and signs an offer specifying amount and expected return
///      2. Owner calls `consume()` with the offer, signature, and PT amount to fulfill
///      3. The maker's `onRequestConsumed` callback is invoked to prepare funds
///      4. Assets are transferred from owner and PT/YT tokens are minted to the maker
contract Request is IRequest, OfferReceiver, VaultController, Initializable, OwnableRoles, ReentrancyGuardTransient {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;
  using LibMintAuth for address;
  using LibChecks for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Role for addresses authorized to pull funds from the contract via `pullFunds()`.
  uint256 internal constant _ROLE_PULLER = _ROLE_0;

  /// @dev Role for addresses authorized to consume offers and authorize minting via `consume()` and `authorizeMinting()`.
  uint256 internal constant _ROLE_CONSUMER = _ROLE_1;

  /// @dev Maximum offset from the current timestamp for the repayment deadline (90 days).
  uint256 internal constant _MAX_REPAYMENT_DEADLINE_OFFSET = 90 days;

  constructor() {
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the Request contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param asset The address of the underlying ERC20 asset (e.g., USDC)
  /// @param repaymentDeadline The time at which repayments are unlocked regardless of whether repaid is true or false
  /// @param repaid Whether the request has been repaid, enabling withdrawals
  /// @param ptToken The address of the Principal Token contract
  /// @param ytToken The address of the Yield Token contract
  /// @param lastMintTimestamp Timestamp of the last mint() or consume() call (0 if none). Packed with `ytToken`.
  /// @param mintToRepaidDelay Minimum delay (seconds) between the last mint/consume and setRepaid(uint256). Packed with `ytToken`.
  /// @param name The base name for the PT/YT tokens (prefixed with "PT-" / "YT-")
  /// @param symbol The base symbol for the PT/YT tokens (prefixed with "PT-" / "YT-")
  struct RequestStorage {
    address asset;
    uint64 repaymentDeadline;
    bool repaid;
    address ptToken;
    address ytToken;
    uint40 lastMintTimestamp;
    uint40 mintToRepaidDelay;
    string name;
    string symbol;
  }

  /// @dev Storage slot for the Request contract's main storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("request.main")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _MAIN_STORAGE_SLOT = 0xb094c22784bf6cbc6b58dc638ba7a1e443b696c9c43939e48b3762e49818c300;

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return requestStorage A storage pointer to the RequestStorage struct
  function _requestStorage() internal pure returns (RequestStorage storage requestStorage) {
    assembly ("memory-safe") {
      requestStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the Request contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier. Sets up the contract owner,
  ///      underlying asset, PT/YT token addresses, and metadata. The contract starts in a non-repaid
  ///      state where withdrawals are disabled until either setRepaid(uint256) is called or the repayment deadline passes.
  /// @param owner_ The address that will own the contract and have admin privileges
  /// @param puller_ The address that will have the puller role
  /// @param consumer_ The address that will have the consumer role (can call consume and authorizeMinting)
  /// @param asset_ The address of the underlying ERC20 asset (e.g., USDC)
  /// @param ptToken_ The address of the deployed Principal Token contract
  /// @param ytToken_ The address of the deployed Yield Token contract
  /// @param name_ The base name for the tokens (will be prefixed with "PT-" / "YT-")
  /// @param symbol_ The base symbol for the tokens (will be prefixed with "PT-" / "YT-")
  /// @param repaymentDeadline_ The timestamp after which withdrawals are automatically enabled, regardless of repaid status
  /// @param mintToRepaidDelay_ Minimum delay (seconds) between the last mint/consume and setRepaid(uint256)
  function initialize(
    address owner_,
    address puller_,
    address consumer_,
    address asset_,
    address ptToken_,
    address ytToken_,
    string memory name_,
    string memory symbol_,
    uint64 repaymentDeadline_,
    uint40 mintToRepaidDelay_
  ) public initializer {
    // Validate repayment deadline is within a reasonable range
    if (
      repaymentDeadline_ <= block.timestamp + mintToRepaidDelay_
        || repaymentDeadline_ > block.timestamp + _MAX_REPAYMENT_DEADLINE_OFFSET
    ) {
      revert LibRequestErrors.InvalidRepaymentDeadline();
    }

    RequestStorage storage _request = _requestStorage();
    _request.asset = asset_;
    _request.repaymentDeadline = repaymentDeadline_;
    _request.mintToRepaidDelay = mintToRepaidDelay_;
    _request.ptToken = ptToken_;
    _request.ytToken = ytToken_;
    _request.name = name_;
    _request.symbol = symbol_;
    _initializeOwner(owner_);
    _grantRoles(puller_, _ROLE_PULLER);
    _grantRoles(consumer_, _ROLE_CONSUMER);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          METADATA                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc VaultController
  function _asset() internal view override returns (address) {
    return _requestStorage().asset;
  }

  /// @inheritdoc VaultController
  /// @dev Returns true only if the request has been marked as repaid.
  ///      Use syncRepaidStatus() to trigger automatic repayment after the deadline.
  function _canWithdraw() internal view override returns (bool) {
    return _requestStorage().repaid;
  }

  /// @inheritdoc VaultController
  /// @dev Syncs the repaid status if the deadline has passed but repaid is still false.
  ///      Sets repaid to true and emits the Repaid event when the deadline is reached.
  function _syncWithdrawalStatus() internal override returns (bool) {
    RequestStorage storage req = _requestStorage();
    // If already repaid, return true
    if (req.repaid) return true;
    // else if deadline has passed, set repaid to true and emit the Repaid event
    if (block.timestamp >= req.repaymentDeadline) {
      req.repaid = true;
      emit Repaid(IERC20(_asset()).balanceOf(address(this)));
      return true;
    }
    // else return false
    return false;
  }

  /// @inheritdoc IHasAsset
  function asset() external view override(IHasAsset, VaultController) returns (address) {
    return _asset();
  }

  /// @inheritdoc ITokenController
  function name() external view returns (string memory) {
    return _requestStorage().name;
  }

  /// @inheritdoc ITokenController
  function symbol() external view returns (string memory) {
    return _requestStorage().symbol;
  }

  /// @inheritdoc ITokenController
  function decimals() external view returns (uint8) {
    return IERC20(_asset()).decimals();
  }

  /// @inheritdoc TokenController
  function _ptToken() internal view override returns (address) {
    return _requestStorage().ptToken;
  }

  /// @inheritdoc TokenController
  function _ytToken() internal view override returns (address) {
    return _requestStorage().ytToken;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRequest
  /// @dev Only callable by the owner. Once called, `canWithdraw()` returns true and users
  ///      can redeem their PT/YT tokens for the underlying asset. This action is irreversible.
  ///      Emits a {Repaid} event with the total amount of underlying assets available for redemption.
  ///
  ///      minBalance prevents a malicious facilitator from draining assets before setRepaid is called.
  ///      maxBalance prevents a malicious facilitator (who is also a YT holder) from over-repaying
  ///      assets just before setRepaid to inflate their YT redemption value at the expense of intent
  ///      shareholders. Pass type(uint256).max to skip the upper bound check.
  /// @custom:reverts If the request has already been repaid or the deadline has passed
  /// @custom:reverts If the mint-to-repaid delay has not elapsed since the last mint/consume
  /// @custom:reverts If the current balance is below minBalance or above maxBalance
  function setRepaid(uint256 minBalance, uint256 maxBalance) external onlyOwner nonReentrant {
    if (_syncWithdrawalStatus()) revert LibRequestErrors.AlreadyRepaid();
    RequestStorage storage req = _requestStorage();
    uint40 _lastMint = req.lastMintTimestamp;
    if (_lastMint != 0) {
      uint40 _availableAt = _lastMint + req.mintToRepaidDelay;
      if (block.timestamp < _availableAt) {
        revert LibRequestErrors.MintToRepaidDelayNotElapsed(_availableAt);
      }
    }
    uint256 balance = IERC20(_asset()).balanceOf(address(this));
    if (balance < minBalance) revert LibRequestErrors.InsufficientBalance(balance, minBalance);
    if (balance > maxBalance) revert LibRequestErrors.ExcessiveBalance(balance, maxBalance);
    req.repaid = true;
    emit Repaid(balance);
  }

  /// @inheritdoc IRequest
  /// @dev Allows anyone to sync the repaid status after the repayment deadline has passed.
  ///      If the deadline has passed and repaid is still false, this will set repaid to true
  ///      and emit the Repaid event. This is useful to trigger the state change without requiring
  ///      a withdrawal attempt.
  /// @return repaid Whether the request is now marked as repaid
  function syncRepaidStatus() external returns (bool) {
    return _syncWithdrawalStatus();
  }

  /// @inheritdoc IRequest
  function lastMintTimestamp() external view returns (uint40) {
    return _requestStorage().lastMintTimestamp;
  }

  /// @inheritdoc IRequest
  function mintToRepaidDelay() external view returns (uint40) {
    return _requestStorage().mintToRepaidDelay;
  }

  /// @inheritdoc IRequest
  function repaidAvailableAt() external view returns (uint40) {
    RequestStorage storage req = _requestStorage();
    if (req.lastMintTimestamp == 0) return 0;
    return req.lastMintTimestamp + req.mintToRepaidDelay;
  }

  /// @inheritdoc IRequest
  function setMintToRepaidDelay(uint40 mintToRepaidDelay_) external onlyOwner {
    uint256(mintToRepaidDelay_).checkNotZero();
    _requestStorage().mintToRepaidDelay = mintToRepaidDelay_;
    emit MintToRepaidDelaySet(mintToRepaidDelay_);
  }

  /// @inheritdoc IRequest
  /// @dev Only callable by the owner or consumer role. The authorized address can then call `mint()` to receive
  ///      the tokens after transferring the required underlying asset. This is useful for
  ///      whitelisting participants or implementing custom minting logic.
  ///      Emits an {AuthorizedMinting} event.
  function authorizeMinting(address to, uint128 ptAmount, uint128 ytAmount) external onlyOwnerOrRoles(_ROLE_CONSUMER) {
    to.updateMintAuth(ptAmount, ytAmount);
    emit AuthorizedMinting(to, ptAmount, ytAmount);
  }

  /// @inheritdoc IRequestInteractions
  /// @dev Only callable by the puller role. This function is used after offers are consumed to
  ///      transfer the collected funds to the puller. The puller
  ///      is then expected to repay by transferring assets back to the contract before
  ///      `setRepaid(uint256)` is called to enable PT/YT holder withdrawals.
  ///      Emits a {FundsPulled} event and a Transfer event from the underlying asset contract.
  /// @custom:reverts If the request has been repaid or the deadline has passed
  function pullFunds(uint256 amount, bytes calldata data) external onlyRoles(_ROLE_PULLER) {
    if (_syncWithdrawalStatus()) revert LibRequestErrors.AlreadyRepaid();
    _asset().safeTransfer(msg.sender, amount);
    emit FundsPulled(msg.sender, amount);
    if (data.length > 0) {
      IRequestInteractionsCallback(msg.sender).onPullFunds(amount, data);
    }
  }

  /// @inheritdoc IRequestInteractions
  /// @dev Transfers the underlying assets back to the contract. This is purely optional
  ///      with the given implementation and may be done via a simple transfer.
  ///      Cannot be called after the request has been repaid (when withdrawals are enabled).
  /// @custom:reverts If the request has been repaid or the deadline has passed
  function repay(uint256 amount) external {
    if (_syncWithdrawalStatus()) revert LibRequestErrors.AlreadyRepaid();
    _asset().safeTransferFrom(msg.sender, address(this), amount);
  }

  /// @inheritdoc IRequestInteractions
  /// @dev Returns true when the request has been marked as repaid via setRepaid(uint256) or syncRepaidStatus().
  ///      Call syncRepaidStatus() after the deadline to update the repaid flag.
  function isRepaid() external view returns (bool) {
    return _requestStorage().repaid;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          MINTING                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRequest
  function mintAuthorization(address account) external view returns (uint128 ptAmount, uint128 ytAmount) {
    (ptAmount, ytAmount) = account.mintAuth();
  }

  /// @inheritdoc IRequest
  /// @dev The caller must have been previously authorized via `authorizeMinting()`. This function:
  ///      1. Reads the caller's authorized PT/YT amounts from storage
  ///      2. Validates slippage: PT must not exceed maxPt (caps the deposit), YT must meet minYt (protects yield)
  ///      3. Transfers PT amount of underlying asset from caller to this contract
  ///      4. Mints the authorized PT and YT amounts to the caller
  ///      5. Clears the minting authorization (one-time use)
  ///
  ///      The caller must have approved this contract to spend the required asset amount.
  ///      Note: The authorization is consumed after minting (amounts reset to 0).
  ///
  ///      maxPt caps the deposit: if the consumer front-runs to increase ptMintAuth, the broker
  ///      would deposit more than expected for the same yield. Pass type(uint128).max to skip.
  ///      minYt protects yield: if the consumer front-runs to decrease ytMintAuth, the broker
  ///      would receive less yield for their deposit.
  /// @custom:reverts If the request has been repaid or the deadline has passed
  /// @custom:reverts SlippageExceeded if authorized PT exceeds maxPt or authorized YT is below minYt
  function mint(uint128 maxPt, uint128 minYt) external nonReentrant {
    if (_syncWithdrawalStatus()) revert LibRequestErrors.AlreadyRepaid();
    (uint128 ptMintAuth, uint128 ytMintAuth) = msg.sender.mintAuth();
    // Early return when no authorization — prevents griefing where a zero-authorized caller
    // repeatedly calls mint to bump lastMintTimestamp and permanently delay setRepaid().
    if (ptMintAuth == 0 && ytMintAuth == 0) return;
    if (ptMintAuth > maxPt || ytMintAuth < minYt) revert LibRequestErrors.SlippageExceeded();
    msg.sender.updateMintAuth(0, 0);
    _asset().safeTransferFrom(msg.sender, address(this), ptMintAuth);
    _mint(msg.sender, ptMintAuth, ytMintAuth);
    _requestStorage().lastMintTimestamp = uint40(block.timestamp);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     OFFER CONSUMPTION                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRequest
  /// @dev Only callable by the owner or consumer role. This function implements the core offer consumption flow:
  ///      1. Validates the offer signature using EIP-712 (via `_validateOffer`)
  ///      2. Calculates the proportional YT amount based on the PT amount being consumed
  ///      3. If `offer.useCallback` is true, calls the maker's `onRequestConsumed` callback to prepare funds
  ///      4. Transfers the PT amount of underlying asset from the maker to this contract
  ///      5. Mints PT and YT tokens to the offer maker
  ///
  ///      The YT amount is calculated as: `ytAmount = offer.expectedReturn * ptAmount / offer.amount`
  ///      This ensures proportional distribution when partially consuming an offer.
  ///
  ///      The callback allows the maker to prepare funds (e.g., withdraw from DeFi, set allowances)
  ///      before the asset transfer occurs. Set `offer.useCallback` to false for EOA makers or
  ///      contracts that don't need the callback (e.g., have pre-approved allowances).
  ///
  /// @custom:reverts If the request has been repaid or the deadline has passed
  /// @custom:reverts If the offer signature is invalid
  /// @custom:reverts If the asset transfer fails
  function consume(Offer calldata offer, bytes calldata signature, uint256 ptAmount)
    external
    onlyOwnerOrRoles(_ROLE_CONSUMER)
    nonReentrant
    returns (uint256 ytAmount)
  {
    if (_syncWithdrawalStatus()) revert LibRequestErrors.AlreadyRepaid();
    if (ptAmount == 0 || ptAmount > offer.amount) revert LibRequestErrors.InvalidPtAmount();
    _validateOffer(offer, signature);
    ytAmount = offer.expectedReturn.mulDiv(ptAmount, offer.amount);
    if (offer.useCallback) {
      IRequestCallback(offer.maker).onRequestConsumed(offer, signature, ptAmount, ytAmount);
    }
    _asset().safeTransferFrom(offer.maker, address(this), ptAmount);
    _mint(offer.maker, ptAmount, ytAmount);
    _requestStorage().lastMintTimestamp = uint40(block.timestamp);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL OVERRIDES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc EIP712
  function _domainNameAndVersion() internal view override returns (string memory _name, string memory _version) {
    _name = _requestStorage().name;
    _version = "0.0.1";
  }

  /// @inheritdoc EIP712
  /// @dev Returns true because the name is stored in storage and may differ across proxy instances.
  function _domainNameAndVersionMayChange() internal pure override returns (bool) {
    return true;
  }

  /// @inheritdoc ReentrancyGuardTransient
  /// @dev Returns false to disable the transient reentrancy guard on all networks.
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
