// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {SUSD3Fund} from "./SUSD3Fund.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";

/// @title SUSD3FundFactory
/// @author 3F Protocol
/// @notice Factory for deploying SUSD3Fund instances using the beacon proxy pattern.
/// @dev Deploys a SUSD3Fund implementation and an UpgradeableBeacon in the constructor.
///      Each `createFund` call deploys an ERC1967 beacon proxy and initializes it atomically.
///      Post-deployment: the WrappedAsset owner must grant ISSUER_ROLE to the new fund.
contract SUSD3FundFactory {
  using LibClone for address;
  using LibChecks for address;

  event FactoryDeployed();
  event FundCreated(address indexed fund, address indexed susd3);

  address public immutable SUSD3_FUND_BEACON;

  constructor(address initialBeaconOwner) {
    SUSD3_FUND_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new SUSD3Fund())));
    emit FactoryDeployed();
  }

  /// @notice Deploys a new SUSD3Fund beacon proxy and initializes it.
  /// @param owner The owner of the new fund.
  /// @param depositor The depositor contract address (granted DEPOSITOR_ROLE).
  /// @param susd3 The sUSD3 (staked USD3) strategy address.
  /// @param wrappedShare The WrappedAsset contract wrapping the sUSD3 share token.
  /// @return fund The address of the newly deployed fund.
  function createFund(address owner, address depositor, address susd3, address wrappedShare)
    external
    returns (address fund)
  {
    fund = SUSD3_FUND_BEACON.deployERC1967BeaconProxy();
    SUSD3Fund(fund).initialize(owner, depositor, susd3, wrappedShare);
    emit FundCreated(fund, susd3);
  }
}
