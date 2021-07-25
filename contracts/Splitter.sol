// SPDX-License-Identifier: MIT
pragma solidity 0.6.8;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IAuctionHouse.sol";

contract Splitter {
  // --- Libraries ---
  using Address for address payable;
  using SafeERC20 for IERC20;

  // --- Data ---
  /// @notice Merkle root used to verify claim proofs
  bytes32 public merkleRoot;

  /// @notice Owner has authority to manage auctions
  address public owner;

  /// @notice Address of the token used for auction, which is also the token received after the auction ends
  address public auctionCurrency;

  /// @notice If `auctionCurrency` is this address, we are using ETH, otherwise it's an ERC20
  address constant internal ETH_ADDRESS = address(0);

  /// @notice Address of the Zora auction house
  IAuctionHouse public auctionHouse;

  /// @notice ID of the auction created by this contract
  uint256 public auctionId;

  /// @notice After auction ends, this represents the amount of funds to split between accounts
  uint256 public auctionProceeds;
  
  /// @notice Percentage amounts in the Merkle tree are stored as integers, where this is their denominator. For
  /// example, if a user has a value of 400,000 in the Merkle tree means, that user is allowed to claim
  // 400,000 / denominator = 400,000 / 1,000,000 = 40% of proceeds
  uint256 constant public denominator = 1e6;

  /// @notice Mapping from the claim ID to the claim status
  mapping(bytes32 => bool) internal claimed;

  /// @notice Used for batch claims
  struct Claim {
    address account;
    uint256 percent;
    bytes32[] merkleProof;
  }

  // --- Events ---
  /// @notice Emitted on claim, where percent is the numerator, so divide by `denominator` to get the true percent
  event Claimed(address account, uint256 percent);

  // --- Modifiers ---
  modifier onlyOwner() {
    require(msg.sender == owner, "Not authorized");
    _;
  }

  // --- Initialization for minimal proxy ---
  function initialize(bytes32 _merkleRoot, address _auctionCurrency, address _owner, address _auctionHouse) external {
    require(merkleRoot == bytes32(0), "Already initialized");
    merkleRoot = _merkleRoot;
    auctionCurrency = _auctionCurrency;
    owner = _owner;
    auctionHouse = IAuctionHouse(_auctionHouse);
  }

  // --- Claim funds ---
  function endAuctionAndClaim(address _account, uint256 _percent, bytes32[] calldata _merkleProof) external {
    endAuction();
    claim(_account, _percent, _merkleProof);
  }

  function claim(address _account, uint256 _percent, bytes32[] memory _merkleProof) public {
    // Revert if already claimed or if there is nothing to split
    require(!isClaimed(_account), "Already claimed");
    require(auctionProceeds > 0, "No funds to claim");

    // Verify proof
    bytes32 _leaf = keccak256(abi.encodePacked(_account, _percent));
    require(MerkleProof.verify(_merkleProof, merkleRoot, _leaf), "Invalid proof");

    // Checks passed. Update claim status and proceed with withdraw
    _setClaimed(_account); // reentrancy guard not required since we change claim status before transferring funds
    transfer(_account, mul(auctionProceeds, _percent) / denominator);
    emit Claimed(_account, _percent);
  }

  function endAuctionAndBatchClaim(Claim[] calldata _claims) external {
    endAuction();

    // We re-implement the functionality of `batchClaim` because we cannot call that methods here, as this version of
    // Solidity does not support passing a calldata array into another method: https://github.com/ethereum/solidity/issues/9160
    for (uint256 i = 0; i < _claims.length; i += 1) {
      claim(_claims[i].account, _claims[i].percent, _claims[i].merkleProof);
    }
  }

  function batchClaim(Claim[] memory _claims) public {
    for (uint256 i = 0; i < _claims.length; i += 1) {
      claim(_claims[i].account, _claims[i].percent, _claims[i].merkleProof);
    }
  }

  // --- Auction management ---
  // To create an auction, the Splitter must own the NFT
  function createAuction(uint256 _tokenId, address _tokenContract, uint256 _duration, uint256 _reservePrice, address payable _curator, uint8 _curatorFeePercentages) external onlyOwner returns (uint256) {
    require(auctionId == 0, "An auction has already been created");
    IERC721(_tokenContract).approve(address(auctionHouse), _tokenId);
    auctionId = auctionHouse.createAuction(_tokenId, _tokenContract, _duration, _reservePrice, _curator, _curatorFeePercentages, auctionCurrency);
    return auctionId;
  }

  function setAuctionApproval(bool _approved) external onlyOwner {
    require(auctionId > 0, "An auction has not been created");
    auctionHouse.setAuctionApproval(auctionId, _approved);
  }

  function setAuctionReservePrice(uint256 _reservePrice) external onlyOwner {
    require(auctionId > 0, "An auction has not been created");
    auctionHouse.setAuctionReservePrice(auctionId, _reservePrice);
  }

  function endAuction() public {
    require(auctionId > 0, "An auction has not been created");

    // End auction, which transfers proceeds to this contract
    auctionHouse.endAuction(auctionId);

    // Save off that amount as the amount to split
    if (auctionCurrency == ETH_ADDRESS) {
      auctionProceeds = address(this).balance;
    } else {
      auctionProceeds = IERC20(auctionCurrency).balanceOf(address(this));
    }
  }

  function cancelAuction() external onlyOwner {
    require(auctionId > 0, "An auction has not been created");
    auctionHouse.cancelAuction(auctionId);
  }

  receive() external payable {
    // For receiving ETH after auctions
  }

  // --- NFT management ---
  function transferNft(address _to, uint256 _tokenId, address _tokenContract) external onlyOwner {
    IERC721(_tokenContract).transferFrom(address(this), _to, _tokenId);
  }

  // --- Claim heplers ---
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
    if (auctionCurrency == ETH_ADDRESS) payable(_to).sendValue(_amount);
    else IERC20(auctionCurrency).safeTransfer(_to, _amount);
  }

  function mul(uint x, uint y) internal pure returns (uint z) {
    // From DSMath, which is a bit cheaper than OpenZeppelin's SafeMath
    // https://github.com/dapphub/ds-math/blob/a3c1333371d2c38b41e823081b6d314c40094e68/src/math.sol
    require(y == 0 || (z = x * y) / y == x, "Overflow");
  }
  
}