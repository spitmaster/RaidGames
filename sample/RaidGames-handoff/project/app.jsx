/* global React, ReactDOM, ROSTER, LOOT_PRESETS, GAMES,
          AddonFrame, LobbyScreen, CountdownScreen, PlayingScreen, ResultsScreen,
          useTweaks, TweaksPanel, TweakSection, TweakSelect, TweakColor,
          TweakRadio, TweakToggle, TweakNumber */

const { useState, useEffect, useRef, useCallback } = React;

// ---- Tweak defaults wrapped in EDITMODE markers --------------
const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "ironwood",
  "role": "leader",
  "loot": "legendary",
  "teamSize": 10
}/*EDITMODE-END*/;

const LOOT_OPTIONS = [
  { value: "none",      label: "友谊赛 · 无战利品" },
  { value: "rare",      label: "精良 · 深岩护肩" },
  { value: "epic",      label: "史诗 · 幽影披风" },
  { value: "legendary", label: "传说 · 萨弗隆斯" },
];

const DURATION_MS = 10000;       // 10 seconds
const TICK_MS = 50;              // smooth timer/AI updates
const COUNTDOWN_STEPS = ["3", "2", "1", "GO!"];

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const isLeader = t.role === "leader";

  // build roster (you are always p1; leader is p1 OR not depending on role)
  const players = React.useMemo(() => {
    const count = Math.max(2, Math.min(ROSTER.length, t.teamSize));
    const base = ROSTER.slice(0, count);
    return base.map((p, i) => ({
      ...p,
      isLeader: i === 0 ? isLeader : (!isLeader && i === 1), // when member, someone else leads
    }));
  }, [t.teamSize, isLeader]);
  const selfId = "p1";
  const loot = t.loot === "none" ? null : LOOT_PRESETS[t.loot];

  // ---- machine state ----
  // 'lobby' | 'countdown' | 'playing' | 'results' | 'history'
  const [phase, setPhase] = useState("lobby");
  const [prevPhase, setPrevPhase] = useState("lobby");
  const [selectedGame, setSelectedGame] = useState("tap");
  const [readySet, setReadySet] = useState(new Set(players.filter(p => !p.isLeader).map(p => p.id)));
  const [countdown, setCountdown] = useState(0);
  const [timeLeft, setTimeLeft] = useState(DURATION_MS);
  const [scores, setScores] = useState({});
  const [pressed, setPressed] = useState(false);
  const [customPrize, setCustomPrize] = useState("");
  const aiRefs = useRef({}); // per-player ai rate
  const pressTimerRef = useRef(null);

  // Reset readySet if roster changes
  useEffect(() => {
    setReadySet(new Set(players.filter(p => !p.isLeader).map(p => p.id)));
  }, [players]);

  // ---- Lobby actions ----
  const onToggleReady = useCallback(() => {
    setReadySet(s => {
      const ns = new Set(s);
      if (ns.has(selfId)) ns.delete(selfId); else ns.add(selfId);
      return ns;
    });
  }, []);

  // ---- Begin countdown ----
  const onStart = useCallback(() => {
    // seed AI keypress rates: roughly 5-9 cps each
    const rates = {};
    players.forEach(p => {
      // self stays at 0 (driven by clicks). Others get a rate.
      if (p.id !== selfId) {
        rates[p.id] = 4.5 + Math.random() * 4.5; // 4.5 - 9 cps
      }
    });
    aiRefs.current = rates;
    setScores(Object.fromEntries(players.map(p => [p.id, 0])));
    setCountdown(0);
    setPhase("countdown");
  }, [players]);

  // ---- Countdown timer ----
  useEffect(() => {
    if (phase !== "countdown") return;
    if (countdown >= COUNTDOWN_STEPS.length) {
      setTimeLeft(DURATION_MS);
      setPhase("playing");
      return;
    }
    const t = setTimeout(() => setCountdown(c => c + 1), countdown === COUNTDOWN_STEPS.length - 1 ? 600 : 900);
    return () => clearTimeout(t);
  }, [phase, countdown]);

  // ---- Playing loop ----
  useEffect(() => {
    if (phase !== "playing") return;
    const startedAt = performance.now();
    let last = startedAt;
    let raf;
    const loop = (now) => {
      const dt = now - last;
      last = now;
      const elapsed = now - startedAt;
      const left = Math.max(0, DURATION_MS - elapsed);
      setTimeLeft(left);
      // tick AIs
      setScores(prev => {
        const next = { ...prev };
        for (const p of players) {
          if (p.id === selfId) continue;
          const rate = aiRefs.current[p.id] || 6;
          // expected increment per dt: rate * dt/1000  -> use jitter
          const inc = (rate * dt) / 1000 * (0.6 + Math.random() * 0.9);
          next[p.id] = (next[p.id] || 0) + inc;
        }
        return next;
      });
      if (left <= 0) {
        // round up scores
        setScores(prev => {
          const next = {};
          for (const k of Object.keys(prev)) next[k] = Math.round(prev[k]);
          return next;
        });
        setPhase("results");
        return;
      }
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, [phase, players]);

  // ---- Press handler (self) ----
  const onPress = useCallback(() => {
    if (phase !== "playing") return;
    setScores(s => ({ ...s, [selfId]: (s[selfId] || 0) + 1 }));
    setPressed(true);
    if (pressTimerRef.current) clearTimeout(pressTimerRef.current);
    pressTimerRef.current = setTimeout(() => setPressed(false), 70);
  }, [phase]);

  // ---- Keyboard space ----
  useEffect(() => {
    const onKey = (e) => {
      if (e.code === "Space" || e.key === " ") {
        e.preventDefault();
        onPress();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onPress]);

  // ---- Play again ----
  const onPlayAgain = useCallback(() => {
    setPhase("lobby");
    setScores({});
    setTimeLeft(DURATION_MS);
    setCountdown(0);
  }, []);

  // ---- history toggle ----
  const onToggleHistory = useCallback(() => {
    setPhase(p => {
      if (p === "history") return prevPhase || "lobby";
      setPrevPhase(p);
      return "history";
    });
  }, [prevPhase]);

  // round scores for display in playing screen
  const displayScores = React.useMemo(() => {
    const out = {};
    for (const k of Object.keys(scores)) out[k] = Math.floor(scores[k]);
    return out;
  }, [scores]);

  // ---- Render ----
  return (
    <div data-theme={t.theme}>
      <div className="app-shell">
        <AddonFrame
          isLeader={isLeader}
          onClose={() => alert("插件已最小化 (mock)")}
          onHistory={onToggleHistory}
          historyActive={phase === "history"}
        >
          {phase === "history" && (
            <HistoryScreen
              history={window.MATCH_HISTORY}
              onBack={onToggleHistory}
            />
          )}
          {phase === "lobby" && (
            <LobbyScreen
              loot={loot}
              customPrize={customPrize}
              onCustomPrizeChange={setCustomPrize}
              players={players}
              selfId={selfId}
              isLeader={isLeader}
              selectedGame={selectedGame}
              onSelectGame={setSelectedGame}
              readySet={readySet}
              onToggleReady={onToggleReady}
              onStart={onStart}
            />
          )}
          {phase === "countdown" && (
            <PlayingScreen
              loot={loot}
              customPrize={customPrize}
              players={players}
              selfId={selfId}
              scores={Object.fromEntries(players.map(p => [p.id, 0]))}
              timeLeft={DURATION_MS}
              totalDuration={DURATION_MS}
              onPress={() => {}}
              pressed={false}
              countdownValue={COUNTDOWN_STEPS[countdown] || "GO!"}
            />
          )}
          {phase === "playing" && (
            <PlayingScreen
              loot={loot}
              customPrize={customPrize}
              players={players}
              selfId={selfId}
              scores={displayScores}
              timeLeft={timeLeft}
              totalDuration={DURATION_MS}
              onPress={onPress}
              pressed={pressed}
            />
          )}
          {phase === "results" && (
            <ResultsScreen
              loot={loot}
              customPrize={customPrize}
              players={players}
              scores={scores}
              selfId={selfId}
              isLeader={isLeader}
              onPlayAgain={onPlayAgain}
              onClose={() => setPhase("lobby")}
            />
          )}
        </AddonFrame>
      </div>

      <TweaksPanel title="Tweaks">
        <TweakSection title="主题">
          <TweakRadio
            label="风格"
            value={t.theme}
            onChange={v => setTweak("theme", v)}
            options={[
              { value: "ironwood", label: "暖金" },
              { value: "arcane",   label: "奥术" },
              { value: "crimson",  label: "血色" },
            ]}
          />
        </TweakSection>

        <TweakSection title="身份">
          <TweakRadio
            label="你的角色"
            value={t.role}
            onChange={v => setTweak("role", v)}
            options={[
              { value: "leader", label: "团长" },
              { value: "member", label: "团员" },
            ]}
          />
        </TweakSection>

        <TweakSection title="战利品">
          <TweakSelect
            label="本局奖品"
            value={t.loot}
            onChange={v => setTweak("loot", v)}
            options={LOOT_OPTIONS}
          />
        </TweakSection>

        <TweakSection title="团队规模">
          <TweakRadio
            label="人数"
            value={t.teamSize}
            onChange={v => setTweak("teamSize", v)}
            options={[
              { value: 5,  label: "5人" },
              { value: 10, label: "10人" },
              { value: 25, label: "25人" },
            ]}
          />
        </TweakSection>

        <TweakSection title="跳转到状态">
          <TweakButton label="① 大厅" onClick={() => setPhase("lobby")} />
          <TweakButton label="② 倒计时" onClick={() => { setCountdown(0); setPhase("countdown"); }} />
          <TweakButton label="③ 比赛中 (预填分数)" onClick={() => {
            const seed = {};
            players.forEach(p => seed[p.id] = p.id === selfId ? 12 : Math.floor(20 + Math.random() * 50));
            setScores(seed);
            setTimeLeft(4200);
            setPhase("playing");
          }} />
          <TweakButton label="④ 结算" onClick={() => {
            const seed = {};
            players.forEach((p, i) => seed[p.id] = i === 0 ? 78 : Math.floor(40 + Math.random() * 35));
            setScores(seed);
            setPhase("results");
          }} />
          <TweakButton label="⑤ 战史" onClick={() => setPhase("history")} />
        </TweakSection>
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
