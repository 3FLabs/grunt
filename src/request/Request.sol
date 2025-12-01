// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OfferReceiver} from "./abstract/OfferReceiver.sol";
import {VaultController} from "./abstract/vault/VaultController.sol";
import {TokenController} from "./abstract/tokens/TokenController.sol";
import {LibMintAuth} from "../libs/request/LibMintAuth.sol";
import {IERC20} from "../interfaces/integrations/IERC20.sol";
import {IRequest} from "../interfaces/request/IRequest.sol";
import {IRequestCallback} from "../interfaces/request/IRequestCallback.sol";
import {ITokenController} from "../interfaces/request/ITokenController.sol";
import {Offer} from "../interfaces/request/IOfferReceiver.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {EIP712} from "lib/solady/src/utils/EIP712.sol";

/// @title Request
/// @notice Contract for managing funding requests with dual-token (PT/YT) issuance.
/// @dev This contract combines multiple functionalities:
///      - **OfferReceiver**: Validates and processes signed offers using EIP-712 signatures
///      - **VaultController**: Manages PT/YT tokens with ERC4626-style redemptions
///      - **Initializable**: Supports initialization for proxy deployments
///      - **Ownable**: Restricts admin functions to the contract owner
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
///      4. Once offers are consumed, the owner pulls funds to a receiver via `pullFunds()`
///      5. The borrower repays by transferring the asset back to the contract
///      6. Once fully repaid, the owner calls `setRepaid()` to enable withdrawals for PT/YT holders
///
///      Offer Consumption Flow:
///      1. A maker creates and signs an offer specifying amount and expected return
///      2. Owner calls `consume()` with the offer, signature, and PT amount to fulfill
///      3. The maker's `onRequestConsumed` callback is invoked to prepare funds
///      4. Assets are transferred from owner and PT/YT tokens are minted to the maker
contract Request is IRequest, OfferReceiver, VaultController, Initializable, Ownable, ReentrancyGuardTransient {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;
  using LibMintAuth for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ERRORS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The request has already been repaid, preventing further calls to `setRepaid()`.
  error AlreadyRepaid();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Storage struct containing all persistent state for the Request contract.
  /// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
  ///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
  /// @param asset The address of the underlying ERC20 asset (e.g., USDC)
  /// @param repaid Whether the request has been repaid, enabling withdrawals
  /// @param ptToken The address of the Principal Token contract
  /// @param ytToken The address of the Yield Token contract
  /// @param name The base name for the PT/YT tokens (prefixed with "PT-" / "YT-")
  /// @param symbol The base symbol for the PT/YT tokens (prefixed with "PT-" / "YT-")
  struct RequestStorage {
    address asset;
    bool repaid;
    address ptToken;
    address ytToken;
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
    /// @solidity memory-safe-assembly
    assembly {
      requestStorage.slot := _MAIN_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the Request contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier. Sets up the contract owner,
  ///      underlying asset, PT/YT token addresses, and metadata. The contract starts in a non-repaid
  ///      state where withdrawals are disabled.
  /// @param owner_ The address that will own the contract and have admin privileges
  /// @param asset_ The address of the underlying ERC20 asset (e.g., USDC)
  /// @param ptToken_ The address of the deployed Principal Token contract
  /// @param ytToken_ The address of the deployed Yield Token contract
  /// @param name_ The base name for the tokens (will be prefixed with "PT-" / "YT-")
  /// @param symbol_ The base symbol for the tokens (will be prefixed with "PT-" / "YT-")
  function initialize(
    address owner_,
    address asset_,
    address ptToken_,
    address ytToken_,
    string memory name_,
    string memory symbol_
  ) public initializer {
    RequestStorage storage req = _requestStorage();
    req.asset = asset_;
    req.ptToken = ptToken_;
    req.ytToken = ytToken_;
    req.name = name_;
    req.symbol = symbol_;
    _initializeOwner(owner_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          METADATA                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc VaultController
  function _asset() internal view override returns (address) {
    return _requestStorage().asset;
  }

  /// @inheritdoc VaultController
  function _canWithdraw() internal view override returns (bool) {
    return _requestStorage().repaid;
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
  ///      Emits a {Repaid} event.
  /// @custom:reverts If the request has already been repaid
  function setRepaid() external onlyOwner {
    if (_canWithdraw()) revert AlreadyRepaid();
    _requestStorage().repaid = true;
    emit Repaid();
  }

  /// @inheritdoc IRequest
  /// @dev Only callable by the owner. The authorized address can then call `mint()` to receive
  ///      the tokens after transferring the required underlying asset. This is useful for
  ///      whitelisting participants or implementing custom minting logic.
  ///      Emits an {AuthorizedMinting} event.
  function authorizeMinting(address to, uint128 ptAmount, uint128 ytAmount) external onlyOwner {
    to.updateMintAuth(ptAmount, ytAmount);
    emit AuthorizedMinting(to, ptAmount, ytAmount);
  }

  /// @inheritdoc IRequest
  /// @dev Only callable by the owner. This function is used after offers are consumed to
  ///      transfer the collected funds to the borrower (or any designated receiver). The borrower
  ///      is then expected to repay by transferring assets back to the contract before
  ///      `setRepaid()` is called to enable PT/YT holder withdrawals.
  ///      Emits a Transfer event from the underlying asset contract.
  /// @custom:reverts If the request has been repaid
  function pullFunds(address receiver, uint256 amount) external onlyOwner {
    if (_canWithdraw()) revert AlreadyRepaid();
    _asset().safeTransfer(receiver, amount);
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
  ///      2. Transfers PT amount of underlying asset from caller to this contract
  ///      3. Mints the authorized PT and YT amounts to the caller
  ///      4. Clears the minting authorization (one-time use)
  ///
  ///      The caller must have approved this contract to spend the required asset amount.
  ///      Note: The authorization is consumed after minting (amounts reset to 0).
  /// @custom:reverts If the request has been repaid
  function mint() external {
    if (_canWithdraw()) revert AlreadyRepaid();
    (uint128 ptMintAuth, uint128 ytMintAuth) = msg.sender.mintAuth();
    msg.sender.updateMintAuth(0, 0);
    _asset().safeTransferFrom(msg.sender, address(this), ptMintAuth);
    _mint(msg.sender, ptMintAuth, ytMintAuth);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     OFFER CONSUMPTION                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRequest
  /// @dev Only callable by the owner. This function implements the core offer consumption flow:
  ///      1. Validates the offer signature using EIP-712 (via `_validateOffer`)
  ///      2. Calculates the proportional YT amount based on the PT amount being consumed
  ///      3. Calls the maker's `onRequestConsumed` callback to prepare funds
  ///      4. Transfers the PT amount of underlying asset from owner to this contract
  ///      5. Mints PT and YT tokens to the offer maker
  ///
  ///      The YT amount is calculated as: `ytAmount = offer.expectedReturn * ptAmount / offer.amount`
  ///      This ensures proportional distribution when partially consuming an offer.
  ///
  ///      The callback allows the maker to prepare funds (e.g., withdraw from DeFi, set allowances)
  ///      before the asset transfer occurs.
  ///
  /// @custom:reverts If the request has been repaid
  /// @custom:reverts If the offer signature is invalid
  /// @custom:reverts If the asset transfer fails
  function consume(Offer calldata offer, bytes calldata signature, uint256 ptAmount)
    external
    onlyOwner
    nonReentrant
    returns (uint256 ytAmount)
  {
    if (_canWithdraw()) revert AlreadyRepaid();
    _validateOffer(offer, signature);
    ytAmount = offer.expectedReturn.mulDiv(ptAmount, offer.amount);
    IRequestCallback(offer.maker).onRequestConsumed(offer, signature, ptAmount, ytAmount);
    _asset().safeTransferFrom(offer.maker, address(this), ptAmount);
    _mint(offer.maker, ptAmount, ytAmount);
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
