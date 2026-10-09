# Hood Test (HOODT)

A fixed-supply ERC-20 launch token for Robinhood Chain (chain id 4663), delivered as a Foundry
project at the repository root.

| Item | Value |
| --- | --- |
| Solidity contract | `HOODTToken` (`src/HOODTToken.sol`) |
| Token name | Hood Test |
| Token symbol | HOODT |
| Decimals | 18 |
| Total supply | 1,000,000,000 HOODT = `1000000000000000000000000000` minor units (1e27) |
| Constructor arguments | none |
| Owner / admin | none |
| Minting after launch | none, the supply is fixed forever |
| Transfer rules | plain ERC-20, no fee, tax, limit, pause or blacklist |

## Behaviour

- The constructor mints the entire supply to `msg.sender`, the deployer, once. It calls no other
  contract and needs nothing deployed beforehand, so it behaves identically on an empty chain.
- `transfer`, `approve` and `transferFrom` are standard. Transfers to the zero address and approvals
  of the zero spender revert. An allowance of `type(uint256).max` is treated as infinite and is not
  decremented.
- `totalSupply()` returns the constant `TOTAL_SUPPLY`; there is no mint, burn, pause, freeze,
  blacklist, ownership, upgrade, proxy, `delegatecall` or `selfdestruct` anywhere in the contract.
- Every parameter is a compile-time constant. There is nothing to configure after launch.
- The contract is self-contained and imports nothing, so the build depends on no external library.

## Supply distribution (done by the launch factory, not by this contract)

The deployer is IdentityMD's launch factory. The token mints the full 1e27 units to it and never
subtracts any allocation itself. The factory then:

1. forwards the swarm's 10% to the launch's Merkle distributor;
2. seeds 90% (`economics.poolBps` = 9000) single-sided into the Uniswap v4 pool through the
   PoolManager at `0x8366a39cc670b4001a1121b8f6a443a643e40951`, paired with IMD
   (`0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`), opening at a 2,500 IMD market cap for the whole
   supply (`economics.initialMarketCapWei` = `2500000000000000000000`);
3. sends any remainder to `economics.remainderTo`
   (`0x000000000000000000000000000000000000dead`).

Because transfers are exact and untaxed, every launch flow (factory to distributor, distributor to
claimant, factory to PoolManager, trader to and from PoolManager) moves exactly what it says.

## Deployment parameters

`launch.json` at the root is the manifest for this launch, with exactly the keys the brief
requires: `kind`, `token`, `contracts` (empty), `pool`, `economics` and `notes`.

- `pool.fee` 12500 (1.25%), `pool.tickSpacing` 60.
- `pool.initialPrice` `125270724187523965593206900` is provenance only (IMD minor units per HOODT
  minor unit with HOODT as currency0). The deployer derives the real opening sqrt price from the
  economics once the token's address, and so the currency order, is known.
- No application contracts are deployed alongside the token.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, the optimizer on (200 runs) and
`bytecode_hash = "none"` with `cbor_metadata = false`, so the built bytecode carries no metadata
hash and is reproducible for verification. `ffi` is off and no filesystem permissions are granted.

The only dependency is `forge-std` v1.9.7, vendored as ordinary files under `lib/forge-std/src`
(tests only; the token itself imports nothing). There are no git submodules.

## Tests

`test/HOODTToken.t.sol` holds the smoke suite this assignment asked for: deployment and metadata,
the exact supply, the constructor mint to the deployer with no external calls, exact fee-free
transfers (partial, whole balance, zero, to self), the insufficient-balance and zero-address
failure paths, allowances (decrement, infinite, missing, exceeded, zero spender), the absence of
mint and admin selectors, and a bytecode scan for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`.
A separate agent writes the fuzz and invariant suites after this delivery, as the brief directs.

## Operational responsibilities and assumptions

- This repository authorises no transactions and holds no keys. Deployment, pool seeding and the
  swarm distribution are the launch factory's and deployer's work.
- The chain, pair token, fee, tick spacing and economics are fixed by the launch order and are not
  open questions.
- Passing tests are not a security audit. The contract is small and standard, but an independent
  adversarial review before release remains the launch policy's responsibility.
- Explorer verification after deployment uses the same pinned compiler settings; nothing in the
  build is machine-specific.
