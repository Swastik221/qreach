# QREACH architecture

## Overview

QREACH is a creator escrow with a public record of paid posts. A sponsor locks QUSDC for one named
creator. The creator accepts, publishes the post and submits its link. The sponsor approves, or stays
silent until the review window ends. Then the creator is paid and anyone can look the post up.

There is no backend and no database. The contract is the only source of truth. The app reads
contract views and rebuilds history from event logs in the browser.

```
┌──────────── Browser (Next.js 15, wagmi 2, viem 2) ────────────┐
│ pages: / /check /sponsor /sponsor/new /creator /c/[id]         │
│        /k/[name] /judge                                        │
│ lib/indexer.ts  ── getLogs in 9,999-block chunks from          │
│                    NEXT_PUBLIC_DEPLOY_BLOCK, incremental cache │
│ components/useTx.ts ── switch chain → simulate → sign →        │
│                        wait for receipt → check status         │
└───────────────┬───────────────────────────────┬───────────────┘
                │ writes / reads                 │ reads only
                ▼                                ▼
     Qreach.sol (QIE mainnet)            QIE oracle (QIE/USD, display)
       ├─ QUSDC (SafeERC20)              QIEDEX getAmountsIn (quote)
       ├─ QIEDEX router (swapETHForExactTokens)
       └─ QIE ID (domainOwnerByName)
```

## Contract: `contracts/src/Qreach.sol`

State per campaign: sponsor, creator, amount (uint128, 6 dp), acceptBy, deliverBy, reviewWindow,
status, submittedAt, paidAt, postHash.

```
            accept (creator, ≤acceptBy)       submitWork (creator, ≤deliverBy)
 Created ─────────────────────────► Accepted ───────────────────────────► Submitted
   │  │                                │                                     │
   │  └ decline (creator) ► Declined   └ refundExpired (anyone, >deliverBy)   ├ approveAndPay (sponsor)
   ├ cancel (sponsor) ───► Refunded         ► Refunded                       └ autoRelease (anyone,
   └ refundExpired (anyone, >acceptBy) ► Refunded                               >submittedAt+review)
                                                                               ► Paid
```

| Function | Who | Effect |
|---|---|---|
| `createCampaign` | sponsor | pull `amount` QUSDC (needs approval) |
| `createCampaignWithQIE` | sponsor | swap QIE → exact QUSDC on QIEDEX, return unused QIE |
| `cancel` | sponsor | Created → Refunded |
| `accept` / `decline` | creator | Created → Accepted / Declined (refund) |
| `submitWork` | creator | Accepted → Submitted; stores keccak256 of the normalised URL |
| `approveAndPay` | sponsor | Submitted → Paid |
| `autoRelease` | anyone | Submitted → Paid after the review window |
| `refundExpired` | anyone | Created/Accepted → Refunded after the matching deadline |
| `setQieName` | anyone | links caller to a `.qie` label they own in QIE ID |

Limits: minimum 0.5 QUSDC; brief ≤ 500 bytes; URL 10–300 bytes, `https://`, printable ASCII;
review window 1 h–7 d. Every change emits an event (`CampaignCreated`, `Accepted`, `Declined`,
`WorkSubmitted`, `PaidPromotion`, `Refunded`, `QieNameSet`).

Creator stats (`completed`, `expired`, `earned`) are kept on chain for the Shill Score:
`50 × delivered rate + 30 × min(1, completed/10) + 20 × min(1, sponsors/5)`.

## Frontend: `app/`

| Path | Purpose |
|---|---|
| `lib/config.ts` | chain selection (1990 / 1983 / 31337), official mainnet addresses, explorer links |
| `lib/abi.ts` | ABI generated with `forge inspect Qreach abi` (checked identical to the build) |
| `lib/indexer.ts` | event-log indexer with overlap re-scan and de-duplication |
| `lib/normalizeUrl.ts` | canonical post URLs for X, Instagram, YouTube, LinkedIn |
| `lib/campaign.ts` | allowed next actions from status + chain time |
| `lib/oracle.ts` | oracle price with staleness flag; QIEDEX quote |
| `lib/qieName.ts` | `.qie` resolve and reverse lookup, re-checked against QIE ID |
| `components/useTx.ts` | the only write path; real receipt status |
| `components/useChainNow.ts` | deadlines use the chain's clock, not the browser's |

## QIE components

| Component | Used for |
|---|---|
| QIE Mainnet | everything |
| QUSDC | escrow currency |
| QIEDEX | pay in QIE (contract) and live quotes (app) |
| QIE ID | pick creators by `.qie` name; on-chain ownership check |
| QIE Oracle | QIE/USD shown next to the QIE quote |
| QIE Wallet | EIP-1193 / EIP-6963 injected wallet |
