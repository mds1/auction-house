import { ethers } from "hardhat";
import { BigNumberish } from "ethers";
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import chai, { expect } from "chai";
import asPromised from "chai-as-promised";
import { SplitterFactory, Splitter } from "../typechain";
import { SplitTree } from "../utils/split-tree";

chai.use(asPromised);
const { isAddress, hexlify, hexZeroPad, randomBytes } = ethers.utils;
const dummyMerkleRoot = hexZeroPad('0x1', 32); // 32 byte value of 0x0000...00001

describe("SplitterFactory", () => {
  let splitterFactory: SplitterFactory;
  let splitterImplementation: Splitter;

  async function deploySplitter() {
    // Deploy splitter
    const merkleRoot = hexlify(randomBytes(32)); // random 32 byte merkle root
    const tx = await splitterFactory.createSplitter(merkleRoot);

    // Parse logs for the address of the new Splitter
    const receipt = await ethers.provider.getTransactionReceipt(tx.hash);
    const log = splitterFactory.interface.parseLog(receipt.logs[0]);
    const { splitter: splitterAddress } = log.args;

    // Verify Splitter was properly created
    const splitter = await ethers.getContractAt('Splitter', splitterAddress) as Splitter;
    return { merkleRoot, splitter, tx };
  }

  beforeEach(async () => {
    await ethers.provider.send("hardhat_reset", []);
    // Deploy Splitter implementation used by factory
    splitterImplementation= (await (await ethers.getContractFactory("Splitter")).deploy()) as Splitter;

    // Initialize implementation with a dummy merkle root (to prevent use of the implementation contract)
    // WARNING: Do not initialize with a value of all zeros, as all zeroes indicates an uninitialized Splitter
    await splitterImplementation.initialize(dummyMerkleRoot);

    // Deploy SplitterFactory
    const addr = splitterImplementation.address;
    splitterFactory= (await (await ethers.getContractFactory("SplitterFactory")).deploy(addr)) as SplitterFactory;
  });

  describe("#constructor", () => {
    it("should be able to deploy", async () => {
      expect(isAddress(splitterImplementation.address)).to.be.true;
      expect(isAddress(splitterFactory.address)).to.be.true;
    });
  });

  describe("#createSplitter", () => {
    it('should create a new splitter', async () => {
      const { merkleRoot, splitter, tx } = await deploySplitter();
      const expectedAddress = await splitterFactory.getSplitterAddress(merkleRoot);
      expect(tx).to.emit(splitterFactory, 'SplitterCreated').withArgs(expectedAddress);
      expect(await splitter.merkleRoot()).to.equal(merkleRoot);
    });
  });

  describe("#getSplitterAddress", () => {
    it('should compute and return the address of deployed splitters', async () => {
      const { merkleRoot, splitter } = await deploySplitter();
      expect(await splitterFactory.getSplitterAddress(merkleRoot)).to.equal(splitter.address)
    });
  });
});

describe('Splitter', () => {
  let splitter: Splitter;
  let users: SignerWithAddress[];
  let tree: SplitTree;
  let merkleRoot: string;
  let allocations: {account:string; percent: BigNumberish}[];

  beforeEach(async () => {
    await ethers.provider.send("hardhat_reset", []);
    users = await ethers.getSigners();

    // Get Merkle root
    allocations = [{account: users[0].address, percent: '1000000'}];
    tree = new SplitTree(allocations);
    merkleRoot = tree.getHexRoot();

    // Deploy and initialize Splitter from factory
    const splitterImplementation = (await (await ethers.getContractFactory("Splitter")).deploy()) as Splitter;
    await splitterImplementation.initialize(dummyMerkleRoot);
    const addr = splitterImplementation.address;
    const splitterFactory= (await (await ethers.getContractFactory("SplitterFactory")).deploy(addr)) as SplitterFactory;
    await splitterFactory.createSplitter(merkleRoot);
    splitter = await ethers.getContractAt('Splitter', await splitterFactory.getSplitterAddress(merkleRoot)) as Splitter;
  });

  describe("#initialize", () => {
    it('should initialize', async () => {
      expect(await splitter.merkleRoot()).to.equal(merkleRoot);
    });
    
    it('should not allow re-initialization', async () => {
      await expect(splitter.initialize(merkleRoot)).to.be.revertedWith('Already initialized');
    });
  });

  describe("#claim", () => {
    it('should allow users to claim', async () => {
      const { account, percent } = allocations[0]
      const proof = tree.getProof(account, percent);
      await splitter.claim(account, percent, proof);
    });
    
    it('should reject if already claimed', async () => {
      const { account, percent } = allocations[0]
      const proof = tree.getProof(account, percent);
      await splitter.claim(account, percent, proof);
      await expect(splitter.claim(account, percent, proof)).to.be.revertedWith('Already claimed');
    });

    it('should reject claims with invalid proofs', async () => {
      const { account, percent } = allocations[0]
      const proof = tree.getProof(account, percent);
      await expect(splitter.claim(account, '1', proof)).to.be.revertedWith('Invalid proof');
    });
  });
})
