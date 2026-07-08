// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MidasFund} from "./MidasFund.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title MidasFundFactory
/// @author 3F Protocol
/// @notice Factory for deploying MidasFund instances using the beacon proxy pattern.
/// @dev Deploys a MidasFund implementation and an UpgradeableBeacon in the constructor.
///      Each `createFund` call deploys an ERC1967 beacon proxy and initializes it atomically.
///      Multiple funds can be deployed for the same mToken to run several settlements
///      concurrently, all sharing the same WrappedAsset.
///      Post-deployment:
///      - the WrappedAsset owner must grant ISSUER_ROLE to the new fund;
///      - Midas must greenlist the new fund (and the WrappedAsset, once) when the vault
///        greenlist is enabled or the mToken is permissioned (e.g. mGLOBAL);
///      - the fund owner grants OPERATOR_ROLE / HOLDBACK_ROLE / VAULT_MANAGER_ROLE to the
///        relevant accounts.
contract MidasFundFactory {
  using LibClone for address;

  event FactoryDeployed();
  event FundCreated(address indexed fund, address indexed depositVault, address indexed redemptionVault);

  address public immutable MIDAS_FUND_BEACON;

  constructor(address initialBeaconOwner) {
    MIDAS_FUND_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new MidasFund())));
    emit FactoryDeployed();
  }

  /// @notice Deploys a new MidasFund beacon proxy and initializes it.
  /// @param owner The owner of the new fund.
  /// @param depositor The depositor contract address (granted DEPOSITOR_ROLE).
  /// @param depositVault The Midas DepositVault (issuance vault) proxy address.
  /// @param redemptionVault The Midas RedemptionVault proxy address.
  /// @param wrappedShare The WrappedAsset contract wrapping the mToken.
  /// @param asset The payment token used for deposits and redemptions (e.g. USDC).
  /// @return fund The address of the newly deployed fund.
  function createFund(
    address owner,
    address depositor,
    address depositVault,
    address redemptionVault,
    address wrappedShare,
    address asset
  ) external returns (address fund) {
    fund = MIDAS_FUND_BEACON.deployERC1967BeaconProxy();
    MidasFund(fund).initialize(owner, depositor, depositVault, redemptionVault, wrappedShare, asset);
    emit FundCreated(fund, depositVault, redemptionVault);
  }
}
