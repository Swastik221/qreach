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

## Checklist

- [ ] `forge test` and `FORK=1 forge test --match-contract Fork --fork-url https://rpc1mainnet.qie.digital` pass
- [ ] Deployer keystore exists (`cast wallet list`) and holds at least 0.05 QIE (deploy costs ~0.006 QIE)
- [ ] Dry run prints `preflight ok` and `chain 1990`
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

The script stops with a revert message if any dependency check fails.

## 3. Deploy (sends a transaction)

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url qie_mainnet --account deployer --broadcast
```

Read the real results from the broadcast record. Do not use the "block (simulation)" line from the log:

```bash
jq -r '.transactions[0].contractAddress, .transactions[0].hash, (.receipts[0].blockNumber|tonumber)' contracts/broadcast/Deploy.s.sol/1990/run-latest.json
```

Check on chain:

```bash
cast call <QREACH> "qusdc()(address)" --rpc-url https://rpc1mainnet.qie.digital
```

```bash
cast call <QREACH> "nextId()(uint256)" --rpc-url https://rpc1mainnet.qie.digital
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
   | `NEXT_PUBLIC_REPO_URL` | the submission repository URL |

   Leave `NEXT_PUBLIC_QUSDC` and `NEXT_PUBLIC_QIEID` empty on mainnet.
3. Deploy, then run the smoke test below.

With the CLI instead: `npm i -g vercel`, then `cd app && vercel link`, add the variables with `vercel env add`, and run `vercel --prod`.

## 6. Smoke test after hosting

- [ ] `/` loads and the ticker shows numbers (contract reads work)
- [ ] Connect QIE Wallet; on another network the header shows "Switch to QIE Mainnet"
- [ ] `/judge` shows the contract address, "QUSDC at 0x3F43…", a live QIEDEX quote and the oracle price
- [ ] `/check?u=https://x.com/i/status/1` shows "No QREACH record"
- [ ] `/sponsor/new` shows your QUSDC balance
- [ ] Real flow (each step sends a transaction): create a 0.5 QUSDC offer from wallet A, accept and submit from wallet B, approve from A, confirm `/check` shows "Paid"

## Rollback

The contract cannot be changed or paused. If a problem is found, stop linking to it, deploy a fixed
version, and point `NEXT_PUBLIC_QREACH` and `NEXT_PUBLIC_DEPLOY_BLOCK` at the new one. Open campaigns
on the old contract still settle under its own rules: anyone can trigger refunds and auto-releases.
