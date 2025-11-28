# Hidden Tetris Score

Privacy-preserving Tetris leaderboard built on Zama fhEVM. Final scores are sent to the smart contract **fully encrypted**, and the leaderboard exposes only **relative tiers** (e.g. "top 10%", "top 3") — never raw scores. Players can decrypt their own exact score locally via the Zama Relayer.

> **TL;DR**
>
> * Play Tetris off-chain.
> * Encrypt the final score in the browser.
> * Submit encrypted score to the HiddenTetrisScore contract.
> * Contract computes your tier (top 3 / top 10% / participant) under FHE.
> * Only you can decrypt your exact score using `userDecrypt`.

---

## Tech Stack

* **Smart contract**: Solidity, Zama fhEVM FHE primitives
* **Network**: Sepolia fhEVM
* **Contract address**: `0xC11B92dE32C2b3D6bEc7b1ef9f96A814D3aE32Fb`
* **Frontend**: Vanilla HTML + CSS + JS
* **Wallet**: MetaMask / any EIP-1193 provider
* **FHE client**: Zama Relayer SDK (`relayer-sdk-js@0.3.0-5`)
* **Bundling**: none (single-page `index.html`)

---

## Concept

Classic Tetris leaderboards leak everything: your exact score and how it compares to others. Hidden Tetris Score keeps that sensitive data under homomorphic encryption:

* Scores are encrypted in the browser using Zama Relayer.
* The contract only sees ciphertexts and performs FHE operations.
* It stores:

  * your encrypted best score for a Tetris board,
  * encrypted flags for tier membership (top 10% / top 3).
* The UI only shows tiers on-chain.
* Exact score is decrypted **only on the player side** with `userDecrypt`.

No global "top score" ever exists in plaintext on-chain.

---

## Smart Contract Overview

> **File:** `HiddenTetrisScore.sol` (not shown here, but ABI is embedded in the frontend)

Key ideas:

* **Boards**

  * Each Tetris variation (e.g. difficulty / rule set) is a `boardId` (`uint256`).
  * Owner can configure **encrypted thresholds** for each board:

    * `minScoreTop10`: minimum score to be in the top-10% tier.
    * `minScoreTop3`: minimum score to be in the top-3 tier.

* **Player scores**

  * Players submit their final score as an external encrypted `euint16`.
  * Contract ingests it via FHE, compares against encrypted thresholds, and computes encrypted Boolean flags `isTop10` / `isTop3`.
  * Only encrypted score and encrypted flags are stored.

* **Decryption / privacy**

  * No public decryption of scores.
  * Players use Zama Relayer `userDecrypt` from the frontend to reveal their own score and tier locally.

* **Read functions**

  * `getBoardMeta(boardId)` – check if board has thresholds configured.
  * `getBoardThresholdHandles(boardId)` – owner-only; returns handles for encrypted thresholds.
  * `getMyScoreHandle(boardId)` – returns handle for caller’s encrypted score + `hasScore`.
  * `getMyTierHandles(boardId)` – returns handles for caller’s score + tier flags.

---

## Frontend Overview

> **File:** `index.html` (single-page app)

The UI is intentionally simple and focused on demonstrating **encrypt → send → decrypt**:

### Layout

* **Header**

  * App title: **Hidden Tetris Score**.
  * Network pill: Sepolia fhEVM.
  * Contract pill: short contract address.
  * Wallet connect button (MetaMask): connect / disconnect.
  * Owner badge (only when connected as contract owner).

* **Play & Submit (left card)**

  * **Board ID**: numeric `boardId` selector.
  * **Final score slider**: range `0…65535`, representing final Tetris score.
  * **Random demo score** button: uses `randomSeed()` helper.
  * **Encrypt & send** button:

    * Encrypts the `score` with `fheCore.encryptUint16`.
    * Calls `submitEncryptedScore(boardId, encScoreHandle, proof)` on the contract.

* **Your Result (right card)**

  * Visual score bar (local scaling up to 10k+) showing relative magnitude.
  * Label: encrypted best score existence / meta.
  * Tier badges:

    * Participant
    * Top 10%
    * Top 3
  * **Decrypt my score** button:

    * Reads handles via `getMyTierHandles(boardId)`.
    * Calls `userDecrypt` through Relayer.
    * Normalizes decrypted values (score, top10 flag, top3 flag) and updates UI.

* **Owner Panel (bottom card)**

  * Visible only for `owner()`.
  * Fields: `boardId`, `top10Threshold`, `top3Threshold`.
  * Button **Encrypt & set**:

    * Encrypts both thresholds (uint16) via Relayer.
    * Calls `setBoardThresholds(boardId, encTop10, encTop3, proof)`.

* **Activity Console**

  * Minimal log window at the bottom.
  * Shows high-level steps: connecting wallet, encrypting, sending tx, decrypting results.
  * Uses `safeStringify` for BigInt-safe logging.

---

## FHE Frontend Core (`fheCore`)

The project embeds a small reusable core inside `index.html` that wraps all Zama Relayer functionality:

* `configure({ contractAddress, abi })`
* `connectWallet()` / `disconnectWallet()` / `autoConnectIfAuthorized()`
* `getState()` – provider, signer, contract, relayer, account, owner
* `randomSeed(modulus)` – crypto-safe pseudo-random integer for demo scores
* `encryptUint16(value)` – homomorphically encrypt uint16 → `{ handle, proof, handles }`
* `userDecryptHandles(handles)` – generic `userDecrypt`, returns `pick(handle) -> BigInt`
* `isOwner()` – simple owner check based on `owner()`

Helpers:

* `safeStringify(obj)` – BigInt-aware JSON logging
* `normalizeDecryptedValue(v)` – handles `boolean | bigint | number | string`
* `buildValuePicker(out, pairs)` – maps decrypted outputs back to handles

All of this is built directly on top of:

```js
import {
  initSDK,
  createInstance,
  SepoliaConfig,
  generateKeypair
} from "https://cdn.zama.org/relayer-sdk-js/0.3.0-5/relayer-sdk-js.js";
```

The Relayer instance is created with:

* `relayerUrl = "https://relayer.testnet.zama.org"`
* `gatewayUrl = "https://gateway.testnet.zama.org"`

(With optional localhost proxy support if needed.)

---

## Running Locally

> The frontend is a single static file, but Relayer requires proper COOP/COEP headers and (ideally) HTTPS.

### 1. Clone the repo

```bash
git clone https://github.com/<your-org-or-user>/hidden-tetris-score.git
cd hidden-tetris-score
```

### 2. Serve `index.html` with correct headers

Example Node/Express dev server:

```js
// server.js
import express from "express";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3042;

// Required for Relayer SDK (WASM/Workers)
app.use((req, res, next) => {
  res.setHeader("Cross-Origin-Opener-Policy", "same-origin");
  res.setHeader("Cross-Origin-Embedder-Policy", "require-corp");
  next();
});

app.use(express.static(__dirname));

app.listen(PORT, () => {
  console.log(`Serving on http://localhost:${PORT}`);
});
```

Then run:

```bash
node server.js
```

Open in browser:

```text
http://localhost:3042/
```

> Make sure MetaMask is installed and points to Sepolia fhEVM.

---

## How to Use

1. **Connect wallet**

   * Click **Connect wallet**.
   * MetaMask will switch/add Sepolia network if needed.

2. **Pick a board & score**

   * Set **Board** ID (e.g. `1`).
   * Move the **Final score** slider or press **Random demo score**.

3. **Encrypt & send score**

   * Press **Encrypt & send**.
   * The UI will:

     * encrypt your score via Relayer;
     * call `submitEncryptedScore` on the contract;
     * confirm once the transaction is mined.

4. **Decrypt your own result**

   * Press **Decrypt my score**.
   * The UI will:

     * read handles via `getMyTierHandles(boardId)`;
     * call `userDecrypt` via Relayer;
     * update the bar, your numerical score and tier badges.

5. **Owner: configure thresholds**

   * Connect as `owner()` address.
   * Use the **Owner panel** to set `top10` and `top3` thresholds.
   * Press **Encrypt & set**.

---

## Safety & Privacy Notes

* All scores and thresholds are stored **encrypted** as `euint16` under Zama fhEVM.
* Tiers (top 10%, top 3) are computed with homomorphic comparisons (`>=`) directly on ciphertexts.
* No public decrypt of scores is implemented.
* Only the player can run `userDecrypt` for their own score/flags (via ACL + Relayer flows).

This is a **demo / hackathon-style** project, not a production leaderboard:

* No economic incentives or rewards.
* No anti-cheat. We assume the game client is honest.

---

## Development Notes

* Contract and frontend are intentionally minimalistic to highlight FHE operations.
* All Relayer calls are wrapped to avoid BigInt serialization issues.
* UI text is in English; code comments may be mixed EN/RU (builder’s preference).

---

## License

MIT – feel free to fork, modify and build your own encrypted games on top of Zama fhEVM.
