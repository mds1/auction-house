// Based on https://github.com/mirror-xyz/splits/blob/972232c7649c432515e8fd371b8b40bb19f4121b/merkle-tree/balance-tree.ts
// which is based on https://github.com/Uniswap/merkle-distributor/blob/c3255bfa2b684594ecd562cacd7664b0f18330bf/src/balance-tree.ts

import MerkleTree from "./merkle-tree";
import { BigNumber, BigNumberish, utils } from "ethers";

export class SplitTree {
  readonly denominator = BigNumber.from('1000000');
  private readonly tree: MerkleTree;

  constructor(balances: { account: string; percent: BigNumberish }[]) {
    // Verify sum of percentages equals 100%, where percents are given as the numerator
    const total = balances.reduce((sum, current) => sum.add(current.percent), BigNumber.from('0'));
    if (!total.eq(this.denominator)) throw new Error('Percentage allocations do not sum to 100%');

    // Input is valid, create MerkleTree
    this.tree = new MerkleTree(
      balances.map(({ account, percent }) => {
        return SplitTree.toNode(account, BigNumber.from(percent));
      })
    );
  }

  public static verifyProof(
    account: string,
    percent: BigNumberish,
    proof: Buffer[],
    root: Buffer
  ): boolean {
    let pair = SplitTree.toNode(account, percent);
    for (const item of proof) {
      pair = MerkleTree.combinedHash(pair, item);
    }

    return pair.equals(root);
  }

  // keccak256(abi.encode(account, percent))
  public static toNode(account: string, percent: BigNumberish): Buffer {
    return Buffer.from(
      utils
        .solidityKeccak256(["address", "uint256"], [account, percent])
        .substr(2),
      "hex"
    );
  }

  public getHexRoot(): string {
    return this.tree.getHexRoot();
  }

  // returns the hex bytes32 values of the proof
  public getProof(
    account: string,
    percent: BigNumberish
  ): string[] {
    return this.tree.getHexProof(SplitTree.toNode(account, percent));
  }
}