# Testing QREACH

Results last run on 2026-11-27 (forge 1.8.3, Node 26.7).

| Suite | Command | Result |
|---|---|---|
| Contract unit + fuzz | `cd contracts && forge test` | 72 passed (fuzz: 512 runs each) |
| Contract invariants | (part of `forge test`) | 3 passed (64 runs × 32 calls) |
| Mainnet fork | see below | 4 passed |
| Format | `cd contracts && forge fmt --check` | passes |
| App types | `cd app && npm run typecheck` | passes |
| App unit (Vitest) | `cd app && npm test` | 19 passed |
| App build | `cd app && npm run build` | passes |
| E2E happy path | `RUN=1 node e2e/flow.mjs` | PASS (10 steps) |
| E2E edge cases | `RUN=2 node e2e/edge-cases.mjs` | PASS (15 steps) |

## Contracts

```bash
cd contracts && forge test -vvv
```

Fork tests read live QIE mainnet. They send nothing and need no key:

```bash
cd contracts && FORK=1 forge test --match-contract Fork --fork-url https://rpc1mainnet.qie.digital -vv
```

What is covered: every function's happy path and every custom error; access control (including a fuzzed
stranger); deadline boundaries on both sides; insufficient balance and allowance; swap deadline,
short swap and leftover refund; event arguments; creator stats; every money function against every
terminal state; unknown ids; reentrancy through the leftover-QIE refund and through a malicious router.

Invariants (random sequences of all seven actions plus time warps):
- contract QUSDC balance == sum of open escrows
- creator's recorded earnings == QUSDC the creator received
- sponsor + creator + contract balances == total minted (nothing created or lost)

Fork tests: QUSDC symbol and decimals, oracle freshness, `.qie` ownership check against the real QIE ID,
and a real QIEDEX swap through `createCampaignWithQIE`.

## App unit tests

`lib/normalizeUrl.test.ts`, `lib/score.test.ts`, `lib/campaign.test.ts`. Pure functions, no mocks.

## End-to-end (real UI, real contract, local chain)

A small EIP-1193 test wallet is injected into headless Chromium and forwards to anvil. Nothing is
mocked between the UI and the contract. **Run against a production build.** Under `next dev` the
happy-path suite fails with a page error ("Invalid or unexpected token"). This is a known dev-server-only
issue and also happens on the base commit.

Start anvil (terminal 1):

```bash
anvil
```

Deploy mocks and QREACH, and register `riya.qie`. Run this before **each** suite:

```bash
bash app/e2e/reset.sh
```

Build and start the app against the local chain (terminal 2):

```bash
cd app && NEXT_PUBLIC_CHAIN_ID=31337 NEXT_PUBLIC_QREACH=0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 NEXT_PUBLIC_QUSDC=0x5FbDB2315678afecb367f032d93F642f64180aa3 NEXT_PUBLIC_QIEID=0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 NEXT_PUBLIC_DEPLOY_BLOCK=0 NEXT_DIST_DIR=.next-local npx next build && NEXT_DIST_DIR=.next-local npx next start -p 3210
```

Install Playwright (once, not saved to package.json):

```bash
cd app && npm i --no-save playwright && npx playwright install chromium
```

```bash
cd app && RUN=1 node e2e/flow.mjs
```

```bash
bash app/e2e/reset.sh && cd app && RUN=2 node e2e/edge-cases.mjs
```

Screenshots go to `app/e2e/shots-<RUN>/` (git-ignored).

Edge suite steps: A wrong network → switch; B reconnect after reload; **B2 a transaction started on the
wrong network switches the wallet first**; C form validation; D wallet rejection; E stranger has no
actions; F pending post on /check; G post reuse blocked; G2 post squatting; H missed deadline and score
drop; I decline after the accept deadline; J phone-size pay-in-QIE with headroom returned; K indexing
across 25k+ blocks; L contract balance == open escrow.

## Not covered

- Real QIE Wallet extension UI (the test wallet speaks the same EIP-1193/6963 protocol).
- Mainnet end-to-end with real funds: pending deployment (see `DEPLOYMENT.md`).
- Visual regression and accessibility audits.
