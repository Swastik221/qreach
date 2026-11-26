# QREACH security notes

**Not audited.** This is a hackathon project. The review below was done in-house and backed by tests.
Passing tests is not an audit. Use small amounts.

## Trust model

- **No admin.** No owner, no pause, no upgrade, no fee. Nobody can move escrowed funds except
  through the rules below. The deployer has no special rights.
- Funds can only go to the campaign's recorded **sponsor** (cancel, decline, expiry) or its recorded
  **creator** (approval, auto-release). Anyone may trigger `refundExpired` and `autoRelease`, but cannot
  change where the money goes.
- External contracts trusted: QUSDC, the QIEDEX router (only inside `createCampaignWithQIE`), QIE ID
  (only for name ownership). QUSDC on mainnet is not upgradeable and has no pause or blacklist
  functions (checked on chain 2026-11-27).

## Protections in the contract

| Threat | Protection | Test |
|---|---|---|
| Reentrancy | `nonReentrant` on every function that moves funds; state set before transfers | `test_reentrancy_*` |
| Double pay / refund | status checked, then set to a terminal state before transfer | `test_terminalStates_cannotMoveFundsAgain`, invariants |
| Unauthorised actions | sponsor/creator checks on every role function | `test_*_only*`, `testFuzz_strangerCannotMoveFunds` |
| Bad deadlines | accept-by in the future, deliver-by after it, review 1 h–7 d | `test_create_reverts*`, boundary tests |
| Token transfer quirks | OpenZeppelin `SafeERC20` | — |
| Swap slippage | exact-output swap, input capped at `msg.value` (quote + 2% in the app), 15 min deadline, received amount checked, unused QIE returned | `test_createWithQIE_*`, fork test |
| Stray native QIE | `receive` accepts only the router | `test_receive_onlyRouter` |
| Junk URLs / XSS | on-chain: `https://`, printable ASCII, ≤300 bytes; app renders as text and `href` only | `test_submit_rejectsBadUrls` |
| Accounting drift | invariant: balance == open escrow; total supply conserved | invariants |

## Known limitations (by design, stated to users)

1. **No disputes.** After a creator submits a link, the money goes to the creator, either on approval
   or automatically after the review window. A sponsor cannot reject a submission. The contract
   accepts any well-formed https link; it does not check that the post exists or matches the brief.
2. **No proof of authorship.** The contract cannot tell who wrote a post. Several creators can submit
   the same URL; `/check` shows all records and warns when more than one creator claimed it.
3. **Shill Score is not Sybil-resistant.** A creator can raise it by paying themselves from a second
   wallet. It reflects on-chain history only.
4. **Social accounts are not linked.** A `.qie` name proves wallet ownership of the name, not of an
   X/Instagram account.
5. **Immutable.** Bugs are fixed by redeploying, not patching.
6. **Oracle is display-only.** It never affects amounts. The app flags prices older than 6 hours.

## Frontend

- All writes go through `components/useTx.ts`: switch to the app chain, simulate, sign with an explicit
  `chainId`, wait for the receipt, and show failure if `status !== success`.
- Only `NEXT_PUBLIC_*` variables are read. The production bundle was scanned for key-like strings and
  none were found.
- No backend, no cookies, no stored user data.

## Reporting

Open a GitHub issue without exploit details and ask for a private contact, or contact the maintainers directly.
