// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ParetoFund} from "./ParetoFund.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";

/// @title ParetoFundFactory
/// @author 3F Protocol
/// @notice Factory for deploying ParetoFund instances using the beacon proxy pattern.
/// @dev Deploys a ParetoFund implementation and an UpgradeableBeacon in the constructor.
///      Each `createFund` call deploys an ERC1967 beacon proxy and initializes it atomically.
///      Post-deployment: the WrappedAsset owner must grant ISSUER_ROLE to the new fund.
contract ParetoFundFactory {
  using LibClone for address;
  using LibChecks for address;

  event FactoryDeployed();
  event FundCreated(address indexed fund, address indexed vault);

  address public immutable PARETO_FUND_BEACON;

  constructor(address initialBeaconOwner) {
    PARETO_FUND_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new ParetoFund())));
    emit FactoryDeployed();
  }

  /// @notice Deploys a new ParetoFund beacon proxy and initializes it.
  /// @param owner The owner of the new fund.
  /// @param depositor The depositor contract address (granted DEPOSITOR_ROLE).
  /// @param vault The IdleCDOEpochVariant proxy address.
  /// @param wrappedShare The WrappedAsset contract wrapping the AA tranche token.
  /// @return fund The address of the newly deployed fund.
  function createFund(address owner, address depositor, address vault, address wrappedShare)
    external
    returns (address fund)
  {
    fund = PARETO_FUND_BEACON.deployERC1967BeaconProxy();
    ParetoFund(fund).initialize(owner, depositor, vault, wrappedShare);
    emit FundCreated(fund, vault);
  }
}
