// SPDX-License-Identifier: MIT
pragma solidity 0.6.8;

import "@openzeppelin/contracts/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import { IAuctionHouse } from "./interfaces/IAuctionHouse.sol";

contract Splitter {
  using Address for address payable;
  using SafeERC20 for IERC20;

  bytes32 public merkleRoot;
  IERC20 public token; // token this contract will track claims for
  uint256 public denominator = 1e6;
  
  address internal ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  mapping(bytes32 => bool) internal claimed;

  event Claimed(address account, uint256 amount);

  function initialize(bytes32 _merkleRoot, address _token) external {
    require(address(token) == address(0), "Already initialized");
    token = IERC20(_token);
    merkleRoot = _merkleRoot;
  }

  function claim(address _account, uint256 _percent, bytes32[] calldata _merkleProof) external {
    // Revert if already claimed
    require(!isClaimed(_account), 'Already claimed');

    // Verify proof
    bytes32 _leaf = keccak256(abi.encodePacked(_account, _percent));
    require(MerkleProof.verify(_merkleProof, merkleRoot, _leaf), "Invalid proof");

    // Checks passed. Update claim status and proceed with withdraw
    _setClaimed(_account); // reentrancy guard not required since we change claim status before transerring funds
    uint256 _amount = 0; // hardcoded to zero for now
    transfer(_account, _amount);
    emit Claimed(_account, _amount);
  }

  // --- Claim management ---
  function _getClaimId(address _account) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(_account));
  }
  
  function _setClaimed(address _account) internal returns (bool) {
    return claimed[_getClaimId(_account)] = true;
  }

  function isClaimed(address _account) public view returns (bool) {
    return claimed[_getClaimId(_account)];
  }

  function transfer(address _to, uint256 _amount) internal {
    if (address(token) == ETH_ADDRESS) payable(_to).sendValue(_amount);
    else token.safeTransfer(_to, _amount);
  }
  
}