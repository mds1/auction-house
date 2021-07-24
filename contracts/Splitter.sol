// SPDX-License-Identifier: MIT
pragma solidity 0.6.8;

import "@openzeppelin/contracts/cryptography/MerkleProof.sol";
import { IAuctionHouse } from "./interfaces/IAuctionHouse.sol";

contract Splitter {
  bytes32 public merkleRoot;
  uint256 public denominator = 1e6;
  mapping(bytes32 => bool) internal claimed;

  function initialize(bytes32 _merkleRoot) external {
    require(merkleRoot == bytes32(0), "Already initialized");
    merkleRoot = _merkleRoot;
  }

  function claim(address _user, uint256 _percent, bytes32[] calldata _merkleProof) external {
    // Revert if already claimed
    require(!isClaimed(_user), 'Already claimed');

    // Verify proof
    bytes32 _leaf = keccak256(abi.encodePacked(_user, _percent));
    require(MerkleProof.verify(_merkleProof, merkleRoot, _leaf), "Invalid proof");

    // Checks passed. Update claim status and proceed with withdraw
    _setClaimed(_user);
  }

  // --- Claim management ---
  function _getClaimId(address _user) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(_user));
  }
  
  function _setClaimed(address _user) internal returns (bool) {
    return claimed[_getClaimId(_user)] = true;
  }

  function isClaimed(address _user) public view returns (bool) {
    return claimed[_getClaimId(_user)];
  }
}