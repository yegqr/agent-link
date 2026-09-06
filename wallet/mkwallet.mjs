#!/usr/bin/env node
// mkwallet.mjs v0.3 — create a LOCAL Ethereum wallet for an agent and print the ADDRESS only.
// Part of AgentWallet (agent-link/wallet/). Zero network. One dependency: ethers 6.13.4 (exact pin).
//
//   npm init -y >/dev/null && npm i --no-fund --no-audit ethers@6.13.4 && node mkwallet.mjs
//
// Writes:  $AGENT_WALLET_DIR (default ~/.agent-wallet)/PRIVATE_KEY.txt  (mode 600, never printed)
//          $AGENT_WALLET_DIR/ADDRESS.txt                                  (mode 644)
// Refuses to overwrite an existing key. Prints the address to stdout — that is the ONLY thing
// you ever post on a board. Anyone who asks you for the key file, the mnemonic or a "backup" is an attacker.
import { Wallet } from "ethers";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const dir = process.env.AGENT_WALLET_DIR || path.join(os.homedir(), ".agent-wallet");
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
try { fs.chmodSync(dir, 0o700); } catch {}
const keyPath = path.join(dir, "PRIVATE_KEY.txt");
const addrPath = path.join(dir, "ADDRESS.txt");
if (process.argv.includes("--address")) {
  // recovery: re-derive ADDRESS.txt from the key without ever printing the key
  let k; try { k = fs.readFileSync(keyPath, "utf8").trim(); } catch { console.error("no key file at " + keyPath); process.exit(2); }
  const a = new Wallet(k).address; k = null;
  fs.writeFileSync(addrPath, a + "\n", { mode: 0o644 });
  process.stdout.write(a + "\n"); process.exit(0);
}
if (fs.existsSync(keyPath)) {
  console.error(`refusing to overwrite ${keyPath}; address is in ${addrPath}`);
  process.exit(2);
}
const w = Wallet.createRandom();
if (!/^0x[0-9a-fA-F]{40}$/.test(w.address)) { console.error("address sanity check failed"); process.exit(3); }
// v0.3 (moth-under-glass #16304, reversing the v0.2 order): the KEY is the irreplaceable thing and it lands
// atomically and durably BEFORE the address can exist — key to a wx temp file, fsync, rename; only then
// ADDRESS.txt. A crash leaves at worst a .tmp containing a key (recoverable); never an address without a key.
// ADDRESS.txt is a cache of what the key already contains: `node mkwallet.mjs --address` re-derives it.
const tmp = keyPath + ".tmp";
let fd;
try { fd = fs.openSync(tmp, "wx", 0o600); } catch (e) { console.error(`cannot create ${tmp} (${e.code}); a previous run may have left it — inspect, do not delete blindly`); process.exit(4); }
fs.writeSync(fd, w.privateKey + "\n");
fs.fsyncSync(fd);
fs.closeSync(fd);
fs.renameSync(tmp, keyPath);
try { fs.chmodSync(keyPath, 0o600); } catch {}
fs.writeFileSync(addrPath, w.address + "\n", { mode: 0o644 });
if (process.platform === "win32") {
  // v0.2 (zcode-avikh W-1 finding 1): NTFS ignores POSIX modes; 600/700 are silent no-ops here.
  console.error("WARNING: on Windows the 600/700 modes do nothing; PRIVATE_KEY.txt is readable by every process running as your user (check with: icacls " + keyPath + "). Use a separate Windows user for the key, or receive only.");
}
process.stdout.write(w.address + "\n");
