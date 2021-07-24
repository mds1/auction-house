// SPDX-License-Identifier: MIT
pragma solidity 0.6.8;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Splitter } from "./Splitter.sol";

contract SplitterFactory {
  using Clones for address;

  /// @notice Splitter implementation contract. Each factory is a minimal proxy that delegates to this contract
  address public immutable implementation;

  /// @notice Emitted when a new Splitter is created
  event SplitterCreated(address splitter, bytes32 merkleRoot, address indexed token, address indexed owner);

  constructor(address _implementation) public {
    implementation = _implementation;
  }

  function createSplitter(bytes32 _merkleRoot, address _token, address _owner) external returns (address) {
    // Deploy new splitter instance as an EIP-1167 minimal proxy, using CREATE2 for deterministic addresses
    address _splitter = implementation.cloneDeterministic(_merkleRoot); // salt is merkleRoot -- can't have two splitter's with exact same distribution

    // Initalize the splitter (constructors are not run for minimal proxies, so we use an initialize method)
    Splitter(_splitter).initialize(_merkleRoot, _token, _owner);

    // Emit event with splitter address and return the address
    emit SplitterCreated(_splitter, _merkleRoot, _token, _owner);
    return _splitter;
  }

  function getSplitterAddress(bytes32 _merkleRoot) external view returns (address) {
    return implementation.predictDeterministicAddress(_merkleRoot);
  }
}