# Deploying QREACH

Nothing in this file has been broadcast yet. Each step marked **(sends a transaction)** needs the
owner's explicit approval first.

## Network (verified 2026-11-27)

| | Value | Source |
|---|---|---|
| Chain ID | 1990 | qie.digital/developers, `cast chain-id` |
| RPC | https://rpc1mainnet.qie.digital | qie.digital/developers |
| Explorer | https://mainnet.qie.digital (Blockscout) | qie.digital/developers, `/api/v2/stats` |

## Constructor arguments (hard-coded in `contracts/script/Deploy.s.sol`)

| Argument | Address | Verified |
|---|---|---|
| `qusdc_` | `0x3F43DA82eC9A4f5285F10FaF1F26EcA7319E5DA5` | QIE docs + on chain (symbol QUSDC, 6 decimals) |
| `router_` (QIEDEX) | `0x08cd2e72e156D8563B4351eb4065C262A9f553Ef` | QIEDEX docs + on chain (WQIE `0x0087…9139`) |
| `qieId_` | `0x9aab56e7727af53A3131985BFB16d845319b7bdc` | on chain only (not in QIE docs) |

The contract has no owner and no settings, so there is nothing to configure after deployment.
The deployer has no special rights.

## Pre-deploy state (checked 2026-11-28, mainnet block ~12,216,065)

| Item | Value |
|---|---|
| Source | `Anand-240/qreach` `main` after the sync (identical tree to fork `e07de10`). `Qreach.sol` git blob `f6e363d` / sha256 `8451…1348`; `Deploy.s.sol` blob `980fa3b` / sha256 `35bd…2521` |
| Deployer | Foundry keystore `deployer` → `0x17be41a4b30AF4C31a6D763139425af1adee1B45` (sender of the `--account deployer` simulation; keystore files carry no plaintext address) |
| Deployer balance / nonce | 0.05 QIE / 0 (re-checked at block 12,216,207). Keystore file mode set to `600`. |
| Predicted address | `0xecf00C31f73296A1EFa9Fe4D3514813D93807740` = CREATE(deployer, nonce 0). **Only valid while the nonce is 0**: any other transaction from this wallet first changes it. |
| Simulation | `preflight ok`, chain 1990, exactly 1 CREATE, value 0, constructor args as above |
| Bytecode check | Simulated deploy input == `forge inspect src/Qreach.sol:Qreach bytecode` + ABI-encoded args (byte-for-byte) |
| Gas | limit 2,935,961; network gas price 1.125 gwei (base fee 1 gwei) |
| Cost | forge's estimate 0.00587 QIE (at a 2 gwei max fee). At 1.125 gwei ≈ 0.0033 QIE. Even at 10 gwei it is 0.029 QIE, under the 0.05 QIE balance. |

## Checklist

- [x] `forge test` (72 unit/fuzz, 3 invariants) and the fork suite (4/4) pass, re-run 2026-11-28
- [x] Deployer keystore exists and holds 0.05 QIE
- [x] Simulation prints `preflight ok` and `chain 1990`; predicted address `0xecf0…7740`
- [ ] Owner has approved the broadcast

## 1. Keystore (once; the key never appears in a command or a file in the repo)

```bash
cast wallet import deployer --interactive
```

```bash
cast balance $(cast wallet address --account deployer) --rpc-url https://rpc1mainnet.qie.digital --ether
```

## 2. Dry run (simulation only, nothing is sent)

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url qie_mainnet --account deployer
```

The script stops with a revert message if any dependency check fails. To simulate without unlocking
the keystore, use `--sender 0x17be41a4b30AF4C31a6D763139425af1adee1B45` in place of `--account deployer`.
The predicted address is the same, because CREATE addresses depend only on sender and nonce.

## 3. Deploy (sends a transaction)

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url qie_mainnet --account deployer --broadcast
```

Read the real results from the broadcast record. Do not use the "block (simulation)" line from the log:

```bash
jq -r '.transactions[0].contractAddress, .transactions[0].hash, (.receipts[0].blockNumber|tonumber)' contracts/broadcast/Deploy.s.sol/1990/run-latest.json
```

Check on chain. Expect receipt status `1`, non-empty code, the three dependencies, `nextId` 1 and
`MIN_AMOUNT` 500000. The contract has no `owner()`; that call is expected to revert.

```bash
cast receipt <TX_HASH> status --rpc-url https://rpc1mainnet.qie.digital
```

```bash
cast codesize <QREACH> --rpc-url https://rpc1mainnet.qie.digital
```

```bash
for f in "qusdc()(address)" "router()(address)" "qieId()(address)" "nextId()(uint256)" "MIN_AMOUNT()(uint256)"; do cast call <QREACH> "$f" --rpc-url https://rpc1mainnet.qie.digital; done
```

Commit `contracts/broadcast/Deploy.s.sol/1990/run-latest.json`. It holds only public data and serves as the
deployment evidence.

## 4. Verify source on the explorer (Blockscout, no API key)

```bash
cd contracts && forge verify-contract <QREACH> src/Qreach.sol:Qreach --chain-id 1990 --verifier blockscout --verifier-url https://mainnet.qie.digital/api/ --constructor-args $(cast abi-encode "constructor(address,address,address)" 0x3F43DA82eC9A4f5285F10FaF1F26EcA7319E5DA5 0x08cd2e72e156D8563B4351eb4065C262A9f553Ef 0x9aab56e7727af53A3131985BFB16d845319b7bdc) --watch
```

Compiler settings come from `foundry.toml` (solc 0.8.24, optimizer 200 runs).

## 5. Frontend (Vercel)

1. Import the GitHub repository in Vercel. Set **Root Directory** to `app`. The framework is Next.js and the default build command works.
2. Environment variables (Production):

   | Name | Value |
   |---|---|
   | `NEXT_PUBLIC_CHAIN_ID` | `1990` |
   | `NEXT_PUBLIC_QREACH` | address from step 3 |
   | `NEXT_PUBLIC_DEPLOY_BLOCK` | block from step 3 |
   | `NEXT_PUBLIC_REPO_URL` | `https://github.com/Anand-240/qreach` |

   Leave `NEXT_PUBLIC_QUSDC` and `NEXT_PUBLIC_QIEID` empty on mainnet. RPC, explorer, QUSDC, QIEDEX,
   QIE ID and oracle addresses are built into `app/lib/config.ts` for chain 1990, so no variable is needed for them.
3. Deploy, then run the smoke test below.

With the CLI instead: `npm i -g vercel`, then `cd app && vercel link`, add the variables with `vercel env add`, and run `vercel --prod`.

## 6. Smoke test after hosting

- [ ] `/` loads and the ticker shows numbers (contract reads work)
- [ ] Connect QIE Wallet; on another network the header shows "Switch to QIE Mainnet"
- [ ] `/judge` shows the contract address, "QUSDC at 0x3F43…", a live QIEDEX quote and the oracle price
- [ ] `/check?u=https://x.com/i/status/1` shows "No QREACH record"
- [ ] `/sponsor/new` shows your QUSDC balance
## 7. Real two-wallet test on mainnet (every step sends a transaction)

Needs two different wallets. **S** (sponsor) holds at least 1 QUSDC plus about 0.01 QIE for gas.
**C** (creator) holds about 0.01 QIE for gas. Run it against the hosted app with the real address set.
Record every transaction hash in `docs/DEMO.md`.

| # | Who | Action in the app | Verify |
|---|---|---|---|
| 1 | S | `/sponsor/new`: creator = C's address or `.qie` name, 1 QUSDC, review 1 hour, brief | wallet asks for **approve** then **lock**; the campaign page (`/c/<ID>`) shows Created |
| 2 | C | `/creator` → open the offer → Accept | status Accepted; tx link opens on mainnet.qie.digital |
| 3 | C | Submit a real public `https://` post URL | status Submitted; `/check?u=<url>` shows "payment pending" |
| 4 | S | `/c/<ID>` → Approve and pay | status Paid; `/check` shows "Paid", 1.00 QUSDC, S → C |

Independent checks after step 4 (read-only):

```bash
cast call <QREACH> "getCampaign(uint256)((address,uint64,uint32,uint8,address,uint64,uint64,uint128,uint64,bytes32))" <ID> --rpc-url https://rpc1mainnet.qie.digital
```

```bash
cast call 0x3F43DA82eC9A4f5285F10FaF1F26EcA7319E5DA5 "balanceOf(address)(uint256)" <QREACH> --rpc-url https://rpc1mainnet.qie.digital
```

```bash
cast logs --address <QREACH> --from-block <DEPLOY_BLOCK> "PaidPromotion(uint256,address,address,uint256,bytes32,uint64,bool)" --rpc-url https://rpc1mainnet.qie.digital
```

Expect: status `4` (Paid). The contract's QUSDC balance equals the sum of open campaigns (0 if none
are open). C's QUSDC balance went up by exactly 1,000,000 units. There is one `PaidPromotion` log with
`autoReleased = false`.

Other paths (each costs gas and at least 0.5 QUSDC per campaign):
- **Auto-release:** after step 3 on a second campaign, wait out the review window (minimum 1 hour), then anyone clicks "Release payment to creator". Expect a `PaidPromotion` log with `autoReleased = true`.
- **Refund:** create an offer and let the accept deadline pass (minimum 1 day in the app), then anyone clicks "Refund sponsor". For a quick demo, use **Decline** (C) or **Cancel** (S) instead, which refund at once.
- **Pay in QIE:** choose QIE on `/sponsor/new`. The unused QIE comes back in the same transaction.

Write down any step that fails, with its transaction hash. Do not mark the flow as done until all four core steps are confirmed on the explorer.

## Rollback

The contract cannot be changed or paused. If a problem is found, stop linking to it, deploy a fixed
version, and point `NEXT_PUBLIC_QREACH` and `NEXT_PUBLIC_DEPLOY_BLOCK` at the new one. Open campaigns
on the old contract still settle under its own rules: anyone can trigger refunds and auto-releases.
