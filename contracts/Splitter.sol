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

  /// @notice Mapping from a user's address to their claim status
  mapping(address => bool) internal claimed;

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
  /**
   * @notice Initializes the Splitter
   * @dev Used in place of the constructor, since constructors do not run during EIP-1167 proxy creation
   * @param _merkleRoot Merkle root for the desired payout structure
   * @param _auctionCurrency Token address to use for the auction. Use the zero address for ETH
   * @param _owner Owner of the splitter contract with authorization to call auction-related methods
   * @param _auctionHouse Address of the auction house
   */
  function initialize(
    bytes32 _merkleRoot,
    address _auctionCurrency,
    address _owner,
    address _auctionHouse
  ) external {
    require(merkleRoot == bytes32(0), "Already initialized");
    merkleRoot = _merkleRoot;
    auctionCurrency = _auctionCurrency;
    owner = _owner;
    auctionHouse = IAuctionHouse(_auctionHouse);
  }

  // --- Claim funds ---
  /**
   * @notice Enables a user to claim funds they are owed
   * @param _account Address to claim funds for
   * @param _percent Percent of total funds this address is owed
   * @param _merkleProof Proof that the `_account` is owend `_percent` of the funds
   */
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

  /**
   * @notice Enables batch claiming of funds for multiple users
   * @dev Takes an array of claims. See `claim` comments for info on each parameter in the struct of the `_claims` array
   */
  function batchClaim(Claim[] memory _claims) public {
    for (uint256 i = 0; i < _claims.length; i += 1) {
      claim(_claims[i].account, _claims[i].percent, _claims[i].merkleProof);
    }
  }

  // --- Auction management ---
  /**
   * @notice Create a new auction from this Splitter. To create an auction, the Splitter must own the NFT
   * @dev See AuctionHouse documentation for details on each input
   * @dev `auctionCurrency` is not an input as the Splitter contract has this value in storage
   */
  function createAuction(
    uint256 _tokenId,
    address _tokenContract,
    uint256 _duration,
    uint256 _reservePrice,
    address payable _curator,
    uint8 _curatorFeePercentages
  ) external onlyOwner returns (uint256) {
    require(auctionId == 0, "An auction has already been created");
    IERC721(_tokenContract).approve(address(auctionHouse), _tokenId);
    auctionId = auctionHouse.createAuction(_tokenId, _tokenContract, _duration, _reservePrice, _curator, _curatorFeePercentages, auctionCurrency);
    return auctionId;
  }

  /**
   * @notice Approve an auction, opening up the auction for bids.
   * @dev Only callable by the curator. Cannot be called if the auction has already started.
   */
  function setAuctionApproval(bool _approved) external onlyOwner {
    auctionHouse.setAuctionApproval(auctionId, _approved);
  }

  /**
   * @notice Sets the reserve price of the auction
   * @dev Only callable by the curator or the token owner
   */
  function setAuctionReservePrice(uint256 _reservePrice) external onlyOwner {
    auctionHouse.setAuctionReservePrice(auctionId, _reservePrice);
  }

  /**
   * @notice Calls the AuctionHouse to end the auction, and saves off the value of the proceeds earned from the auction
   */
  function endAuctionOnAuctionHouse() public {
    // End auction, which transfers proceeds to this contract
    auctionHouse.endAuction(auctionId);

    // Save off that amount as the amount to split
    _saveProceeds();
  }

  /**
   * @notice Assumes the auction has ended and saves off the value of the proceeds earned from the auction
   * @dev Use this if someone has already called endAuction on the AuctionHouse
   * @dev WARNING: This method has no check that endAuction was already on the AuctionHouse, so do not use this method
   * unless you are certain the auction has ended
   */
  function endAuction() public onlyOwner {
    // Use this if the auction house has already marked the auction as ended
    require(auctionProceeds == 0, "Already ended");
    _saveProceeds();
  }

  /**
   * @dev Saves the proceeds value in storage, which is used for computing claim amounts
   */
  function _saveProceeds() internal {
    // Save off amount to split
    if (auctionCurrency == ETH_ADDRESS) {
      auctionProceeds = address(this).balance;
    } else {
      auctionProceeds = IERC20(auctionCurrency).balanceOf(address(this));
    }
  }

  /**
   * @notice Cancel an auction.
   * @dev Only callable by the curator or the token owner
   */
  function cancelAuction() external onlyOwner {
    require(auctionId > 0, "An auction has not been created");
    auctionHouse.cancelAuction(auctionId);
  }

  /**
   * @notice Allows the owner to transfer an NFT back to the original owner
   * @param _to Address to send token to
   * @param _tokenId The token ID
   * @param _tokenContract Address of the token contract
   */
  function transferNft(address _to, uint256 _tokenId, address _tokenContract) external onlyOwner {
    IERC721(_tokenContract).transferFrom(address(this), _to, _tokenId);
  }

  receive() external payable {
    // For receiving ETH after auctions
  }

  // --- Claim heplers ---
  /**
   * @dev Sets claim status to true once `_account` has claimed their funds
   */
  function _setClaimed(address _account) internal returns (bool) {
    return claimed[_account] = true;
  }

  /**
   * @notice Returns true if `_account` has claimed their funds, false otherwise
   */
   function isClaimed(address _account) public view returns (bool) {
    return claimed[_account];
  }

  /**
   * @dev Transfer helper for transferring ETH and ERC0s to the user
   */
  function transfer(address _to, uint256 _amount) internal {
    if (auctionCurrency == ETH_ADDRESS) payable(_to).sendValue(_amount);
    else IERC20(auctionCurrency).safeTransfer(_to, _amount);
  }

  /**
   * @dev Multiplication that reverts on overflow. From DSMath, which is a bit cheaper than OpenZeppelin's SafeMath
   * @dev https://github.com/dapphub/ds-math/blob/a3c1333371d2c38b41e823081b6d314c40094e68/src/math.sol
   */
  function mul(uint x, uint y) internal pure returns (uint z) {
    require(y == 0 || (z = x * y) / y == x, "Overflow");
  }
}