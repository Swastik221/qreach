# QREACH readiness audit

Date: 2026-11-27. Base commit: `1942729`. Submission deadline: **30 Nov 2026, 23:59 CET**, mainnet only
(source: hackathon.qie.digital).

Everything below was checked by reading the code and running the commands listed. Nothing here means
"audited" in the professional sense: no external security audit has been done.

## 1. Architecture (as built)

```
Browser (Next.js 15, wagmi/viem, no backend)
  ├─ writes ─► Qreach.sol (QIE mainnet, chain 1990) ─► QUSDC (escrow token)
  │                                                  ├► QIEDEX router (pay with QIE: swapETHForExactTokens)
  │                                                  └► QIE ID registry (domainOwnerByName, for .qie names)
  └─ reads ──► contract views + event logs (in-browser indexer, 10k-block chunks)
               QIE/USD oracle (display only), QIEDEX getAmountsIn (quote only)
```

- One contract, `contracts/src/Qreach.sol` (400 lines). No owner, no admin, no fees, no upgrade path.
- Escrow model is **one sponsor → one named creator per campaign** (a direct offer). There is no open
  campaign board, no multi-creator budget and no "apply" step. The product brief describes an open
  marketplace; the code implements direct offers. This is a scope difference, not a bug (see P1-3).
- Lifecycle: `Created → Accepted → Submitted → Paid`, with exits `Created → Refunded` (cancel or
  accept deadline missed), `Created → Declined` (refund), `Accepted → Refunded` (post deadline missed).
- Public verification: the post URL is normalised in the app, hashed (keccak256) and stored. `/check`
  looks up every campaign for a post hash.

## 2. Implemented and verified

| Area | Evidence |
|---|---|
| Create campaign with QUSDC (approve + lock) | unit tests, e2e flow step 1 |
| Create campaign paying in QIE via QIEDEX (exact-out swap, leftover returned) | unit tests, mainnet fork test, e2e step 6 and J |
| Accept / decline / cancel | unit tests, e2e steps 2, 6, 7, I |
| Submit post URL (on-chain https/ASCII check, app-side normalisation) | unit tests, Vitest, e2e step 2 |
| Approve and pay | unit tests, e2e step 3 |
| Auto-release after review window (anyone can call) | unit + fuzz tests, e2e step 8 |
| Refund after missed accept/post deadline (anyone can call) | unit tests, e2e steps 8, H |
| No double pay / double refund | unit tests (terminal-state test), invariants |
| Reentrancy guard on every function that moves funds | 2 dedicated reentrancy tests (added) |
| QIE ID `.qie` names (claim, re-check ownership on display) | unit tests, fork test, e2e step 5 |
| QIE/USD oracle price and staleness flag (display only) | fork test, e2e step 10 |
| Public "is this post paid?" lookup, duplicate-claim warning | e2e steps 4, F, G2 |
| Creator profile and Shill Score | Vitest, e2e steps 5, H |
| Judge dashboard (live contract, components, counters) | e2e steps 10, K |
| Real transaction states (simulate → sign → receipt status) with explorer links | code review of `useTx.ts`, `TxStatus.tsx` |
| Wallet rejection, wrong network, insufficient balance, revert reasons | e2e steps A, B2, C, D, G |

No fake or placeholder success states were found. Every number on screen comes from a contract read
or an event log.

## 3. Test results (all run on 2026-11-27 on this machine)

| Command | Result |
|---|---|
| `forge fmt --check` | **failed** at baseline (1 file); passes after `forge fmt` |
| `forge build` | passes (lint notes only: unsafe-typecast, require-in-loop; reviewed, both safe) |
| `forge test` | baseline: 59 unit/fuzz + 2 invariants passed. Now: **72 unit/fuzz + 3 invariants passed**, fork suite skipped by design |
| `FORK=1 forge test --match-contract Fork --fork-url https://rpc1mainnet.qie.digital` | **4/4 passed** against live mainnet |
| `forge script script/Deploy.s.sol --rpc-url qie_mainnet` (simulation only, no broadcast) | preflight ok; ~2.94M gas, ~0.006 QIE |
| `npx tsc --noEmit` | passes |
| `npx vitest run` | **19/19 passed** |
| `next build` (mainnet env) | passes |
| `e2e/flow.mjs` against **production build** + anvil | **PASS** (10 steps) |
| `e2e/edge-cases.mjs` against **production build** + anvil | **PASS** (15 steps incl. new B2) |
| `e2e/flow.mjs` against `next dev` | **fails**: page error "Invalid or unexpected token", page stops hydrating after a second navigation. Pre-existing (fails identically on the base commit). Dev-server only; root cause not found. |

Before the fixes below, `e2e/reset.sh` did not run on this machine (hard-coded path, removed forge flag,
and errors sent to /dev/null), so the e2e suites could not be run as documented.

## 4. Bugs found and fixed in this pass

| ID | Severity | Issue | Fix |
|---|---|---|---|
| F1 | P1 | `useTx` sent transactions on whatever network the wallet was on. wagmi's `writeContract` without `chainId` does no chain check, so a wallet on another chain would sign there (QUSDC approve sent to a random address on another network). | `useTx` switches the wallet to the app chain first and passes `chainId` so wagmi refuses to sign on a mismatch. New e2e step B2 fails on the old code and passes on the new code (verified both ways). |
| F2 | P2 | `forge fmt --check` failed. | Formatted. |
| F3 | P2 | `e2e/reset.sh`: hard-coded `~/qreach/contracts`, uses `--start-fresh` (removed in forge 1.8), hides errors, and intermittently fails with "max fee per gas less than block base fee" after `anvil_reset`. | Path relative to the script, flag removed, errors visible, explicit local gas price. |
| F4 | P2 | Deploy script had no checks before a mainnet broadcast. | `_preflight()` on chain 1990: code exists at all three dependencies, QUSDC symbol and 6 decimals, router WQIE matches the official address, QIE ID resolves `qie.qie`. |
| F5 | P3 | No `test` / `typecheck` npm scripts. | Added. |
| F6 | P3 | `.env.example` did not say which values are required, where to get them, or that they are public. | Rewritten. |

## 5. Security review of `Qreach.sol`

Reviewed manually. Findings:

| Topic | Result |
|---|---|
| Access control | Sponsor-only: `cancel`, `approveAndPay`. Creator-only: `accept`, `decline`, `submitWork`. Anyone: `autoRelease`, `refundExpired` (funds can only go to the creator or sponsor recorded in the campaign). Correct. |
| State machine | Every money-moving function checks status first and sets the terminal status before the transfer. No path from a terminal state. Tested for all 5 functions × 3 terminal states. |
| Double withdrawal | Not possible (status is set before transfer; invariants `balanceEqualsOpenEscrow`, `qusdcConserved`, `statsMatchPayouts` hold over 2,048 random calls). |
| Reentrancy | `nonReentrant` on create (both), cancel, decline, approve, autoRelease, refundExpired. `accept`/`submitWork` move no funds. The only external call to an untrusted address is the leftover-QIE refund to `msg.sender`; re-entry from it is blocked (tested). |
| ERC20 safety | `SafeERC20` everywhere. QUSDC on mainnet: 6 decimals, not a proxy (EIP-1967 slot empty), no `paused`/blacklist functions (selectors absent from bytecode), so a token admin cannot freeze escrow. |
| Decimals | Amounts are raw QUSDC units (6 dp) end to end; `MIN_AMOUNT` 500,000 = 0.5 QUSDC; `uint128` cap enforced. No division anywhere, so no rounding. |
| Deadlines | `acceptBy > now`, `deliverBy > acceptBy`, review window 1 h–7 d. Boundaries consistent: action allowed at `== deadline`, refund only `> deadline` (tested both sides). |
| QIEDEX swap | Exact-output swap; maximum input is `msg.value` (app sends quote + 2%); swap deadline 15 min; the contract checks it received at least `amountOut`; unused QIE is returned in the same transaction. Maximum slippage loss is bounded by the 2% headroom. |
| Oracle | Not used by the contract. App shows it with a 6 h staleness flag. On chain the feed's `description()` is "QIE / USDT" (docs call it "QIE Native"); the app labels it QIE/USD. Value 0.1601 matched the QIEDEX pool (~0.158) on 2026-11-27. |
| Events | Every state change emits an event; the app's indexer is built only from them. |

### Residual risks (documented, not changed)

| ID | Severity | Risk |
|---|---|---|
| S1 | P1 (decision) | **No dispute path.** Once a post is submitted, the money can only go to the creator: by approval, or automatically after the review window. A sponsor who thinks the post is wrong cannot stop payment. Any https URL is accepted. This favours creators by design; it must be stated clearly in the demo and README. Adding `reject` without an arbiter just moves the power to the sponsor, so no change is recommended before the deadline. |
| S2 | P2 | The contract cannot see the post or prove who wrote it. Two creators can submit the same URL; `/check` warns. Already documented in README. |
| S3 | P2 | Shill Score can be farmed with a second wallet acting as sponsor (cost: gas + the paid amount, which goes back to the farmer). Already documented. |
| S4 | P2 | The QIE ID registry address (0x9aab…7bdc) is **not listed in official QIE docs**. It is verified only on chain (it resolves `qie.qie`). Worth confirming with the QIE team. |
| S5 | P3 | Immutable contract: a bug means redeploying and pointing the app at a new address. |
| S6 | P3 | No external audit. Tests passing is not an audit. |

## 6. Configuration

| Item | Status |
|---|---|
| Chain 1990, RPC `rpc1mainnet.qie.digital`, explorer `mainnet.qie.digital` | Confirmed against qie.digital/developers and on chain (`eth_chainId` = 1990). |
| QUSDC `0x3F43…5DA5` | Confirmed: qie.digital/developers and QIEDEX token list; on chain symbol QUSDC, 6 dp. |
| QIEDEX router `0x08cd…53Ef` | Confirmed: qiedex.qie.digital/qiedex-contracts; WQIE and factory match; WQIE/QUSDC pair has liquidity (~28.7k QIE / ~4.55k QUSDC). |
| QIE/USD oracle `0x3Bc6…3D17` | Listed in docs.qie.digital oracle table (as "QIE Native"); fresh on chain. |
| QIE ID `0x9aab…7bdc` | On chain only (see S4). |
| Testnet RPC | `foundry.toml` uses `rpc1testnet`; docs list `rpc4testnet`. Testnet is not used for submission. |
| Explorer type | Blockscout (`/api/v2/stats` responds), so `forge verify-contract --verifier blockscout` works. |
| `NEXT_PUBLIC_QREACH`, `NEXT_PUBLIC_DEPLOY_BLOCK` | **Empty: no deployment exists.** |
| Git remote | `origin` = `github.com/Swastik221/qreach` (fork). Submission repo confirmed 2026-11-28: `github.com/Anand-240/qreach`. |
| `Anchor.toml` | Not present and not relevant (EVM project). |
| Hosting | No Vercel project, CLI or credentials found on this machine. |

## 7. Does a deployment exist?

- **Mainnet contract: no.** No `contracts/broadcast/` records, no address in any config, no GitHub
  deployments, empty repository homepage.
- **Live frontend: no.** No Vercel config or CLI, no URL anywhere in the repository.

## 8. Prioritised action plan

### P0: blocks submission
1. **Deploy `Qreach` to QIE mainnet** (needs your approval and a funded `deployer` keystore, ~0.006 QIE). Then verify it on Blockscout. See `docs/DEPLOYMENT.md`.
2. **Host the frontend** with `NEXT_PUBLIC_CHAIN_ID=1990`, the real address and deploy block (needs your Vercel or other hosting account).
3. **Run one real mainnet flow** (create → accept → submit → pay, plus one refund or decline) with two wallets: ≥ 1 QUSDC or equivalent QIE, plus gas. Record the transaction hashes for the README and demo.

### P1: required before launch
1. Done: wrong-network transaction bug (F1).
2. Decide how to present S1 (no dispute path) in the README and demo. Recommendation: say it plainly.
3. Describe the product as **direct sponsor→creator offers**, not an open marketplace, in the submission text.
4. Confirm which GitHub repository is the submission (`Swastik221/qreach` vs `Anand-240/qreach`) and set `NEXT_PUBLIC_REPO_URL`.
5. Commit and push this pass's changes.

### P2: important
1. Ask QIE to confirm the QIE ID registry address (S4).
2. Fill the README live-demo, contract and transaction sections with real values after P0.
3. Optional: label the oracle row "QIE/USDT feed" to match its on-chain description.

### P3: polish
1. Investigate why `next dev` breaks the Playwright flow (production build is fine).
2. Move the e2e suites to `@playwright/test` with an npm script.

## 9. Update 2026-11-28: pre-deployment re-verification

### Repository state
- PR #1 (`Swastik221/qreach`) was **merged** into the fork's `main` (`e07de10`) on 2026-11-26. It has no reviews or comments.
- **The official submission repository `Anand-240/qreach` is still at `1942729`.** It has none of the readiness changes. `Swastik221/qreach` is a GitHub fork of it; there is no `upstream` remote locally. The contract to be deployed is `Qreach.sol` @ `e07de10`. That file differs from `1942729` only by `forge fmt` whitespace, but whitespace changes the metadata hash, so the official repo must be updated to match the deployed and verified source.

### Re-run results (all fresh)
`forge clean && forge build`: compiles, no solc warnings. `forge fmt --check`: ok. `forge test`: 72 unit/fuzz passed (fuzz 512 runs) and 3 invariants passed (64 × 32 calls). The fork suite reports "1 skipped" because its `setUp` calls `vm.skip` unless `FORK=1`. Run with `FORK=1` against mainnet: 4/4 passed. App: `tsc` ok, Vitest 19/19, `next build` ok.

### `forge lint` findings (15) and classification

| Rule | Location | Class | Reasoning |
|---|---|---|---|
| reentrancy-eth | `Qreach.sol:186` leftover QIE refund to `msg.sender` before `_create` | Informational / false positive | `createCampaignWithQIE` is `nonReentrant`, as is every other function that moves funds. Re-entry into `accept`, `submitWork` or `setQieName` cannot touch this campaign (no id yet) or any balances. `test_reentrancy_viaLeftoverRefundIsBlocked` proves the guard. |
| reentrancy-events | `:373` `CampaignCreated` emitted after the swap and refund | Informational | Same guard. The only events that could interleave belong to other campaigns, and the indexer keys everything by id. |
| unused-return | `:180` router `amounts` ignored | False positive | The contract checks its actual QUSDC balance change instead, which is stronger than trusting the router's return value. |
| block-timestamp ×6 | `:217, 240, 262, 271, 273, 351` | Low | Deadlines are hours to days long; validator skew is seconds. |
| unsafe-typecast ×3 | `:249, 378` `uint64(block.timestamp)`; `:368` `uint128(amount)` | False positive | uint64 seconds overflow in ~5.8×10^11 years. `amount > type(uint128).max` reverts in `_validate` before the cast. |
| uninitialized-local | `:297` `owner_` | False positive | Assigned in the `try` branch; the `catch` branch reverts, so it is never read uninitialized. |
| require-revert-in-loop | `:401` URL character check | Informational | Intended: reject on the first bad byte. |
| environment-read-across-mutation | `test/Qreach.t.sol:688` | Informational (test only) | Without via-IR, `block.timestamp` reads the warped value; the test passes and asserts the right timestamp. |

Also noted, no change needed: (a) QIE force-sent to the contract (selfdestruct) is never refunded and stays stuck, harming no one; (b) if a router ever returned more than `amountOut`, the extra QUSDC would sit unaccounted in the contract. QIEDEX `swapETHForExactTokens` returns exactly `amountOut`, and the mainnet fork test confirms it.

**Conclusion:** no Critical/High/Medium findings. No Solidity change.

### Mainnet dependencies (read-only, block ~12,216,054)
Chain id 1990. All four dependencies and the oracle have bytecode, and none is an EIP-1967 proxy. QUSDC: `symbol` QUSDC, `decimals` 6. Router: `WETH()` = `0x0087…9139` (symbol WQIE); factory `0x8E23…398C`. Quote: 1 QUSDC = 6.33 QIE. QIE ID: `domainOwnerByName("qie","qie")` returns an owner; unknown names revert ("ERC721: owner query for nonexistent token"), which the contract turns into `NotNameOwner`. Still **undocumented by QIE: the QIE ID registry address** (S4).

### Deployer and simulation
- Keystore `deployer` present. Address `0x17be41a4b30AF4C31a6D763139425af1adee1B45` (from the owner's own `--account deployer` simulation; Foundry keystores store no plaintext address). The keystore file mode was `0644`; set to `600` on 2026-11-28.
- Balance 0.05 QIE, nonce 0. Simulation from this sender: `preflight ok`, 1 CREATE, value 0, predicted `0xecf00C31f73296A1EFa9Fe4D3514813D93807740` (matches the earlier simulation, as expected for nonce 0). Gas limit 2,935,961; forge estimate 0.00587 QIE.
- The deploy calldata equals the compiled `Qreach` creation code plus constructor args, byte for byte.
- `foundry-pp/DeployHelper51.sol` stale-artifact warning: a temporary file of forge's `dynamic_test_linking` preprocessor. No `out/` artifact or cache entry references it, and it has no effect on the deployed bytecode (calldata check above).
