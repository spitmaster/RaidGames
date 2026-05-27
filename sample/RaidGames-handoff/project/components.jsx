/* global React */
// 游戏大厅 — shared components & sample data

const { useState, useEffect, useRef, useMemo } = React;

// --- Sample raid roster (25-man) ------------------------------
const ROSTER = [
  { id: "p1",  name: "灰烬之牙",  cls: "warrior", isLeader: true  },
  { id: "p2",  name: "暴风之眼",  cls: "mage",    isLeader: false },
  { id: "p3",  name: "月光教士",  cls: "priest",  isLeader: false },
  { id: "p4",  name: "影刃",      cls: "rogue",   isLeader: false },
  { id: "p5",  name: "破晓之锤",  cls: "paladin", isLeader: false },
  { id: "p6",  name: "苍狼游侠",  cls: "hunter",  isLeader: false },
  { id: "p7",  name: "深渊低语",  cls: "warlock", isLeader: false },
  { id: "p8",  name: "怒涛萨满",  cls: "shaman",  isLeader: false },
  { id: "p9",  name: "翠羽德鲁",  cls: "druid",   isLeader: false },
  { id: "p10", name: "雷霆护卫",  cls: "warrior", isLeader: false },
  { id: "p11", name: "霜火咏者",  cls: "mage",    isLeader: false },
  { id: "p12", name: "晨曦祝祷",  cls: "priest",  isLeader: false },
  { id: "p13", name: "夜行隼",    cls: "rogue",   isLeader: false },
  { id: "p14", name: "金鬃骑士",  cls: "paladin", isLeader: false },
  { id: "p15", name: "鹰眼狙手",  cls: "hunter",  isLeader: false },
  { id: "p16", name: "虚空契约",  cls: "warlock", isLeader: false },
  { id: "p17", name: "潮汐之怒",  cls: "shaman",  isLeader: false },
  { id: "p18", name: "野性之心",  cls: "druid",   isLeader: false },
  { id: "p19", name: "断岳重斧",  cls: "warrior", isLeader: false },
  { id: "p20", name: "时之沙漏",  cls: "mage",    isLeader: false },
  { id: "p21", name: "圣光低吟",  cls: "priest",  isLeader: false },
  { id: "p22", name: "毒雾迷踪",  cls: "rogue",   isLeader: false },
  { id: "p23", name: "圣徽守誓",  cls: "paladin", isLeader: false },
  { id: "p24", name: "翠羚游猎",  cls: "hunter",  isLeader: false },
  { id: "p25", name: "亡焰唤主",  cls: "warlock", isLeader: false },
];

const LOOT_PRESETS = {
  legendary: {
    name: "萨弗隆斯·众王终结者",
    rarity: "legendary",
    glyph: "✦",
    type: "双手剑",
    slot: "主手",
    stat: "+148 力量  ·  +210 耐力",
    flavor: "传说",
  },
  epic: {
    name: "幽影披风",
    rarity: "epic",
    glyph: "☽",
    type: "布甲披风",
    slot: "背部",
    stat: "+62 敏捷  ·  +88 暴击",
    flavor: "史诗",
  },
  rare: {
    name: "深岩护肩",
    rarity: "rare",
    glyph: "◈",
    type: "板甲肩部",
    slot: "肩部",
    stat: "+45 力量  ·  +120 护甲",
    flavor: "精良",
  },
};

const GAMES = [
  { id: "tap",   title: "极速按键",       glyph: "⚡", desc: "10 秒内疯狂按键\n按得最多的胜出",   available: true  },
  { id: "down",  title: "是男人就下100层", glyph: "↓", desc: "下100层闯关\n敬请期待",              available: false },
  { id: "up",    title: "是男人就上100层", glyph: "↑", desc: "上100层闯关\n敬请期待",              available: false },
  { id: "memo",  title: "记忆迷阵",       glyph: "◎", desc: "记忆翻牌挑战\n敬请期待",              available: false },
  { id: "calc",  title: "心算闪电战",     glyph: "∑", desc: "30 秒答题极限\n敬请期待",            available: false },
  { id: "ci",    title: "词牌接龙",       glyph: "✶", desc: "诗词文学比拼\n敬请期待",              available: false },
];

// --- shared bits ----------------------------------------------

function PlayerCard({ player, isSelf, isReady, count, showCount }) {
  let statusEl = null;
  if (showCount) {
    statusEl = <div className="player-status" style={{ fontFamily: "var(--font-mono)" }}>{count ?? 0}</div>;
  } else if (player.isLeader) {
    statusEl = null; // ★ rendered via .is-leader::after
  } else if (isReady) {
    statusEl = <div className="player-status" style={{ color: "var(--success)" }}>✓</div>;
  } else {
    statusEl = <div className="player-status">○</div>;
  }
  return (
    <div
      className={`player ${isSelf ? "is-self" : ""} ${player.isLeader ? "is-leader" : ""} ${isReady ? "is-ready" : ""}`}
      data-class={player.cls}
    >
      <div className="player-portrait">{player.name.slice(0, 1)}</div>
      <div className="player-name">{player.name}</div>
      {statusEl}
    </div>
  );
}

function LootCard({ loot, customPrize, isLeader, onCustomPrizeChange }) {
  // No item loot ─ render a custom-prize card
  if (!loot) {
    const hasPrize = customPrize && customPrize.trim().length > 0;
    const showInput = isLeader; // leader edits inline, members read

    return (
      <div className={`loot-card loot-custom ${hasPrize ? "has-prize" : ""}`}>
        <div className={`item-icon item-icon-custom ${hasPrize ? "has-prize" : ""}`}>
          <span className="item-icon-glyph">◈</span>
        </div>
        <div className="item-info" style={{ minWidth: 0 }}>
          {showInput ? (
            <>
              <input
                type="text"
                className="prize-input"
                value={customPrize || ""}
                onChange={(e) => onCustomPrizeChange?.(e.target.value)}
                placeholder="输入本局奖品 · 例:100组深海精盐 / 5000金币 / 随机一件附魔"
                maxLength={60}
              />
              <div className="prize-input-meta">
                <span style={{ color: "var(--text-mute)" }}>
                  {hasPrize ? "团长设置 · 团员可见" : "留空则为友谊赛 · 仅为娱乐"}
                </span>
                <span style={{ color: "var(--text-mute)", fontFamily: "var(--font-mono)" }}>
                  {(customPrize || "").length}/60
                </span>
              </div>
            </>
          ) : hasPrize ? (
            <>
              <div className="item-name" style={{ color: "var(--accent)" }}>{customPrize}</div>
              <div className="item-meta">
                <span>团长指定</span>
                <span>胜者归属</span>
              </div>
            </>
          ) : (
            <>
              <div className="item-name" style={{ color: "var(--text)" }}>友谊赛 · 无奖品</div>
              <div className="item-meta">
                <span>纯切磋</span>
                <span>胜者享荣誉</span>
              </div>
              <div className="item-stat" style={{ color: "var(--text-mute)" }}>
                等待团长指定奖品 · 或直接开局
              </div>
            </>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="loot-card" data-rarity={loot.rarity}>
      <div className="item-icon">
        <span className="item-icon-glyph">{loot.glyph}</span>
      </div>
      <div className="item-info">
        <div className="item-name">{loot.name}</div>
        <div className="item-meta">
          <span>{loot.type}</span>
          <span>{loot.slot}</span>
          <span style={{ color: "var(--rarity-color)" }}>{loot.flavor}</span>
        </div>
        <div className="item-stat">{loot.stat}</div>
      </div>
    </div>
  );
}

function SectionLabel({ children }) {
  return <div className="section-label">{children}</div>;
}

function AddonFrame({ children, onClose, isLeader, onHistory, historyActive }) {
  return (
    <div className="addon">
      <span className="corner-tr"></span>
      <span className="corner-bl"></span>
      <div className="title-bar">
        <div className="title-flair l"></div>
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center" }}>
          <div className="title-text">游 戏 大 厅</div>
        </div>
        <div className="title-sub">GAME · HALL · v0.1</div>
        <div className="title-flair r"></div>
        <div className="title-actions">
          <button
            className={`title-action ${historyActive ? "is-active" : ""}`}
            onClick={onHistory}
            title="比赛记录"
          >
            战 史
          </button>
          <button className="title-close" onClick={onClose} aria-label="close">✕</button>
        </div>
        <div style={{
          position: "absolute", left: 14, top: "50%", transform: "translateY(-50%)",
          padding: "3px 8px", fontSize: 10, letterSpacing: "0.15em",
          fontFamily: "var(--font-display)",
          color: isLeader ? "var(--accent)" : "var(--text-mute)",
          border: `1px solid ${isLeader ? "var(--accent-deep)" : "var(--divider)"}`,
          borderRadius: 2,
          background: "var(--panel-inset)",
        }}>
          {isLeader ? "★ 团长" : "团员"}
        </div>
      </div>
      <div className="addon-body">{children}</div>
    </div>
  );
}

// --- Mock match history ---------------------------------------
const NOW = Date.now();
const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

const MATCH_HISTORY = [
  { id: "h01", ts: NOW - 6*MIN,        game: "tap", participants: 10,
    prize: { kind: "loot", name: "萨弗隆斯·众王终结者", rarity: "legendary", glyph: "✦" },
    winner: { name: "暴风之眼", cls: "mage", score: 92 },
    you: { rank: 3, score: 76, won: false } },
  { id: "h02", ts: NOW - 38*MIN,       game: "tap", participants: 10,
    prize: { kind: "custom", text: "50组深岩精铁" },
    winner: { name: "灰烬之牙", cls: "warrior", score: 84 },
    you: { rank: 1, score: 84, won: true } },
  { id: "h03", ts: NOW - 2*HOUR,       game: "tap", participants: 25,
    prize: { kind: "loot", name: "幽影披风", rarity: "epic", glyph: "☽" },
    winner: { name: "影刃", cls: "rogue", score: 103 },
    you: { rank: 8, score: 71, won: false } },
  { id: "h04", ts: NOW - 4*HOUR,       game: "tap", participants: 25,
    prize: { kind: "loot", name: "深岩护肩", rarity: "rare", glyph: "◈" },
    winner: { name: "灰烬之牙", cls: "warrior", score: 88 },
    you: { rank: 1, score: 88, won: true } },
  { id: "h05", ts: NOW - DAY + 3*HOUR, game: "tap", participants: 10,
    prize: { kind: "none" },
    winner: { name: "破晓之锤", cls: "paladin", score: 79 },
    you: { rank: 4, score: 65, won: false } },
  { id: "h06", ts: NOW - DAY - HOUR,   game: "tap", participants: 25,
    prize: { kind: "custom", text: "5000金币 + 10组附魔尘" },
    winner: { name: "翠羽德鲁", cls: "druid", score: 95 },
    you: { rank: 12, score: 60, won: false } },
  { id: "h07", ts: NOW - DAY - 4*HOUR, game: "tap", participants: 10,
    prize: { kind: "loot", name: "霜火长杖", rarity: "epic", glyph: "❅" },
    winner: { name: "霜火咏者", cls: "mage", score: 81 },
    you: { rank: 2, score: 78, won: false } },
  { id: "h08", ts: NOW - 2*DAY,        game: "tap", participants: 25,
    prize: { kind: "loot", name: "亡焰之眸", rarity: "legendary", glyph: "✦" },
    winner: { name: "灰烬之牙", cls: "warrior", score: 91 },
    you: { rank: 1, score: 91, won: true } },
  { id: "h09", ts: NOW - 2*DAY - 2*HOUR, game: "tap", participants: 10,
    prize: { kind: "custom", text: "下次副本免费陪打" },
    winner: { name: "深渊低语", cls: "warlock", score: 73 },
    you: { rank: 6, score: 55, won: false } },
  { id: "h10", ts: NOW - 3*DAY,        game: "tap", participants: 10,
    prize: { kind: "loot", name: "潮汐之握", rarity: "rare", glyph: "≈" },
    winner: { name: "怒涛萨满", cls: "shaman", score: 86 },
    you: { rank: 3, score: 74, won: false } },
  { id: "h11", ts: NOW - 4*DAY,        game: "tap", participants: 25,
    prize: { kind: "loot", name: "圣徽护腕", rarity: "epic", glyph: "✚" },
    winner: { name: "灰烬之牙", cls: "warrior", score: 96 },
    you: { rank: 1, score: 96, won: true } },
  { id: "h12", ts: NOW - 5*DAY,        game: "tap", participants: 10,
    prize: { kind: "none" },
    winner: { name: "苍狼游侠", cls: "hunter", score: 82 },
    you: { rank: 5, score: 62, won: false } },
  { id: "h13", ts: NOW - 6*DAY,        game: "tap", participants: 25,
    prize: { kind: "custom", text: "30组幽影丝线" },
    winner: { name: "毒雾迷踪", cls: "rogue", score: 88 },
    you: { rank: 7, score: 68, won: false } },
  { id: "h14", ts: NOW - 8*DAY,        game: "tap", participants: 10,
    prize: { kind: "loot", name: "破晓之拥", rarity: "epic", glyph: "☀" },
    winner: { name: "破晓之锤", cls: "paladin", score: 85 },
    you: { rank: 4, score: 71, won: false } },
  { id: "h15", ts: NOW - 10*DAY,       game: "tap", participants: 25,
    prize: { kind: "loot", name: "时之沙漏", rarity: "legendary", glyph: "✦" },
    winner: { name: "时之沙漏", cls: "mage", score: 102 },
    you: { rank: 2, score: 89, won: false } },
];

// expose to other Babel files
Object.assign(window, {
  ROSTER, LOOT_PRESETS, GAMES, MATCH_HISTORY,
  PlayerCard, LootCard, SectionLabel, AddonFrame,
});
