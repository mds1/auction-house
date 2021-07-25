import { ethers, network } from "hardhat";
import { BigNumber, BigNumberish } from "ethers";
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import chai, { expect } from "chai";
import asPromised from "chai-as-promised";
import { SplitterFactory, Splitter } from "../typechain";
import { SplitTree } from "../utils/split-tree";
import { deployWETH } from "./utils";

chai.use(asPromised);
const { isAddress, hexlify, hexZeroPad, randomBytes, parseEther } = ethers.utils;
const { AddressZero } = ethers.constants;
const AddressOne = '0x0000000000000000000000000000000000000001';
const AddressEth = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';
const merkleRootZero = hexZeroPad('0x0', 32); // 32 bytes of zeros
const to32ByteHex = (x: BigNumberish) => hexZeroPad(BigNumber.from(x).toHexString(), 32);

describe("SplitterFactory", () => {
  let splitterFactory: SplitterFactory;
  let splitterImplementation: Splitter;
  let owner: SignerWithAddress;

  async function deploySplitter() {
    // Deploy splitter
    const merkleRoot = hexlify(randomBytes(32)); // random 32 byte merkle root
    const tx = await splitterFactory.createSplitter(merkleRoot, AddressEth, owner.address);

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
    [owner] = await ethers.getSigners();

    // Deploy Splitter implementation used by factory
    splitterImplementation= (await (await ethers.getContractFactory("Splitter")).deploy()) as Splitter;

    // Initialize implementation with dummy data
    // WARNING: Make sure token address is not all zeros, as all zeroes indicates an uninitialized Splitter
    await splitterImplementation.initialize(merkleRootZero, AddressOne, AddressZero);

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
      expect(tx).to.emit(splitterFactory, 'SplitterCreated').withArgs(expectedAddress, merkleRoot, AddressEth, owner.address);
      expect(await splitter.merkleRoot()).to.equal(merkleRoot);
      expect(await splitter.auctionCurrency()).to.equal(AddressEth);
      expect(await splitter.owner()).to.equal(owner.address);
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
  let owner: SignerWithAddress;
  let accounts: SignerWithAddress[];
  let tree: SplitTree;
  let merkleRoot: string;
  let allocations: { account: string; percent: BigNumberish }[];

  async function fundSplitter() {
    // Used to send proceeds to the splitter contract, i.e. acts as a way to short-circuit the auction process for testing
    const amount = parseEther('1');
    await accounts[accounts.length-1].sendTransaction({ to: splitter.address, value: amount });
    await network.provider.send('hardhat_setStorageAt', [splitter.address, '0x5', to32ByteHex(amount)]);
    return amount;
  }

  beforeEach(async () => {
    await ethers.provider.send("hardhat_reset", []);
    [owner, ...accounts] = await ethers.getSigners();

    // Get Merkle root
    allocations = [ 
      { account: accounts[0].address, percent: '500' }, // 0.05%
      { account: accounts[1].address, percent: '10000' }, // 1%
      { account: accounts[2].address, percent: '25000' }, // 2.5%
      { account: accounts[3].address, percent: '127500' }, // 12.75%
      { account: accounts[4].address, percent: '327000' }, // 32.7%
      { account: accounts[5].address, percent: '510000' }, // 51%
    ];
    tree = new SplitTree(allocations);
    merkleRoot = tree.getHexRoot();

    // Deploy and initialize Splitter from factory
    const splitterImplementation = (await (await ethers.getContractFactory("Splitter")).deploy()) as Splitter;
    await splitterImplementation.initialize(merkleRootZero, AddressOne, AddressZero);
    const addr = splitterImplementation.address;
    const splitterFactory= (await (await ethers.getContractFactory("SplitterFactory")).deploy(addr)) as SplitterFactory;
    await splitterFactory.createSplitter(merkleRoot, AddressEth, owner.address);
    const splitterAddress = await splitterFactory.getSplitterAddress(merkleRoot);
    splitter = await ethers.getContractAt('Splitter', splitterAddress) as Splitter;
  });

  describe("#initialize", () => {
    it('should initialize', async () => {
      expect(await splitter.merkleRoot()).to.equal(merkleRoot);
    });
    
    it('should not allow re-initialization', async () => {
      await expect(splitter.initialize(merkleRoot, AddressEth, owner.address)).to.be.revertedWith('Already initialized');
      await expect(splitter.initialize(merkleRootZero, AddressZero, AddressZero)).to.be.revertedWith('Already initialized');
    });
  });

  describe("#claim", () => {
    async function getBalance(account: string, token: string) {
      if (token === AddressEth) return ethers.provider.getBalance(account);
      const contract = new ethers.Contract(token, ['function balanceOf(address) returns (uint256)']);
      return (await contract.balanceOf(account)) as BigNumber;
    }

    it('should allow users to claim', async () => {
      const auctionProceeds = await fundSplitter();
      const denominator = await splitter.denominator();

      for (const allocation of allocations) {
        const { account, percent } = allocation;
        const initialBalance = await getBalance(account, AddressEth);
        const delta = auctionProceeds.mul(percent).div(denominator)
        const proof = tree.getProof(account, percent);
        await splitter.claim(account, percent, proof);
        expect(await getBalance(account, AddressEth)).to.equal(initialBalance.add(delta));
      }
    });

    it('should reject if already claimed', async () => {
      await fundSplitter();
      const { account, percent } = allocations[0]
      const proof = tree.getProof(account, percent);
      await splitter.claim(account, percent, proof);
      await expect(splitter.claim(account, percent, proof)).to.be.revertedWith('Already claimed');
    });

    it('should reject claims with invalid proofs', async () => {
      await fundSplitter();
      const { account, percent } = allocations[0]
      const proof = tree.getProof(account, percent);
      await expect(splitter.claim(account, '1', proof)).to.be.revertedWith('Invalid proof');
    });
  });
})
