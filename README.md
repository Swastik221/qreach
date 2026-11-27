# QREACH

Hire creators with escrow, and let anyone check if a post was paid. Built on QIE mainnet for QIE Hackathon 3.0
(Consumer Apps & Social).

**Status (2026-11-28):**
- Tested locally: contract unit, fuzz and invariant tests; app unit tests; browser end-to-end suites on a local chain.
- Tested against a QIE mainnet fork: real QUSDC, QIEDEX, QIE ID and oracle.
- Simulated on mainnet: deployment dry run passes its dependency checks.
- **Not yet deployed to mainnet. No live URL yet. No real two-wallet mainnet flow yet.** The deployment
  section below will hold real addresses and links once they exist.

## Problem

Creators are often paid late or not at all, and sponsors pay up front with no guarantee. Audiences cannot tell a paid
post from an honest one.

## Solution

A sponsor locks QUSDC for a named creator. The creator accepts, publishes the post and submits its link. The sponsor
approves, or stays silent until the review window ends, and the creator is paid from escrow. Every paid post becomes a
public record: paste any post link into `/check` to see who paid, how much and when.

## Features

- Direct offers to a creator chosen by `.qie` name or address, paid in QUSDC or in QIE (swapped on QIEDEX in the same transaction)
- Deadlines to accept and to post; full refund to the sponsor if either is missed, triggered by anyone
- Automatic release to the creator after the sponsor's review window
- Public "is this post paid?" lookup that cleans share links, so every copy of a post gives the same answer
- Creator profiles with a Shill Score computed only from on-chain history
- Judge page with live contract data and every QIE component
- No backend: every number comes from contract reads and event logs

## Architecture

```
Next.js app (wagmi/viem) ──► Qreach.sol on QIE mainnet ──► QUSDC · QIEDEX router · QIE ID
          └── reads: contract views, event logs, QIE oracle, QIEDEX quotes
```

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Stack: Solidity 0.8.24, Foundry, OpenZeppelin 5.1,
Next.js 15, React 19, wagmi 2, viem 2, Tailwind 4, Vitest, Playwright.

## QIE components

| Component | Where | How |
|---|---|---|
| QIE Wallet | app | connect and sign (EIP-1193, discovered via EIP-6963) |
| QUSDC | contract | escrow currency |
| QIEDEX | contract + app | `createCampaignWithQIE` swaps QIE to exact QUSDC (`swapETHForExactTokens`) and returns the rest; app shows live quotes |
| QIE ID (.qie) | contract + app | `setQieName` checks `domainOwnerByName(label, "qie")`; app resolves names to addresses |
| QIE Oracle | app | QIE/USD price next to the pay-with-QIE quote |

Addresses are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md). They were checked against QIE docs and on chain on 2026-11-27.

## Setup

```sh
git clone --recurse-submodules <repo>
cd contracts && forge build
cd ../app && cp .env.example .env.local && npm install && npm run dev
```

Every variable is explained in [app/.env.example](app/.env.example). All of them are public; never put a key in them.

## Testing

```sh
cd contracts && forge test                         # 72 unit/fuzz + 3 invariants
FORK=1 forge test --match-contract Fork --fork-url https://rpc1mainnet.qie.digital
cd app && npm run typecheck && npm test            # 19 Vitest tests
```

End-to-end suites drive the real UI in headless Chromium against a local chain: the happy path, plus 15 edge cases
including wrong network, wallet rejection, post squatting, missed deadlines, QIE leftover refunds and accounting.
See [docs/TESTING.md](docs/TESTING.md).

## Deployment

How to deploy: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

| | |
|---|---|
| Network | QIE Mainnet, chain 1990 |
| QREACH contract | not deployed yet |
| Live demo | not deployed yet |
| Example transactions | not available yet |

## Known limits

- The contract cannot see the post. It stores the link the creator submits; the sponsor checks it.
- If the sponsor does nothing during the review window, the creator is paid automatically.
- There is no dispute process. Once a link is submitted, the sponsor can approve but cannot reject.
- The contract cannot tell who wrote a post, so the same post can be submitted by more than one
  creator. Nobody can block the real creator this way, and /check shows every record for a post
  with a warning when more than one creator claimed it. One creator cannot use one post twice.
- The Shill Score can be inflated with a second wallet acting as a sponsor. It counts only what
  happened on chain: 50 x delivered rate + 30 x experience + 20 x sponsor variety.
- A .qie name has no reverse record in QIE ID, so creators link their name once with `setQieName`.
  The app re-checks ownership every time it shows a name. Social accounts are not linked.
- Not audited. See [docs/SECURITY.md](docs/SECURITY.md).

## Credits

- OpenZeppelin Contracts v5.1.0 (MIT)
- forge-std v1.9.4 (MIT/Apache-2.0)

## Licence

MIT
