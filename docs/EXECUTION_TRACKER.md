# QREACH execution tracker

Legend: `[x]` completed (with evidence) · `[~]` in progress · `[!]` blocked · `[ ]` not started

Last updated: 2026-11-28. Submission deadline: 30 Nov 2026, 23:59 CET.

## Phase 1: Audit
- [x] Read the repository, docs and config, and check git status → `docs/READINESS_AUDIT.md`
- [x] Run the existing checks (forge, fork, vitest, tsc, build, e2e) → audit §3
- [x] Verify mainnet chain and dependency addresses against qie.digital and on chain → audit §6
- [x] Check for an existing deployment → none (audit §7)

## Phase 2: Contract hardening
- [x] `forge fmt --check` passes
- [x] Manual security review → audit §5 (no contract logic change needed)
- [x] Added 13 unit tests: deadline boundaries, insufficient balance/allowance, swap deadline, events, stats, terminal states, unknown ids, 2 reentrancy attacks → `forge test`: 72 unit/fuzz passed
- [x] Added conservation invariant → 3 invariants passed
- [x] Fork tests against live mainnet → 4/4 passed
- [x] Mainnet preflight in `Deploy.s.sol` → simulation printed "preflight ok"

## Phase 3: Frontend
- [x] Transactions switch to the app chain before signing (F1) → e2e B2 fails on old code, passes on new
- [x] Real transaction states, explorer links, rejection, balance, revert errors → already present; e2e C, D, G
- [x] `.env.example` documents every variable
- [x] `npm run typecheck`, `npm test` scripts

## Phase 4: Integration testing
- [x] `reset.sh` repaired (path, forge flag, gas price, visible errors)
- [x] `e2e/flow.mjs` PASS against production build
- [x] `e2e/edge-cases.mjs` PASS against production build (15 steps)
- [ ] `next dev` + Playwright page error (pre-existing, dev-only, P3)

## Phase 5: Mainnet deployment
- [x] Deployment checklist and commands → `docs/DEPLOYMENT.md`
- [x] Dry run on mainnet (simulation only, nothing sent)
- [x] 2026-11-28 re-verification: clean build, all tests, fork 4/4, 15 lint findings classified (none Medium or above), dependencies re-checked on chain (audit §9)
- [x] Deployer `0x17be…1B45`: 0.05 QIE, nonce 0. Simulation from it: preflight ok, predicted `0xecf00C31f73296A1EFa9Fe4D3514813D93807740`, deploy calldata == compiled bytecode
- [!] Broadcast deployment: **waiting for your explicit authorization**
- [!] Verify the contract on Blockscout: after deployment
- [!] Read-only checks of the deployed contract: after deployment
- [!] Real end-to-end mainnet flow: needs two wallets, QUSDC/QIE, and your approval for each transaction

## Phase 6: Frontend hosting
- [x] Production build passes; no secrets in the client bundle (scanned)
- [!] Hosting account (Vercel or other): not available on this machine
- [!] Set `NEXT_PUBLIC_QREACH` and `NEXT_PUBLIC_DEPLOY_BLOCK`: after deployment
- [!] Post-deploy smoke test (home, wallet, network, reads, campaign, judge, check)

## Phase 7: Submission
- [x] `docs/ARCHITECTURE.md`, `docs/DEPLOYMENT.md`, `docs/TESTING.md`, `docs/SECURITY.md`
- [x] README: current status, honest limits, links to docs
- [x] Demo script → `docs/DEMO.md`
- [!] README live URL, contract address, transaction links: after Phases 5–6
- [!] Screenshots from the live product: after Phase 6
- [x] Submission repository confirmed: `Anand-240/qreach`
- [x] Readiness pass merged into fork `Swastik221/qreach` main (PR #1, `e07de10`)
- [x] Deployer keystore permissions set to `600`
- [x] Sync branch `official-sync` prepared locally: fast-forward of official `1942729` (no force-push)
- [!] Push `official-sync` to `Anand-240/qreach` `main`: **needs your authorization**
- [!] Hosting: Vercel CLI not installed and no project linked (a Vercel login file exists on this machine)
