# Zora — Auction House with Splitter 〜 𓀨 〜

- [Zora — Auction House with Splitter 〜 𓀨 〜](#zora--auction-house-with-splitter--𓀨-)
  - [Overview](#overview)
  - [Requirements](#requirements)
  - [Development and Usage](#development-and-usage)
  - [Other](#other)
- [Original README](#original-readme)
  - [Architecture](#architecture)
    - [Curators](#curators)
    - [Create Auction](#create-auction)
    - [Cancel Auction](#cancel-auction)
    - [Set Auction Approval](#set-auction-approval)
    - [Create Bid](#create-bid)
    - [End Auction](#end-auction)
  - [Local Development](#local-development)
    - [Install Dependencies](#install-dependencies)
    - [Compile Contracts](#compile-contracts)
    - [Run Tests](#run-tests)
  - [Bug Bounty](#bug-bounty)
  - [Acknowledgements](#acknowledgements)

## Overview

This repository is a fork of the the [Zora Auction House](https://github.com/ourzora/auction-house) repo at commit [54a12ec](https://github.com/ourzora/auction-house/commit/54a12ec1a6cf562e49f0a4917990474b11350a2d), modified to add a `Splitter` contract based on the requirements defined [here](https://github.com/ourzora/auction-house/issues/5).

Anyone can deploy their own `Splitter` contract from the `SplitterFactory`, and use it to create an auction on Zora and split the auction proceeds in a predefined way where each account has a defined percentage of the proceeds it is entitled to.

## Requirements

The `SplitterFactory` and `Splitter` contract added to this repository satisfies each requirement from https://github.com/ourzora/auction-house/issues/5 as follows:

> Allow for a user to initiate a split contract that keeps track of a pool of ownership for a reasonable # of addresses without being too gas intensive. Use mirror implementation with Merkle proofs as inspiration (https://github.com/mirror-xyz/splits/blob/main/contracts/Splitter.sol)

Similar to Mirror's implementation, a new `Splitter` instance is defined by calling `SplitterFactory.createSplitter()` and passing it the Merkle root (along with other inputs discussed later). The Merkle root is generated from an array of objects of type `{account: string; percent: BigNumberish}[]`. An example of defining this array and using it to obtain the Merkle root can be found in the Splitter tests and is shown below for convenience:

```typescript
import { SplitTree } from "./utils/split-tree";

// The `percent` is defined in parts per million, so the sum of all
// percents in the `allocations` array must be 1,000,000
const allocations = [ 
  { account: accounts[0].address, percent: '500' }, // 0.05%
  { account: accounts[1].address, percent: '10000' }, // 1%
  { account: accounts[2].address, percent: '25000' }, // 2.5%
  { account: accounts[3].address, percent: '127500' }, // 12.75%
  { account: accounts[4].address, percent: '327000' }, // 32.7%
  { account: accounts[5].address, percent: '510000' }, // 51%
];

tree = new SplitTree(allocations);
merkleRoot = tree.getHexRoot();
```

This allows a very large number of addresses to split allocations for a very affordable gas price. For a Splitter that uses ETH as it's `auctionCurrency`, the cost to claim your share of ETH with the `claim` method is less than 70k gas (about $2 at current prices). This is true whether the splitter is configured for 2 addresses or 100 addresses. (Costs for tokens will be a bit higher, as token transfers are more expensive than ETH transfers).

Additionally, `Splitter` contracts are deployed as EIP-1167 minimal proxies to minimize deployment cost. The cost to deploy a new `Splitter` is 136k gas (about $4)

> Allow for the split contract to interact with Auction House to call functions such as createAuction, setAuctionReservePrice, and cancelAuction

The `Splitter` contract has various methods to allow interacting with the `AuctionHouse`. These methods have very similar function signatures to the `AuctionHouse` versions.
- `createAuction()` has the same function signature as the `AuctionHouse` method, but does not take the `auctionCurrency` as an input, as the contract already knows what to use as it's defined in the `Splitter` at construction.
- `setAuctionApproval()` only take approval status as an input, as the `auctionId` is already known by the contract since it created the auction 
- `setAuctionReservePrice()` only take reserve price as an input, as the `auctionId` is already known by the contract since it created the auction 
- `cancelAuction()` takes no inputs, as the `auctionId` is already known by the contract since it created the auction 
- `endAuction()` takes no inputs, as the `auctionId` is already known by the contract since it created the auction. After ending the auction, this method also checks the contract's own balance of `auctionCurrency` and saves it to storage as `auctionProceeds`. This amount is used by the `claim` method to compute what each user is owed.

> Determine a heuristic for the conditions required for the split contract to be able to call AuctionHouse methods (in mvp, it might make sense to allow for the split creator address to call methods that interact with AuctionHouse and punt any sort of governance down the line).

Because Merkle proofs are used to claim funds, there is no way for the contract to compute an array of the accounts used to generate the Merkle root and use that array as the foundation for access to the auction methods. 

Instead, when creating a new splitter an `owner` address is passed as in input to `SplitterFactory.createSplitter()`. The Splitter's `owner` is the only address allowed to call all auction methods. This approach allows maximum flexibility over how to call these methods, as this means the `owner` can be an ordinary EOA, a multisig, or even a protocol's DAO behind a timelock. 

> Once the split contract has sold an NFT on AuctionHouse, the split particpants have the ability to receive their share. This could be implement by individual claiming functions, or a single function that would divy out the split shares to all members of the split in a single transactions.

Similar to the previous requirement, because Merkle proofs are used to claim funds, there is no way for the contract to know the full array of the accounts and their percentage allocations to automatically distribute funds.

Instead, eligible users must claim their funds with one of four methods. Note that all of these methods are public and can be called by anyone on behalf of a given `account`, and funds are transferred to that `account`.

If `endAuction` has been called:
- The `claim` method will claim funds for the specified account
- The `batchClaim` method extends the `claim` method so the caller can claim funds on behalf of multiple accounts in a single transaction

If `endAuction` has not been called:
- The `endAuctionAndClaim` method is a convenience method which batches the `endAuction` and `claim` calls into a single transaction. A user can call this method to simultaneously end the auction and claim their share of the proceeds.
- The `endAuctionAndBatchClaim` method is similar to `endAuctionAndClaim`, but allows claiming on behalf of multiple users in a single transaction

The claim methods take an `account`, `percent`, and `merkleProof` as inputs. It verifies that those input parameters can be used generate the `merkleRoot` stored on the Splitter. Once verified, the method computes how much `account` is owed based on `percent` and `auctionProceeds` and transfers the amount to `account`.

> Allow for the splits contract to split both ETH and / or ERC20 tokens.

When creating a new `Splitter`, you specify the `auctionCurrency` as an input. When set to `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`, the `Splitter` knows that ETH is used as the auction current. For any other address an ERC20 token is assumed.

> To simplify the scope of the contract, each split should only be used once, and for a specific auction.

The `Splitter` is designed this way:
- It can only be initialized once, which happens at deploy time
- Claims cannot be executed until `auctionProceeds` are greater than zero
- `auctionProceeds` will not be greater than zero until an auction ends
- The `createAuction` method can only be called one time in the lifetime of the contract

## Development and Usage

To create your own `Splitter`, follow these steps:

1. Define the percentages of proceeds each address is entitled to. This should be an array of objects containing `account` and `percent` keys. The `account` specifies the address, and the `percent` is the percentage of the proceeds that account should receive.
    1. Percentages are defined in parts per million and you specify the numerator. For example, to give someone 25%, their `percent` should be `0.25 * 1,000,000 = 250,000`
    2. The sum of all percentages must add up to 1,000,000. If it does not, an error will be thrown in the next step
    3. See the sample `allocation` defined below

```typescript
// The `percent` is defined in parts per million, so the sum of all
// percents in the `allocations` array must be 1,000,000
const allocations = [ 
  { account: account0, percent: '500' }, // 0.05%
  { account: account1, percent: '10000' }, // 1%
  { account: account2, percent: '25000' }, // 2.5%
  { account: account3, percent: '127500' }, // 12.75%
  { account: account4, percent: '327000' }, // 32.7%
  { account: account5, percent: '510000' }, // 51%
];
```

2. Create an instance of the `SplitTree` class and use that to get the Merkle root of your `allocations`

```typescript
import { SplitTree } from "./utils/split-tree";

const allocations = [ /* defined above */ ];
const tree = new SplitTree(allocations);
const merkleRoot = tree.getHexRoot();
```

3. Call `createSplitter` on an instance of the `SplitterFactory` and pass the required input parameters. The snippet below assumes you already have a `splitterFactory` instance created with ethers

```typescript
// merkleRoot was defined above

// Define the Splitter's auction currency. We use the special address
// below to specify ETH. Other addresses are ERC20 tokens
const auctionCurrency = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';

// Define the Splitter's owner. The owner address is the only address
// with the authority to call all auction related methods
const owner = '0x1234567890123456789012345678901234567890';
const tx = await splitterFactory.createSplitter(merkleRoot, auctionCurrency, owner);
```

4. Parse the event logs to find the address of the `Splitter` you just created

```typescript
// Parse logs for the address of the new Splitter
const receipt = await ethersProvider.getTransactionReceipt(tx.hash);
const log = splitterFactory.interface.parseLog(receipt.logs[0]);
const { splitter: splitterAddress } = log.args; // this is our address
```

5. You can create a `Splitter` contract instance pointing to `splitterAddress` to interact with it, create a new auction, etc. We'll now fast forward until the completion of an auction, after `endAuction` was called, and demonstrate how to claim funds

6. Generate the merkle proof for the address you want to claim funds for, then call the `claim` method. A similar process would be used for `batchClaim`. Generating this proof requires access to the original `allocations` array so you can generate the proof. We assume `splitter` is an ethers contract instance pointing to a specific `Splitter` contract.

```typescript
// Claiming for the third user in the allocations array
const { account, percent } = allocations[2];
const proof = tree.getProof(account, percent);
await splitter.claim(account, percent, proof); // that's it!
```

## Other

There is one edge case to be aware of: The amount that can be claimed rounds to zero if `auctionProceeds * percent < denominator`. We use a `denominator` of 1e6, which is small enough that in practice this will be exceedingly rare and only occur for negligible claim amounts.

For example, with USDC (we choose USDC for the example since it has 6 decimal places, meaning zero-value claims are more likely to happen with USDC than with tokens that have 18 decimals), you would claim zero USDC if `auctionProceeds` are below 1 USDC and you have one-millionth of the claim (`percent = 1`). Say proceeds are 0.99 USDC, then we have `0.99e6 * 1 / 1e6 = 0.99`, but the EVM floors division resulting in zero. If proceeds are 1 UDSC, this would not happen when your share is one-millionth of the proceeds.

------------------------

<div align="center"><i>original README below</i></div>

------------------------

# Original README

![Auction House Header Image](./auction-house.png)

The Zora Auction House is an open and permissionless system that allows any creator, community, platform or DAO to create and run their own curated auction houses. 

These auction houses run reserve timed auctions for NFTs, with special emphasis given to the role of curators. If an owner of an NFT chooses to list with a curator, that curator can charge a curator fee and has to approve any auction before it commences with that curators auction house. 

Anyone is able to run an NFT auction on the protocol for free by simply not specifying a curator.

The Zora ethos is to create public goods that are either owned by the community or by no one. As such, we have deployed this without admin functionality, and is therefore entirely permissionless and unstoppable.

*Mainnet address:* `0xE468cE99444174Bd3bBBEd09209577d25D1ad673`

*Rinkeby address:* `0xE7dd1252f50B3d845590Da0c5eADd985049a03ce`

## Architecture
This protocol allows a holder of any NFT to create and perform
a permissionless reserve auction. It also acknowledges the role of
curators in auctions, and optionally allows the auction creator to 
dedicate a portion of the winnings from the auction to a curator of their choice.

Note that if a curator is specified, the curator decides when to start the auction. 
Additionally, the curator is able to cancel an auction before it begins.

### Curators
In a metaverse of millions of NFTs, the act of curation is critical. Curators create and facilitate context and community which augment the value of NFTs that they select. The act of curation creates value for the NFT by contextualizing it and signalling its importance to a particular community. The act of curation is extremely valuable, and is directly recognized by the Auction House system. A curator who successfully auctions off an NFT for an owner can earn a share in the sale. 

We have defined a *curator* role in the auction house. A curator can:
- Approve and deny proposals for an NFT to be listed with them.
- Earn a fee for their curation
- Cancel an auction prior to bidding being commenced

Creators and collectors can submit a proposal to list their NFTs with a curator onchain, which the curator must accept (or optionally reject). This creates an onchain record of a curators activity and value creation. 

Creators and collectors always have the option to run an auction themselves for free.

### Create Auction
At any time, the holder of a token can create an auction. When an auction is created,
the token is moved out of their wallet and held in escrow by the auction. The owner can 
retrieve the token at any time, so long as the auction has not begun. 

| **Name**               | **Type**       | **Description**                                                                                |
|------------------------|----------------|------------------------------------------------------------------------------------------------|
| `tokenId`              | `uint256`      | The tokenID to use in the auction                                                              |
| `tokenContract`        | `address`      | The address of the nft contract the token is from                                              |
| `duration`             | `uint256`      | The length of time, in seconds, that the auction should run for once the reserve price is hit. |
| `reservePrice`         | `uint256`      | The minimum price for the first bid, starting the auction.                                     |
| `creator`              | `address`      | The address of the current token holder, the creator of the auction                            |
| `curator`              | `address`      | The address of the curator for this auction                                                    |
| `curatorFeePercentage` | `uint8`        | The percentage of the winning bid to share with the curator                                    |
| `auctionCurrency`      | `address`      | The currency to perform this auction in, or 0x0 for ETH                                        |

### Cancel Auction
If an auction has not started yet, the curator or the creator of the auction may cancel the auction, and remove it from the registry. 
This action returns the token to the previous holder.

| **Name**               | **Type**       | **Description**                                                                                |
|------------------------|----------------|------------------------------------------------------------------------------------------------|
| `auctionId`            | `uint256`      | The ID of the auction                                                                          |

### Set Auction Approval
If a created auction specifies a curator to start the auction, the curator _must_ approve it in order for it to start.
This is to allow curators to specifically choose which auctions they are willing to curate and perform.

| **Name**               | **Type**       | **Description**                                                                                |
|------------------------|----------------|------------------------------------------------------------------------------------------------|
| `auctionId`            | `uint256`      | The ID of the auction                                                                          |
| `approved`             | `bool`         | The approval state to set on the auction                                                       |

### Create Bid
If an auction is approved, anyone is able to bid. The first bid _must_ be greater than the reserve price. 
Once the first bid is successfully placed, other bidders may continue to place bids up until the auction's duration has passed.

If a bid is placed in the final 15 minutes of the auction, the auction is extended for another 15 minutes. 

| **Name**               | **Type**       | **Description**                                                                                |
|------------------------|----------------|------------------------------------------------------------------------------------------------|
| `auctionId`            | `uint256`      | The ID of the auction                                                                          |
| `amount`               | `uint256`      | The amount of currency to bid. If the bid is in ETH, this must match the sent ETH value        |

### End Auction
Once the auction is no longer receiving bids, Anyone may finalize the auction.
This action transfers the NFT to the winner, places the winning bid on the piece, and pays out the auction creator and curator.

| **Name**               | **Type**       | **Description**                                                                                |
|------------------------|----------------|------------------------------------------------------------------------------------------------|
| `auctionId`            | `uint256`      | The ID of the auction                                                                          |

## Local Development
The following assumes `node >= 12`

### Install Dependencies

```shell script
yarn
```

### Compile Contracts

```shell script
npx hardhat compile
```

### Run Tests

```shell script
npx hardhat test
```

## Bug Bounty
- 25 ETH for any critical bugs that could result in loss of funds.
- Rewards will be given for smaller bugs or ideas.


## Acknowledgements

This project is the result of an incredible community of builders, projects and contributors.

We would like to acknowledge the [Mint Fund](https://mint.af) and the [$BOUNTY backers](https://mint.mirror.xyz/6tD-QHgfCWvfKTjZgMoDd-8Gwdx3oibYuaGvg715Xco) for crowdfunding and coordinating the development of an opensource version of reserve auctions, implemented by [Billy Rennekamp](https://twitter.com/billyrennekamp).

We would also like to credit projects that have pioneered and improved on the reserve auction mechanism and experience, such as SuperRare. Lastly, we'd like to ackowledge [Coldie](https://twitter.com/Coldie), the original pioneer of the reserve timed auction mechanism.
