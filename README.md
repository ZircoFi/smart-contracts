# ZircoFi contracts

Smart contracts for ZircoFi: a non-custodial swap venue for tokenized real-world assets on Robinhood Chain. Anchor vaults quote both sides of every market around the guarded Chainlink mid, block-size flow settles through signed RFQ maker quotes, and one router composes the two behind a single entry point, settled in USDG.

Built with Foundry for Robinhood Chain (chain ID 4663), an Arbitrum Nitro chain.

## Layout

```
src/
  SwapRouter.sol              sole trader entry point: eligibility, vault-versus-RFQ selection, two-leg composition
  AnchorVault.sol             one per market: oracle-anchored quoting, inventory skew, LP shares, in-kind withdrawal
  VaultFactory.sol            deploys vaults and is the registry the router resolves them from
  RfqSettlement.sol           EIP-712 maker quotes, nonce cancellation, atomic band-checked settlement
  OracleRouter.sol            Chainlink feeds and streams with session, staleness, move-cap and sequencer guards
  EligibilityRegistry.sol     role checks through a swappable policy adapter
  adapters/NativeAttestationAdapter.sol   self-contained attestation store with EAS semantics
  ParamController.sol         every tunable parameter behind a timelock; guardian can only pause swaps
  FeeCollector.sol            receives the itemised swap fees, RFQ fees and the protocol spread share
  libraries/                  Types (quotes, breakdowns, roles and constants)
  interfaces/                 protocol and external (Chainlink, ERC-8056) interfaces
  mocks/                      local-development stand-ins: USDG, Stock Token, aggregator, stream adapter
script/Deploy.s.sol           full deployment and configuration; opens the launch market
script/Seed.s.sol             seeds a fresh testnet deployment with liquidity and a first pair of fills
script/Activity.s.sol         adds a round of multi-wallet activity (deposits, a withdrawal, a batch of swaps)
test/                         Foundry suite: vault accounting, swap pricing, regimes and halts, RFQ, governance
deployments/                  addresses written by the deploy script, one JSON file per chain ID
```

## Deployments

### Robinhood Chain testnet (chain ID 46630)

Deployed 1 September 2026 from `0x11a66772a0BD9F1a798704448f36D697718F6f61`, which is also the bootstrap owner, guardian and attestation issuer on testnet. All twelve contracts are verified on [Blockscout](https://explorer.testnet.chain.robinhood.com). External dependencies are mocks: the deploy script stands in its own USDG, NVDAx stock token and Chainlink aggregator (NVDAx at 176.40 USDG). The full list is in `deployments/46630.json`.

| Contract | Address |
| --- | --- |
| SwapRouter | [`0x0E0036d5fe155038E499cb6d9e92f1E8cC61b4cC`](https://explorer.testnet.chain.robinhood.com/address/0x0E0036d5fe155038E499cb6d9e92f1E8cC61b4cC) |
| RfqSettlement | [`0x5F9Bea6190dDbe1cC6FDB92Cb31b97F5395872E9`](https://explorer.testnet.chain.robinhood.com/address/0x5F9Bea6190dDbe1cC6FDB92Cb31b97F5395872E9) |
| VaultFactory | [`0xeA9b5e56387D97ac721a98D6E90C8dA0C4e445B9`](https://explorer.testnet.chain.robinhood.com/address/0xeA9b5e56387D97ac721a98D6E90C8dA0C4e445B9) |
| AnchorVault (NVDAx / USDG, `zvNVDAx`) | [`0xAd0DC93C44B5C6419Dc762008F150A36e23172a6`](https://explorer.testnet.chain.robinhood.com/address/0xAd0DC93C44B5C6419Dc762008F150A36e23172a6) |
| OracleRouter | [`0xd3eEf50777D4e5Dd43Cd32bE386143EEd68f6bea`](https://explorer.testnet.chain.robinhood.com/address/0xd3eEf50777D4e5Dd43Cd32bE386143EEd68f6bea) |
| EligibilityRegistry | [`0x42c8337789F26eDdeaAAFF393285fEa074b1beEa`](https://explorer.testnet.chain.robinhood.com/address/0x42c8337789F26eDdeaAAFF393285fEa074b1beEa) |
| NativeAttestationAdapter | [`0xaA05D002BA926FbE7f12518568C7f660c9AaE997`](https://explorer.testnet.chain.robinhood.com/address/0xaA05D002BA926FbE7f12518568C7f660c9AaE997) |
| ParamController | [`0x547043759582B63138681f58CCEbe88C20e695e8`](https://explorer.testnet.chain.robinhood.com/address/0x547043759582B63138681f58CCEbe88C20e695e8) |
| FeeCollector | [`0xb97569c3FC7E79cf3D5117B0356a2D0444F26ACB`](https://explorer.testnet.chain.robinhood.com/address/0xb97569c3FC7E79cf3D5117B0356a2D0444F26ACB) |
| USDG (mock) | [`0x3E3e5BBeeacc1e50ACEBae3b4385f82Fc1d81cDC`](https://explorer.testnet.chain.robinhood.com/address/0x3E3e5BBeeacc1e50ACEBae3b4385f82Fc1d81cDC) |
| NVDAx stock token (mock) | [`0x2418E25422395DB7122cf27Ed26AF85E4338A8B2`](https://explorer.testnet.chain.robinhood.com/address/0x2418E25422395DB7122cf27Ed26AF85E4338A8B2) |
| NVDAx / USD aggregator (mock) | [`0x7Cc6aF674774cba6CAc3af8B9D523D388d06069a`](https://explorer.testnet.chain.robinhood.com/address/0x7Cc6aF674774cba6CAc3af8B9D523D388d06069a) |

The testnet deployment runs with the documented launch parameters, `TIMELOCK_DELAY=3600` and `FINISH_BOOTSTRAP=false`, so the deployer can still call the `ParamController` setters directly.

### Robinhood Chain mainnet (chain ID 4663)

Not yet deployed. Mainnet requires the live `USDG`, `STOCK_TOKEN`, `STOCK_FEED` and `SEQUENCER_FEED` addresses; the script refuses to deploy mocks on chain ID 4663.

## How a swap settles

1. The trader calls `SwapRouter.swapExactIn` with the pair, an exact input, a minimum output and a deadline, optionally attaching a signed maker quote.
2. The router checks the trader's `TRADER` attestation, re-derives the anchor vault's price from oracle and vault state in the same transaction, verifies the maker quote's signature if one was attached, and settles whichever venue outputs more.
3. The vault prices from the formula: guarded Chainlink mid, tier half-spread times the session multiplier, signed inventory skew, itemised fee. Every fill emits its full breakdown, and nothing can settle outside the tier's oracle band on either venue.
4. Token-to-token swaps run as two atomic legs through USDG; if either leg cannot clear inside its market's guards, both revert.

## Quick start

```bash
forge soldeer install     # pulls forge-std and OpenZeppelin into dependencies/
forge build
forge test -vv
```

Dependencies are managed by soldeer (no git submodules). Solidity 0.8.26, Cancun EVM, via-IR.

## Deploying

1. Copy `.env.example` to `.env` and fill in `PRIVATE_KEY` and `ROBINHOOD_RPC` (the official RPC is listed at docs.robinhood.com/chain).
2. Set `USDG`, `STOCK_TOKEN` and `STOCK_FEED` to the live addresses. On a local Anvil chain or the testnet they can be left blank to deploy mocks.
3. Run:

```bash
source .env
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --verify
```

The script writes `deployments/<chainId>.json` with every address, opens the launch market and sets the documented launch parameters (Tier A: 10 bps half-spread, 75 bps band, 50,000 USDG clip; x1.5 extended and x3 closed session multipliers; 2 bps fees and a 10% spread share). Set `GOV` to hand ownership to the governance multisig and `FINISH_BOOTSTRAP=true` to lock parameters to the timelock. On a local chain the deployer attests itself for every role so the flows can be exercised immediately.

## Governance model

- `ParamController` starts in bootstrap mode: the owner can call setters directly. `finishBootstrap()` is irreversible and routes every change through `schedule` / `execute` with the configured delay.
- The guardian can only pause swaps. Nothing can pause deposits, withdrawals or RFQ cancellation.
- `SwapRouter`, `AnchorVault`, `VaultFactory` and `RfqSettlement` have no proxy and no admin. Improvements ship as new deployments that LPs migrate to by choice.

## Key invariants

- No fill clears outside the tier's oracle band, from a vault or a maker, in any regime, under any parameter set the controller accepts.
- Vault withdrawal is pro-rata in kind and works in every state: halted, guardian-paused, market retired, attestation expired. Nothing can trap LP funds.
- Value per share never decreases from a swap; mint and burn rounding always favours the vault.
- A fill may not leave a vault outside its inventory band, and the preview and the fill agree exactly, so the harmful side goes one-sided instead of absorbing unbounded inventory.
- Every market is priced with the feed configured for the exact token in the vault, never a wrapper or a derived rate.
- Quotes are itemised on-chain: the fill event carries mid, spread, skew and fee, matching what was quoted.

## Notes for integrators

- Approvals run against the router (traders) and `RfqSettlement` (makers); Permit2 and ERC-4337 batching sit above these contracts rather than inside them.
- Deposits price the incoming assets at the guarded mid, so they revert while a market is halted; withdrawals read no oracle at all and never revert on market state.
- `AnchorVault.quoteSwap` is the exact preview: it reverts while the market is halted, and the router treats that as "no vault quote" so RFQ can still carry the market.

## Security

The security programme (testing, audits, bounty and disclosure) is described in `docs/architecture/security.md`. Report vulnerabilities to security@zircofi.com rather than in public issues.
