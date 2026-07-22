// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {LibChecks} from "../libs/common/LibChecks.sol";
import {LibBorrowErrors} from "../libs/borrow/LibBorrowErrors.sol";
import {IBorrowOffersRegistry} from "../interfaces/borrow/IBorrowOffersRegistry.sol";

/// @title BorrowOffersRegistry
/// @notice The single, protocol-wide source of truth for the offer roles (proposer, guardian) and
///         the per-collateral offer configuration (timelock and minimum bonus) of the offer-based
///         pre-liquidation feature of {MorphoBorrowPosition}.
/// @dev See {IBorrowOffersRegistry} for the role and configuration semantics. Deployed once
///      behind an ERC1967 proxy (via Solady's `ERC1967Factory`, whose admin controls upgrades, so
///      this implementation carries no upgrade surface of its own); each {MorphoBorrowPosition}
///      implementation stores this contract's address as an immutable.
///      See docs/deployment.md#post-deployment-wiring.
/// @author 3F Protocol
contract BorrowOffersRegistry is IBorrowOffersRegistry, Initializable, OwnableRoles {
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Proposer role: allowed to post offers on any {MorphoBorrowPosition}.
  /// @dev Aliases Solady `_ROLE_0`; defined here, where `OwnableRoles` is inherited, so the bit
  ///      values have a single source.
  uint256 public constant PROPOSER_ROLE = _ROLE_0;

  /// @notice Guardian role: allowed to revoke offers on any {MorphoBorrowPosition} (the veto
  ///         power inside the timelock window, and the kill switch for a bad standing offer).
  uint256 public constant GUARDIAN_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CONFIGURATION BOUNDS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Lower bound for a collateral's offer timelock, and the implicit default: effective
  ///         timelocks are floored to this value, so an unconfigured collateral has the minimum
  ///         veto window rather than a disabled band. The positive floor means an offer can never
  ///         be same-block consumable (a key reentrancy assumption of `preLiquidate`).
  uint40 public constant MIN_OFFER_TIMELOCK = 15 minutes;

  /// @notice Upper bound for a collateral's offer timelock. Because a timelock change is itself
  ///         delayed by the current effective timelock, this ceiling bounds both the worst-case
  ///         band freeze a compromised owner can cause and the time to recover from one.
  uint40 public constant MAX_OFFER_TIMELOCK = 7 days;

  /// @notice Default minimum offer bonus, in basis points (100 = 1%), for a collateral whose
  ///         floor was never explicitly set (fail-safe default). An explicit {setMinOfferBonus}
  ///         of 0 still disables the floor.
  uint16 public constant DEFAULT_MIN_OFFER_BONUS_BPS = 100;

  /// @notice Upper bound for a collateral's minimum offer bonus (1000 = 10%): a sanity ceiling so
  ///         the owner cannot demand a floor no realistic offer could clear.
  /// @dev The de-risking check caps any fill's bonus at `(1 - LTV) / LTV` of the debt value, so a
  ///      floor near this ceiling can make the band unusable at high LTV until the owner lowers
  ///      it again (the setter is instant). See docs/borrow.md#liquidation-offers.
  uint16 public constant MAX_MIN_OFFER_BONUS_BPS = 1_000;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Offer configuration of one collateral token (single packed slot).
  /// @param offerTimelock The collateral's stored timelock; 0 means never explicitly configured.
  ///        Reads are floored to `MIN_OFFER_TIMELOCK`, so the stored zero is never observable.
  /// @param pendingTimelock The scheduled next value (meaningful only when `pendingTimelockAt` is
  ///        non-zero).
  /// @param pendingTimelockAt When `pendingTimelock` becomes effective; 0 means no pending change.
  /// @param minOfferBonusBpsPlusOne The collateral's minimum offer bonus, stored biased by one so
  ///        the never-set state is distinguishable from an explicit disable: 0 means never set
  ///        (reads `DEFAULT_MIN_OFFER_BONUS_BPS`); any other value reads `value - 1` (so an
  ///        explicit 0, stored as 1, disables the floor).
  struct OfferConfig {
    uint40 offerTimelock;
    uint40 pendingTimelock;
    uint40 pendingTimelockAt;
    uint16 minOfferBonusBpsPlusOne;
  }

  /// @notice Storage struct for the registry: the per-collateral offer configurations.
  /// @dev Uses ERC-7201 namespaced storage: the registry lives behind an ERC1967 proxy, and the
  ///      namespace keeps this state clear of the Solady owner/role slots and the `Initializable`
  ///      slot across upgrades.
  struct RegistryStorage {
    mapping(address collateral => OfferConfig config) configs;
  }

  /// @dev Storage slot for the registry's storage struct.
  ///      Computed as: keccak256(abi.encode(uint256(keccak256("borrow.offers.registry")) - 1)) & ~bytes32(uint256(0xff))
  ///      This follows the ERC-7201 namespaced storage pattern to prevent storage collisions.
  bytes32 private constant _REGISTRY_STORAGE_SLOT = 0x9e4b7ef77535fc667096f8e3df2c35603425271af7ec94b458b5318a5b1c5500;

  /// @dev Returns a reference to the registry's storage struct.
  function _registryStorage() internal pure returns (RegistryStorage storage registryStorage) {
    assembly ("memory-safe") {
      registryStorage.slot := _REGISTRY_STORAGE_SLOT
    }
  }

  constructor() {
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the registry with its owner.
  /// @dev Collaterals need no seeding: an unconfigured collateral reads the fail-safe defaults
  ///      (see the configuration-bound constants above).
  /// @param owner_ The registry owner (governance); manages roles and configuration, transferable
  ///        with Solady's built-in two-step handover.
  function initialize(address owner_) external initializer {
    owner_.checkNotZero();
    _initializeOwner(owner_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowOffersRegistry
  /// @dev Toggles the proposer bit via Solady `_updateRoles`; the owner also retains native
  ///      `grantRoles`/`revokeRoles`.
  function setProposer(address account, bool enabled) external override onlyOwner {
    account.checkNotZero();
    _updateRoles(account, PROPOSER_ROLE, enabled);
  }

  /// @inheritdoc IBorrowOffersRegistry
  /// @dev Toggles the guardian bit via Solady `_updateRoles`.
  function setGuardian(address account, bool enabled) external override onlyOwner {
    account.checkNotZero();
    _updateRoles(account, GUARDIAN_ROLE, enabled);
  }

  /// @inheritdoc IBorrowOffersRegistry
  function checkCanCreateOffer(address account) external view override {
    _checkHasRolesOrOwner(account, PROPOSER_ROLE);
  }

  /// @inheritdoc IBorrowOffersRegistry
  function checkCanRevokeOffer(address account) external view override {
    _checkHasRolesOrOwner(account, GUARDIAN_ROLE);
  }

  /// @dev Reverts with Solady's `Unauthorized` unless `account` holds any of `roles` or is the
  ///      registry owner. The account-parameterized sibling of Solady's `_checkOwnerOrRoles`
  ///      (which only checks `msg.sender`): positions forward their callers here.
  function _checkHasRolesOrOwner(address account, uint256 roles) internal view {
    if (!hasAnyRole(account, roles) && account != owner()) revert Unauthorized();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CONFIGURATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowOffersRegistry
  /// @dev The change lands only after the collateral's *current* effective timelock elapses,
  ///      re-based on each call, so a reduction can never be accelerated (ratcheting the timelock
  ///      down over sequential steps is possible but each step costs at least the current
  ///      timelock and is monitorable). Bounded to `[MIN_OFFER_TIMELOCK, MAX_OFFER_TIMELOCK]`.
  ///      See docs/borrow.md#liquidation-offers.
  function setOfferTimelock(address collateral, uint40 timelock) external override onlyOwner {
    collateral.checkNotZero();
    if (timelock < MIN_OFFER_TIMELOCK || timelock > MAX_OFFER_TIMELOCK) {
      revert LibBorrowErrors.OfferTimelockOutOfRange();
    }
    OfferConfig storage config = _registryStorage().configs[collateral];
    uint40 currentTimelock = _floorTimelock(_promoteTimelock(config));
    uint40 effectiveAt = uint40(block.timestamp + currentTimelock);
    config.pendingTimelock = timelock;
    config.pendingTimelockAt = effectiveAt;
    emit OfferTimelockScheduled(collateral, timelock, effectiveAt);
  }

  /// @inheritdoc IBorrowOffersRegistry
  /// @dev Stored biased by one (see {OfferConfig.minOfferBonusBpsPlusOne}). The bias cannot
  ///      overflow: the bound is checked first and `MAX_MIN_OFFER_BONUS_BPS + 1` fits `uint16`.
  function setMinOfferBonus(address collateral, uint16 minOfferBonusBps) external override onlyOwner {
    collateral.checkNotZero();
    if (minOfferBonusBps > MAX_MIN_OFFER_BONUS_BPS) revert LibBorrowErrors.MinOfferBonusOutOfRange();
    _registryStorage().configs[collateral].minOfferBonusBpsPlusOne = minOfferBonusBps + 1;
    emit MinOfferBonusSet(collateral, minOfferBonusBps);
  }

  /// @dev Promotes a due pending timelock into `offerTimelock` (clearing the pending slots) and
  ///      returns the now-effective stored timelock (unfloored). Called by {setOfferTimelock} so
  ///      a scheduled change lands lazily on the next write; the views compute the promotion
  ///      without writing.
  function _promoteTimelock(OfferConfig storage config) internal returns (uint40 timelock) {
    if (config.pendingTimelockAt != 0 && block.timestamp >= config.pendingTimelockAt) {
      timelock = config.pendingTimelock;
      config.offerTimelock = timelock;
      config.pendingTimelock = 0;
      config.pendingTimelockAt = 0;
    } else {
      timelock = config.offerTimelock;
    }
  }

  /// @dev Floors a stored timelock to `MIN_OFFER_TIMELOCK`: a never-configured collateral stores
  ///      zero, and flooring makes that zero unobservable everywhere (the offer band is open by
  ///      default).
  function _floorTimelock(uint40 timelock) internal pure returns (uint40) {
    return timelock < MIN_OFFER_TIMELOCK ? MIN_OFFER_TIMELOCK : timelock;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IBorrowOffersRegistry
  /// @dev Promotes a due pending timelock in the computation only (no write); a scheduled change
  ///      is therefore observed by every reader the moment it falls due, even before the next
  ///      {setOfferTimelock} persists it. The result is floored to `MIN_OFFER_TIMELOCK`, so a
  ///      never-configured collateral reads the minimum veto window (never zero).
  function offerConfig(address collateral)
    external
    view
    override
    returns (uint40 offerTimelock, uint16 minOfferBonusBps)
  {
    OfferConfig storage config = _registryStorage().configs[collateral];
    offerTimelock = _floorTimelock(
      (config.pendingTimelockAt != 0 && block.timestamp >= config.pendingTimelockAt)
        ? config.pendingTimelock
        : config.offerTimelock
    );
    uint16 storedBonus = config.minOfferBonusBpsPlusOne;
    minOfferBonusBps = storedBonus == 0 ? DEFAULT_MIN_OFFER_BONUS_BPS : storedBonus - 1;
  }

  /// @inheritdoc IBorrowOffersRegistry
  /// @dev A due-but-not-yet-promoted change reads as no pending change (see the interface note).
  function pendingOfferTimelock(address collateral) external view override returns (uint40 value, uint40 effectiveAt) {
    OfferConfig storage config = _registryStorage().configs[collateral];
    if (config.pendingTimelockAt == 0 || block.timestamp >= config.pendingTimelockAt) return (0, 0);
    return (config.pendingTimelock, config.pendingTimelockAt);
  }
}
