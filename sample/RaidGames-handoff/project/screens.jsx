/* global React, ROSTER, LOOT_PRESETS, GAMES, PlayerCard, LootCard, SectionLabel */
// 游戏大厅 — screens for each game state

const { useState: _us, useEffect: _ue, useRef: _ur, useMemo: _um } = React;

// ============================================================
// LOBBY  — main waiting room
// ============================================================
function LobbyScreen({ loot, customPrize, onCustomPrizeChange, players, selfId, isLeader, selectedGame, onSelectGame, readySet, onToggleReady, onStart }) {
  const allReady = players.filter(p => !p.isLeader).every(p => readySet.has(p.id));
  const selectedAvailable = GAMES.find(g => g.id === selectedGame)?.available;
  const notReadyCount = players.filter(p => !p.isLeader && !readySet.has(p.id)).length;
  const readyCount    = players.filter(p => !p.isLeader && readySet.has(p.id)).length;
  const totalMembers  = players.filter(p => !p.isLeader).length;

  return (
    <div className="col gap-16">
      {/* loot */}
      <div>
        <SectionLabel>
          {loot
            ? "本次战利品 · Loot In Dispute"
            : (customPrize && customPrize.trim() ? "本局奖品 · Custom Prize" : "比赛模式 · Match Mode")}
        </SectionLabel>
        <LootCard
          loot={loot}
          customPrize={customPrize}
          isLeader={isLeader}
          onCustomPrizeChange={onCustomPrizeChange}
        />
      </div>

      {/* players grid — full width */}
      <div>
        <SectionLabel>
          <span>参赛者</span>
          <span style={{ color: "var(--text)", fontFamily: "var(--font-mono)", letterSpacing: "0.05em" }}>
            {players.length} 人
          </span>
          <span style={{ color: "var(--success)", fontFamily: "var(--font-mono)", letterSpacing: "0.05em" }}>
            ✓ {readyCount}/{totalMembers}
          </span>
        </SectionLabel>
        <div className="players">
          {players.map(p => (
            <PlayerCard
              key={p.id}
              player={p}
              isSelf={p.id === selfId}
              isReady={readySet.has(p.id) || p.isLeader}
            />
          ))}
        </div>
      </div>

      {/* game select */}
      <div>
        <SectionLabel>选择游戏</SectionLabel>
        <div className="game-tiles">
          {GAMES.map(g => (
            <button
              key={g.id}
              className={`game-tile ${selectedGame === g.id ? "is-selected" : ""} ${!g.available ? "is-locked" : ""}`}
              onClick={() => g.available && onSelectGame(g.id)}
              disabled={!g.available}
            >
              {!g.available && <span className="game-tile-lock">即将上线</span>}
              <div className="game-tile-glyph">{g.glyph}</div>
              <div className="game-tile-title">{g.title}</div>
              <div className="game-tile-desc" style={{ whiteSpace: "pre-line" }}>{g.desc}</div>
            </button>
          ))}
        </div>
      </div>

      {/* leader/member action row */}
      <div className="row" style={{ justifyContent: "flex-end", alignItems: "center", gap: 14, paddingTop: 4 }}>
        {!isLeader && (
          <>
            <span style={{ fontSize: 12, color: "var(--text-mute)", letterSpacing: "0.1em" }}>
              {readySet.has(selfId) ? "已准备 · 等待团长开局" : "请点击准备"}
            </span>
            <button
              className={`btn ${readySet.has(selfId) ? "" : "btn-primary"}`}
              onClick={onToggleReady}
            >
              {readySet.has(selfId) ? "取消准备" : "准 备"}
            </button>
          </>
        )}
        {isLeader && (
          <>
            <span style={{
              fontSize: 12,
              color: allReady ? "var(--success)" : "var(--text-mute)",
              letterSpacing: "0.1em"
            }}>
              {allReady ? "✓ 全员就绪" : `等待 ${notReadyCount} 人准备`}
            </span>
            <button
              className="btn btn-primary btn-lg"
              onClick={onStart}
              disabled={!selectedAvailable}
            >
              开 始 比 赛
            </button>
          </>
        )}
      </div>

      <LogStrip lines={[
        { tag: "system", text: `[团长] ${players.find(p => p.isLeader)?.name} 创建了游戏大厅` },
        { tag: "system", text:
            loot
              ? `战利品 < ${loot.name} > 进入分配 · ${players.length} 人参赛`
              : (customPrize && customPrize.trim()
                  ? `奖品 < ${customPrize.trim()} > 进入分配 · ${players.length} 人参赛`
                  : `本局为友谊赛 · ${players.length} 人参赛 · 无奖品`) },
        { tag: "tag",    text: `当前游戏: ${GAMES.find(g => g.id === selectedGame)?.title || "未选择"}` },
      ]} />
    </div>
  );
}

// ============================================================
// COUNTDOWN  — 3 · 2 · 1 · GO
// ============================================================
function CountdownScreen({ value }) {
  return (
    <div className="countdown">
      <div className={`countdown-num ${value === "GO!" ? "is-go" : ""}`} key={value}>{value}</div>
      <div className="countdown-sub">准 备 · 极 速 按 键</div>
    </div>
  );
}

// ============================================================
// PLAYING  — 10s smash
// ============================================================
function PlayingScreen({ loot, customPrize, players, selfId, scores, timeLeft, onPress, pressed, totalDuration, countdownValue }) {
  const ranked = _um(() => {
    return [...players].sort((a, b) => (scores[b.id] || 0) - (scores[a.id] || 0));
  }, [players, scores]);

  const myCount = scores[selfId] || 0;
  const maxScore = Math.max(1, ...Object.values(scores));
  const pct = (timeLeft / totalDuration) * 100;
  const myRank = ranked.findIndex(p => p.id === selfId) + 1;
  const isCountdown = countdownValue != null;

  // adaptive board columns
  const cols = players.length <= 6 ? 1 : players.length <= 12 ? 2 : 3;

  return (
    <div className="col gap-16 play-wrap">
      {/* countdown overlay — appears ON TOP of the playing layout */}
      {isCountdown && (
        <div className="countdown-overlay">
          <div className="countdown-overlay-backdrop" />
          <div className="countdown-overlay-inner">
            <div
              className={`countdown-num ${countdownValue === "GO!" ? "is-go" : ""}`}
              key={countdownValue}
            >
              {countdownValue}
            </div>
            <div className="countdown-sub">准 备 · 极 速 按 键</div>
          </div>
        </div>
      )}

      {/* castbar — horizontal progress strip */}
      <div className="castbar-wrap">
        <div className="castbar">
          <div className="castbar-fill" style={{ width: `${pct}%` }} />
          <div className="castbar-label">
            <span>{isCountdown ? "准 备 中" : "极 速 按 键"}</span>
            <span className="castbar-time">{(timeLeft / 1000).toFixed(1)}<span style={{ color: "var(--text-mute)", fontSize: 10, marginLeft: 2 }}>s</span></span>
          </div>
        </div>
      </div>

      {/* hero zone — prize · smash · count */}
      <div className="play-hero">
        <div className="play-stat play-stat-l">
          {loot && (
            <div className="play-mini-loot" data-rarity={loot.rarity}>
              <div className="item-icon" style={{ width: 36, height: 36 }}>
                <span className="item-icon-glyph" style={{ fontSize: 16 }}>{loot.glyph}</span>
              </div>
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ fontSize: 12, color: "var(--rarity-color)", fontFamily: "var(--font-display)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {loot.name}
                </div>
                <div style={{ fontSize: 10, color: "var(--text-mute)", letterSpacing: "0.1em" }}>
                  争 夺 中
                </div>
              </div>
            </div>
          )}
          {!loot && customPrize && customPrize.trim() && (
            <div className="play-mini-loot" style={{ "--rarity-color": "var(--accent)" }}>
              <div className="item-icon item-icon-custom has-prize" style={{ width: 36, height: 36 }}>
                <span className="item-icon-glyph" style={{ fontSize: 16 }}>◈</span>
              </div>
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ fontSize: 12, color: "var(--accent)", fontFamily: "var(--font-display)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {customPrize}
                </div>
                <div style={{ fontSize: 10, color: "var(--text-mute)", letterSpacing: "0.1em" }}>
                  争 夺 中
                </div>
              </div>
            </div>
          )}
          {!loot && !(customPrize && customPrize.trim()) && (
            <div className="play-stat-label" style={{ opacity: 0.5 }}>
              友 谊 赛
            </div>
          )}
        </div>

        <div style={{ position: "relative", paddingBottom: 30 }}>
          <button
            className={`smash-btn ${pressed ? "is-pressed" : ""}`}
            disabled={isCountdown}
            onMouseDown={onPress}
            onTouchStart={(e) => { e.preventDefault(); onPress(); }}
          >
            {isCountdown ? "就 位" : "点 击"}
          </button>
          <div className="smash-key">SPACE · CLICK · TAP</div>
        </div>

        <div className="play-stat play-stat-r">
          <div className="my-count">{myCount}</div>
          <div className="play-stat-label">
            我的次数 · 第 <span style={{ color: "var(--accent)" }}>{myRank || "—"}</span> 名
          </div>
        </div>
      </div>

      {/* full-width live board */}
      <div>
        <SectionLabel>
          <span>实时排名</span>
          <span style={{ color: "var(--text-dim)", fontFamily: "var(--font-mono)" }}>
            {players.length} 人激战
          </span>
        </SectionLabel>
        <div className="live-board" style={{ "--cols": cols }}>
          {ranked.map((p, i) => {
            const s = scores[p.id] || 0;
            return (
              <div
                key={p.id}
                className={`live-row rank-${i + 1} ${p.id === selfId ? "is-self" : ""}`}
                data-class={p.cls}
              >
                <div className="live-row-rank">{i + 1}</div>
                <div className="live-row-name">{p.name}</div>
                <div className="live-row-score">{s}</div>
                <div className="live-row-bar" style={{ width: `${(s / maxScore) * 100}%` }} />
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// ============================================================
// RESULTS  — winner + final board + loot award
// ============================================================
function ResultsScreen({ loot, customPrize, players, scores, selfId, onPlayAgain, onClose, isLeader }) {
  const ranked = _um(() => {
    return [...players].sort((a, b) => (scores[b.id] || 0) - (scores[a.id] || 0));
  }, [players, scores]);
  const winner = ranked[0];
  const duration = 10;

  return (
    <div className="results">
      <div className="winner-banner">
        <div className="winner-label">— 胜 利 者 —</div>
        <div className="winner-name" data-class={winner.cls} style={{ color: "var(--class-color, var(--accent-glow))" }}>
          {winner.name}
        </div>
        <div className="winner-score">
          以 <strong>{scores[winner.id]}</strong> 次按键{loot || (customPrize && customPrize.trim()) ? "夺得奖品" : "技压全场"}
        </div>
      </div>

      {loot ? (
        <div className="loot-award" data-rarity={loot.rarity}>
          <span>战 利 品 已 归 属</span>
          <strong>{loot.name}</strong>
          <span>→</span>
          <strong style={{ color: "var(--class-color)", textShadow: `0 0 8px var(--class-color)` }}
                  data-class={winner.cls}>
            {winner.name}
          </strong>
        </div>
      ) : (customPrize && customPrize.trim()) ? (
        <div className="loot-award" style={{ "--rarity-color": "var(--accent)" }}>
          <span>奖 品 已 归 属</span>
          <strong style={{ color: "var(--accent)" }}>{customPrize}</strong>
          <span>→</span>
          <strong style={{ color: "var(--class-color)", textShadow: `0 0 8px var(--class-color)` }}
                  data-class={winner.cls}>
            {winner.name}
          </strong>
        </div>
      ) : (
        <div className="loot-award" style={{ "--rarity-color": "var(--accent)" }}>
          <span>友 谊 赛 · 纯 切 磋</span>
          <strong style={{ color: "var(--class-color)", textShadow: `0 0 8px var(--class-color)` }}
                  data-class={winner.cls}>
            {winner.name}
          </strong>
          <span>赢 得 本 场 荣 誉</span>
        </div>
      )}

      <div className="col gap-4" style={{ width: "100%" }}>
        <SectionLabel>最终排名</SectionLabel>
        <div className="final-board" style={{ "--cols": players.length <= 6 ? 1 : players.length <= 12 ? 2 : 3 }}>
          {ranked.map((p, i) => {
            const s = scores[p.id] || 0;
            return (
              <div
                key={p.id}
                className={`final-row rank-${i + 1}`}
                data-class={p.cls}
              >
                <div className="final-row-rank">{i === 0 ? "✦" : i + 1}</div>
                <div className="final-row-name">
                  {p.name}{p.id === selfId ? "  (你)" : ""}
                </div>
                <div className="final-row-cps">
                  <span>CPS </span>{(s / duration).toFixed(1)}
                </div>
                <div className="final-row-score">{s}</div>
              </div>
            );
          })}
        </div>
      </div>

      <div className="row" style={{ width: "100%", justifyContent: "space-between", marginTop: 6 }}>
        <button className="btn" onClick={onClose}>关 闭</button>
        {isLeader && (
          <button className="btn btn-primary" onClick={onPlayAgain}>再 来 一 局</button>
        )}
      </div>
    </div>
  );
}

// ============================================================
// HISTORY  — personal match record panel
// ============================================================
function formatTime(ts) {
  const now = Date.now();
  const diff = now - ts;
  const d = new Date(ts);
  const pad = (n) => String(n).padStart(2, "0");
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (diff < 60 * 1000) return "刚刚";
  if (diff < 60 * 60 * 1000) return `${Math.floor(diff / 60000)} 分钟前`;
  if (diff < 24 * 60 * 60 * 1000) return `今天 ${hm}`;
  if (diff < 2 * 24 * 60 * 60 * 1000) return `昨天 ${hm}`;
  const days = Math.floor(diff / (24 * 60 * 60 * 1000));
  if (days < 7) return `${days} 天前`;
  return `${pad(d.getMonth() + 1)}/${pad(d.getDate())} ${hm}`;
}

function HistoryScreen({ history, onBack }) {
  const total = history.length;
  const wins  = history.filter(h => h.you.won).length;
  const winRate = total ? (wins / total * 100).toFixed(1) : "0";
  // count distinct prizes won (only when you won + prize wasn't 'none')
  const prizesWon = history.filter(h => h.you.won && h.prize.kind !== "none").length;
  const avgScore = total
    ? Math.round(history.reduce((a, h) => a + h.you.score, 0) / total)
    : 0;

  return (
    <div className="col gap-16">
      {/* stats summary */}
      <div className="history-stats">
        <StatCard label="总 场 次" value={total} accent="text" />
        <StatCard label="胜 场" value={wins} accent="gold" />
        <StatCard label="胜 率" value={`${winRate}%`} accent={parseFloat(winRate) >= 30 ? "gold" : "text"} />
        <StatCard label="奖 品 收 获" value={prizesWon} accent="rare" />
        <StatCard label="平 均 分" value={avgScore} accent="text" />
      </div>

      {/* match list */}
      <div>
        <SectionLabel>
          <span>对战记录</span>
          <span style={{ color: "var(--text-dim)", fontFamily: "var(--font-mono)" }}>
            最近 {total} 局
          </span>
        </SectionLabel>
        <div className="history-list">
          {history.map(h => <HistoryRow key={h.id} match={h} />)}
        </div>
      </div>
    </div>
  );
}

function StatCard({ label, value, accent }) {
  return (
    <div className={`stat-card stat-${accent}`}>
      <div className="stat-value">{value}</div>
      <div className="stat-label">{label}</div>
    </div>
  );
}

function HistoryRow({ match }) {
  const game = GAMES.find(g => g.id === match.game);
  const { prize, winner, you } = match;
  const rarityColor =
    prize.kind === "loot" ? `var(--rar-${prize.rarity})` :
    prize.kind === "custom" ? "var(--accent)" :
    "var(--text-mute)";

  return (
    <div className={`history-row ${you.won ? "is-win" : ""}`}>
      <div className="history-time">{formatTime(match.ts)}</div>

      <div className="history-game">
        <span className="history-game-glyph">{game?.glyph}</span>
        <span>{game?.title}</span>
        <span className="history-game-meta">· {match.participants} 人</span>
      </div>

      <div className="history-prize" style={{ "--prize-color": rarityColor }}>
        {prize.kind === "loot" && (
          <>
            <span className="history-prize-glyph" style={{ color: rarityColor }}>{prize.glyph}</span>
            <span className="history-prize-name" style={{ color: rarityColor }}>{prize.name}</span>
          </>
        )}
        {prize.kind === "custom" && (
          <>
            <span className="history-prize-glyph" style={{ color: rarityColor }}>◈</span>
            <span className="history-prize-name" style={{ color: rarityColor }}>{prize.text}</span>
          </>
        )}
        {prize.kind === "none" && (
          <>
            <span className="history-prize-glyph" style={{ color: "var(--text-mute)" }}>·</span>
            <span className="history-prize-name" style={{ color: "var(--text-mute)" }}>友谊赛</span>
          </>
        )}
      </div>

      <div className="history-winner">
        <span style={{ color: "var(--text-mute)", fontSize: 10, letterSpacing: "0.15em" }}>胜者</span>
        <span className="history-winner-name" data-class={winner.cls}
              style={{ color: "var(--class-color)" }}>
          {winner.name}
        </span>
        <span className="history-winner-score">{winner.score}</span>
      </div>

      <div className={`history-result ${you.won ? "is-win" : ""}`}>
        {you.won ? (
          <>
            <span className="history-result-badge win">胜</span>
            <span className="history-result-detail">{you.score} 次</span>
          </>
        ) : (
          <>
            <span className="history-result-badge loss">第 {you.rank} 名</span>
            <span className="history-result-detail">{you.score} 次</span>
          </>
        )}
      </div>
    </div>
  );
}
function LogStrip({ lines }) {
  return (
    <div className="log-strip">
      {lines.map((l, i) => (
        <div key={i} className="log-line">
          <span className={l.tag}>[{l.tag === "system" ? "系统" : l.tag === "warn" ? "警告" : "战团"}]</span>
          {l.text}
        </div>
      ))}
    </div>
  );
}

Object.assign(window, {
  LobbyScreen, CountdownScreen, PlayingScreen, ResultsScreen, HistoryScreen, LogStrip,
});
