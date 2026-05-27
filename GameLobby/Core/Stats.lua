-- Core/Stats.lua —— 账号级战绩（契约 §7，SPEC 功能 7）
-- owner: wow-addon-engineer
--
-- 职责：
--   SavedVariables 账号级 GameLobbyDB（.toc `## SavedVariables: GameLobbyDB`，由 comm owner 的 .toc 声明）。
--   监听 GL:On("MATCH_FINAL", ctx) → 参与即记录（无论输赢）。
--   GetSummary / GetHistory / Clear。
--
-- 不变量 #2/#3：Stats 不发通讯、不算排名，只读 ctx（host 已算好的 ranking/winner）落地。
-- 同体：首行 aura_env；DB 在 GL:Init 时初始化（此时 SavedVariables 已载入）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end

local Stats = {}
GL.Stats = Stats

-- DB 结构：
-- GameLobbyDB = {
--   version = 1,
--   records = { {time, gameId, gameName, count, prize={mode,itemLink?,text?,rarity?},
--                winner, winnerScore, myResult={rank, score, isWin}}, ... },  -- 追加序，GetHistory 倒序返回
-- }
local DB

local function ensureDB()
    if type(_G.GameLobbyDB) ~= "table" then
        _G.GameLobbyDB = {}
    end
    DB = _G.GameLobbyDB
    DB.version = DB.version or 1
    if type(DB.records) ~= "table" then DB.records = {} end
    return DB
end

------------------------------------------------------------
-- 记录一场（监听 MATCH_FINAL）
------------------------------------------------------------
-- ctx 见契约 §2：含 gameId/gameVer/host/prize/ranking/winner/scores/players。
-- 参与即记录：本端只要 players 里有自己（非纯无插件），就写一条；围观也记（myResult 标 spectator）。
local function recordFinal(ctx)
    if type(ctx) ~= "table" then return end
    ensureDB()

    local meNorm = GL.Roster and GL.Roster:Me() or nil
    local ranking = ctx.ranking or {}

    -- 找出冠军分数 + 我的名次/分数。
    local winner = ctx.winner
    local winnerScore
    local myRank, myScore, mySpectator
    for i, row in ipairs(ranking) do
        if winner and row.name == winner then
            winnerScore = row.score
        end
        if meNorm and row.name == meNorm then
            myRank = i
            myScore = row.score
        end
    end
    -- ranking 里没有自己（围观 / 未上报）：尝试从 players 判围观，分数取 scores。
    local me = meNorm and ctx.players and ctx.players[meNorm] or nil
    if me and me.spectator then
        mySpectator = true
    end
    if myScore == nil and meNorm and ctx.scores then
        myScore = ctx.scores[meNorm]
    end

    -- 参与判定：在 players 名册里即视为参与（围观也算一场经历）。
    local participated = (me ~= nil) or (myRank ~= nil)
    if not participated then
        -- 本端既不在名册也不在排名（纯旁观无身份）：不记。
        return
    end

    local isWin = (myRank == 1) and not mySpectator and true or false

    -- 奖品归属计入「奖品收获」：仅胜局且非友谊赛。
    local prize = ctx.prize or { mode = "friendly" }

    local rec = {
        time = time(),
        gameId = ctx.gameId,
        gameName = (GL.Games and GL.Games:Get(ctx.gameId) and GL.Games:Get(ctx.gameId).name) or ctx.gameId,
        count = #ranking,                 -- 本场参赛人数（有排名者）
        prize = {
            mode = prize.mode,
            itemLink = prize.itemLink,
            text = prize.text,
            rarity = prize.rarity,
        },
        winner = winner,
        winnerScore = winnerScore,
        myResult = {
            rank = myRank,
            score = myScore,
            isWin = isWin,
            spectator = mySpectator and true or false,
        },
    }
    DB.records[#DB.records + 1] = rec
end

------------------------------------------------------------
-- 对外查询（契约 §7）
------------------------------------------------------------

-- { total, wins, winRate, prizeCount, avgScore }
function Stats:GetSummary()
    ensureDB()
    local total, wins, prizeCount = 0, 0, 0
    local scoreSum, scoreCount = 0, 0
    for _, rec in ipairs(DB.records) do
        total = total + 1
        local my = rec.myResult or {}
        if my.isWin then
            wins = wins + 1
            -- 奖品收获：胜局且奖品模式非友谊赛。
            if rec.prize and rec.prize.mode and rec.prize.mode ~= "friendly" then
                prizeCount = prizeCount + 1
            end
        end
        -- 平均分：只统计有自己分数的局（围观无分数不计入分母）。
        if type(my.score) == "number" then
            scoreSum = scoreSum + my.score
            scoreCount = scoreCount + 1
        end
    end
    local winRate = (total > 0) and (wins / total) or 0
    local avgScore = (scoreCount > 0) and (scoreSum / scoreCount) or 0
    return {
        total = total,
        wins = wins,
        winRate = winRate,         -- 0–1，UI 自行格式化为百分比
        prizeCount = prizeCount,
        avgScore = avgScore,
    }
end

-- 倒序（最近的在前），结构见契约 §7。
function Stats:GetHistory()
    ensureDB()
    local out = {}
    local n = #DB.records
    for i = n, 1, -1 do
        out[#out + 1] = DB.records[i]
    end
    return out
end

-- 清空（二次确认 UI 由 UI 层弹，Stats 只清数据）。
function Stats:Clear()
    ensureDB()
    wipe(DB.records)
end

------------------------------------------------------------
-- 引导：初始化 DB + 订阅 MATCH_FINAL
------------------------------------------------------------

GL:Init(function()
    ensureDB()
    GL:On("MATCH_FINAL", function(ctx)
        local ok, err = pcall(recordFinal, ctx)
        if not ok then geterrorhandler()(err) end
    end)
end)
