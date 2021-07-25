// SPDX-License-Identifier: MIT
pragma solidity 0.6.8;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./Splitter.sol";

/**
 * @notice Deploys splitter contracts as EIP-1167 minimal proxies
 */
contract SplitterFactory {
  using Clones for address;

  /// @notice Splitter implementation contract. Each factory is a minimal proxy that delegates to this contract
  address public immutable implementation;

  /// @notice Address of the Auction House used in the Splitter
  address public immutable auctionHouse;

  /// @notice Emitted when a new Splitter is created
  event SplitterCreated(address splitter, bytes32 merkleRoot, address indexed auctionCurrency, address indexed owner);

  /**
   * @param _implementation Splitter implementation contract
   * @param _auctionHouse Auction house contract
   */
  constructor(address _implementation, address _auctionHouse) public {
    implementation = _implementation;
    auctionHouse = _auctionHouse;
  }

  /**
   * @notice Creates a new splitter contract
   * @param _merkleRoot Merkle root for the desired payout structure
   * @param _auctionCurrency Token address to use for the auction. Use the zero address for ETH
   * @param _owner Owner of the splitter contract with authorization to call auction-related methods
   * @return Address of the new Splitter contract
   */
  function createSplitter(bytes32 _merkleRoot, address _auctionCurrency, address _owner) external returns (address) {
    // Deploy new splitter instance as an EIP-1167 minimal proxy, using CREATE2 for deterministic addresses
    address _splitter = implementation.cloneDeterministic(_merkleRoot); // salt is merkleRoot -- can't have two splitter's with exact same distribution

    // Initalize the splitter (constructors are not run for minimal proxies, so we use an initialize method)
    Splitter(payable(_splitter)).initialize(_merkleRoot, _auctionCurrency, _owner, auctionHouse);

    // Emit event with splitter address and return the address
    emit SplitterCreated(_splitter, _merkleRoot, _auctionCurrency, _owner);
    return _splitter;
  }

  /**
   * @notice Given a `_merkleRoot`, returns the address of that splitter contract
   */
   function getSplitterAddress(bytes32 _merkleRoot) external view returns (address) {
    return implementation.predictDeterministicAddress(_merkleRoot);
  }
}