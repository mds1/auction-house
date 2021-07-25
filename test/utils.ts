import { ethers } from "hardhat";
import {
  MarketFactory,
  Media,
  MediaFactory,
} from "@zoralabs/core/dist/typechain";
import {
  BadBidder,
  AuctionHouse,
  WETH,
  BadERC721,
  TestERC721,
  SplitterFactory,
  Splitter,
} from "../typechain";
import { sha256 } from "ethers/lib/utils";
import Decimal from "../utils/Decimal";
import { BigNumber } from "ethers";

const { hexlify, hexZeroPad, randomBytes } = ethers.utils;

export const { AddressZero } = ethers.constants;
export const AddressOne = '0x0000000000000000000000000000000000000001';
export const AddressEth = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';
export const merkleRootZero = hexZeroPad('0x0', 32); // 32 bytes of zeros
export const THOUSANDTH_ETH = ethers.utils.parseUnits(
  "0.001",
  "ether"
) as BigNumber;
export const TENTH_ETH = ethers.utils.parseUnits("0.1", "ether") as BigNumber;
export const ONE_ETH = ethers.utils.parseUnits("1", "ether") as BigNumber;
export const TWO_ETH = ethers.utils.parseUnits("2", "ether") as BigNumber;

export const deployWETH = async () => {
  const [deployer] = await ethers.getSigners();
  return (await (await ethers.getContractFactory("WETH")).deploy()) as WETH;
};

export const deployOtherNFTs = async () => {
  const bad = (await (
    await ethers.getContractFactory("BadERC721")
  ).deploy()) as BadERC721;
  const test = (await (
    await ethers.getContractFactory("TestERC721")
  ).deploy()) as TestERC721;

  return { bad, test };
};

export const deployZoraProtocol = async () => {
  const [deployer] = await ethers.getSigners();
  const market = await (await new MarketFactory(deployer).deploy()).deployed();
  const media = await (
    await new MediaFactory(deployer).deploy(market.address)
  ).deployed();
  await market.configure(media.address);
  return { market, media };
};

export const deploySplitter = async ({
  factory,
  merkleRoot,
  auctionCurrency,
  owner,
  auctionHouse
}: {
  factory?: SplitterFactory;
  merkleRoot?: string;
  auctionCurrency?: string;
  owner?: string;
  auctionHouse?: string;
}) => {
  // Set defaults for Splitter
  merkleRoot = merkleRoot || hexlify(randomBytes(32)); // random 32 byte merkle root if not provided
  auctionCurrency = auctionCurrency || AddressEth; // use ETH if not specified
  owner = owner || AddressZero; // set owner to zero address if not provided
  auctionHouse = auctionHouse || AddressZero; // set auctionHouse to zero address if not provided

  // Deploy factory if required
  if (!factory) {
    // Deploy Splitter implementation
    const implementation = (await (await ethers.getContractFactory("Splitter")).deploy()) as Splitter;
    
    // Initialize implementation with dummy data
    // WARNING: Make sure token address is not all zeros, as all zeroes indicates an uninitialized Splitter
    await implementation.initialize(merkleRootZero, AddressOne, AddressZero, AddressZero);
    
    // Deploy SplitterFactory
    const addr = implementation.address;
    factory = (await (await ethers.getContractFactory("SplitterFactory")).deploy(addr)) as SplitterFactory;
  }

  // Deploy splitter
  const tx = await factory.createSplitter(merkleRoot, AddressEth, owner);

  // Parse logs for the address of the new Splitter
  const receipt = await ethers.provider.getTransactionReceipt(tx.hash);
  const log = factory.interface.parseLog(receipt.logs[0]);
  const { splitter: splitterAddress } = log.args;

  // Return contracts
  const splitter = await ethers.getContractAt('Splitter', splitterAddress) as Splitter;
  return { splitter, factory, tx, merkleRoot };
};

export const deployBidder = async (auction: string, nftContract: string) => {
  return (await (
    await (await ethers.getContractFactory("BadBidder")).deploy(
      auction,
      nftContract
    )
  ).deployed()) as BadBidder;
};

export const mint = async (media: Media) => {
  const metadataHex = ethers.utils.formatBytes32String("{}");
  const metadataHash = await sha256(metadataHex);
  const hash = ethers.utils.arrayify(metadataHash);
  await media.mint(
    {
      tokenURI: "zora.co",
      metadataURI: "zora.co",
      contentHash: hash,
      metadataHash: hash,
    },
    {
      prevOwner: Decimal.new(0),
      owner: Decimal.new(85),
      creator: Decimal.new(15),
    }
  );
};

export const approveAuction = async (
  media: Media,
  auctionHouse: AuctionHouse
) => {
  await media.approve(auctionHouse.address, 0);
};

export const revert = (messages: TemplateStringsArray) =>
  `VM Exception while processing transaction: reverted with reason string '${messages[0]}'`;
