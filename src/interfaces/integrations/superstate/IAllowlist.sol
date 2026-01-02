// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

interface IAllowlist {
  /**
   * @notice Gets the entityId for the provided address
   * @param addr The address to get the entityId for
   */
  function addressEntityIds(address addr) external view returns (uint256);

  /**
   * @notice Checks whether an address is allowed to use a private instrument
   * @param addr The address to check permissions for
   * @param instrument The private instrument symbol to check permissions for
   */
  function isAddressAllowedForPrivateInstrument(address addr, string calldata instrument) external view returns (bool);

  /**
   * @dev Checks if an address is allowed to interact with public instrument
   * @param addr The address to check
   * @return True if the address is allowed, false otherwise
   */
  function isAddressAllowedForPublicInstrument(address addr) external view returns (bool);
}
