// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {WildcatFund} from "./WildcatFund.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";

/// @title WildcatFundFactory
/// @author 3F Protocol
/// @notice Factory for deploying WildcatFund instances using the beacon proxy pattern.
/// @dev Deploys a WildcatFund implementation and an UpgradeableBeacon in the constructor.
///      Each `createFund` call deploys an ERC1967 beacon proxy and initializes it atomically.
///      Post-deployment:
///      - the WrappedAsset owner must grant ISSUER_ROLE to the new fund;
///      - per market/hooks policy, the new fund may need a deposit credential on the market's
///        hooks contract (one-time onboarding, e.g. granted by the borrower); markets with an
///        open-access pull provider (like wmtUSDC) require no onboarding.
contract WildcatFundFactory {
  using LibClone for address;
  using LibChecks for address;

  event FactoryDeployed();
  event FundCreated(address indexed fund, address indexed wrapper);

  address public immutable WILDCAT_FUND_BEACON;

  constructor(address initialBeaconOwner) {
    WILDCAT_FUND_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new WildcatFund())));
    emit FactoryDeployed();
  }

  /// @notice Deploys a new WildcatFund beacon proxy and initializes it.
  /// @param owner The owner of the new fund.
  /// @param depositor The depositor contract address (granted DEPOSITOR_ROLE).
  /// @param wrapper The official Wildcat ERC-4626 wrapper of the target market.
  /// @param wrappedShare The WrappedAsset contract wrapping the ERC-4626 wrapper shares.
  /// @return fund The address of the newly deployed fund.
  function createFund(address owner, address depositor, address wrapper, address wrappedShare)
    external
    returns (address fund)
  {
    fund = WILDCAT_FUND_BEACON.deployERC1967BeaconProxy();
    WildcatFund(fund).initialize(owner, depositor, wrapper, wrappedShare);
    emit FundCreated(fund, wrapper);
  }
}
