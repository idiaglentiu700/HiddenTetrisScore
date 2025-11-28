// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
  FHE,
  ebool,
  euint16,
  externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract HiddenTetrisScore is ZamaEthereumConfig {
  // ---------------------------------------------------------------------------
  // Ownership
  // ---------------------------------------------------------------------------

  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // ---------------------------------------------------------------------------
  // Simple nonReentrant guard (future-proof for payable flows)
  // ---------------------------------------------------------------------------

  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // ---------------------------------------------------------------------------
  // Leaderboard configuration (per "board" / season)
  // ---------------------------------------------------------------------------

  /**
   * Each board is a separate leaderboard (e.g. season, tournament, daily board).
   * Owner defines encrypted thresholds for two tiers:
   *  - eMinScoreTop10: encrypted min score required for "top 10%" badge.
   *  - eMinScoreTop3:  encrypted min score required for "top 3" badge.
   *
   * The actual tiers (10%, 3%) are computed off-chain.
   * Off-chain logic:
   *  - Aggregate scores, compute numeric thresholds,
   *  - Encrypt thresholds via Relayer, call setBoardThresholds(...) on-chain.
   */
  struct BoardConfig {
    bool exists;
    euint16 eMinScoreTop10;
    euint16 eMinScoreTop3;
  }

  // boardId => config
  mapping(uint256 => BoardConfig) private boards;

  event BoardThresholdsSet(
    uint256 indexed boardId,
    bytes32 minScoreTop10Handle,
    bytes32 minScoreTop3Handle
  );

  /**
   * Set or update encrypted thresholds for a leaderboard board.
   *
   * All values are encrypted off-chain as externalEuint16 using the same proof.
   * The proof is a Zama gateway attestation that these ciphertexts are valid.
   */
  function setBoardThresholds(
    uint256 boardId,
    externalEuint16 encMinScoreTop10,
    externalEuint16 encMinScoreTop3,
    bytes calldata proof
  ) external onlyOwner {
    require(boardId != 0, "invalid boardId");
    require(proof.length != 0, "missing proof");

    BoardConfig storage B = boards[boardId];
    B.exists = true;

    // Ingest encrypted minScoreTop10
    euint16 eTop10 = FHE.fromExternal(encMinScoreTop10, proof);
    FHE.allowThis(eTop10);
    B.eMinScoreTop10 = eTop10;

    // Ingest encrypted minScoreTop3
    euint16 eTop3 = FHE.fromExternal(encMinScoreTop3, proof);
    FHE.allowThis(eTop3);
    B.eMinScoreTop3 = eTop3;

    emit BoardThresholdsSet(
      boardId,
      FHE.toBytes32(B.eMinScoreTop10),
      FHE.toBytes32(B.eMinScoreTop3)
    );
  }

  /**
   * Lightweight metadata (no FHE ops).
   */
  function getBoardMeta(uint256 boardId)
    external
    view
    returns (bool exists)
  {
    BoardConfig storage B = boards[boardId];
    return B.exists;
  }

  /**
   * Owner-only: expose encrypted threshold handles for debugging / analytics.
   * NOTE: Only parties with ACL access (typically this contract) can use them.
   */
  function getBoardThresholdHandles(uint256 boardId)
    external
    view
    onlyOwner
    returns (bytes32 minTop10Handle, bytes32 minTop3Handle)
  {
    BoardConfig storage B = boards[boardId];
    require(B.exists, "board does not exist");
    return (
      FHE.toBytes32(B.eMinScoreTop10),
      FHE.toBytes32(B.eMinScoreTop3)
    );
  }

  // ---------------------------------------------------------------------------
  // Player scores (encrypted)
  // ---------------------------------------------------------------------------

  /**
   * Per-player encrypted state for a given board:
   *  - eScore:   best encrypted Tetris score for this board.
   *  - eIsTop10: encrypted flag "score >= minScoreTop10".
   *  - eIsTop3:  encrypted flag "score >= minScoreTop3".
   *
   * All three are:
   *  - owned long-term by the contract (FHE.allowThis),
   *  - decryptable by the player (FHE.allow(..., player)).
   *
   * Frontend:
   *  - uses getMyTierHandles(...) + userDecrypt(...) to show:
   *      - numeric score (only to the player),
   *      - text badges: top 3 / top 10 / others.
   */
  struct PlayerScore {
    euint16 eScore;
    ebool   eIsTop10;
    ebool   eIsTop3;
    bool    hasScore;
  }

  // boardId => player => encrypted score state
  mapping(uint256 => mapping(address => PlayerScore)) private scores;

  event ScoreSubmitted(
    uint256 indexed boardId,
    address indexed player,
    bytes32 scoreHandle,
    bytes32 isTop10Handle,
    bytes32 isTop3Handle,
    bool    isFirstScore
  );

  // ---------------------------------------------------------------------------
  // Submit encrypted score
  // ---------------------------------------------------------------------------

  /**
   * Submit encrypted final Tetris score for a board.
   *
   * Frontend flow (high level):
   *  1) Game ends → you have a numeric score (0..65535).
   *  2) Frontend uses Relayer SDK:
   *       const buf = relayer.createEncryptedInput(contractAddress, userAddress);
   *       buf.add16(score);
   *       const { handles, inputProof } = await buf.encrypt();
   *  3) Call submitEncryptedScore(boardId, handles[0], inputProof).
   *
   * Contract:
   *  - Ingests eScoreNew from external ciphertext.
   *  - Keeps BEST score: max(previousScore, newScore) under FHE.
   *  - Computes eIsTop10 / eIsTop3 on the best score using encrypted thresholds.
   *  - Grants user decryption rights for eScore, eIsTop10, eIsTop3.
   *
   * NOTE:
   *  - Scores stay encrypted forever; no public decryption is used.
   *  - Leaderboard UI can show only relative rank for the connected wallet.
   */
  function submitEncryptedScore(
    uint256 boardId,
    externalEuint16 encScore,
    bytes calldata proof
  ) external nonReentrant {
    BoardConfig storage B = boards[boardId];
    require(B.exists, "board does not exist");
    require(proof.length != 0, "missing proof");

    PlayerScore storage P = scores[boardId][msg.sender];

    // Ingest new encrypted score from Gateway
    euint16 eScoreNew = FHE.fromExternal(encScore, proof);

    // Give contract and player rights on new ciphertext
    FHE.allowThis(eScoreNew);
    FHE.allow(eScoreNew, msg.sender);

    euint16 eBestScore;
    bool isFirstScore = !P.hasScore;

    if (!P.hasScore) {
      // First submission: current best is the new score
      eBestScore = eScoreNew;
    } else {
      // Compare new score with previously stored best score (all under FHE)
      ebool newIsBetter = FHE.gt(eScoreNew, P.eScore);
      eBestScore = FHE.select(newIsBetter, eScoreNew, P.eScore);
    }

    // Compute encrypted tier flags based on BEST score and board thresholds
    ebool eIsTop10 = FHE.ge(eBestScore, B.eMinScoreTop10);
    ebool eIsTop3  = FHE.ge(eBestScore, B.eMinScoreTop3);

    // Persist encrypted state
    P.eScore   = eBestScore;
    P.eIsTop10 = eIsTop10;
    P.eIsTop3  = eIsTop3;
    P.hasScore = true;

    // Keep long-term rights for contract on stored ciphertexts
    FHE.allowThis(P.eScore);
    FHE.allowThis(P.eIsTop10);
    FHE.allowThis(P.eIsTop3);

    // Allow player to decrypt their score and tier flags privately
    FHE.allow(P.eScore, msg.sender);
    FHE.allow(P.eIsTop10, msg.sender);
    FHE.allow(P.eIsTop3, msg.sender);

    emit ScoreSubmitted(
      boardId,
      msg.sender,
      FHE.toBytes32(P.eScore),
      FHE.toBytes32(P.eIsTop10),
      FHE.toBytes32(P.eIsTop3),
      isFirstScore
    );
  }

  // ---------------------------------------------------------------------------
  // Getters (handles only, no FHE ops)
  // ---------------------------------------------------------------------------

  /**
   * Minimal view: does the caller already have a score for this board,
   * and what is the encrypted handle for that best score?
   *
   * UI can use this to show:
   *  - "No score yet" vs "Encrypted score submitted",
   *  - a button for "Decrypt my score" via userDecrypt(...).
   */
  function getMyScoreHandle(uint256 boardId)
    external
    view
    returns (bytes32 scoreHandle, bool hasScore)
  {
    PlayerScore storage P = scores[boardId][msg.sender];
    return (FHE.toBytes32(P.eScore), P.hasScore);
  }

  /**
   * Full player view for a board:
   *  - scoreHandle: encrypted best score (userDecrypt only),
   *  - top10Handle: encrypted flag (1 => inside top tier),
   *  - top3Handle:  encrypted flag,
   *  - hasScore:    whether any score exists yet.
   *
   * Frontend uses userDecrypt(...) and then:
   *   - normalizeDecryptedValue(scoreHandle) to BigInt score,
   *   - normalizeDecryptedValue(top10Handle) !== 0n → in top10,
   *   - normalizeDecryptedValue(top3Handle)  !== 0n → in top3.
   */
  function getMyTierHandles(uint256 boardId)
    external
    view
    returns (
      bytes32 scoreHandle,
      bytes32 top10Handle,
      bytes32 top3Handle,
      bool    hasScore
    )
  {
    PlayerScore storage P = scores[boardId][msg.sender];
    return (
      FHE.toBytes32(P.eScore),
      FHE.toBytes32(P.eIsTop10),
      FHE.toBytes32(P.eIsTop3),
      P.hasScore
    );
  }

  /**
   * Optional: owner can introspect encrypted tier flags for a user
   * without seeing the actual value (still requires ACL to decrypt).
   * This is useful for debugging / analytics, but not mandatory for UI.
   */
  function getUserTierHandles(uint256 boardId, address user)
    external
    view
    onlyOwner
    returns (
      bytes32 scoreHandle,
      bytes32 top10Handle,
      bytes32 top3Handle,
      bool    hasScore
    )
  {
    PlayerScore storage P = scores[boardId][user];
    return (
      FHE.toBytes32(P.eScore),
      FHE.toBytes32(P.eIsTop10),
      FHE.toBytes32(P.eIsTop3),
      P.hasScore
    );
  }
}
