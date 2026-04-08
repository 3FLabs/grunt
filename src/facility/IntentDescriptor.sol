// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IIntentDescriptor} from "src/interfaces/facility/IIntentDescriptor.sol";
import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {LibString} from "lib/solady/src/utils/LibString.sol";
import {Base64} from "lib/solady/src/utils/Base64.sol";

/// @title IntentDescriptor
/// @author 3F Protocol
/// @notice Generates metadata for 3F facility intent tokens (ERC6909).
/// @dev Provides on-chain SVG images and JSON metadata for intent tokens.
contract IntentDescriptor is IIntentDescriptor {
  using LibString for uint256;

  /// @inheritdoc IIntentDescriptor
  function name(IFacility, uint256 id) external pure override returns (string memory) {
    return string.concat("3F facility intent #", id.toString());
  }

  /// @inheritdoc IIntentDescriptor
  function symbol(IFacility, uint256 id) external pure override returns (string memory) {
    return string.concat("3F-INTENT-", id.toString());
  }

  /// @inheritdoc IIntentDescriptor
  function description(IFacility, uint256 id) external pure override returns (string memory) {
    return string.concat(
      "This is the intent id number ",
      id.toString(),
      " to deposit or withdraw from the 3F protocol. ",
      "Hold this token to participate in the facility's liquidity operations."
    );
  }

  /// @inheritdoc IIntentDescriptor
  function tokenURI(IFacility, uint256 id) external pure override returns (string memory) {
    string memory tokenName = _name(id);
    string memory tokenDescription = _description(id);
    string memory tokenSymbol = _symbol(id);
    string memory image = _generateSvg(tokenSymbol);

    string memory json =
      string.concat('{"name":"', tokenName, '","description":"', tokenDescription, '","image":"', image, '"}');

    return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
  }

  /// @dev Internal helper to generate name.
  function _name(uint256 id) internal pure returns (string memory) {
    return string.concat("3F facility intent #", id.toString());
  }

  /// @dev Internal helper to generate symbol.
  function _symbol(uint256 id) internal pure returns (string memory) {
    return string.concat("3F-INTENT-", id.toString());
  }

  /// @dev Internal helper to generate description.
  function _description(uint256 id) internal pure returns (string memory) {
    return string.concat(
      "This is the intent id number ",
      id.toString(),
      " to deposit or withdraw from the 3F protocol. ",
      "Hold this token to participate in the facility's liquidity operations."
    );
  }

  /// @dev Generates an SVG image for the intent token.
  /// @param tokenSymbol The symbol to display on the token.
  /// @return The base64-encoded SVG data URI.
  function _generateSvg(string memory tokenSymbol) internal pure returns (string memory) {
    string memory svg = string.concat(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
      "<defs>",
      '<linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
      '<stop offset="0%" style="stop-color:#1a1a2e"/>',
      '<stop offset="100%" style="stop-color:#16213e"/>',
      "</linearGradient>",
      '<linearGradient id="accent" x1="0%" y1="0%" x2="100%" y2="0%">',
      '<stop offset="0%" style="stop-color:#0f3460"/>',
      '<stop offset="100%" style="stop-color:#533483"/>',
      "</linearGradient>",
      "</defs>",
      '<rect width="400" height="400" rx="24" fill="url(#bg)"/>',
      '<rect x="20" y="20" width="360" height="360" rx="16" fill="none" stroke="url(#accent)" stroke-width="2" opacity="0.6"/>',
      '<circle cx="200" cy="160" r="60" fill="url(#accent)" opacity="0.8"/>',
      '<text x="200" y="172" font-family="Arial,sans-serif" font-size="32" font-weight="bold" fill="#e94560" text-anchor="middle">3F</text>',
      '<text x="200" y="280" font-family="Arial,sans-serif" font-size="18" font-weight="600" fill="#eaeaea" text-anchor="middle">',
      tokenSymbol,
      "</text>",
      '<text x="200" y="340" font-family="Arial,sans-serif" font-size="12" fill="#888888" text-anchor="middle">FACILITY INTENT TOKEN</text>',
      "</svg>"
    );

    return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));
  }
}
