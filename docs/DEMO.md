# Demo script (3–4 minutes)

Prepare beforehand: wallet A (sponsor) with ≥ 1 QUSDC and some QIE, wallet B (creator) with a little
QIE for gas and, ideally, a `.qie` name linked on `/creator`. Publish a real post from B's social account.
Keep a second browser profile signed in as B.

| Time | Show | Say |
|---|---|---|
| 0:00 | `/` | Sponsored posts are often undisclosed, and creators often get paid late or not at all. Both sides need trust. |
| 0:25 | `/` ticker | QREACH puts the deal on QIE: money is locked before work starts, and every paid post becomes a public record. |
| 0:40 | `/sponsor/new` as A | Pick the creator by `.qie` name (QIE ID). Set 1 QUSDC, deadlines and a brief. Show the QIE option with the live QIEDEX quote and oracle price. Lock: approve, then lock. Open the explorer link. |
| 1:30 | `/creator` as B | The offer appears. Accept (explorer link). Paste the post link: it is cleaned to a canonical URL. Submit. |
| 2:15 | `/c/<id>` as A | Timeline with a transaction for each step. Approve and pay: 1 QUSDC moves to B in the same transaction. |
| 2:40 | `/check` | Paste the post link from another share URL. It shows "Paid": who, how much, when, and the brief. Anyone can check this without a wallet. |
| 3:05 | `/k/<name>` | Shill Score, computed only from on-chain history. |
| 3:20 | `/judge` | Contract with no owner, no fee and no upgrade path. Five QIE components with live data. How to run the tests. |
| 3:40 | — | Limits, stated plainly: no dispute process (silence pays the creator), the contract cannot see the post, the score can be farmed. |

## Transactions to capture for the README (after the live run)

| Step | Tx hash | Explorer link |
|---|---|---|
| Deploy QREACH | | |
| Approve QUSDC | | |
| createCampaign | | |
| accept | | |
| submitWork | | |
| approveAndPay | | |
| createCampaignWithQIE (optional) | | |
| decline or refundExpired (optional) | | |

## Screenshots to take

Home, sponsor form with the QIE quote, campaign timeline (paid), `/check` "Paid" result, creator
profile, judge page, phone-width campaign page.
