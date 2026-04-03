// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Request} from "../../../src/request/Request.sol";
import {IRequestCallback} from "../../../src/interfaces/request/IRequestCallback.sol";
import {Offer} from "../../../src/interfaces/request/IOfferReceiver.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";

/// @notice Malicious callback that attempts to reenter Request during onRequestConsumed
/// @dev Used to test reentrancy protection on setRepaid() and mint()
contract MaliciousRequestCallback is IRequestCallback {
  using SafeTransferLib for address;

  enum AttackType {
    NONE,
    SET_REPAID,
    MINT
  }

  address public asset;
  address public request;
  address public signer;
  AttackType public attackType;
  bool public attackTriggered;
  bytes public lastRevertReason;

  bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

  constructor(address _asset, address _signer) {
    asset = _asset;
    signer = _signer;
  }

  function setRequest(address _request) external {
    request = _request;
  }

  function setAttackType(AttackType _type) external {
    attackType = _type;
    attackTriggered = false;
    lastRevertReason = "";
  }

  function onRequestConsumed(Offer calldata, bytes calldata, uint256 principal, uint256) external override {
    // Approve the request to pull funds so consume() can complete after the caught error
    asset.safeApprove(request, principal);

    if (attackType == AttackType.SET_REPAID) {
      attackTriggered = true;
      try Request(request).setRepaid(0, type(uint256).max) {}
      catch (bytes memory reason) {
        lastRevertReason = reason;
      }
    } else if (attackType == AttackType.MINT) {
      attackTriggered = true;
      try Request(request).mint(type(uint128).max, 0) {}
      catch (bytes memory reason) {
        lastRevertReason = reason;
      }
    }
  }

  /// @notice Check if last revert was Reentrancy error
  function wasReentrancyError() external view returns (bool) {
    bytes memory reason = lastRevertReason;
    if (reason.length < 4) return false;
    bytes4 selector;
    assembly {
      selector := mload(add(reason, 32))
    }
    return selector == ReentrancyGuardTransient.Reentrancy.selector;
  }

  /// @notice EIP-1271 signature validation
  function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
    if (SignatureCheckerLib.isValidSignatureNowCalldata(signer, hash, signature)) {
      return MAGIC_VALUE;
    }
    return bytes4(0xffffffff);
  }
}
