// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OfferReceiver} from "../../../src/request/abstract/OfferReceiver.sol";
import {Offer} from "../../../src/interfaces/request/IOfferReceiver.sol";

/// @notice Mock contract for testing OfferReceiver functionality
/// @dev Exposes internal _validateOffer function for testing and implements required EIP712 functions
contract MockOfferReceiver is OfferReceiver {
  string internal _name;
  string internal _symbol;

  constructor(string memory name_, string memory symbol_) {
    _name = name_;
    _symbol = symbol_;
  }

  /// @notice Exposes the internal _validateOffer function for testing
  function validateOffer(Offer calldata offer, bytes calldata signature) external {
    _validateOffer(offer, signature);
  }

  /// @notice Exposes the internal _hashTypedData function for testing
  function hashTypedData(bytes32 structHash) external view returns (bytes32) {
    return _hashTypedData(structHash);
  }

  /// @notice Returns the name and version for EIP-712 domain separator
  function _domainNameAndVersion() internal view override returns (string memory name, string memory version) {
    name = _name;
    version = "1";
  }
}

