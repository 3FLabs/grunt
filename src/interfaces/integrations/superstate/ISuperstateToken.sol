// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IERC20} from "../IERC20.sol";

interface ISuperstateToken is IERC20 {
  // V1 remaining

  /// @dev Event emitted when tokens are minted
  event Mint(address indexed minter, address indexed to, uint256 amount);

  /// @dev Emitted when the accounting pause is triggered by `admin`.
  event AccountingPaused(address admin);

  /// @dev Emitted when the accounting pause is lifted by `admin`.
  event AccountingUnpaused(address admin);

  /// @dev Thrown when a request is not sent by the authorized admin
  error Unauthorized();

  /// @dev Thrown when an address does not have sufficient permissions, as dictated by the Allowlist
  error InsufficientPermissions();

  /// @dev Thrown when the current timestamp has surpassed the expiration time for a signature
  error SignatureExpired();

  /// @dev Thrown if the signature has an S value that is in the upper half order.
  error InvalidSignatureS();

  /// @dev Thrown if the signature is invalid or its signer does not match the expected singer
  error BadSignatory();

  /// @dev Thrown if accounting pause is already on
  error AccountingIsPaused();

  /// @dev Thrown if accounting pause is already off
  error AccountingIsNotPaused();

  /// @dev Thrown if array length arguments aren't equal
  error InvalidArgumentLengths();

  /// @dev Thrown if `to` does not share the same `entityId` as `msg.sender` during subscribe
  error MismatchEntityIds();

  /**
   * @notice Returns the domain separator used in the encoding of the
   * signature for permit
   * @return bytes32 The domain separator
   */
  function DOMAIN_SEPARATOR() external view returns (bytes32);

  /// @notice The next expected nonce for an address, for validating authorizations via signature
  function nonces(address toFind) external view returns (uint256);

  /**
   * @notice Invokes the {Pausable-_pause} internal function
   * @dev Can only be called by the admin
   */
  function pause() external;

  /**
   * @notice Invokes the {Pausable-_unpause} internal function
   * @dev Can only be called by the admin
   */
  function unpause() external;

  /**
   * @return bool True if the accounting is currently paused, false otherwise
   */
  function accountingPaused() external view returns (bool);

  /**
   * @notice Pauses mint and burn
   * @dev Can only be called by the admin
   */
  function accountingPause() external;

  /**
   * @notice Unpauses mint and burn
   * @dev Can only be called by the admin
   */
  function accountingUnpause() external;

  /**
   * @notice Sets approval amount for a spender via signature from signatory
   * @param owner The address that signed the signature
   * @param spender The address to authorize (or rescind authorization from)
   * @param value Amount that `owner` is approving for `spender`
   * @param deadline Expiration time for the signature
   * @param v The recovery byte of the signature
   * @param r Half of the ECDSA signature pair
   * @param s Half of the ECDSA signature pair
   */
  function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    external;

  /**
   * @notice Mint new tokens to a recipient
   * @dev Only callable by the admin
   * @param dst Recipient of the minted tokens
   * @param amount Amount of tokens to mint
   */
  function mint(address dst, uint256 amount) external;

  /**
   * @notice Mint new tokens to many recipients
   * @dev Only callable by the admin
   * @param dsts Recipients of the minted tokens
   * @param amounts Amounts of tokens to mint
   */
  function bulkMint(address[] calldata dsts, uint256[] calldata amounts) external;

  /**
   * @notice Initialize the contract
   * @param _name The token name
   * @param _symbol The token symbol
   */
  function initialize(string calldata _name, string calldata _symbol) external;

  // V2 remaining

  /// @dev Thrown if an attempt to call `renounceOwnership` is made
  error RenounceOwnershipDisabled();

  /**
   * @notice Initialize version 2 of the contract.
   * @notice If creating an entirely new contract, the original `initialize` method still needs to be called.
   */
  function initializeV2() external;

  // V3 remaining

  /// @dev Struct for storing supported stablecoin configuration
  struct StablecoinConfig {
    address sweepDestination;
    uint96 fee;
  }

  /// @dev Emitted when the max oracle delay is set
  event SetMaximumOracleDelay(uint256 oldMaxOracleDelay, uint256 newMaxOracleDelay);

  /// @dev Event emitted when the address for the pricing oracle changes
  event SetOracle(address oldOracle, address newOracle);

  /// @dev Event emitted when the configuration for a supported stablecoin changes
  event SetStablecoinConfig(
    address indexed stablecoin, address oldSweepDestination, address newSweepDestination, uint96 oldFee, uint96 newFee
  );

  /// @dev Event emitted when stablecoins are used to Subscribe to a Superstate fund
  /// @param subscriber The address of the subscriber
  /// @param to The address of the recipient
  /// @param stablecoin The address of the stablecoin used to subscribe
  /// @param stablecoinInAmountAfterFee The amount of stablecoin used to subscribe, after fees are deducted
  /// @param stablecoinInAmountBeforeFee The amount of stablecoin used to subscribe, before fees are deducted
  /// @param superstateTokenOutAmount The amount of Superstate tokens received
  event SubscribeV2(
    address indexed subscriber,
    address indexed to,
    address stablecoin,
    uint256 stablecoinInAmountAfterFee,
    uint256 stablecoinInAmountBeforeFee,
    uint256 superstateTokenOutAmount
  );

  /// @dev Thrown when an argument is invalid
  error BadArgs();

  /// @dev Thrown when Chainlink Oracle data is bad
  error BadChainlinkData();

  /// @dev Thrown when owner tries to set the fee for a stablecoin too high
  error FeeTooHigh();

  /// @dev Thrown when the superstateUstbOracle is the 0 address
  error OnchainSubscriptionsDisabled();

  /// @dev Thrown when trying to calculate amount of Superstate Tokens you'd get for an unsupported stablecoin
  error StablecoinNotSupported();

  /// @dev Thrown when the msg.sender would receive 0 Superstate tokens out for their call to subscribe, or trying to bridge 0 tokens
  error ZeroSuperstateTokensOut();

  function allowlistV2() external view returns (address);

  /**
   * @notice Initialize version 3 of the contract
   * @notice If creating an entirely new contract, the original `initialize` method still needs to be called.
   */
  function initializeV3(address _allowlist) external;

  // V4

  /// @dev Event emitted when the admin burns tokens
  event AdminBurn(address indexed burner, address indexed src, uint256 amount);

  /// @dev Event emitted when the user wants to bridge their tokens to another chain or book entry
  event Bridge(
    address caller,
    address indexed src,
    uint256 amount,
    address indexed ethDestinationAddress,
    string otherDestinationAddress,
    uint256 chainId
  );

  /// @dev Event emitted when the users wants to redeem their shares with an offchain payout
  event OffchainRedeem(address indexed burner, address indexed src, uint256 amount);

  /// @dev Event emitted when the owner changes the redemption contract address
  event SetRedemptionContract(address oldRedemptionContract, address newRedemptionContract);

  /// @notice Emitted when a chain ID's support status is updated
  event SetChainIdSupport(uint256 indexed chainId, bool oldSupported, bool newSupported);

  /// @dev Thrown when bridge function arguments have two destinations
  error TwoDestinationsInvalid();

  /// @dev Thrown when bridge function chainId is set to 0 but onchain destination arguments are provided
  error OnchainDestinationSetForBridgeToBookEntry();

  /// @dev Thrown when bridge function chainId is not supported
  error BridgeChainIdDestinationNotSupported();

  /**
   * @notice Check permissions of an address for transferring
   * @param addr Address to check permissions for
   * @return bool True if the address has sufficient permission, false otherwise
   */
  function isAllowed(address addr) external view returns (bool);

  /**
   * @notice Burn tokens from a given source address
   * @dev Only callable by the admin
   * @param src Source address from which tokens will be burned
   * @param amount Amount of tokens to burn
   */
  function adminBurn(address src, uint256 amount) external;

  /**
   * @notice Burn tokens from the caller's address for offchain redemption
   * @param amount Amount of tokens to burn
   */
  function offchainRedeem(uint256 amount) external;

  /**
   * @notice Burn tokens from the caller's address to bridge to another chain
   * @dev If destination address on chainId isn't on allowlist, or chainID isn't supported, tokens wind up in book entry
   * @param amount Amount of tokens to burn
   * @param ethDestinationAddress ETH address to send to on another chain
   * @param otherDestinationAddress Non-EVM addresses to send to on another chain
   * @param chainId Numerical identifier of destination chain to send tokens to
   */
  function bridge(
    uint256 amount,
    address ethDestinationAddress,
    string calldata otherDestinationAddress,
    uint256 chainId
  ) external;

  /**
   * @notice Burn tokens from the caller's address to bridge to Superstate book entry
   * @param amount Amount of tokens to burn
   */
  function bridgeToBookEntry(uint256 amount) external;

  /**
   * @notice Sets redemption contract address
   * @dev Used for convenience for devs
   * @dev Set to address(0) if no such contract exists for the token
   * @param _newRedemptionContract New contract address
   */
  function setRedemptionContract(address _newRedemptionContract) external;

  /**
   * @notice Sets support status for a specific chain ID
   * @param _chainId The chain ID to update
   * @param _supported Whether the chain ID should be supported
   */
  function setChainIdSupport(uint256 _chainId, bool _supported) external;

  /**
   * @notice The ```subscribe`` function takes in stablecoins and mints SuperstateToken in the proper amount for the to address depending on the current Net Asset Value per Share.
   * @param to The address where USTB will be deposited at
   * @param inAmount The amount of the stablecoin in
   * @param stablecoin The address of the stablecoin to calculate with
   */
  function subscribe(address to, uint256 inAmount, address stablecoin) external;

  /**
   * @notice The ```subscribe``` function takes in stablecoins and mints SuperstateToken in the proper amount for the msg.sender depending on the current Net Asset Value per Share.
   * @param inAmount The amount of the stablecoin in
   * @param stablecoin The address of the stablecoin to calculate with
   */
  function subscribe(uint256 inAmount, address stablecoin) external;

  /**
   * @notice The ```setOracle``` function sets the address of the AggregatorV3Interface to be used to price the SuperstateToken
   * @dev Requires msg.sender to be the owner address
   * @param _newOracle The address of the oracle contract to update to
   */
  function setOracle(address _newOracle) external;

  /**
   * @notice The ```setMaximumOracleDelay``` function sets the max oracle delay to determine if Chainlink data is stale
   * @dev Requires msg.sender to be the owner address
   * @param _newMaxOracleDelay The new max oracle delay
   */
  function setMaximumOracleDelay(uint256 _newMaxOracleDelay) external;

  /**
   * @notice The ```setStablecoinConfig``` function sets the configuration fields for accepted stablecoins for onchain subscriptions
   * @dev Requires msg.sender to be the owner address
   * @param stablecoin The address of the stablecoin
   * @param newSweepDestination The new address to sweep stablecoin subscriptions to
   * @param newFee The new fee in basis points to charge for subscriptions in ```stablecoin```
   */
  function setStablecoinConfig(address stablecoin, address newSweepDestination, uint96 newFee) external;

  /**
   * @notice The ```getChainlinkPrice``` function returns the chainlink price and the timestamp of the last update
   * @return _isBadData True if the data is stale or negative
   * @return _updatedAt The timestamp of the last update
   * @return _price The price
   */
  function getChainlinkPrice() external view returns (bool _isBadData, uint256 _updatedAt, uint256 _price);

  /**
   * @notice Calculates the fee amount based on the input amount and subscription fee
   * @param amount The input amount to calculate fee for
   * @param subscriptionFee The fee rate to apply
   * @return The calculated fee amount
   */
  function calculateFee(uint256 amount, uint256 subscriptionFee) external pure returns (uint256);

  /**
   * @notice The ```calculateSuperstateTokenOut``` function calculates the total amount of Superstate tokens you'll receive for the inAmount of stablecoin. Treats all stablecoins as if they are always worth a dollar.
   * @param inAmount The amount of the stablecoin in
   * @param stablecoin The address of the stablecoin to calculate with
   * @return superstateTokenOutAmount The amount of Superstate tokens received for inAmount of stablecoin
   * @return stablecoinInAmountAfterFee The amount of stablecoin in after any fees
   * @return feeOnStablecoinInAmount The amount of the stablecoin taken in fees
   */
  function calculateSuperstateTokenOut(uint256 inAmount, address stablecoin)
    external
    view
    returns (uint256 superstateTokenOutAmount, uint256 stablecoinInAmountAfterFee, uint256 feeOnStablecoinInAmount);
}
