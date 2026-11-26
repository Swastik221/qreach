// Shared helpers for the QREACH end-to-end suites. Run of every QREACH button against a local anvil chain.
// A small EIP-1193 test wallet is injected; it forwards calls to anvil, whose dev accounts are unlocked.
// Setup: anvil running, `bash reset.sh` done, app on :3210 with CHAIN_ID=31337 and the reset.sh addresses.
// Run:   RUN=1 node flow.mjs
import { chromium } from "playwright";
import fs from "node:fs";
import { execSync } from "node:child_process";

const APP = process.env.APP ?? "http://localhost:3210";
const RPC = "http://127.0.0.1:8545";
const SPONSOR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const CREATOR = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const STRANGER = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";
const OUT = new URL(`./shots-${process.env.RUN ?? "x"}/`, import.meta.url).pathname;
fs.mkdirSync(OUT, { recursive: true });

function walletScript(account) {
  return `(() => {
    const RPC = ${JSON.stringify(RPC)}, ACCT = ${JSON.stringify(account)};
    let id = 0, authorized = localStorage.getItem("tw-auth") === "1";
    const listeners = {};
    const provider = {
      isTestWallet: true,
      async request({ method, params }) {
        if (method === "eth_requestAccounts") { authorized = true; localStorage.setItem("tw-auth", "1"); return [ACCT]; }
        if (method === "eth_accounts") return authorized ? [ACCT] : [];
        if (method === "eth_chainId" && localStorage.getItem("tw-wrong-chain") === "1") return "0x1";
        if (method === "wallet_switchEthereumChain" || method === "wallet_addEthereumChain") {
          localStorage.removeItem("tw-wrong-chain");
          (listeners.chainChanged ?? []).forEach((f) => f("0x7a69"));
          return null;
        }
        if (method === "eth_sendTransaction" && localStorage.getItem("tw-reject") === "1") {
          localStorage.removeItem("tw-reject");
          const e = new Error("User rejected the request."); e.code = 4001; throw e;
        }
        if (method === "wallet_requestPermissions") return [{ parentCapability: "eth_accounts" }];
        if (method === "wallet_revokePermissions") { authorized = false; localStorage.removeItem("tw-auth"); return null; }
        const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params: params ?? [] }) });
        const j = await r.json();
        if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; e.data = j.error.data; throw e; }
        return j.result;
      },
      on(ev, fn) { (listeners[ev] ??= []).push(fn); },
      removeListener(ev, fn) { listeners[ev] = (listeners[ev] ?? []).filter((f) => f !== fn); },
    };
    window.ethereum = provider;
    window.__twEmit = (ev, v) => (listeners[ev] ?? []).forEach((f) => f(v));
    const info = { uuid: "00000000-0000-4000-8000-000000000001", name: "Test Wallet", icon: "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg'/>", rdns: "dev.test.wallet" };
    const announce = () => window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail: Object.freeze({ info, provider }) }));
    window.addEventListener("eip6963:requestProvider", announce);
    announce();
  })();`;
}

async function rpc(method, params = []) {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  return (await r.json()).result;
}
async function warp(seconds) {
  await rpc("evm_increaseTime", [seconds]);
  await rpc("evm_mine");
}

const browser = await chromium.launch();
const errors = [];
let shotN = 0;
async function ctx(account, viewport = { width: 1280, height: 900 }) {
  const c = await browser.newContext({ viewport });
  await c.grantPermissions(["clipboard-read", "clipboard-write"], { origin: APP });
  await c.addInitScript(walletScript(account));
  const p = await c.newPage();
  p.on("pageerror", (e) => errors.push(`pageerror: ${e.message.split("\n")[0]}`));
  p.on("console", (m) => m.type() === "error" && errors.push(`console: ${m.text().split("\n")[0]}`));
  return p;
}
async function connect(p) {
  const header = p.locator("header");
  await header.getByRole("button", { name: "Connect wallet" }).click();
  await header.getByRole("button", { name: "Test Wallet" }).click();
  await header.getByRole("button", { name: "Disconnect" }).waitFor();
}
const shot = (p, n) => p.screenshot({ path: `${OUT}${String(++shotN).padStart(2, "0")}-${n}.png`, fullPage: true });
const step = (s) => console.log(`-- ${s}`);
const done = (p, label) => p.getByRole("status").filter({ hasText: `${label}: done` }).waitFor({ timeout: 30000 });

async function createCampaign(s, { creator, amount, quick, review = "24", acceptDays = "2", pay = "QUSDC", brief }) {
  await s.goto(`${APP}/sponsor/new`);
  await s.getByLabel("1. Creator").fill(creator);
  if (quick) await s.getByRole("button", { name: `${quick} QUSDC`, exact: true }).click();
  else await s.getByLabel("2. Amount (QUSDC = US dollars)").fill(amount);
  if (pay === "QIE") {
    await s.getByRole("button", { name: "QIE", exact: true }).click();
    await s.getByText(/You send up to/).waitFor();
  }
  await s.getByLabel("4. Accept within").selectOption(acceptDays);
  await s.getByLabel("Your review time").selectOption(review);
  await s.getByLabel("5. Brief").fill(brief);
  const lock = s.getByRole("button", { name: /^Lock .* QUSDC$/ });
  await lock.waitFor();
  await s.waitForFunction(() => {
    const b = [...document.querySelectorAll("button")].find((x) => /^Lock .* QUSDC$/.test(x.textContent ?? ""));
    return b && !b.disabled;
  }, null, { timeout: 30000 });
  await lock.click();
  await s.waitForURL(/\/c\/\d+$/, { timeout: 60000 });
  return Number(s.url().split("/").pop());
}


// ======================= Suite 2: edge cases, wrong paths and money accounting =======================
const PP = "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9";
const QUSDC = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
const SPONSOR2 = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"; // anvil account 3, holds no QUSDC
const castBin = `${process.env.HOME}/.foundry/bin/cast`;
const cast = (args) => execSync(`${castBin} ${args} --rpc-url ${RPC}`, { encoding: "utf8", cwd: "/tmp" }).trim();
const qusdcOf = (a) => BigInt(cast(`call ${QUSDC} "balanceOf(address)(uint256)" ${a}`).split(" ")[0]);
const expect = (cond, msg) => { if (!cond) throw new Error(`CHECK FAILED: ${msg}`); };
const setFlag = (p, k) => p.evaluate((k) => localStorage.setItem(k, "1"), k);

try {
  // ---------- Wrong network, then switch ----------
  const s = await ctx(SPONSOR);
  await s.goto(`${APP}/`);
  await connect(s);
  await s.evaluate(() => { localStorage.setItem("tw-wrong-chain", "1"); window.__twEmit("chainChanged", "0x1"); });
  await s.locator("header").getByRole("button", { name: /Switch to/ }).click();
  await s.locator("header").getByRole("button", { name: "Disconnect" }).waitFor({ timeout: 15000 });
  step("A wrong network shows Switch button; switching connects");

  // ---------- Connection survives reload; Enter key submits check ----------
  await s.reload();
  await s.locator("header").getByRole("button", { name: "Disconnect" }).waitFor({ timeout: 15000 });
  await s.getByLabel("Post link").fill("x.com/a/status/1");
  await s.getByLabel("Post link").press("Enter");
  await s.waitForURL(/\/check\?u=/);
  await s.getByText("No QREACH record").waitFor({ timeout: 30000 });
  step("B wallet stays connected after reload; Enter submits the check box");

  // ---------- Form validation ----------
  await s.goto(`${APP}/sponsor/new`);
  // Wallet drifts to another network; the next transaction must switch back before signing.
  await s.evaluate(() => { localStorage.setItem("tw-wrong-chain", "1"); window.__twEmit("chainChanged", "0x1"); });
  await s.locator("header").getByRole("button", { name: /Switch to/ }).waitFor();
  await s.getByRole("button", { name: "Mint 100 test QUSDC" }).click();
  await done(s, "Mint 100 test QUSDC");
  expect(await s.evaluate(() => localStorage.getItem("tw-wrong-chain")) === null, "wallet was switched before the tx was sent");
  step("B2 a transaction started on the wrong network switches the wallet first");
  const lockBtn = s.getByRole("button", { name: /^Lock .* QUSDC$/ });
  await s.getByLabel("1. Creator").fill(SPONSOR);
  await s.getByText("You cannot hire yourself.").waitFor();
  await s.getByLabel("1. Creator").fill("not a name!");
  await s.getByText("Enter a .qie name like riya.qie, or a 0x address.").waitFor();
  await s.getByLabel("1. Creator").fill("riya.qie");
  await s.getByLabel("2. Amount (QUSDC = US dollars)").fill("0.4");
  await s.getByText("The minimum is 0.5 QUSDC.").waitFor();
  await s.getByLabel("2. Amount (QUSDC = US dollars)").fill("500");
  await s.getByText("Not enough QUSDC in your wallet.").waitFor();
  await s.getByLabel("2. Amount (QUSDC = US dollars)").fill("2");
  await s.getByLabel("4. Accept within").selectOption("7");
  await s.getByLabel("Post within").selectOption("5");
  await s.getByText("The posting deadline must be after the accept deadline.").waitFor();
  await s.getByLabel("Post within").selectOption("14");
  await s.getByText("Write a short brief.").waitFor();
  expect(await lockBtn.isDisabled(), "lock disabled while brief empty");
  await s.getByLabel("5. Brief").fill("x".repeat(600));
  expect((await s.getByLabel("5. Brief").inputValue()).length === 500, "brief capped at 500");
  await s.getByLabel("5. Brief").fill("Validation test campaign.");
  expect(!(await lockBtn.isDisabled()), "lock enabled when valid");
  await shot(s, "form-valid");
  step("C form validation: self-hire, bad name, min amount, balance, date order, brief required and capped");

  // ---------- Reject in wallet at step 2, retry needs one step only (allowance kept) ----------
  await s.getByLabel("4. Accept within").selectOption("2");
  await s.getByLabel("Post within").selectOption("5");
  await s.getByLabel("Your review time").selectOption("1");
  await s.getByText("Two wallet steps: approve QUSDC, then lock it.").waitFor();
  // approve goes through, then reject the lock
  await s.evaluate(() => {
    const orig = window.ethereum.request.bind(window.ethereum);
    let n = 0;
    window.ethereum.request = async (a) => {
      if (a.method === "eth_sendTransaction" && ++n === 2) { const e = new Error("User rejected the request."); e.code = 4001; throw e; }
      return orig(a);
    };
  });
  await lockBtn.click();
  await s.getByText("You rejected the request in your wallet.").waitFor({ timeout: 30000 });
  expect(qusdcOf(PP) === 0n, "nothing locked after rejection");
  await s.getByText("Two wallet steps: approve QUSDC, then lock it.").waitFor({ state: "detached", timeout: 15000 });
  await lockBtn.click();
  await s.waitForURL(/\/c\/1$/, { timeout: 60000 });
  expect(qusdcOf(PP) === 2_000_000n, "2 QUSDC locked");
  step("D wallet rejection shows a readable error, locks nothing; retry uses the existing approval (1 step)");

  // ---------- Stranger sees no actions; creator cannot approve ----------
  const x = await ctx(STRANGER);
  await x.goto(`${APP}/c/1`);
  await x.getByText("Connect to act on this campaign.").waitFor({ timeout: 30000 });
  await connect(x);
  for (const name of ["Accept offer", "Cancel offer", /Approve and pay/, "Submit post", "Refund sponsor", "Release payment to creator"])
    expect((await x.getByRole("button", { name }).count()) === 0, `stranger must not see ${name}`);
  step("E stranger sees the campaign but no action buttons");

  // ---------- Creator: accept, submit; pending state on /check; reuse blocked ----------
  const c = await ctx(CREATOR);
  await c.goto(`${APP}/c/1`);
  await connect(c);
  await c.getByRole("button", { name: "Accept offer" }).click();
  await done(c, "Accept offer");
  expect((await c.getByRole("button", { name: /Approve and pay/ }).count()) === 0, "creator cannot see approve");
  await c.getByLabel("Link to your published post").fill("https://x.com/riya/status/777");
  await c.getByRole("button", { name: "Submit post" }).click();
  await done(c, "Submit post");
  await x.goto(`${APP}/check?u=${encodeURIComponent("https://twitter.com/RIYA/status/777?s=1")}`);
  await x.getByText("Paid deal / payment pending").waitFor({ timeout: 30000 });
  await shot(x, "check-pending");
  step("F submitted post shows 'payment pending' on /check (from a different share link)");

  // second campaign, creator tries to reuse the same post
  const id2 = await createCampaign(s, { creator: "riya.qie", amount: "1", brief: "Reuse test." });
  await c.goto(`${APP}/c/${id2}`);
  await c.getByRole("button", { name: "Accept offer" }).click();
  await done(c, "Accept offer");
  await c.getByLabel("Link to your published post").fill("https://mobile.twitter.com/riya/status/777/photo/1");
  await c.getByRole("button", { name: "Submit post" }).click();
  await c.getByText("You already used this post in another campaign.").waitFor({ timeout: 30000 });
  step("G a creator cannot reuse their own post on a second campaign (readable error)");

  // ---------- Squatting: someone else submits riya's next post first; riya is not blocked ----------
  const sq = await ctx(STRANGER);
  const idSq = await createCampaign(s, { creator: STRANGER, amount: "0.5", brief: "Squatter campaign." });
  await sq.goto(`${APP}/c/${idSq}`);
  await connect(sq);
  await sq.getByRole("button", { name: "Accept offer" }).click();
  await done(sq, "Accept offer");
  await sq.getByLabel("Link to your published post").fill("https://x.com/riya/status/888");
  await sq.getByRole("button", { name: "Submit post" }).click();
  await done(sq, "Submit post");
  const idReal = await createCampaign(s, { creator: "riya.qie", amount: "0.5", brief: "Real campaign for post 888." });
  await c.goto(`${APP}/c/${idReal}`);
  await c.getByRole("button", { name: "Accept offer" }).click();
  await done(c, "Accept offer");
  await c.getByLabel("Link to your published post").fill("https://x.com/riya/status/888");
  await c.getByRole("button", { name: "Submit post" }).click();
  await done(c, "Submit post");
  await x.goto(`${APP}/check?u=${encodeURIComponent("x.com/riya/status/888")}`);
  await x.getByText("Warning: 2 different creators submitted this post.").waitFor({ timeout: 30000 });
  expect((await x.getByText("Paid deal / payment pending").count()) === 2, "both records shown");
  await shot(x, "check-squat-warning");
  step(`G2 squatter submitted riya's post first (#${idSq}); riya still submitted it (#${idReal}); /check shows both with a warning`);

  // ---------- Sponsor pays #1; creator misses deadline on #2; score drops ----------
  await s.goto(`${APP}/c/1`);
  await s.getByRole("button", { name: /Approve and pay/ }).click();
  await done(s, "Approve and pay");
  const creatorBefore = qusdcOf(CREATOR);
  expect(creatorBefore === 2_000_000n, `creator got 2 QUSDC, has ${creatorBefore}`);
  await warp(6 * 86400);
  await c.goto(`${APP}/c/${id2}`);
  await c.getByText("Expired").waitFor({ timeout: 30000 });
  expect((await c.getByRole("button", { name: "Submit post" }).count()) === 0, "no submit after deadline");
  await s.goto(`${APP}/c/${id2}`);
  const sBefore = qusdcOf(SPONSOR);
  await s.getByRole("button", { name: "Refund sponsor" }).click();
  await done(s, "Refund sponsor");
  expect(qusdcOf(SPONSOR) - sBefore === 1_000_000n, "sponsor refunded 1 QUSDC");
  await c.goto(`${APP}/k/${CREATOR}`);
  await c.getByText("Shill Score / 100").waitFor({ timeout: 30000 });
  const score = (await c.locator(".display.text-8xl").innerText()).trim();
  // completed 1, expired 1, sponsors 1: 50*0.5 + 30*0.1 + 20*0.2 = 32
  expect(score === "32", `score after a missed deadline should be 32, is ${score}`);
  await shot(c, "profile-after-miss");
  step("H creator missed a deadline: no submit button, sponsor refunded exactly, Shill Score 57 -> 32");

  // ---------- Offer past accept-by: creator can still decline ----------
  const id3 = await createCampaign(s, { creator: "riya.qie", amount: "0.5", acceptDays: "1", brief: "Late decline test." });
  await warp(1.5 * 86400);
  await c.goto(`${APP}/c/${id3}`);
  await c.getByText("The accept deadline passed. You can still decline", { exact: false }).waitFor({ timeout: 30000 });
  expect((await c.getByRole("button", { name: "Accept offer" }).count()) === 0, "no accept after accept-by");
  await c.getByRole("button", { name: "Decline and refund" }).click();
  await c.getByRole("button", { name: "Yes, decline and refund" }).click();
  await done(c, "Decline offer");
  step("I after accept-by the creator cannot accept but can decline, which refunds");

  // ---------- Sponsor without QUSDC; pay with QIE returns the leftover ----------
  const s2 = await ctx(SPONSOR2, { width: 390, height: 844 });
  await s2.goto(`${APP}/sponsor/new`);
  await s2.getByRole("button", { name: "Menu" }).click();
  await s2.locator("#mobile-menu").getByRole("button", { name: "Connect wallet" }).click();
  await s2.locator("#mobile-menu").getByRole("button", { name: "Test Wallet" }).click();
  await s2.getByRole("button", { name: "Close" }).click();
  await s2.getByLabel("1. Creator").fill("riya.qie");
  await s2.getByLabel("2. Amount (QUSDC = US dollars)").fill("3");
  await s2.getByText("Not enough QUSDC in your wallet.").waitFor({ timeout: 30000 });
  await s2.getByRole("button", { name: "QIE", exact: true }).click();
  await s2.getByText(/You send up to/).waitFor();
  await s2.getByLabel("5. Brief").fill("Paid in QIE from a phone.");
  const nativeBefore = BigInt(await rpc("eth_getBalance", [SPONSOR2, "latest"]));
  await s2.getByRole("button", { name: /^Lock 3.00 QUSDC$/ }).click();
  await s2.waitForURL(/\/c\/\d+$/, { timeout: 60000 });
  const nativeAfter = BigInt(await rpc("eth_getBalance", [SPONSOR2, "latest"]));
  const spent = nativeBefore - nativeAfter;
  const swapCost = 3_000_000n * 1_000_000_000n; // mock price: 1 unit = 1 gwei
  expect(spent >= swapCost && spent < swapCost + 10n ** 15n, `QIE spent ${spent}, swap cost ${swapCost}: the 2% headroom must come back`);
  await shot(s2, "qie-campaign-mobile");
  step(`J phone-size sponsor with no QUSDC paid in QIE; spent ${spent} wei = swap cost + gas, headroom returned`);

  // ---------- Indexer across the 10,000-block chunk limit ----------
  await rpc("anvil_mine", ["0x61a8"]); // 25,000 blocks
  const id5 = await createCampaign(s, { creator: "riya.qie", amount: "0.5", brief: "After 25k empty blocks." });
  const fresh = await ctx(STRANGER);
  await fresh.goto(`${APP}/judge`);
  await fresh.getByText("QIE components used").waitFor();
  await fresh.waitForFunction(() => document.body.innerText.includes("CAMPAIGNS") || document.body.innerText.includes("Campaigns"));
  const nextId = Number(cast(`call ${PP} "nextId()(uint256)"`).split(" ")[0]);
  await fresh.locator(".bx", { hasText: "Campaigns" }).first().getByText(String(nextId - 1), { exact: true }).waitFor({ timeout: 60000 });
  step(`K indexer reads logs across >25k blocks in 10k chunks: judge shows ${nextId - 1} campaigns (#${id5} is the newest)`);

  // ---------- Accounting: contract balance == open escrow ----------
  let open = 0n;
  for (let i = 1; i < nextId; i++) {
    const out = cast(`call ${PP} "getCampaign(uint256)((address,uint64,uint32,uint8,address,uint64,uint64,uint128,uint64,bytes32))" ${i}`);
    const f = out.replace(/[()]/g, "").split(", ");
    const status = Number(f[3]);
    if (status >= 1 && status <= 3) open += BigInt(f[7].split(" ")[0]);
  }
  expect(qusdcOf(PP) === open, `contract holds ${qusdcOf(PP)} but open escrow is ${open}`);
  const earned = BigInt(cast(`call ${PP} "creatorStats(address)((uint32,uint32,uint128))" ${CREATOR}`).replace(/[()]/g, "").split(", ")[2].split(" ")[0]);
  expect(earned === qusdcOf(CREATOR), "creator earned == creator balance");
  step(`L accounting: contract balance ${qusdcOf(PP)} == open escrow ${open}; creator earnings match balance`);

  console.log("RESULT: PASS");
} catch (e) {
  console.log("RESULT: FAIL", e.message.split("\n").slice(0, 6).join(" | "));
  for (const pg of browser.contexts().flatMap((x) => x.pages())) await shot(pg, "fail").catch(() => {});
} finally {
  console.log("errors:", JSON.stringify([...new Set(errors)].slice(0, 15), null, 1));
  await browser.close();
}