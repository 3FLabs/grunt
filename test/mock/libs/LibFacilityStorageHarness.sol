// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {Asset} from "src/libs/facility/LibIntent.sol";

/// @dev Harness contract to expose internal LibStorage (facility) functions for testing
contract LibFacilityStorageHarness {
  using LibStorage for FacilityStorageData;

  /// @dev Expose getIntent
  function getIntent(uint256 id) external view {
    LibStorage.facilityStorage().getIntent(id);
  }

  /// @dev Expose getResolvingIntent
  function getResolvingIntent(uint256 id) external view {
    LibStorage.facilityStorage().getResolvingIntent(id);
  }

  /// @dev Expose getDepositingIntent
  function getDepositingIntent(uint256 id) external view {
    LibStorage.facilityStorage().getDepositingIntent(id);
  }

  /// @dev Expose getResolvedIntent
  function getResolvedIntent(uint256 id) external view {
    LibStorage.facilityStorage().getResolvedIntent(id);
  }

  /// @dev Expose createIntent
  function createIntent(Asset calldata depositAsset, uint8 quorum, bool transferableIntent)
    external
    returns (uint256 id)
  {
    (, id) = LibStorage.facilityStorage().createIntent(depositAsset, quorum, transferableIntent);
  }

  /// @dev Expose checkNotPaused
  function checkNotPaused() external view {
    LibStorage.checkNotPaused();
  }

  /// @dev Expose checkDigest
  function checkDigest(bytes32 digest) external {
    LibStorage.facilityStorage().checkDigest(digest);
  }

  /// @dev Expose checkFundIntent
  function checkFundIntent(address fund, uint256 targetIntentId) external {
    LibStorage.facilityStorage().checkFundIntent(fund, targetIntentId);
  }

  /// @dev Expose checkRequestIntent
  function checkRequestIntent(address request, uint256 targetIntentId) external {
    LibStorage.facilityStorage().checkRequestIntent(request, targetIntentId);
  }

  /// @dev Expose abandonFund
  function abandonFund(address fund) external {
    LibStorage.facilityStorage().abandonFund(fund);
  }

  /// @dev Expose abandonRequest
  function abandonRequest(address request) external {
    LibStorage.facilityStorage().abandonRequest(request);
  }

  /// @dev Set the pause timestamp for testing
  function setPausedUntil(uint40 pausedUntil) external {
    LibStorage.facilityStorage().pausedUntil = pausedUntil;
  }

  /// @dev Get the last intent ID for verification
  function lastIntentId() external view returns (uint256) {
    return LibStorage.facilityStorage().lastIntentId;
  }

  /// @dev Check if digest is used
  function isDigestUsed(bytes32 digest) external view returns (bool) {
    return LibStorage.facilityStorage().usedSwapDigests[digest];
  }

  /// @dev Get fund intent mapping
  function getFundIntent(address fund) external view returns (uint256) {
    return LibStorage.facilityStorage().fundsIntent[fund];
  }

  /// @dev Get request intent mapping
  function getRequestIntent(address request) external view returns (uint256) {
    return LibStorage.facilityStorage().requestsIntent[request];
  }
}
