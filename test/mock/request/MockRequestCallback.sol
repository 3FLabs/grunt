// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IRequestCallback} from "../../../src/interfaces/request/IRequestCallback.sol";
import {Offer} from "../../../src/interfaces/request/IOfferReceiver.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";

/// @notice Mock contract for testing IRequestCallback functionality
/// @dev Implements the callback to prepare funds when an offer is consumed
///      Also implements EIP-1271 for signature validation
contract MockRequestCallback is IRequestCallback {
  using SafeTransferLib for address;

  address public asset;
  address public request;
  address public signer; // EOA that signs on behalf of this contract
  bool public shouldRevert;
  bool public callbackCalled;
  uint256 public lastPrincipal;
  uint256 public lastYield;

  // EIP-1271 magic value
  bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

  constructor(address _asset, address _signer) {
    asset = _asset;
    signer = _signer;
  }

  function setRequest(address _request) external {
    request = _request;
  }

  function setShouldRevert(bool _shouldRevert) external {
    shouldRevert = _shouldRevert;
  }

  function setSigner(address _signer) external {
    signer = _signer;
  }

  function onRequestConsumed(Offer calldata, bytes calldata, uint256 principal, uint256 yield) external override {
    if (shouldRevert) revert("MockRequestCallback: forced revert");

    callbackCalled = true;
    lastPrincipal = principal;
    lastYield = yield;

    // Approve the request to pull funds
    if (request != address(0)) {
      asset.safeApprove(request, principal);
    }
  }

  /// @notice EIP-1271 signature validation
  /// @dev Validates that the signature was created by the authorized signer
  function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
    if (SignatureCheckerLib.isValidSignatureNowCalldata(signer, hash, signature)) {
      return MAGIC_VALUE;
    }
    return bytes4(0xffffffff);
  }

  // Helper to fund this contract
  function fund(uint256 amount) external {
    asset.safeTransferFrom(msg.sender, address(this), amount);
  }
}

