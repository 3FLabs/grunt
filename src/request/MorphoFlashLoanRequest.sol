// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Offer} from "../interfaces/request/IOfferReceiver.sol";
import {IRequest} from "../interfaces/request/IRequest.sol";
import {IRequestInteractions} from "../interfaces/request/IRequestInteractions.sol";
import {IHasAsset} from "../interfaces/request/IHasAsset.sol";
import {IFacilityIntents} from "../interfaces/facility/base/IFacilityIntents.sol";
import {IFacilityRequests} from "../interfaces/facility/base/IFacilityRequests.sol";
import {IERC20} from "../interfaces/integrations/IERC20.sol";
import {IMorphoFlashLoanCallback} from "lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IMorpho} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {LibChecks} from "../libs/common/LibChecks.sol";
import {LibCall} from "lib/solady/src/utils/LibCall.sol";

/// @title MorphoFlashLoanRequest
/// @notice A facilitator contract that uses Morpho flash loans to temporarily act as a request
///         on a facility intent. It atomically sets itself as the request, delegatecalls a
///         whitelisted script, then unsets itself and repays the flash loan.
/// @dev This contract must be granted FACILITATOR_ROLE on the target facility.
///      Assumes that calling setRequest with address(0) does not require guardian signatures.
///
///      Debt model: the contract's full token balance at callback start (flash loan amount +
///      any pre-existing dust) is stored in transient storage as the raw debt. The actual
///      outstanding debt is computed as rawDebt - assetBalance. The asset balance must never
///      exceed the raw debt.
///
///      Flow:
///      1. Owner calls execute() with flash loan amount, setRequest params, script, and payload
///      2. Contract initiates a flash loan from Morpho
///      3. In callback: sets raw debt, sets itself as the request on the facility
///      4. Pulls the flash loan amount from this request into the facility
///      5. Delegatecalls the whitelisted script (which can chain facility operations)
///      6. Repays the flash loan amount from the facility back to this request
///      7. Removes itself as the request on the facility
///      8. Approves Morpho to pull back the flash loaned amount
///
/// @author 3F Protocol
contract MorphoFlashLoanRequest is
  IRequest,
  IMorphoFlashLoanCallback,
  OwnableRoles,
  Initializable,
  ReentrancyGuardTransient
{
  using SafeTransferLib for address;
  using LibChecks for address;
  using LibChecks for uint256;
  using LibCall for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the caller is not the expected address.
  error UnauthorizedCaller();

  /// @notice Thrown when a flash loan is initiated while a previous debt is still outstanding.
  error DebtNotRepaid();

  /// @notice Thrown when the asset balance exceeds the raw debt in transient storage.
  error BalanceExceedsDebt();

  /// @notice Thrown when a function from IRequest that is not supported by this contract is called.
  error NotSupported();

  /// @notice Thrown when a script is not whitelisted.
  error ScriptNotAllowed();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for executing flash loans.
  uint256 internal constant EXECUTOR_ROLE = _ROLE_0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a script's whitelist status is updated.
  event ScriptSet(address indexed script, bool allowed);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Morpho protocol contract used for flash loans.
  IMorpho public immutable MORPHO;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      ERC-7201 STORAGE                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Storage layout for the MorphoFlashLoanRequest contract.
  struct MorphoFlashLoanRequestStorage {
    address facility;
    address asset;
    mapping(address => bool) scripts;
  }

  /// @dev keccak256(abi.encode(uint256(keccak256("morpho.flashloan.request")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _STORAGE_SLOT = 0xe235e8263aa081940d6fc27ca3127dc45529c8e5313f795cd9f59b68f1c2c600;

  /// @dev Returns the ERC-7201 namespaced storage pointer.
  function _storage() internal pure returns (MorphoFlashLoanRequestStorage storage morphoFlashLoanRequestStorage) {
    assembly ("memory-safe") {
      morphoFlashLoanRequestStorage.slot := _STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     TRANSIENT STORAGE                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Transient storage slot for the raw debt set during a flash loan.
  uint256 private constant _RAW_DEBT_TSLOT = uint256(keccak256("MorphoFlashLoanRequest.debt")) - 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STRUCTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Parameters for calling setRequest on the facility.
  /// @param intentId The intent ID on the facility.
  /// @param deadline Timestamp after which the guardian signatures expire.
  /// @param signers Sorted guardian signer addresses.
  /// @param signatures Corresponding EIP-712 signatures.
  struct SetRequestParams {
    uint256 intentId;
    uint256 deadline;
    address[] signers;
    bytes[] signatures;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the MorphoFlashLoanRequest implementation contract.
  /// @param morpho_ The Morpho protocol contract address (immutable across all proxies).
  constructor(address morpho_) {
    morpho_.checkContract();
    MORPHO = IMorpho(morpho_);
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INITIALIZE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the proxy instance.
  /// @param owner_ The owner who can manage scripts and rescue tokens.
  /// @param executor_ The address granted EXECUTOR_ROLE to call execute.
  /// @param facility_ The facility contract address.
  /// @param asset_ The underlying asset token address.
  function initialize(address owner_, address executor_, address facility_, address asset_) public initializer {
    owner_.checkNotZero();
    executor_.checkNotZero();
    facility_.checkContract();
    asset_.checkContract();

    MorphoFlashLoanRequestStorage storage $ = _storage();
    $.facility = facility_;
    $.asset = asset_;

    _initializeOwner(owner_);
    _grantRoles(executor_, EXECUTOR_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EXECUTE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Executes an atomic flash-loan-backed request cycle on the facility.
  /// @dev Only callable by addresses with EXECUTOR_ROLE. Initiates a Morpho flash loan, sets this
  ///      contract as the request on the facility, delegatecalls the whitelisted script, then unsets itself.
  /// @param flashLoanAmount The amount of asset to flash loan from Morpho.
  /// @param requestParams Parameters for the setRequest call (intent ID + guardian signatures).
  /// @param script The whitelisted script contract to delegatecall.
  /// @param scriptPayload The calldata to pass to the script.
  function execute(
    uint256 flashLoanAmount,
    SetRequestParams calldata requestParams,
    address script,
    bytes calldata scriptPayload
  ) external onlyRoles(EXECUTOR_ROLE) nonReentrant {
    flashLoanAmount.checkNotZero();
    MORPHO.flashLoan(_storage().asset, flashLoanAmount, abi.encode(requestParams, script, scriptPayload));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     SCRIPT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets whether a script is whitelisted for delegatecall during execute.
  /// @param script The script contract address.
  /// @param allowed Whether the script should be whitelisted.
  function setScript(address script, bool allowed) external onlyOwner {
    if (allowed) script.checkContract();
    _storage().scripts[script] = allowed;
    emit ScriptSet(script, allowed);
  }

  /// @notice Returns whether a script is whitelisted.
  /// @param script The script contract address.
  /// @return Whether the script is whitelisted.
  function isScript(address script) external view returns (bool) {
    return _storage().scripts[script];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FLASH LOAN CALLBACK                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Callback called by Morpho during a flash loan.
  /// @dev Sets the raw debt, registers this contract as the request, pulls the flash loan amount
  ///      into the facility, delegatecalls the whitelisted script, repays back, unsets itself,
  ///      and approves Morpho to reclaim the loaned amount. Only callable by Morpho.
  /// @param assets The amount of assets that was flash loaned.
  /// @param data The encoded SetRequestParams, script address, and script payload.
  function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
    if (msg.sender != address(MORPHO)) revert UnauthorizedCaller();
    if (_getRawDebt() != 0) revert DebtNotRepaid();

    MorphoFlashLoanRequestStorage storage $ = _storage();

    // Set raw debt to full balance (flash loan + any pre-existing dust) — actual debt is rawDebt - assetBalance
    _setRawDebt(IERC20($.asset).balanceOf(address(this)));

    (SetRequestParams memory params, address script, bytes memory scriptPayload) =
      abi.decode(data, (SetRequestParams, address, bytes));
    address facility = $.facility;

    // Set this contract as the request on the facility
    IFacilityIntents(facility)
      .setRequest(params.intentId, address(this), params.deadline, params.signers, params.signatures);

    // Pull the flash loan amount from this request into the facility
    IFacilityRequests(facility).pull(params.intentId, assets);

    // Delegatecall the whitelisted script
    if (!$.scripts[script]) revert ScriptNotAllowed();
    script.delegateCallContract(scriptPayload);

    // Repay the flash loan amount from the facility back to this request
    IFacilityRequests(facility).repay(params.intentId, assets);

    // Remove this contract as the request (assumes no signatures required for address(0))
    IFacilityIntents(facility)
      .setRequest(params.intentId, address(0), type(uint256).max, new address[](0), new bytes[](0));

    // Approve Morpho to pull back the flash loaned amount
    $.asset.safeApproveWithRetry(address(MORPHO), assets);

    // Clear raw debt so isRepaid() returns true within the same transaction
    _setRawDebt(0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IHasAsset                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IHasAsset
  function asset() external view returns (address) {
    return _storage().asset;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    IRequestInteractions                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRequestInteractions
  /// @dev Returns true when there is no outstanding flash loan debt. This includes the initial
  ///      state before any loan is taken.
  function isRepaid() external view returns (bool) {
    return _debt() == 0;
  }

  /// @inheritdoc IRequestInteractions
  /// @dev Called by the facility during pull(). Transfers assets out, increasing the computed debt.
  function pullFunds(uint256 amount, bytes calldata) external {
    if (msg.sender != _storage().facility) revert UnauthorizedCaller();
    _storage().asset.safeTransfer(msg.sender, amount);
  }

  /// @inheritdoc IRequestInteractions
  /// @dev Called by the facility during repay(). Transfers assets in, decreasing the computed debt.
  ///      Reverts if the resulting balance would exceed the raw debt.
  function repay(uint256 amount) external {
    MorphoFlashLoanRequestStorage storage $ = _storage();
    $.asset.safeTransferFrom(msg.sender, address(this), amount);

    uint256 rawDebt = _getRawDebt();
    if (rawDebt != 0 && IERC20($.asset).balanceOf(address(this)) > rawDebt) revert BalanceExceedsDebt();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  IRequest (not applicable)                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRequest
  function setRepaid(uint256, uint256) external pure {
    revert NotSupported();
  }

  /// @inheritdoc IRequest
  /// @dev Equivalent to isRepaid() for this implementation — flash loans are atomic,
  ///      so there is no async repayment to sync.
  function syncRepaidStatus() external view returns (bool) {
    return _debt() == 0;
  }

  /// @inheritdoc IRequest
  function lastMintTimestamp() external pure returns (uint40) {
    return 0;
  }

  /// @inheritdoc IRequest
  function mintToRepaidDelay() external pure returns (uint40) {
    return 0;
  }

  /// @inheritdoc IRequest
  function repaidAvailableAt() external pure returns (uint40) {
    return 0;
  }

  /// @inheritdoc IRequest
  function setMintToRepaidDelay(uint40) external pure {
    revert NotSupported();
  }

  /// @inheritdoc IRequest
  function authorizeMinting(address, uint128, uint128) external pure {
    revert NotSupported();
  }

  /// @inheritdoc IRequest
  function mintAuthorization(address) external pure returns (uint128, uint128) {
    return (0, 0);
  }

  /// @inheritdoc IRequest
  function mint(uint128, uint128) external pure {
    revert NotSupported();
  }

  /// @inheritdoc IRequest
  function consume(Offer calldata, bytes calldata, uint256) external pure returns (uint256) {
    revert NotSupported();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          RESCUE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Rescues tokens stuck in the contract.
  /// @dev Only callable by the owner. Useful for recovering tokens sent by mistake.
  /// @param token The token address to rescue.
  /// @param to The address to send the tokens to.
  /// @return amount The amount of tokens rescued.
  function rescue(address token, address to) external onlyOwner returns (uint256 amount) {
    amount = token.safeTransferAll(to);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Computes the actual outstanding debt as rawDebt - assetBalance.
  ///      Returns 0 when no flash loan is active (rawDebt == 0).
  ///      Reverts with BalanceExceedsDebt if the asset balance exceeds the raw debt.
  function _debt() internal view returns (uint256) {
    uint256 rawDebt = _getRawDebt();
    if (rawDebt == 0) return 0;
    uint256 balance = IERC20(_storage().asset).balanceOf(address(this));
    if (balance > rawDebt) revert BalanceExceedsDebt();
    return rawDebt - balance;
  }

  /// @dev Reads the raw debt from transient storage.
  function _getRawDebt() internal view returns (uint256 debt) {
    uint256 slot = _RAW_DEBT_TSLOT;
    assembly ("memory-safe") {
      debt := tload(slot)
    }
  }

  /// @dev Writes the raw debt to transient storage.
  function _setRawDebt(uint256 debt) internal {
    uint256 slot = _RAW_DEBT_TSLOT;
    assembly ("memory-safe") {
      tstore(slot, debt)
    }
  }

  /// @dev Always use transient storage for reentrancy guard (not just on mainnet).
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
