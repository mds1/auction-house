// SPDX-License-Identifier: MIT
pragma solidity 0.6.8;

import { IAuctionHouse } from "./interfaces/IAuctionHouse.sol";

contract Splitter {
  bytes32 public merkleRoot;

  function initialize(bytes32 _merkleRoot) external {
    require(merkleRoot == bytes32(0), "Already initialized");
    merkleRoot = _merkleRoot;
  }
}