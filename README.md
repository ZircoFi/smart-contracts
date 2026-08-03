# ZircoFi contracts

Smart contracts for ZircoFi: a non-custodial swap venue for tokenized real-world assets on Robinhood Chain. Anchor vaults quote both sides of every market around the guarded Chainlink mid, block-size flow settles through signed RFQ maker quotes, and one router composes the two behind a single entry point, settled in USDG.

Built with Foundry for Robinhood Chain (chain ID 4663), an Arbitrum Nitro chain.

## Quick start

```bash
forge soldeer install     # pulls forge-std and OpenZeppelin into dependencies/
forge build
forge test -vv
```

Dependencies are managed by soldeer (no git submodules). Solidity 0.8.26, Cancun EVM, via-IR.
