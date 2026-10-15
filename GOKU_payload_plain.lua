-- ============================================================================
-- SECUREX VIP MOD MENU 4.6 (CLEAN ONLINE ENGINE)
-- Ultra High Performance | 110+ FPS Stable | Zero Bloat
-- Features: Native Wallhack, Head HP Bar (Wall-Penetrating), Box ESP,
--           MiniMap ESP, Aim Assist, No Recoil, iPad View, Mod Skin
-- ============================================================================

-- Re-entrance guard: allow re-init when the player controller changes (new match)
do
    local ok, gp = pcall(require, "GameLua.GameCore.Data.GameplayData")
    local pc = (ok and gp and gp.GetPlayerController and gp.GetPlayerController())
        or (slua_GameFrontendHUD and slua_GameFrontendHUD.GetPlayerController and slua_GameFrontendHUD:GetPlayerController())
    if pc and _G._MOD_LOADED and _G._MOD_PC == pc then return end
    if pc then _G._MOD_PC = pc end
    _G._MOD_LOADED = true
end

-- CORE ENGINE & LUA MODULE IMPORTS
local ENetRole = import("ENetRole")
local EPawnState = import("EPawnState")
local ESpecialMovementType = import("ESpecialMovementType")
local ESpiderSwingMoveState = import("ESpiderSwingMoveState")
local ESurviveWeaponPropSlot = import("ESurviveWeaponPropSlot")
local EParachuteState = import("EParachuteState")
local EMovementMode = import("EMovementMode")
local EStateType = import("EStateType")
local ESTEPoseState = import("ESTEPoseState")
local EGameModeType = import("EGameModeType")
local STExtraGameStateBase = import("STExtraGameStateBase")
local UKismetSystemLibrary = import("KismetSystemLibrary")
local USTExtraBlueprintFunctionLibrary = import("STExtraBlueprintFunctionLibrary")
local GameplayData = require("GameLua.GameCore.Data.GameplayData")
local GamePlayTools = require("GameLua.Mod.BaseMod.Common.GamePlayTools")
local InGameMarkTools = require("GameLua.Mod.BaseMod.Common.InGameMarkTools")
local KismetMathLibrary = import("KismetMathLibrary")
local GameplayStatics = import("GameplayStatics")
local LinearColor = import("LinearColor")
local FVec = FVector or (pcall(import, "Vector") and import("Vector")) or (pcall(import, "FVector") and import("FVector"))

-- Export to _G for any nested/external calls
_G.InGameMarkTools = InGameMarkTools
_G.GameplayData = GameplayData
-- SAFE VALIDATION HELPER
local _slua = rawget(_G, "slua")
local function Valid(obj)
    if not obj then return false end
    if _slua and _slua.isValid then
        local ok, v = pcall(_slua.isValid, obj)
        if not ok or not v then return false end
    end
    return true
end
_G.Valid = Valid

local function SafeMethodCall(obj, method, ...)
    if not obj then return false, nil end
    local fn = obj[method]
    if type(fn) ~= "function" then return false, nil end
    return pcall(fn, obj, ...)
end
_G.SafeMethodCall = SafeMethodCall

-- IMMUTABLE PAWN KEY RESOLVER (STABLE ACROSS SLUA WRAPPERS)
local function GetPawnKey(pawn)
    if not Valid(pawn) then return nil end
    local uid = nil
    if pawn.GetUniqueID then
        local okID, id = pcall(pawn.GetUniqueID, pawn)
        if okID and id and id ~= 0 then uid = id end
    end
    if uid then return uid end
    local pk = pawn.PlayerKey
    if pk and pk ~= 0 then return pk end
    local uState = pawn.PlayerState
    if Valid(uState) and uState.PlayerKey and uState.PlayerKey ~= 0 then return uState.PlayerKey end
    local puid = pawn.PlayerUID
    if puid and puid ~= "" and puid ~= "0" then return tostring(puid) end
    return tostring(pawn)
end
_G.GetPawnKey = GetPawnKey

-- BULLETPROOF PAWN HEALTH STATUS CHECK (NEVER FALSELY REPORTS LIVING ENEMIES AS DEAD)
local function IsPawnDead(pawn)
    if not Valid(pawn) then return true end
    local hs = pawn.HealthStatus
    if hs == 2 or hs == 3 or pawn.bIsDead or pawn.bDead then return true end
    if pawn.Health and pawn.Health <= 0 and hs ~= 1 and hs ~= 0 then return true end
    return false
end
_G.IsPawnDead = IsPawnDead

-- CACHED PLAYER PAWNS RESOLUTION (1.0s TTL FOR CRISP TDM & CLASSIC UPDATES)
local _PAWN_CACHE = nil
local _PAWN_CACHE_TIME = 0
local _PAWN_CACHE_TTL = 1.5

local function InvalidatePawnCache()
    _PAWN_CACHE = nil
    _PAWN_CACHE_TIME = 0
end
_G.InvalidatePawnCache = InvalidatePawnCache

local function GetCachedPlayerPawns()
    local now = os.clock()
    if _PAWN_CACHE and (now - _PAWN_CACHE_TIME) < _PAWN_CACHE_TTL then
        return true, _PAWN_CACHE
    end

    local pawnsList = {}
    local seenPawns = {}
    local function AddPawn(p)
        if not Valid(p) then return end
        local key = GetPawnKey(p) or p
        if not seenPawns[key] then
            seenPawns[key] = true
            pawnsList[#pawnsList + 1] = p
        end
    end

    pcall(function()
        local ok, pawns = SafeMethodCall(_G.Game or Game, "GetAllPlayerPawns")
        if ok and pawns then
            for _, p in pairs(pawns) do AddPawn(p) end
        end
    end)

    if #pawnsList == 0 then
        pcall(function()
            if GameplayData and GameplayData.GetAllCharacters then
                local chars = GameplayData.GetAllCharacters()
                if chars then for _, c in pairs(chars) do AddPawn(c) end end
            end
        end)
    end

    if #pawnsList == 0 then
        pcall(function()
            local okGS, GS = pcall(require, "GameLua.GameCore.Data.CGameState")
            if okGS and GS and GS.GetAllCharacters then
                local chars = GS:GetAllCharacters()
                if chars then for _, c in pairs(chars) do AddPawn(c) end end
            end
        end)
    end

    if #pawnsList > 0 then
        _PAWN_CACHE = pawnsList
        _PAWN_CACHE_TIME = now
        return true, _PAWN_CACHE
    end

    _PAWN_CACHE_TIME = now
    if _PAWN_CACHE then return true, _PAWN_CACHE end
    return false, {}
end
_G.GetCachedPlayerPawns = GetCachedPlayerPawns

-- FRAME CACHE: CAMERA-ANCHORED LOCAL PAWN, LOCATION, HUD, PC & SPECTATE STATE
local _FrameCache = { frame = -1, pawn = nil, pos = nil, hud = nil, pc = nil, team = 0, time = 0, spectatedTarget = nil, isSpectating = false }
local function GetFrameCache()
    local f = os.clock()
    if (f - (_FrameCache.time or 0)) > 0.05 then
        _FrameCache.time = f
        _FrameCache.frame = _FrameCache.frame + 1
        local pawn, pos, hud, pc = nil, nil, nil, nil
        pcall(function()
            if GameplayData then
                if GameplayData.GetLocalCharacter then pawn = GameplayData.GetLocalCharacter() end
                if not pawn and GameplayData.GetPlayerCharacter then pawn = GameplayData.GetPlayerCharacter() end
            end
        end)
        if not pc and slua_GameFrontendHUD then
            pcall(function() pc = slua_GameFrontendHUD:GetPlayerController() end)
        end
        if not pc and GameplayData then
            pcall(function() pc = GameplayData.GetPlayerController and GameplayData.GetPlayerController() end)
        end
        if not pawn and pc then
            pcall(function()
                if pc.GetPlayerCharacterSafety then pawn = pc:GetPlayerCharacterSafety() end
                if not pawn and pc.GetPawn then pawn = pc:GetPawn() end
                if not pawn and pc.GetPlayerCharacter then pawn = pc:GetPlayerCharacter() end
            end)
        end

        local spectatedTarget = nil
        local isSpectating = false
        pcall(function()
            if pc and Valid(pc) then
                local vt = nil
                if pc.GetViewTarget then vt = pc:GetViewTarget() end
                if not vt and pc.PlayerCameraManager and pc.PlayerCameraManager.ViewTarget then
                    vt = pc.PlayerCameraManager.ViewTarget.Target
                end
                local localIsDead = false
                if pawn and Valid(pawn) then
                    local hs = pawn.HealthStatus
                    if hs == 2 or hs == 3 or pawn.bIsDead or pawn.bDead or (pawn.Health and pawn.Health <= 0 and hs ~= 1) then
                        localIsDead = true
                    end
                else
                    localIsDead = true
                end

                if (localIsDead or pc.bIsSpectating or (pc.IsInSpectatingMode and pc:IsInSpectatingMode())) and vt and Valid(vt) then
                    isSpectating = true
                    spectatedTarget = vt
                end
            end
        end)

        if isSpectating and spectatedTarget then
            pawn = spectatedTarget
            local okVT, vtPos = SafeMethodCall(spectatedTarget, "K2_GetActorLocation")
            if okVT and vtPos then pos = vtPos end
            _FrameCache.team = spectatedTarget.TeamID or 0
        else
            if pawn then
                local okLoc, pPos = SafeMethodCall(pawn, "K2_GetActorLocation")
                if okLoc and pPos then pos = pPos end
            else
                pawn = _FrameCache.pawn
                pos = _FrameCache.pos
            end
            _FrameCache.team = pawn and pawn.TeamID or 0
        end

        if not hud and pawn and Valid(pawn) then pcall(function() hud = pawn.MyHUD end) end
        if not hud and pc and Valid(pc) then pcall(function() hud = pc.MyHUD or (pc.GetHUD and pc:GetHUD()) end) end
        if not hud and slua_GameFrontendHUD and Valid(slua_GameFrontendHUD) then hud = slua_GameFrontendHUD end
        if not hud and _FrameCache.hud and Valid(_FrameCache.hud) then hud = _FrameCache.hud end
        _FrameCache.pawn = pawn
        _FrameCache.pos = pos
        _FrameCache.hud = hud
        _FrameCache.pc = pc
        _FrameCache.spectatedTarget = spectatedTarget
        _FrameCache.isSpectating = isSpectating
    end
    return _FrameCache.pawn, _FrameCache.pos, _FrameCache.hud, _FrameCache.pc, _FrameCache.team, _FrameCache.spectatedTarget, _FrameCache.isSpectating
end
_G.GetFrameCache = GetFrameCache

-- MULTI-FALLBACK PLAYER CONTROLLER RESOLUTION
local function GetActivePlayerController(passedPc)
    if Valid(passedPc) and passedPc.AddGameTimer then return passedPc end
    local pc = nil
    pcall(function()
        if GameplayData and GameplayData.GetPlayerController then pc = GameplayData.GetPlayerController() end
    end)
    if Valid(pc) and pc.AddGameTimer then return pc end

    pcall(function()
        local world = _slua and _slua.getWorld and _slua.getWorld()
        local KSL = UKismetSystemLibrary or import("KismetSystemLibrary")
        if KSL and world and KSL.GetPlayerController then
            local retPc = KSL.GetPlayerController(world, 0)
            if Valid(retPc) and retPc.AddGameTimer then pc = retPc end
        end
    end)
    if Valid(pc) and pc.AddGameTimer then return pc end

    if _G.Game and _G.Game.AddGameTimer then return _G.Game end

    pcall(function()
        if slua_GameFrontendHUD and Valid(slua_GameFrontendHUD) then
            local retPc = slua_GameFrontendHUD:GetPlayerController()
            if Valid(retPc) and retPc.AddGameTimer then pc = retPc end
        end
    end)
    return pc
end

-- MULTI-FALLBACK LOCAL PLAYER CHARACTER RESOLUTION
local function GetLocalPlayer(pc)
    local p = nil
    if Valid(pc) then
        pcall(function()
            if pc.GetPlayerCharacterSafety then p = pc:GetPlayerCharacterSafety() end
            if not Valid(p) and pc.GetCurPlayerCharacter then p = pc:GetCurPlayerCharacter() end
            if not Valid(p) and pc.GetPawn then p = pc:GetPawn() end
        end)
    end
    if not Valid(p) then
        pcall(function()
            if GameplayData then
                if GameplayData.GetLocalCharacter then p = GameplayData.GetLocalCharacter() end
                if not Valid(p) and GameplayData.GetPlayerCharacter then p = GameplayData.GetPlayerCharacter() end
            end
        end)
    end
    if not Valid(p) then
        local activePc = GetActivePlayerController()
        if Valid(activePc) and activePc ~= pc then
            pcall(function()
                if activePc.GetPlayerCharacterSafety then p = activePc:GetPlayerCharacterSafety() end
                if not Valid(p) and activePc.GetCurPlayerCharacter then p = activePc:GetCurPlayerCharacter() end
            end)
        end
    end
    return p
end

-- ENEMY RESOLUTION (USES CACHED PLAYER PAWNS + TEAM FILTER)
local function GetAllEnemies(localPlayer)
    local ok, pawns = GetCachedPlayerPawns()
    if not ok or not pawns then return {} end
    local localPawn, _, _, _, myTeam = GetFrameCache()
    local lp = localPlayer or localPawn
    local myTeamId = (lp and lp.TeamID) or myTeam or 0
    local enemies = {}
    for _, p in ipairs(pawns) do
        if Valid(p) and p ~= lp then
            local pTeam = p.TeamID or (type(p.GetTeamID) == "function" and p:GetTeamID())
            if not (myTeamId > 0 and pTeam and pTeam > 0 and pTeam == myTeamId) then
                enemies[#enemies + 1] = p
            end
        end
    end
    return enemies
end
_G.GetAllEnemies = GetAllEnemies

-- CLEAR MOD TIMERS ON MATCH EXIT
local function ClearModTimers(pc)
    if not _G.LexusState or not _G.LexusState.ModTimers then return end
    for _, tData in ipairs(_G.LexusState.ModTimers) do
        if type(tData) == "table" and Valid(tData.owner) and tData.owner.RemoveGameTimer and tData.id then
            pcall(tData.owner.RemoveGameTimer, tData.owner, tData.id)
        elseif type(tData) == "number" and Valid(pc) and pc.RemoveGameTimer then
            pcall(pc.RemoveGameTimer, pc, tData)
        end
    end
    _G.LexusState.ModTimers = {}
end
_G.ClearModTimers = ClearModTimers

-- TimerManager - Centralised, safe timer wrapper for mod timers
local ModTimerManagerEnabled = true
local TimerManager = {}
TimerManager.Enabled = ModTimerManagerEnabled
TimerManager.MinInterval = {
    UI        = 0.05,
    Movement  = 0.2,
    Visual    = 0.3,
    Diagnostic = 1.0
}
TimerManager._byId = {}
TimerManager._byOwner = {}
local function safeOwnerKey(owner)
    if not owner then return "__nil" end
    if owner.GetUniqueID then return tostring(owner:GetUniqueID()) end
    return tostring(owner)
end
function TimerManager:SetCategoryMinInterval(category, seconds)
    if category and seconds then
        self.MinInterval[category] = tonumber(seconds) or self.MinInterval[category]
    end
end
function TimerManager:Register(owner, name, interval, loop, category, fn)
    if not self.Enabled then
        if owner and owner.AddGameTimer then return owner:AddGameTimer(interval, loop, fn) end
        return nil
    end
    if not owner or type(fn) ~= "function" or not owner.AddGameTimer then return nil end

    category = category or "Visual"
    local minI = self.MinInterval[category] or 0.10
    local useInterval = math.max(interval or minI, minI)
    local ownerKey = safeOwnerKey(owner)
    local nameKey = ownerKey .. "" .. tostring(name or "__unnamed")

    local existingId = self._byName and self._byName[nameKey]
    if existingId and self._byId[existingId] then
        return existingId
    elseif existingId then
        self:Clear(existingId)
    end

    local timerId = nil
    local wrapped = function()
        if not Valid(owner) then
            if timerId and owner and type(owner.RemoveGameTimer) == "function" then
                pcall(owner.RemoveGameTimer, owner, timerId)
            end
            TimerManager:Clear(timerId)
            return
        end
        pcall(fn, owner)
    end

    timerId = owner:AddGameTimer(useInterval, loop, wrapped)
    if not timerId then return nil end

    self._byId[timerId] = {
        owner = owner,
        ownerKey = ownerKey,
        name = name,
        nameKey = nameKey,
        interval = useInterval,
        loop = loop,
        category = category,
        registeredAt = os.clock()
    }
    self._byName = self._byName or {}
    self._byName[nameKey] = timerId
    self._byOwner[ownerKey] = self._byOwner[ownerKey] or {}
    table.insert(self._byOwner[ownerKey], timerId)
    return timerId
end

function TimerManager:Clear(timerId)
    if not timerId then return end
    local rec = self._byId[timerId]
    if not rec then return end
    if Valid(rec.owner) and rec.owner.RemoveGameTimer then
        pcall(rec.owner.RemoveGameTimer, rec.owner, timerId)
    end
    if rec.nameKey and self._byName then self._byName[rec.nameKey] = nil end
    if rec.ownerKey and self._byOwner[rec.ownerKey] then
        for i, tid in ipairs(self._byOwner[rec.ownerKey]) do
            if tid == timerId then
                table.remove(self._byOwner[rec.ownerKey], i)
                break
            end
        end
    end
    self._byId[timerId] = nil
end

function TimerManager:ClearAllForOwner(owner)
    local ok = safeOwnerKey(owner)
    if not self._byOwner[ok] then return end
    local list = {}
    for _, tid in ipairs(self._byOwner[ok]) do list[#list + 1] = tid end
    for _, tid in ipairs(list) do self:Clear(tid) end
    self._byOwner[ok] = nil
end
_G.TimerManager = TimerManager
-- STATIC CONSTANTS & COLORS
local C_GREEN = {R=0, G=255, B=0, A=255}
local C_RED = {R=255, G=0, B=0, A=255}
local C_CYAN = {R=0, G=255, B=255, A=255}
local C_YELLOW = {R=255, G=255, B=0, A=255}
local C_WHITE = {R=255, G=255, B=255, A=255}
local C_BLUE_TEXT = {R=0, G=200, B=255, A=255}
local SCALE_COLOR_V2 = {R=3, G=3, B=0, A=0}

local function Notify(msg)
    pcall(function()
        if _G.LexusNotify then _G.LexusNotify("[VIP] " .. tostring(msg)) end
    end)
end

-- LEXUS CONFIGURATION
_G.LexusConfig = _G.LexusConfig or { 
    TargetFPS = 165,
    ModSkin = false,           
    SkinOptionOpen = false,
    ESP_All = false,
    EnemyCounterEnabled = false,
    HealthBarESPEnabled = false,
    BoxESPEnabled = false,
    MapESPEnabled = false,
    SnaplineESPEnabled = false,
    WallHackEnabled = false,
    ColorEnemyWHVis = 0,
    ColorEnemyWHOcc = 2,
    ColorBotWHVis = 1,
    ColorBotWHOcc = 3,
    GlowIntensity = 60,
    VehicleESPEnabled = false,
    VehicleDistance = 400,
    VehicleShowDist = true,
    LootESPEnabled = false,
    LootDistance = 60,
    LootFlares = true,
    LootWeapons = true,
    LootArmor = true,
    LootScopes = true,
    LootMeds = true,
    AimAssistEnabled = true,
    AimPower = 50,
    IgnoreKnocked = true,
    IgnoreBot = false,
    NoRecoilEnabled = false,
    RecoilReduction = 100,
    iPadViewEnabled = false,
    iPadViewFOV = 110,
    VisualCleanupEnabled = false
}

_G.LexusState = _G.LexusState or { 
    MatchStarted = false, 
    VisualsStarted = false, 
    SkinWasApplied = false, 
    DirtyConfig = false,
    NativeESPReady = false,
    ModTimers = {}
}

-- BULLETPROOF TIMER REGISTRY: NEVER SELF-DESTRUCTS ON TEMPORARY NIL PAWN
local function AddModTimer(passedOwner, interval, loop, func)
    local target = GetActivePlayerController(passedOwner)
    if not Valid(target) or not target.AddGameTimer then return nil end
    local timerId
    local wrapped = function()
        if not Valid(target) then
            if timerId and target.RemoveGameTimer then pcall(target.RemoveGameTimer, target, timerId) end
            return
        end
        local localPlayer = GetLocalPlayer(target)
        pcall(func, localPlayer, target)
    end
    timerId = target:AddGameTimer(interval, loop, wrapped)
    if timerId then
        table.insert(_G.LexusState.ModTimers, { owner = target, id = timerId })
    end
    return timerId
end

-- ==================== MOD SKIN SYSTEM ====================
_G.VIP_Attachments = {
    [1101004236]={1010042307,1010042306,1010042308,1010042304,1010042300,1010042305,1010042299,1010042298,1010042297,1010042296,1010042295,1010042294,0,1010042314,1010042309,1010042316,1010042317,1010042318,1010042310,1010042315,1010042319,0},
    [1101001116]={1010011106,1010011107,1010011108,0,1010011109,1010011112,1010011105,1010011104,1010011103,0,1010011102,0,0,0,0,0,0,0,0,0,0,0},
    [1101001128]={1010011232,1010011233,1010011234,1010011228,1010011227,1010011229,1010011226,1010011225,1010011224,1010011223,1010011222,0,0,0,0,0,0,0,0,0,0,0},
    [1101001154]={1010011487,1010011488,1010011489,1010011493,1010011490,1010011494,1010011486,1010011485,1010011484,1010011483,1010011482,1010011497,0,0,0,0,0,0,0,0,1010011498,0},
    [1101001174]={1010011667,1010011668,1010011669,1010011673,1010011670,1010011674,1010011666,1010011665,1010011664,1010011663,1010011662,0,0,0,0,0,0,0,0,0,0,0},
    [1101001213]={1010012067,1010012068,1010012069,1010012072,1010012070,1010012073,1010012066,1010012065,1010012064,1010012063,1010012062,0,0,0,0,0,0,0,0,1010012074,0},
    [1101001231]={1010012267,1010012268,1010012269,1010012273,1010012272,1010012274,1010012266,1010012265,1010012264,1010012263,1010012262,1010012075,0,0,0,0,0,0,0,0,1010012275,0},
    [1101001242]={1010012357,1010012358,1010012359,1010012363,1010012362,1010012364,1010012356,1010012355,1010012354,1010012353,1010012352,1010012276,0,0,0,0,0,0,0,0,1010012365,0},
    [1101001249]={1010012437,1010012438,1010012439,1010012443,1010012442,1010012444,1010012436,1010012435,1010012434,1010012433,1010012432,1010012366,0,0,0,0,0,0,0,0,1010012445,0},
    [1101001256]={1010012588,1010012589,1010012590,1010012593,1010012592,1010012594,1010012587,1010012586,1010012585,1010012584,1010012583,1010012582,0,0,0,0,0,0,0,0,1010012595,0},
    [1101001265]={1010012698,1010012699,1010012700,1010012703,1010012702,1010012704,1010012697,1010012696,1010012695,1010012694,1010012693,1010012692,0,0,0,0,0,0,0,0,1010012705,0},
    [1101001276]={1010012698,1010012699,1010012700,1010012703,1010012702,1010012704,1010012697,1010012696,1010012695,1010012694,1010012693,1010012692,0,0,0,0,0,0,0,0,1010012705,0},
    [1101002029]={1010020249,1010020250,1010020255,1010020247,1010020246,1010020248,1010020240,1010020239,1010020238,1010020237,1010020236,1010020235,0,0,0,0,0,0,0,1010020257,1010020256,1010020258},
    [1101002056]={1010020519,0,0,1010020517,1010020516,1010020518,1010020500,1010020509,1010020508,1010020507,1010020506,1010020505,0,0,0,0,0,0,0,0,0,0},
    [1101002081]={1010020768,1010020769,1010020770,1010020766,1010020760,1010020767,1010020759,1010020758,1010020757,1010020756,1010020755,1010020776,0,0,0,0,0,0,0,1010020775,1010020777,1010020778},
    [1101003070]={1010030654,1010030653,1010030655,1010030649,1010030648,1010030650,1010030647,1010030646,1010030645,1010030644,1010030643,1010030642,0,1010030658,1010030656,1010030660,1010030662,1010030659,1010030657,0,1010030663,0},
    [1101003080]={1010030754,1010030753,1010030755,1010030749,1010030748,1010030750,1010030747,1010030746,1010030745,1010030744,1010030743,1010030742,0,1010030758,1010030756,1010030760,1010030762,1010030759,1010030757,0,1010030763,0},
    [1101003099]={1010030943,1010030944,1010030945,1010030939,1010030938,1010030942,1010030937,1010030936,1010030935,1010030934,1010030933,1010030932,0,1010030947,1010030946,1010030948,1010030949,1010030953,1010030952,0,1010030955,0},
    [1101003119]={1010031139,1010031140,1010031142,1010031138,1010031137,1010031146,1010031136,1010031135,1010031134,1010031133,1010031132,0,0,1010031144,1010031143,0,0,0,1010031145,0,0,0},
    [1101003146]={1010031229,1010031230,1010031237,1010031228,1010031227,1010031242,1010031226,1010031225,1010031224,1010031223,1010031222,0,0,1010031239,1010031238,0,0,0,1010031240,0,0,0},
    [1101003167]={1010031609,1010031610,1010031613,1010031608,1010031607,1010031617,1010031606,1010031605,1010031604,1010031603,1010031602,1010031618,0,1010031615,1010031614,1010031620,1010031622,1010031619,1010031616,0,1010031623,0},
    [1101003181]={1010031765,1010031764,1010031766,1010031759,1010031758,1010031763,1010031757,1010031756,1010031755,1010031754,1010031753,1010031752,0,1010031769,1010031767,1010031773,1010031774,1010031772,1010031768,0,1010031775,0},
    [1101003195]={1010031912,1010031911,1010031913,1010031908,1010031907,1010031909,1010031906,1010031905,1010031904,1010031903,1010031902,1010031901,0,1010031916,1010031914,1010031918,1010031919,1010031917,1010031915,0,1010031921,0},
    [1101003208]={1010032034,1010032033,1010032045,1010032029,1010032028,1010032032,1010032027,1010032026,1010032025,1010032024,1010032023,1010032022,0,1010032038,1010032036,1010032042,1010032043,1010032039,1010032037,0,1010032044,0},
    [1101004046]={1010040474,1010040475,1010040476,1010040472,1010040471,1010040473,1010040470,1010040469,1010040468,1010040467,1010040466,1010040481,0,1010040479,1010040477,1010040482,1010040483,1010040484,1010040478,1010040480,1010040485,0},
    [1101004062]={1010040578,1010040577,1010040579,1010040575,1010040570,1010040576,1010040569,1010040568,1010040567,1010040566,1010040565,1010040564,0,1010040585,1010040580,1010040587,1010040588,1010040589,1010040584,1010040586,1010040590,1010040594},
    [1101004098]={1010040924,1010040926,1010040925,0,1010040937,1010040938,1010040935,1010040934,1010040929,1010040928,1010040927,0,0,1010040939,1010040945,0,0,0,1010040944,1010040936,0,0},
    [1101004138]={1010041136,1010041137,1010041138,1010041134,1010041129,1010041135,1010041128,1010041127,1010041126,1010041125,1010041124,0,0,1010041145,1010041139,0,0,0,1010041144,1010041146,0,0},
    [1101004163]={1010041570,1010041574,1010041575,1010041568,1010041567,1010041569,1010041566,1010041565,1010041564,1010041560,1010041554,0,0,1010041578,1010041576,0,0,0,1010041577,1010041579,0,0},
    [1101004201]={1010041956,1010041957,1010041958,1010041950,1010041949,1010041955,1010041948,1010041947,1010041946,1010041945,1010041944,1010041967,0,1010041965,1010041959,0,0,0,1010041960,1010041966,0,0},
    [1101004209]={1010042038,1010042037,1010042039,1010042035,1010042034,1010042036,1010042029,1010042028,1010042027,1010042026,1010042025,1010042024,0,1010042046,1010042044,1010042048,1010042049,1010042054,1010042045,1010042047,1010042055,0},
    [1101004218]={1010042128,1010042127,1010042129,1010042125,1010042124,1010042126,1010042119,1010042118,1010042117,1010042116,1010042115,1010042114,0,1010042136,1010042134,1010042138,1010042139,1010042144,1010042135,1010042137,1010042145,0},
    [1101004226]={1010042238,1010042237,1010042239,1010042235,1010042234,1010042236,1010042233,1010042232,1010042231,1010042219,1010042218,1010042217,0,1010042243,1010042241,1010042245,1010042246,1010042247,1010042242,1010042244,1010042248,0},
    [1101004246]={1010042406,1010042407,1010042408,1010042404,1010042400,1010042405,1010042399,1010042398,1010042397,1010042396,1010042395,1010042394,0,1010042414,1010042409,1010042416,1010042417,1010042418,1010042410,1010042415,1010042419,1010042420},
    [1101005038]={0,0,1010050327,1010050329,1010050328,1010050330,1010050326,1010050325,1010050324,1010050323,1010050322,1010050334,0,0,0,0,0,0,0,0,0,0},
    [1101005052]={0,0,1010050467,1010050469,1010050468,1010050470,1010050466,1010050465,1010050464,1010050463,1010050462,1010050473,0,0,0,0,0,0,0,0,0,0},
    [1101005098]={0,0,1010050928,1010050930,1010050929,1010050932,1010050927,1010050926,1010050925,1010050924,1010050923,1010050922,0,0,0,0,0,0,0,0,0,0},
    [1101006062]={1010060573,1010060572,1010060574,1010060564,1010060563,1010060571,1010060562,1010060561,1010060554,1010060553,1010060552,1010060551,0,1010060583,1010060581,1010060591,1010060592,1010060584,1010060582,0,1010060593,0},
    [1101006075]={1010060702,1010060701,1010060703,1010060698,1010060697,1010060699,1010060696,1010060695,1010060694,1010060693,1010060692,1010060691,0,1010060706,1010060704,1010060708,1010060709,1010060707,1010060705,0,1010060711,0},
    [1101006085]={1010060796,1010060795,1010060797,1010060793,1010060789,1010060794,1010060788,1010060787,1010060786,1010060785,1010060784,1010060783,0,1010060800,1010060798,1010060804,1010060805,1010060803,1010060799,0,1010060806,0},
    [1101007046]={1010070410,1010070413,1010070414,1010070408,1010070407,1010070409,1010070406,1010070405,1010070404,1010070403,1010070402,1010070418,0,1010070417,1010070415,1010070420,1010070422,1010070419,1010070416,0,1010070423,0},
    [1101007062]={1010070579,1010070578,1010070581,1010070576,1010070575,1010070577,1010070574,1010070573,1010070572,1010070571,1010070569,1010070568,0,1010070584,1010070582,1010070585,1010070586,1010070587,1010070583,0,1010070588,0},
    [1101007071]={1010070663,1010070662,1010070664,1010070659,1010070658,1010070660,1010070657,1010070656,1010070655,1010070654,1010070653,1010070652,0,1010070667,1010070665,1010070668,1010070669,1010070670,1010070666,0,1010070672,0},
    [1101008051]={1010080463,1010080464,1010080465,1010080459,1010080458,1010080462,1010080457,1010080456,1010080455,1010080454,1010080453,1010080452,0,1010080467,1010080466,1010080468,1010080469,1010080473,1010080472,0,1010080475,0},
    [1101008061]={1010080563,1010080564,1010080565,1010080559,1010080558,1010080562,1010080557,1010080556,1010080555,1010080554,1010080553,0,0,1010080567,1010080566,0,0,0,1010080572,0,0,0},
    [1101008070]={1010080609,1010080612,1010080613,1010080608,1010080607,1010080617,1010080606,1010080605,1010080604,1010080603,1010080602,0,0,1010080615,1010080614,0,0,0,1010080616,0,0,0},
    [1101008081]={1010080740,1010080743,1010080745,1010080738,1010080737,1010080739,1010080736,1010080735,1010080734,1010080733,1010080732,1010080748,0,1010080747,1010080746,1010080750,1010080752,1010080749,1010080744,0,1010080753,0},
    [1101008104]={1010080980,1010080982,1010080984,1010080978,1010080977,1010080979,1010080976,1010080975,1010080974,1010080973,1010080972,1010080992,0,1010080986,1010080985,1010080989,1010080987,1010080993,1010080983,0,1010080988,0},
    [1101008116]={1010081110,1010081112,1010081114,1010081108,1010081107,1010081109,1010081106,1010081105,1010081104,1010081103,1010081102,0,0,1010081116,1010081115,0,0,0,1010081113,0,0,0},
    [1101008126]={1010081210,1010081225,1010081226,1010081208,1010081207,1010081209,1010081206,1010081205,1010081204,1010081203,1010081202,1010081218,0,1010081217,1010081216,1010081219,1010081220,1010081222,1010081214,1010081228,1010081227,1010081229},
    [1101008136]={1010081314,1010081315,1010081316,1010081312,1010081308,1010081313,1010081307,1010081306,1010081305,1010081304,1010081303,1010081302,0,1010081318,1010081317,1010081322,1010081323,1010081325,1010081324,0,1010081326,0},
    [1101008146]={1010081401,1010081402,1010081403,1010081398,1010081397,1010081399,1010081396,1010081395,1010081394,1010081393,1010081392,1010081391,0,1010081405,1010081404,1010081406,1010081407,1010081409,1010081408,0,1010081411,0},
    [1101008154]={1010081531,1010081532,1010081533,1010081528,1010081527,1010081529,1010081526,1010081525,1010081524,1010081523,1010081522,1010081521,0,1010081541,1010081534,1010081542,1010081543,1010081545,1010081544,0,1010081546,0},
    [1101008163]={1010081582,1010081583,1010081584,1010081579,1010081578,1010081580,1010081577,1010081576,1010081575,1010081574,1010081573,1010081572,0,1010081586,1010081585,1010081587,1010081588,1010081590,1010081589,0,1010081592,0},
    [1101012033]={1010120284,1010120285,1010120286,1010120280,1010120279,1010120283,1010120278,1010120277,1010120276,1010120275,1010120274,1010120273,0,0,0,0,0,0,0,0,1010120287,0},
    [1101100012]={1011000066,1011000067,1011000068,0,0,0,1011000058,1011000057,1011000056,1011000055,1011000054,1011000053,0,0,0,0,0,0,0,0,1011000073,0},
    [1101102007]={1011010025,1011010024,1011010026,1011010020,1011010019,1011010023,1011010018,1011010017,1011010016,1011010015,1011010014,1011010013,0,0,0,0,0,0,0,0,1011010027,0},
    [1101102017]={1011020027,1011020028,1011020029,1011020025,1011020024,1011020026,1011020019,1011020018,1011020017,1011020016,1011020015,1011020014,0,1011020036,1011020034,1011020038,1011020039,1011020044,1011020035,1011020037,1011020045,1011020047},
    [1101102025]={1011020127,1011020128,1011020129,1011020125,1011020124,1011020126,1011020119,1011020118,1011020117,1011020116,1011020115,1011020114,0,1011020136,1011020134,1011020138,1011020139,1011020144,1011020135,1011020137,1011020145,0},
    [1101102041]={1011020214,1011020215,1011020216,1011020212,1011020211,1011020213,1011020209,1011020208,1011020207,1011020206,1011020205,1011020204,0,1011020219,1011020217,1011020222,1011020223,1011020224,1011020218,1011020221,1011020225,1011020229},
    [1101102049]={1011020356,1011020357,1011020358,1011020354,1011020350,1011020355,1011020349,1011020348,1011020347,1011020346,1011020345,1011020344,0,1011020364,1011020359,1011020366,1011020367,1011020368,1011020360,1011020365,1011020369,1011020370},
    [1101101007]={1011020436,1011020437,1011020438,1011020434,1011020430,1011020435,1011020429,1011020428,1011020427,1011020426,1011020425,1011020424,0,1011020444,1011020439,1011020446,1011020447,1011020448,1011020440,1011020445,1011020449,1011020450},
    [1102001120]={1020011137,1020011138,1020011139,1020011135,1020011134,1020011136,1020011133,1020011132,0,0,0,0,0,0,0,0,0,0,0,1020011142,0,0},
    [1102001130]={1020011247,1020011248,1020011249,1020011245,1020011244,1020011246,1020011243,1020011242,0,0,0,0,0,0,0,0,0,0,0,1020011250,0,0},
    [1102002043]={1020020372,1020020374,1020020373,1020020383,1020020380,1020020384,1020020379,1020020378,1020020377,1020020376,1020020375,1020020388,0,1020020385,1020020387,0,0,0,1020020386,0,0,0},
    [1102002061]={1020020552,1020020554,1020020553,1020020563,1020020562,1020020564,1020020559,1020020558,1020020557,1020020556,1020020555,1020020578,0,1020020565,1020020567,1020020573,1020020574,1020020572,1020020566,0,1020020569,0},
    [1102002136]={1020021314,1020021313,1020021315,1020021309,1020021308,1020021312,1020021307,1020021306,1020021305,1020021304,1020021303,1020021302,0,1020021318,1020021316,1020021323,1020021324,1020021322,1020021317,0,1020021325,0},
    [1102002424]={1020024193,1020024192,1020024194,1020024189,1020024188,1020024190,1020024187,1020024186,1020024185,1020024184,1020024183,1020024182,0,1020024197,1020024195,1020024199,1020024200,1020024198,1020024196,0,1020024202,0},
    [1102003080]={1020030755,1020030756,1020030758,0,1020030749,1020030754,1020030748,1020030747,1020030746,1020030745,1020030744,1020030764,0,1020030760,0,1020030759,1020030757,0,0,1020030765,0,0},
    [1102003100]={1020030956,1020030957,1020030958,1020030954,1020030950,1020030955,1020030949,1020030948,1020030947,1020030946,1020030945,1020030944,0,1020030964,0,1020030960,1020030959,1020030965,0,1020030967,1020030966,1020030968},
    [1102005064]={1020050588,1020050589,1020050590,0,0,0,1020050587,1020050586,1020050585,1020050584,1020050583,1020050582,0,0,0,0,0,0,0,0,1020050592,0},
    [1103001101]={1030010954,1030010955,1030010956,0,0,0,0,0,0,0,1030010953,1030010952,1030010951,0,0,0,0,0,0,1030010957,0,1030010958},
    [1103001146]={1030011344,1030011345,1030011346,0,0,0,0,0,0,0,1030011343,1030011342,1030011341,0,0,0,0,0,0,1030011347,0,1030011348},
    [1103001154]={1030011484,1030011485,1030011486,0,0,0,0,0,0,0,1030011483,1030011482,1030011481,0,0,0,0,0,0,1030011487,0,1030011488},
    [1103001179]={1030011738,1030011739,1030011741,0,0,0,1030011737,1030011736,1030011735,1030011734,1030011733,1030011732,1030011731,0,0,0,0,0,0,1030011742,1030011743,1030011744},
    [1103001191]={1030011858,1030011859,1030011861,0,0,0,1030011857,1030011856,1030011855,1030011854,1030011853,1030011852,1030011851,0,0,0,0,0,0,1030011862,1030011863,1030011864},
    [1103001202]={1030011948,1030011949,1030011950,0,0,0,1030011947,1030011946,1030011945,1030011944,1030011943,1030011942,1030011941,0,0,0,0,0,0,1030011951,1030011952,1030011953},
    [1103002030]={1030020245,1030020246,1030020247,1030020252,1030020249,1030020253,1030020258,1030020257,1030020256,1030020255,1030020244,1030020243,1030020242,0,0,0,0,0,0,1030020248,0,0},
    [1103002059]={1030020544,1030020545,1030020546,1030020542,1030020539,1030020543,1030020538,1030020537,1030020536,1030020535,1030020534,1030020533,1030020532,0,0,0,0,0,0,1030020547,1030020548,0},
    [1103002087]={1030020824,1030020825,1030020826,0,0,0,1030020818,1030020817,1030020816,1030020815,1030020814,1030020813,1030020812,0,0,0,0,0,0,1030020827,1030020828,0},
    [1103002106]={1030021009,1030021010,1030021012,1030021015,1030021014,1030021016,1030021008,1030021007,1030021006,1030021005,1030021004,1030021003,1030021002,0,0,0,0,0,0,1030021013,1030021017,0},
    [1103002113]={1030021079,1030021080,1030021082,1030021085,1030021084,1030021086,1030021078,1030021077,1030021076,1030021075,1030021074,1030021073,1030021072,0,0,0,0,0,0,1030021083,1030021087,0},
    [1103003022]={1030030165,1030030166,1030030167,1030030172,1030030169,1030030173,0,0,0,0,1030030164,1030030163,1030030162,0,0,0,0,0,0,0,0,0},
    [1103003030]={1030030256,1030030257,1030030258,1030030254,1030030253,1030030255,1030030248,1030030247,1030030246,1030030245,1030030244,1030030243,1030030242,0,0,0,0,0,0,1030030259,1030030249,0},
    [1103003042]={1030030374,1030030375,1030030376,1030030372,1030030369,1030030373,0,0,0,0,1030030364,1030030363,1030030362,0,0,0,0,0,0,1030030377,0,0},
    [1103003051]={1030030458,1030030459,1030030460,1030030456,1030030455,1030030457,0,0,0,0,1030030454,1030030453,1030030452,0,0,0,0,0,0,1030030463,0,0},
    [1103003062]={1030030568,1030030569,1030030570,1030030566,1030030565,1030030567,0,0,0,0,1030030564,1030030563,1030030562,0,0,0,0,0,0,1030030572,0,0},
    [1103003079]={1030030744,1030030745,1030030746,1030030742,1030030740,1030030743,1030030738,1030030737,1030030736,1030030735,1030030734,1030030733,1030030732,0,0,0,0,0,0,1030030747,1030030739,0},
    [1103003087]={1030030825,1030030826,1030030827,1030030823,1030030824,1030030824,1030030818,1030030817,1030030816,1030030815,1030030814,1030030813,1030030812,0,0,0,0,0,0,1030030828,1030030819,0},
    [1103004037]={1030040315,1030040316,1030040317,1030040325,1030040324,1030040323,0,0,0,0,1030040314,1030040313,1030040312,1030040327,1030040326,0,0,0,1030040328,1030040329,0,0},
    [1103006030]={1030060245,1030060246,1030060247,0,1030060253,1030060252,0,0,0,0,1030060244,1030060243,1030060242,0,0,0,0,0,0,0,0,0},
    [1103007028]={1030070233,1030070234,1030070235,1030070226,1030070225,1030070227,1030070218,1030070217,1030070216,1030070215,1030070214,1030070213,1030070212,0,0,0,0,0,0,1030070236,1030070219,0},
    [1103012010]={0,0,0,0,0,0,1030120038,1030120037,1030120036,1030120035,1030120034,1030120033,1030120032,0,0,0,0,0,0,0,0,0},
    [1103012019]={0,0,0,0,0,0,1030120138,1030120137,1030120136,1030120135,1030120134,1030120133,1030120132,0,0,0,0,0,0,0,0,0},
    [1103012031]={0,0,0,0,0,0,1030120258,1030120257,1030120256,1030120255,1030120254,1030120253,1030120252,0,0,0,0,0,0,0,0,0},
    [1103012039]={0,0,0,0,0,0,1030120339,1030120338,1030120337,1030120336,1030120335,1030120334,1030120333,0,0,0,0,0,0,0,0,0},
    [1103102007]={1031020026,1031020027,1031020028,1031020024,1031020023,1031020025,1031020019,1031020018,1031020017,1031020016,1031020015,1031020014,1031020013,0,0,0,0,0,0,1031020029,0,0},
    [1105001034]={0,0,0,0,1050010287,1050010289,1050010286,1050010285,1050010284,1050010283,1050010282,0,0,0,0,0,0,0,0,1050010292,0,0},
    [1105001048]={0,0,0,1050010429,1050010428,1050010434,1050010427,1050010426,1050010425,1050010424,1050010423,0,0,0,0,0,0,0,0,1050010435,0,1050010436},
    [1105001069]={0,0,0,1050010639,1050010638,1050010640,1050010637,1050010636,1050010635,1050010634,1050010633,1050010645,0,0,0,0,0,0,0,0,1050010643,1050010646,1050010644},
    [1105002091]={0,0,0,0,0,0,1050020847,1050020846,1050020845,1050020844,1050020843,1050020842,0,0,0,0,0,0,0,0,0,1050020848},
    [1105010019]={0,0,0,0,0,0,1050100144,1050100143,1050100142,1050100141,1050100139,1050100138,0,0,0,0,0,0,0,0,0,0}
}
_G.BaseAttachToIndex = {
    [201010]=1, [201005]=1, [201004]=1, [201009]=2, [201003]=2, [201002]=2, 
    [201011]=3, [201007]=3, [201006]=3, [204012]=4, [204005]=4, [204008]=4, 
    [204011]=5, [204004]=5, [204007]=5, [204013]=6, [204006]=6, [204009]=6, 
    [203001]=7, [203002]=8, [203003]=9, [203014]=10, [203004]=11, [203015]=12, [203005]=13, 
    [202002]=14, [202001]=15, [202004]=16, [202005]=17, [202007]=18, [202006]=19, 
    [205002]=20, [205003]=20, [205001]=20, [203018]=21, [204014]=22 
}
_G.VipAttachToIndex = {}
for skinId, attachList in pairs(_G.VIP_Attachments) do
    for index, attachId in ipairs(attachList) do
        if attachId > 0 then
            _G.VipAttachToIndex[attachId] = index
        end
    end
end
_G.WeaponSkinMap = _G.WeaponSkinMap or {}
_G.VehicleSkinMap = _G.VehicleSkinMap or {}
_G.OutfitMap = _G.OutfitMap or {}
_G.skinIdCache = _G.skinIdCache or {}
_G.skinIdCache2 = _G.skinIdCache2 or {}
_G.OutfitSkins = {
    Suit = {1405628,1407920,1407916,1407895,1405760,1407870,1407856,1407812,1407758,1407789,1407682,1407696,1407695,1407632,1407631,1407667,1407618,1407573,1407572,1407559,1407558,1407550,1407523,1407718,1407512,1407471,1407470,1406985,1407353,1407366,1407330,1407487,1410668,1407276,1407275,1407142,1407141,1407140,1406971,1406897,1406891,1407187,1405802,1405192,1405334,1400687,1405340,1405623,1405132,1405436,1405435,1405434,1405433,1405208,1407916,1407917,1407918,1407921,1407921,1407926,1407901,1407902,1407903,1407904,1407822,1407823,1407824,1407825,1407807,1407808,1407845,1407846,1407847,1407848,1407794,1411037,1407795,1411038,1407796,1411039},
    Pants = {1404002,1404050,1404425,1404495,1400650,1404522,1404441,1404152,1404196,1404134,1404137,1404164,1404191,1404466,1400052,404035,1404181,404084,1404516},
    Hair = {40605010,40605011,40605012,1410480,1410085,1410299,1402834,441400152,1400150,1402582,1410289,1402218,1402223,1402283,1400426},
    Bag = {
        {501001, 501002, 501003}, {1501001174, 1501002174, 1501003174}, {1501001220, 1501002220, 1501003220},
        {1501001051, 1501002051, 1501003051}, {1501001443, 1501002443, 1501003443}, {1501001265, 1501002265, 1501003265},
        {1501001321, 1501002321, 1501003321}, {1501001277, 1501002277, 1501003277}, {1501001550, 1501002550, 1501003550},
        {1501001592, 1501002592, 1501003592}, {1501001608, 1501002608, 1501003608}, {1501001024, 1501002024, 1501003024},
        {1501001019, 1501002019, 1501003019}, {1501001179, 1501002179, 1501003179}, {1501001194, 1501002194, 1501003194},
        {1501001346, 1501002346, 1501003346}
    },
    Helmet = {
        {502001, 502002, 502003}, {1502001014, 1502002014, 1502003014}, {1502001349, 1502002349, 1502003349},
        {1502001012, 1502002012, 1502003012}, {1502001009, 1502002009, 1502003009}, {1502001397, 1502002397, 1502003397},
        {1502001390, 1502002390, 1502003390}, {1502001381, 1502002381, 1502003381}, {1502001358, 1502002358, 1502003358},
        {1502001350, 1502002350, 1502003350}, {1502001342, 1502002342, 1502003342}
    },
    Pet = {50000,50001,50002,50003,50004,50005,50006,50021,50022,50038,50039,50040}
}
_G.skinIdMappings = {
    [101004]={101004, 1101004246,1101004226,1101004236,1101004062,1101004078,1101004086,1101004201,1101004218},
    [101001]={101001,1101001276,1101001089,1101001213,1101001172,1101001127,1101001230,1101001241},                    
    [101003]={101003,1101003227,1103003208,1101003195,1101003187,1101003098,1101003166,1101003218},                    
    [102002]={102002,1102002136,1102002043,1102002061,1102002424},                                          
    [101008]={101008,1101008146,1101008154,1101008079,1101008126,1101008104,1101008146,1101008061,1101008116},                    
    [101006]={101006,1101006085,1101006061,1101006074,1101006043,1101006032,1101006084},
    [102001]={102001, 1102001120}, -- UZI Băng Giá
    [101005]={101005, 1101005098}, -- Groza Godzilla Bốc Lửa
    [104003]={104003, 1104003037}, -- S12K Nguyên Tử
    [104004]={104004, 1104004035, 1104004041}, -- DBS Quái Thú & Sandsinger
    [101101]={101101, 1101101007}, --asm
    [101007]={101007, 1101007071,1101007062,1101007046,1101007078,1101007072},  -- QBZ
    [101012]={101012, 1101012033},  -- Honey Badger
    [101002]={101002, 1101002081,1101002056,1101002029,1101002149},  -- M16A4
    [101102]={101102, 1101102049,1101102025,1101102017,1101102007,1101102032},  -- ACE32
    [103001]={103001, 1103001202,1103001191,1103001179,1103001146,1103001101,1103001079,1103001202},  -- Kar98k
    [103002]={103002, 1103002113,1103002098,1103002087,1103002060,1103002059,1103002030},  -- M24
    [103003]={103003, 1103003087,1103003079,1103003069,1103003062,1103003055,1103003051,1103003042,1103003030,1103003022,1103003092},  -- AWM
}
_G.VehicleSkins = { 
    [1961001] = { 1961151,1961152,1961153,1961147,1961148,1961149,1961144,1961145,1961137,1961138,1961139,1961066,1961067,1961065,1961062,1961063,1961064,1961054,1961055,1961056,1961057,1961051,1961052,1961053,1961048,1961049,1961050,1961044,1961045,1961046,1961047,1961041,1961042,1961043,1961038,1961039,1961040,1961033,1961034,1961035,1961029,1961030,1961031,1961032,1961007,1961010,1961012,1961013,1961014,1961015,1961140,1961141,1961142,1961143,1991023,1991024 }, --cople rb
    [1903001] = { 1903228,1903220,1903221,1903223,1903218,1903219,1903213,1903212,1903202,1908094,1908095,1903193,1903192,1903191,19030790,19030791,19030800,19030801,1903074,1903075,1903076,1903071,1903072,1903073,1903216,1903217,1991001,1991002,1991003,1991004,1903088,1903089,1903090,1903023 }, --dacia
    [1915004] = { 1915021, 1915022, 1915008, 1915009, 1914011 }, -- Mirado open top        
    [1908001] = { 1908108,1908109,19080951,19081080,1908084,1908085,1908075,1908077,1908078,1908070,1908069,1908066,1908086,1908088,1908089,1908018 },  --uaz 
    [1907002] = { 1907058, 1907054, 1907059, 1907053, 1907063, 1907072, 1907040, 1907041, 1907027, 1907047, 1907021} -- Buggy 
}
_G.CustSlotType = { ClothesEquipemtSlot=5, BackpackEquipemtSlot=8, HelmetEquipemtSlot=9, ParachuteEquipemtSlot=11, GlideEquipemtSlot=15 }
local function DownloadGameItem(id)
    local puffer_manager = require('client.slua.logic.download.puffer.puffer_manager')
    local puffer_const = require('client.slua.logic.download.puffer_const')
    if not puffer_manager or not puffer_const then return end
    local state = puffer_manager.GetState(puffer_const.ENUM_DownloadType.ODPTD, {id})
    if state ~= puffer_const.ENUM_DownloadState.Done and state ~= puffer_const.ENUM_DownloadState.Downloading then
        puffer_manager.Download(puffer_const.ENUM_DownloadType.ODPTD, {id})
    end
end
_G.download_item = DownloadGameItem
_G.get_skin_id = function(weaponID)
    if not weaponID then return nil end
    local targetSkinId = _G.WeaponSkinMap and _G.WeaponSkinMap[weaponID]
    if targetSkinId and targetSkinId > 0 then
        if not _G.skinIdCache2[targetSkinId] then
            if _G.download_item then pcall(_G.download_item, targetSkinId) end
            _G.skinIdCache2[targetSkinId] = true
        end
        return targetSkinId
    end
    return weaponID
end
_G.equip_character_avatar = function(Character)
    if not Character or not slua.isValid(Character) or not Character.AvatarComponent2 then return end
    local BackpackUtils = import("BackpackUtils")
    local SlotSyncData = Character.AvatarComponent2.NetAvatarData and Character.AvatarComponent2.NetAvatarData.SlotSyncData
    if not SlotSyncData or not slua.isValid(SlotSyncData) or not BackpackUtils then return end
    local function EquipAvatar(ApplyDataIdx, mappedSkin, ApplyEquipSlot, isLevelDependent, levelFunc)
        if not mappedSkin or mappedSkin == 0 then return end
        local slotData = SlotSyncData:Get(ApplyDataIdx)
        if slotData and slotData.SlotID == ApplyEquipSlot then
            local applyItemId = mappedSkin
            if isLevelDependent and type(mappedSkin) == "table" then
                local level = levelFunc(slotData.AdditionalItemID) or 1
                if level < 1 then level = 1 end
                if level > 3 then level = 3 end
                applyItemId = mappedSkin[level] or mappedSkin[1]
            end
            if not applyItemId or applyItemId == 0 or slotData.ItemId == applyItemId then return end
            if not _G.skinIdCache[applyItemId] then
                if _G.download_item then pcall(_G.download_item, applyItemId) end
                _G.skinIdCache[applyItemId] = true
            end
            slotData.ItemId = applyItemId
            SlotSyncData:Set(ApplyDataIdx, slotData)
            Character.AvatarComponent2:OnRep_BodySlotStateChanged()
        end
    end
    local hasGliderSlot = false
    for i = 0, SlotSyncData:Num() - 1 do
        local slotData = SlotSyncData:Get(i)
        if slotData and slotData.SlotID == _G.CustSlotType.GlideEquipemtSlot then 
            hasGliderSlot = true
            break 
        end
    end
    if not hasGliderSlot then SlotSyncData:Add({ SlotID = _G.CustSlotType.GlideEquipemtSlot, ItemId = 0 }) end
    for i = 0, SlotSyncData:Num() - 1 do
        EquipAvatar(i, _G.OutfitMap.Suit or 0, _G.CustSlotType.ClothesEquipemtSlot, false)
        EquipAvatar(i, _G.OutfitMap.Pants or 0, 6, false)
        EquipAvatar(i, _G.OutfitMap.Hair or 0, 7, false)
        EquipAvatar(i, _G.OutfitMap.Bag, _G.CustSlotType.BackpackEquipemtSlot, true, BackpackUtils.GetEquipmentBagLevel)
        EquipAvatar(i, _G.OutfitMap.Helmet, _G.CustSlotType.HelmetEquipemtSlot, true, BackpackUtils.GetEquipmentHelmetLevel)
        EquipAvatar(i, _G.OutfitMap.Parachute or 0, _G.CustSlotType.ParachuteEquipemtSlot, false)
    end
end
_G.ApplyWeaponSkins = function(PlayerCharacter)
    pcall(function()
        local WeaponManager = PlayerCharacter:GetWeaponManager()
        if not slua.isValid(WeaponManager) then return end
        for slot = 1, 3 do
            local Weapon = WeaponManager:GetInventoryWeaponByPropSlot(slot)
            if slua.isValid(Weapon) and slua.isValid(Weapon.synData) then
                local WeaponID = Weapon:GetWeaponID()
                local SkinID = _G.get_skin_id(WeaponID) or WeaponID
                local isModified = false
                local SkinData = Weapon.synData:Get(7) 
                if SkinData and SkinData.defineID and SkinData.defineID.TypeSpecificID ~= SkinID then
                    SkinData.defineID.TypeSpecificID = SkinID
                    Weapon.synData:Set(7, SkinData)
                    if Weapon.SetWeaponAvatarID then pcall(function() Weapon:SetWeaponAvatarID(SkinID) end) end
                    if not _G.skinIdCache[SkinID] then 
                        _G.download_item(SkinID)
                        _G.skinIdCache[SkinID] = true 
                    end
                    isModified = true
                end
                if SkinID >= 10000000 and _G.VIP_Attachments and _G.VIP_Attachments[SkinID] then
                    for AttachIdx = 0, 5 do 
                        local attachData = Weapon.synData:Get(AttachIdx)
                        if attachData then
                            local defineIDRef = slua.IndexReference(attachData, "defineID")
                            if defineIDRef then
                                local attachmentId = defineIDRef.TypeSpecificID
                                if attachmentId and attachmentId > 0 then
                                    local mapIndex = _G.BaseAttachToIndex[attachmentId] or _G.VipAttachToIndex[attachmentId]
                                    if mapIndex and _G.VIP_Attachments[SkinID][mapIndex] and _G.VIP_Attachments[SkinID][mapIndex] > 0 then
                                        local targetAttachId = _G.VIP_Attachments[SkinID][mapIndex]
                                        if targetAttachId ~= attachmentId then
                                            attachData.defineID.TypeSpecificID = targetAttachId
                                            Weapon.synData:Set(AttachIdx, attachData)
                                            if not _G.skinIdCache2[targetAttachId] then 
                                                if _G.download_item then pcall(_G.download_item, targetAttachId) end
                                                _G.skinIdCache2[targetAttachId] = true 
                                            end
                                            isModified = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                if isModified then
                    if Weapon.DelayHandleAvatarMeshChanged then pcall(function() Weapon:DelayHandleAvatarMeshChanged() end) end
                    if Weapon.OnRep_synData then pcall(function() Weapon:OnRep_synData() end) end
                end
            end
        end
    end)
end
_G.ApplyVehicleSkins = function(PlayerCharacter)
    pcall(function()
        local Vehicle = PlayerCharacter:GetCurrentVehicle()
        if not slua.isValid(Vehicle) then 
            _G.LastVehicleEntity = nil
            return 
        end
        if _G.LastVehicleEntity == Vehicle and _G.CurrentEquipVehicleID ~= nil then
            return
        end
        local VehicleAvatar = Vehicle.VehicleAvatar or Vehicle.VehicleAvatarComponent_BP or Vehicle:GetAvatarComponent()
        if not slua.isValid(VehicleAvatar) then return end
        local defId = tostring(VehicleAvatar:GetDefaultAvatarID() or Vehicle.VehicleID or "")
        local currentId = tostring(Vehicle:GetAvatarId() or "")
        local applySkinId = 0
        for baseMapId, targetSkin in pairs(_G.VehicleSkinMap) do
            if defId:find(tostring(baseMapId)) or currentId:find(tostring(baseMapId)) then 
                applySkinId = targetSkin
                break 
            end
        end
        if applySkinId and applySkinId > 0 then
            _G.skinIdCache = _G.skinIdCache or {}
            if not _G.skinIdCache[applySkinId] then 
                if _G.download_item then pcall(_G.download_item, applySkinId) end
                _G.skinIdCache[applySkinId] = true 
            end
            VehicleAvatar.curSwitchEffectId = 7303001
            if VehicleAvatar.ChangeItemAvatar then VehicleAvatar:ChangeItemAvatar(applySkinId, true) end
            _G.CurrentEquipVehicleID = applySkinId
            _G.LastVehicleEntity = Vehicle
        end
    end)
end
_G.HandlePetLogic = function()
    pcall(function()
        local petSkin = _G.OutfitMap.Pet
        if not petSkin or petSkin == 0 or petSkin == 50000 or petSkin == _G.LastAppliedPet then return end
        _G.skinIdCache = _G.skinIdCache or {}
        if not _G.skinIdCache[petSkin] then 
            if _G.download_item then pcall(_G.download_item, petSkin) end
            _G.skinIdCache[petSkin] = true 
        end
        local ModuleManager = require("client.module_framework.ModuleManager")
        if ModuleManager then
            local logic_pet = ModuleManager.GetModule(ModuleManager.CommonModuleConfig.logic_pet)
            if logic_pet then
                if logic_pet.SetCurPetID then logic_pet:SetCurPetID(petSkin) end
                if logic_pet.EquipPet then logic_pet:EquipPet(petSkin) end
            end
        end
        _G.LastAppliedPet = petSkin
    end)
end
_G.ForceRefreshSkinMaps = function()
    pcall(function()
        if not _G.LexusState or not _G.LexusState.CustomTextData then return end
        local cData = _G.LexusState.CustomTextData
        if _G.OutfitSkins then
            if cData.SkinSuit and _G.OutfitSkins.Suit[cData.SkinSuit] then _G.OutfitMap.Suit = _G.OutfitSkins.Suit[cData.SkinSuit] end
            if cData.SkinBag and _G.OutfitSkins.Bag[cData.SkinBag] then _G.OutfitMap.Bag = _G.OutfitSkins.Bag[cData.SkinBag] end
            if cData.SkinHelmet and _G.OutfitSkins.Helmet[cData.SkinHelmet] then _G.OutfitMap.Helmet = _G.OutfitSkins.Helmet[cData.SkinHelmet] end
        end
        if _G.skinIdMappings then
            if cData.SkinM416 and _G.skinIdMappings[101004] and _G.skinIdMappings[101004][cData.SkinM416] then _G.WeaponSkinMap[101004] = _G.skinIdMappings[101004][cData.SkinM416] end
            if cData.SkinAKM and _G.skinIdMappings[101001] and _G.skinIdMappings[101001][cData.SkinAKM] then _G.WeaponSkinMap[101001] = _G.skinIdMappings[101001][cData.SkinAKM] end
            if cData.SkinSCAR and _G.skinIdMappings[101003] and _G.skinIdMappings[101003][cData.SkinSCAR] then _G.WeaponSkinMap[101003] = _G.skinIdMappings[101003][cData.SkinSCAR] end
            if cData.SkinM762 and _G.skinIdMappings[101008] and _G.skinIdMappings[101008][cData.SkinM762] then _G.WeaponSkinMap[101008] = _G.skinIdMappings[101008][cData.SkinM762] end
            if cData.SkinAUG and _G.skinIdMappings[101006] and _G.skinIdMappings[101006][cData.SkinAUG] then _G.WeaponSkinMap[101006] = _G.skinIdMappings[101006][cData.SkinAUG] end
            if cData.SkinUMP and _G.skinIdMappings[102002] and _G.skinIdMappings[102002][cData.SkinUMP] then _G.WeaponSkinMap[102002] = _G.skinIdMappings[102002][cData.SkinUMP] end
            if cData.SkinUZI and _G.skinIdMappings[102001] and _G.skinIdMappings[102001][cData.SkinUZI] then _G.WeaponSkinMap[102001] = _G.skinIdMappings[102001][cData.SkinUZI] end
            if cData.SkinGroza and _G.skinIdMappings[101005] and _G.skinIdMappings[101005][cData.SkinGroza] then _G.WeaponSkinMap[101005] = _G.skinIdMappings[101005][cData.SkinGroza] end
            if cData.SkinS12K and _G.skinIdMappings[104003] and _G.skinIdMappings[104003][cData.SkinS12K] then _G.WeaponSkinMap[104003] = _G.skinIdMappings[104003][cData.SkinS12K] end
            if cData.SkinDBS and _G.skinIdMappings[104004] and _G.skinIdMappings[104004][cData.SkinDBS] then _G.WeaponSkinMap[104004] = _G.skinIdMappings[104004][cData.SkinDBS] end
            if cData.SkinASM and _G.skinIdMappings[101101] and _G.skinIdMappings[101101][cData.SkinASM] then _G.WeaponSkinMap[101101] = _G.skinIdMappings[101101][cData.SkinASM] end
            if cData.SkinQBZ and _G.skinIdMappings[101007] and _G.skinIdMappings[101007][cData.SkinQBZ] then _G.WeaponSkinMap[101007] = _G.skinIdMappings[101007][cData.SkinQBZ] end
            if cData.SkinHoney and _G.skinIdMappings[101012] and _G.skinIdMappings[101012][cData.SkinHoney] then _G.WeaponSkinMap[101012] = _G.skinIdMappings[101012][cData.SkinHoney] end
            if cData.SkinM16A4 and _G.skinIdMappings[101002] and _G.skinIdMappings[101002][cData.SkinM16A4] then _G.WeaponSkinMap[101002] = _G.skinIdMappings[101002][cData.SkinM16A4] end
            if cData.SkinACE32 and _G.skinIdMappings[101102] and _G.skinIdMappings[101102][cData.SkinACE32] then _G.WeaponSkinMap[101102] = _G.skinIdMappings[101102][cData.SkinACE32] end
            if cData.SkinKar98k and _G.skinIdMappings[103001] and _G.skinIdMappings[103001][cData.SkinKar98k] then _G.WeaponSkinMap[103001] = _G.skinIdMappings[103001][cData.SkinKar98k] end
            if cData.SkinM24 and _G.skinIdMappings[103002] and _G.skinIdMappings[103002][cData.SkinM24] then _G.WeaponSkinMap[103002] = _G.skinIdMappings[103002][cData.SkinM24] end
            if cData.SkinAWM and _G.skinIdMappings[103003] and _G.skinIdMappings[103003][cData.SkinAWM] then _G.WeaponSkinMap[103003] = _G.skinIdMappings[103003][cData.SkinAWM] end
        end
        if _G.VehicleSkins then
            if cData.SkinDacia and _G.VehicleSkins[1903001] and _G.VehicleSkins[1903001][cData.SkinDacia] then _G.VehicleSkinMap[1903001] = _G.VehicleSkins[1903001][cData.SkinDacia] end
            if cData.SkinUAZ and _G.VehicleSkins[1908001] and _G.VehicleSkins[1908001][cData.SkinUAZ] then _G.VehicleSkinMap[1908001] = _G.VehicleSkins[1908001][cData.SkinUAZ] end
            if cData.SkinCoupe and _G.VehicleSkins[1961001] and _G.VehicleSkins[1961001][cData.SkinCoupe] then _G.VehicleSkinMap[1961001] = _G.VehicleSkins[1961001][cData.SkinCoupe] end
            if cData.SkinBuggy and _G.VehicleSkins[1907002] and _G.VehicleSkins[1907002][cData.SkinBuggy] then _G.VehicleSkinMap[1907002] = _G.VehicleSkins[1907002][cData.SkinBuggy] end
            if cData.SkinMirado and _G.VehicleSkins[1915004] and _G.VehicleSkins[1915004][cData.SkinMirado] then _G.VehicleSkinMap[1915004] = _G.VehicleSkins[1915004][cData.SkinMirado] end
        end
    end)
end
local cached_GameplayStatics = nil
-- [REMOVED] DeadBox/LootCrate Skin System completely removed to eliminate kill freeze & periodic stutters
_G.NeedCheckDeadBoxTimer = 0
_G.DeadBox_TemperRequest = nil
_G.TDFTDeKillCounts = _G.TDFTDeKillCounts or {}
local CACHED_LinearColor = import("LinearColor")
local CACHED_GoldColor = CACHED_LinearColor and CACHED_LinearColor(1.0, 0.8, 0.0, 1.0) or nil
local CACHED_UI_Manager = nil
_G.ForceEnableKillCounterUI = function()
    pcall(function()
        local KillCounterUISubsystem = package.loaded["GameLua.Mod.BaseMod.Client.KillCounter.KillCounterUISubsystem"] or require("GameLua.Mod.BaseMod.Client.KillCounter.KillCounterUISubsystem")
        if KillCounterUISubsystem and KillCounterUISubsystem.__inner_impl and not _G.KCUISystemHacked2 then
            local kcImpl = KillCounterUISubsystem.__inner_impl
            kcImpl.CheckSupportKCUI = function() return true end
            kcImpl.CheckNeedMainKillCounterUI = function(self, PlayerWeapon, PlayerID)
                if slua.isValid(PlayerWeapon) then
                    local WeaponID = PlayerWeapon:GetWeaponID()
                    self:UpdateMainKillCounterUI(true, WeaponID, _G.get_skin_id(WeaponID) or WeaponID)
                else self:UpdateMainKillCounterUI(false) end
            end
            local originalUpdateMainKillCounterUI = kcImpl.UpdateMainKillCounterUI
            kcImpl.UpdateMainKillCounterUI = function(self, bShow, WeaponID, AvatarID)
                if bShow then AvatarID = _G.get_skin_id(WeaponID) or AvatarID end
                if originalUpdateMainKillCounterUI then originalUpdateMainKillCounterUI(self, bShow, WeaponID, AvatarID) end
            end
            _G.KCUISystemHacked2 = true
        end
        local ModuleManager = require("client.module_framework.ModuleManager")
        if ModuleManager and not _G.KCLogicHacked2 then
            local LogicKillCounter = ModuleManager.GetModule(ModuleManager.CommonModuleConfig.LogicKillCounter)
            if LogicKillCounter then
                LogicKillCounter.CheckSupportKC = function() return true end
                LogicKillCounter.CheckSupportKillCounterAvatar = function() return true end
                LogicKillCounter.CheckHasWeaponKillCounter = function() return true end
                LogicKillCounter.GetBaseKillCounterIdByWeaponId = function() return 2100004 end
                LogicKillCounter.GetEquipedKillCounterId = function() return 2100004 end
                LogicKillCounter.GetMyEquipedKillCounterId = function() return 2100004 end
                LogicKillCounter.GetOneWeaponKillCountInBattle = function(self, uid, weaponId) return _G.TDFTDeKillCounts[weaponId] or 0 end
                LogicKillCounter.GetWeaponKillCountByUid = function(self, uid, weaponId) return _G.TDFTDeKillCounts[weaponId] or 0 end
                _G.KCLogicHacked2 = true
            end
        end
        local killInfoPath = "GameLua.Mod.BaseMod.Client.KillInfoTips.KillInfo"
        local KillInfo = package.loaded[killInfoPath] or require(killInfoPath)
        if KillInfo and KillInfo.__inner_impl and not _G.KillInfoCounterHacked then
            local originalFileItem = KillInfo.__inner_impl.FileItem
            KillInfo.__inner_impl.FileItem = function(self, DamageRecordData)
                pcall(function()
                    local gpd = package.loaded["GameLua.GameCore.Data.GameplayData"] or require("GameLua.GameCore.Data.GameplayData")
                    local LocalPlayer = gpd and gpd.GetPlayerCharacter and gpd.GetPlayerCharacter()
                    if slua.isValid(LocalPlayer) and DamageRecordData.Causer == LocalPlayer:GetPlayerNameSafety() then 
                        local currentWeapon = LocalPlayer:GetCurrentWeapon()
                        if slua.isValid(currentWeapon) then
                            local weaponID = currentWeapon:GetWeaponID()
                            local skinID = _G.get_skin_id(weaponID)
                            if skinID then DamageRecordData.CauserWeaponAvatarID = skinID end
                            if _G.OutfitMap.Suit and _G.OutfitMap.Suit ~= 0 then DamageRecordData.CauserClothAvatarID = _G.OutfitMap.Suit end
                            if CACHED_GoldColor then
                                DamageRecordData.IsUseColor, DamageRecordData.UseColor = true, CACHED_GoldColor
                            end
                            if DamageRecordData.ResultHealthStatus == 2 then
                                _G.TDFTDeKillCounts[weaponID] = (_G.TDFTDeKillCounts[weaponID] or 0) + 1
                                -- _G.NeedCheckDeadBoxTimer = 0 
                                if not CACHED_UI_Manager then CACHED_UI_Manager = require("client.slua_ui_framework.manager") end
                                local uiMainKillCounter = CACHED_UI_Manager.GetUI(CACHED_UI_Manager.UI_Config_InGame.MainKillCounter)
                                if uiMainKillCounter and uiMainKillCounter.UpdateWeaponID then
                                    local mainAvatarID = skinID or currentWeapon:GetWeaponMainAvatarID()
                                    uiMainKillCounter:UpdateWeaponID(weaponID, mainAvatarID)
                                    local kcModule = ModuleManager.GetModule(ModuleManager.CommonModuleConfig.LogicKillCounter)
                                    local kcItemID = kcModule:GetEquipedKillCounterId(0, mainAvatarID)
                                    uiMainKillCounter:SetKillCounterItemShowWithNum(kcItemID, _G.TDFTDeKillCounts[weaponID], mainAvatarID)
                                end
                            end
                        end
                    end
                end)
                if originalFileItem then return originalFileItem(self, DamageRecordData) end
            end
            _G.KillInfoCounterHacked = true
        end
        local SwitchWeaponSlotMode2 = package.loaded["GameLua.Mod.BaseMod.Client.MainControlUI.SwitchWeaponSlotMode2"] or require("GameLua.Mod.BaseMod.Client.MainControlUI.SwitchWeaponSlotMode2")
        if SwitchWeaponSlotMode2 and SwitchWeaponSlotMode2.__inner_impl and not _G.SlotBaseHacked then
            SwitchWeaponSlotMode2.__inner_impl.CheckShowKCIcon = function(self)
                if slua.isValid(self.KillCounterImg) then 
                    self.KillCounterImg:SetVisibility(import("ESlateVisibility").SelfHitTestInvisible) 
                end
            end
            _G.SlotBaseHacked = true
        end
    end)
end
function _G.InitializeSkinModSystem()
    pcall(function()
        local LobbyAvatar = package.loaded["client.logic.avatar.LobbyAvatar"] or require("client.logic.avatar.LobbyAvatar")
        if LobbyAvatar and not _G.LobbyAvatarHacked then
            local originalPutonEquipment = LobbyAvatar.PutonEquipment
            LobbyAvatar.PutonEquipment = function(self, itemID, tAvatarCustom, tExtraData)
                local attachIndex = _G.BaseAttachToIndex and _G.BaseAttachToIndex[itemID]
                if attachIndex then
                    local holdingWeaponSkinID = self.GetCurHoldingWeaponSkinID and self:GetCurHoldingWeaponSkinID()
                    if holdingWeaponSkinID and holdingWeaponSkinID >= 10000000 and _G.VIP_Attachments and _G.VIP_Attachments[holdingWeaponSkinID] then
                        local vipAttachID = _G.VIP_Attachments[holdingWeaponSkinID][attachIndex]
                        if vipAttachID and vipAttachID > 0 then
                            if self.HandleDownload then self:HandleDownload(vipAttachID, nil, nil, false) end
                            itemID = vipAttachID
                        end
                    end
                end
                if originalPutonEquipment then return originalPutonEquipment(self, itemID, tAvatarCustom, tExtraData) end
            end
            local originalCharEquipWeaponByResId = LobbyAvatar.CharEquipWeaponByResId
            LobbyAvatar.CharEquipWeaponByResId = function(self, resID, isUse, isAsync, SocketName)
                local retValue = originalCharEquipWeaponByResId and originalCharEquipWeaponByResId(self, resID, isUse, isAsync, SocketName) or nil
                if isUse and self.GetEquipments then
                    local equipments = self:GetEquipments()
                    for _, equip in ipairs(equipments) do
                        if _G.BaseAttachToIndex and _G.BaseAttachToIndex[equip.itemID] then
                            self:PutonEquipment(equip.itemID, equip.CustomInfo, {bIsUse = false})
                        end
                    end
                end
                return retValue
            end
            _G.LobbyAvatarHacked = true
        end
    end)
    pcall(function()
        local Common_Items_UIBP = package.loaded["client.slua.component.item.ItemChildren.Common_Items_UIBP"] or require("client.slua.component.item.ItemChildren.Common_Items_UIBP")
        if Common_Items_UIBP and not _G.IconBaloHacked then
        local originalInitView = Common_Items_UIBP.InitView
            Common_Items_UIBP.InitView = function(self, nItemId, nCount, nValidTime, tExtraData)
                tExtraData = tExtraData or {}
                local displayResId = nil
                if _G.get_skin_id then
                    local skinID = _G.get_skin_id(nItemId)
                    if skinID and skinID ~= nItemId then displayResId = skinID end
                end
                local attachIndex = _G.BaseAttachToIndex and _G.BaseAttachToIndex[nItemId]
                if not displayResId and attachIndex then
                    local GameplayData = require("GameLua.GameCore.Data.GameplayData")
                    local LocalPlayer = GameplayData and GameplayData.GetPlayerCharacter()
                    if slua.isValid(LocalPlayer) then
                        local currentWeapon = LocalPlayer:GetCurrentWeapon()
                        if slua.isValid(currentWeapon) then
                            local weaponID = currentWeapon:GetWeaponID()
                            local finalSkinID = _G.get_skin_id(weaponID) or weaponID
                            if finalSkinID >= 10000000 and _G.VIP_Attachments and _G.VIP_Attachments[finalSkinID] then
                                local vipAttachID = _G.VIP_Attachments[finalSkinID][attachIndex]
                                if vipAttachID and vipAttachID > 0 then displayResId = vipAttachID end
                            end
                        end
                    end
                end
                if displayResId then
                    tExtraData.displayResId = displayResId
                    if not _G.skinIdCache2[displayResId] then
                        if _G.download_item then pcall(_G.download_item, displayResId) end
                        _G.skinIdCache2[displayResId] = true
                    end
                end
                if originalInitView then return originalInitView(self, nItemId, nCount, nValidTime, tExtraData) end
            end
            _G.IconBaloHacked = true
        end
    end)
end


-- HỆ THỐNG LƯU VÀ TẢI SETTING MENU VIP (TỰ ĐỘNG) – Optimized with dirty flag
local function GetConfigPaths(fileName)
    local paths = {
        "//storage/emulated/0/Android/data/com.tencent.ig/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.vng.pubgmobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.pubg.krmobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.rekoo.pubgm/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.pubg.imobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "/Documents/ShadowTrackerExtra/Saved/Paks/puffer_temp/" .. fileName,
        "/com.tencent.ig/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "/com.vng.pubgmobile/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "/com.pubg.krmobile/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "/com.rekoo.pubgm/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "/com.pubg.imobile/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "../../ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "../../../ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "../../../../ShadowTrackerExtra/Saved/Paks/" .. fileName,
        fileName
    }
    pcall(function()
        if os and os.getenv then
            local homeDir = os.getenv("HOME")
            if homeDir and homeDir ~= "" then
                table.insert(paths, 1, homeDir .. "/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName)
                table.insert(paths, 2, homeDir .. "/Documents/ShadowTrackerExtra/Saved/Paks/puffer_temp/" .. fileName)
            end
        end
    end)
    return paths
end
local ConfigFileName = "securex_settings.txt"
_G.LastConfigSaveStr = ""
-- HÀM LƯU CONFIG (only if dirty)
_G.SaveModSettings = function()
    if not _G.LexusState.DirtyConfig then return end
    pcall(function()
        local data = "return {\nLexusConfig = {\n"
        for k, v in pairs(_G.LexusConfig or {}) do
            data = data .. "  [\"" .. tostring(k) .. "\"] = " .. tostring(v) .. ",\n"
        end
        data = data .. "},\nCustomTextData = {\n"
        if _G.LexusState and _G.LexusState.CustomTextData then
            for k, v in pairs(_G.LexusState.CustomTextData) do
                data = data .. "  [\"" .. tostring(k) .. "\"] = " .. tostring(v) .. ",\n"
            end
        end
        data = data .. "}\n}"
        if data == _G.LastConfigSaveStr then return end
        _G.LastConfigSaveStr = data
        local paths = GetConfigPaths(ConfigFileName)
        for _, path in ipairs(paths) do
            local file = io.open(path, "w")
            if file then
                file:write(data)
                file:close()
                break
            end
        end
        _G.LexusState.DirtyConfig = false
    end)
end
-- HÀM TẢI (ĐỌC) CONFIG
_G.LoadModSettings = function()
    pcall(function()
        local paths = GetConfigPaths(ConfigFileName)
        local content = nil
        for _, path in ipairs(paths) do
            local file = io.open(path, "r")
            if file then
                content = file:read("*a")
                file:close()
                break
            end
        end
        if not content then
            local oldPaths = GetConfigPaths("securex_settings.txt")
            for _, path in ipairs(oldPaths) do
                local file = io.open(path, "r")
                if file then
                    content = file:read("*a")
                    file:close()
                    break
                end
            end
        end
        if content then
            local func = load(content)
            if func then
                local savedData = func()
                if savedData and type(savedData) == "table" then
                    if savedData.LexusConfig then
                        for k, v in pairs(savedData.LexusConfig) do
                            _G.LexusConfig[k] = v
                        end
                    end
                    if savedData.CustomTextData then
                        _G.LexusState.CustomTextData = _G.LexusState.CustomTextData or {}
                        for k, v in pairs(savedData.CustomTextData) do
                            _G.LexusState.CustomTextData[k] = v
                        end
                    end
                end
            end
        end
        _G.LexusState.DirtyConfig = true
        _G.SaveModSettings()
    end)
end
-- VÒNG LẶP KIỂM TRA ĐỂ LƯU CHẠY NGẦM (every 3s)
local function AutoSaveLoop()
    pcall(function() if _G.SaveModSettings then _G.SaveModSettings() end end)
    pcall(function()
        local okTicker, ticker = pcall(require, "common.time_ticker") 
        if okTicker and ticker and ticker.AddTimerOnce then 
            ticker.AddTimerOnce(3.0, AutoSaveLoop) 
        end
    end)
end
-- READ
if not _G.ModConfigLoaded then
    _G.LoadModSettings()
    AutoSaveLoop()
    _G.ModConfigLoaded = true
end
-- READ
_G.ReadLiveConfig = function()
    if _G.LexusState.DirtyConfig and _G.SaveModSettings then _G.SaveModSettings() end
end


-- 165 FPS UNLOCK – ALWAYS ON, NO TOGGLE
do
    local math_floor = math.floor
    local math_max = math.max
    local math_min = math.min
    local pcall = pcall
    local require = require
    local tostring = tostring
    local print = print or function(...) end
    local slua = slua
    local isValid = (slua and slua.isValid) or function(obj) return obj ~= nil end
    if _G.__165FPS_UNLOCK_PATCHED then

    else
        local function safe_require(modname)
            local ok, mod = pcall(require, modname)
            if not ok then

                return nil
            end
            return mod
        end
        local graphics = safe_require("client.slua.logic.setting.logic_setting_graphics")
        local fpsComp = safe_require("client.slua.umg.NewSetting.GraphicsNew.Comps.GSC_FPS")
        local fpsFT = safe_require("client.slua.umg.NewSetting.GraphicsNew.Comps.GSC_FPSFT")
        local db = safe_require("client.slua.umg.NewSetting.GraphicsNew.GraphicSettingDB")
        local function get_game_instance()
            if not db then return nil end
            local gi = (db.GetGameInstance and db:GetGameInstance())
            return gi
        end
        if graphics and type(graphics.SetFPS) == "function" then
            if not graphics.__original_SetFPS then
                graphics.__original_SetFPS = graphics.SetFPS
            end
            local orig = graphics.__original_SetFPS
            graphics.SetFPS = function(self, level)
                local ok, err = pcall(orig, self, level)
                if not ok then

                end
                if level == 8 then
                    pcall(function()
                        if self.ExecuteCMD then
                            self:ExecuteCMD("t.MaxFPS", "165")
                            self:ExecuteCMD("r.FrameRateLimit", "165")
                        end
                    end)
                end
            end
        end
        if fpsComp and fpsComp.__inner_impl then
            local impl = fpsComp.__inner_impl
            if not impl.__165patched then
                impl.GetMaxFPSLevel = function() return 8, 8 end
                impl.InitRealSupportFPS = function(self)
                    local tbl = {}
                    for i = 1, 8 do
                        tbl[i] = {true, true}
                    end
                    if db and db.RealSupportFPS then
                        pcall(function() db:UpdateUIData(db.RealSupportFPS, tbl, false) end)
                    end
                    return tbl
                end
                impl.UpdateSelectedFPSState = function(self, level)
                    local fpsMap = {
                        [2] = 20, [3] = 25, [4] = 30,
                        [5] = 40, [6] = 60, [7] = 90, [8] = 120
                    }
                    local UIRoot = self.UIRoot
                    if not UIRoot then return end
                    for i = 2, 8 do
                        local nodeName = "NodeFps" .. tostring(fpsMap[i] or 120)
                        local node = UIRoot[nodeName]
                        if isValid(node) then
                            node:SetIsEnabled(true)
                            pcall(function() node:SetRenderOpacity(1.0) end)
                            local switcherName = "WidgetSwitcher_" .. i
                            local switcher = UIRoot[switcherName]
                            if isValid(switcher) then
                                switcher:SetActiveWidgetIndex(i == level and 0 or 1)
                            end
                        end
                    end
                end
                impl.__165patched = true
            end
        end
        if fpsFT and fpsFT.__inner_impl and db then
            local impl = fpsFT.__inner_impl
            if not impl.__165patched then
                local MIN_FPS, MAX_FPS, STEP = 90, 165, 5
                local function clamp(v)
                    return math_max(MIN_FPS, math_min(MAX_FPS, v))
                end
                impl.ShowOrHide = function(self)
                    pcall(function() self:SelfHitTestInvisible() end)
                    if self.InitFPSFTSwitch then
                        pcall(self.InitFPSFTSwitch, self)
                    end
                end
                impl.InitFPSFTSwitch = function(self)
                    if not db then return end
                    local on = db:GetUIData(db.FPSFineTuneSwitch)
                    local UIRoot = self.UIRoot
                    if not UIRoot then return end
                    if UIRoot.Setting_Switch then
                        pcall(function() UIRoot.Setting_Switch:SetSwitcherEnable2(on, true) end)
                    end
                    if UIRoot.CanvasPanel_8 then
                        pcall(function() self:SetWidgetVisible(UIRoot.CanvasPanel_8, on) end)
                    end
                    if UIRoot.WidgetSwitcher_0 then
                        pcall(function() UIRoot.WidgetSwitcher_0:SetActiveWidgetIndex(2) end)
                    end
                    if self.InitFPSFTValue165 then
                        pcall(self.InitFPSFTValue165, self)
                    end
                end
                impl.InitFPSFTValue165 = function(self)
                    if not db then return end
                    local UIRoot = self.UIRoot
                    if not UIRoot then return end
                    local on = db:GetUIData(db.FPSFineTuneSwitch)
                    local val = on and (db:GetUIData(db.FPSFineTuneNum) or 165) or 165
                    local slider = UIRoot.Slider_screen3
                    local progress = UIRoot.ProgressBar_screen3
                    local textLabel = UIRoot.Veihclescreen3
                    if not (slider and progress and textLabel) then return end
                    if on then
                        pcall(function() slider:SetLocked(false) end)
                        pcall(function() progress:SetFillColorAndOpacity(FLinearColor(1,1,1,1)) end)
                        pcall(function() slider:SetSliderHandleColor(FLinearColor(1,1,1,1)) end)
                    else
                        pcall(function() slider:SetLocked(true) end)
                        pcall(function() progress:SetFillColorAndOpacity(FLinearColor(1,0.625,0.6,1)) end)
                        pcall(function() slider:SetSliderHandleColor(FLinearColor(1,0.625,0.6,1)) end)
                    end
                    local norm = (val - MIN_FPS) / (MAX_FPS - MIN_FPS)
                    pcall(function() textLabel:SetText(tostring(val)) end)
                    pcall(function() slider:SetValue(norm) end)
                    pcall(function() progress:SetPercent(norm) end)
                end
                impl.OnFPSFTValueChange3 = function(self, val)
                    if not db then return end
                    pcall(function()
                        db:UpdateUIData(db.FPSFineTuneNum, val)
                        if self.InitFPSFTValue165 then
                            pcall(self.InitFPSFTValue165, self)
                        end
                        local parent = self.GetParentUI and self:GetParentUI()
                        if parent and parent.SetDirty then
                            pcall(function() parent:SetDirty(true) end)
                        end
                        local gi = get_game_instance()
                        if gi then
                            gi:ExecuteCMD("t.MaxFPS", tostring(val))
                            gi:ExecuteCMD("r.FrameRateLimit", tostring(val))
                        end
                    end)
                end
                impl.OnFPSFTSliderValueChange3 = function(self, nv)
                    if not db then return end
                    if not db:GetUIData(db.FPSFineTuneSwitch) then return end
                    local raw = math_floor(MIN_FPS + (MAX_FPS - MIN_FPS) * nv)
                    raw = math_floor(raw / STEP) * STEP
                    self:OnFPSFTValueChange3(clamp(raw))
                end
                impl.OnFPSFTAdd3 = function(self)
                    local cur = (db and db:GetUIData(db.FPSFineTuneNum)) or MIN_FPS
                    self:OnFPSFTValueChange3(math_min(MAX_FPS, cur + STEP))
                end
                impl.OnFPSFTMinus3 = function(self)
                    local cur = (db and db:GetUIData(db.FPSFineTuneNum)) or MIN_FPS
                    self:OnFPSFTValueChange3(math_max(MIN_FPS, cur - STEP))
                end
                impl.OnFPSFTAdd = impl.OnFPSFTAdd3
                impl.OnFPSFTMinus = impl.OnFPSFTMinus3
                impl.OnFPSFTSliderValueChange = impl.OnFPSFTSliderValueChange3
                impl.__165patched = true
            end
        end
        local function apply_immediate()
            local gi = get_game_instance()
            if not gi then
                local ok, gp = pcall(require, "GameLua.GameCore.Data.GameplayData")
                if ok and gp and gp.GetGameInstance then
                    gi = gp.GetGameInstance()
                end
            end
            if gi then
                pcall(function()
                    gi:ExecuteCMD("t.MaxFPS", "165")
                    gi:ExecuteCMD("r.FrameRateLimit", "165")
                end)
                return true
            end
            return false
        end
        apply_immediate()
        _G.__165FPS_UNLOCK_PATCHED = true

    end
end

-- ENVIRONMENT (NO GRASS ONLY - ULTRA STABLE RENDERING)
local _ENV_LAST_GRASS_STATE = nil
local _ENV_ONCE_DONE = false

local function ApplyEnvironment(force)
    pcall(function()
        local ui_util = pcall(require, "client.common.ui_util") and require("client.common.ui_util")
        local gi = (slua_GameFrontendHUD and slua_GameFrontendHUD.GetGameInstance and slua_GameFrontendHUD:GetGameInstance())
            or (ui_util and ui_util.GetGameInstance and ui_util.GetGameInstance())
            or (_G.GameInstance)
            or (GameplayStatics and GameplayStatics.GetGameInstance and _slua and _slua.getWorld and GameplayStatics.GetGameInstance(_slua.getWorld()))
        local KSL = UKismetSystemLibrary or import("KismetSystemLibrary")
        local world = _slua and _slua.getWorld and _slua.getWorld()

        if gi and gi.ExecuteCMD and not _ENV_ONCE_DONE then
            gi:ExecuteCMD("r.Touch.EnableVibration", "0")
            gi:ExecuteCMD("r.GTSyncType", "2")
            gi:ExecuteCMD("r.OneFrameThreadLag", "0")
            local targetFpsStr = tostring((_G.LexusConfig and _G.LexusConfig.TargetFPS) or 165)
            gi:ExecuteCMD("t.MaxFPS", targetFpsStr)
            gi:ExecuteCMD("r.FrameRateLimit", targetFpsStr)
            gi:ExecuteCMD("r.VSync", "0")
            gi:ExecuteCMD("r.Streaming.PoolSize", "0")
            gi:ExecuteCMD("grass.DiscardDataOnLoad", "0")
            gi:ExecuteCMD("r.EnableWeaponCompTickOptimise", "1")
            gi:ExecuteCMD("r.EnableWeaponGameStallIssueFix", "1")
            gi:ExecuteCMD("slate.SuperFrameMiniMapUpdateRate", "3")
            _ENV_ONCE_DONE = true
        end

        local cleanup = (_G.LexusConfig and _G.LexusConfig.VisualCleanupEnabled == true)
        if force or _ENV_LAST_GRASS_STATE ~= cleanup then
            _ENV_LAST_GRASS_STATE = cleanup
            if gi and gi.ExecuteCMD then
                gi:ExecuteCMD("grass.DiscardDataOnLoad", "0")
                if cleanup then
                    gi:ExecuteCMD("grass.DensityScale", "0")
                    gi:ExecuteCMD("foliage.DensityScale", "0")
                    gi:ExecuteCMD("r.Fog", "0")
                    gi:ExecuteCMD("grass.flush", "1")
                else
                    gi:ExecuteCMD("grass.DensityScale", "1")
                    gi:ExecuteCMD("foliage.DensityScale", "1")
                    gi:ExecuteCMD("r.Fog", "1")
                    gi:ExecuteCMD("grass.flush", "1")
                end
            end
            if KSL and world then
                KSL.ExecuteConsoleCommand(world, "grass.DiscardDataOnLoad 0")
                if cleanup then
                    KSL.ExecuteConsoleCommand(world, "grass.DensityScale 0")
                    KSL.ExecuteConsoleCommand(world, "foliage.DensityScale 0")
                    KSL.ExecuteConsoleCommand(world, "r.Fog 0")
                    KSL.ExecuteConsoleCommand(world, "grass.flush 1")
                else
                    KSL.ExecuteConsoleCommand(world, "grass.DensityScale 1")
                    KSL.ExecuteConsoleCommand(world, "foliage.DensityScale 1")
                    KSL.ExecuteConsoleCommand(world, "r.Fog 1")
                    KSL.ExecuteConsoleCommand(world, "grass.flush 1")
                end
            end
        end
    end)
end
_G.ApplyEnvironment = ApplyEnvironment
-- AIM ASSIST, NO RECOIL, IPAD VIEW (ALL MAPS + TDM SUPPORT WITH SMOOTH STABLE CAMERA)
local aimOriginalCache = {}
-- Fixed base values (stock BGMI defaults — used only for cache if entity has no values)
local AIM_BASE_VALUES = { Speed = 8.1, RangeRate = 1.8, SpeedRate = 2.5, RangeRateSight = 5.5, SpeedRateSight = 1.4, CrouchRate = 1.2, ProneRate = 1.1, DyingRate = 0 }
-- Per-field multipliers: SMOOTH + STRONG feel
-- Speed 2.2x = smooth natural tracking (not jerky, not twitchy)
-- RangeRateSight 6.0x = scope pulls enemy from FAR distance (4x/6x/8x)
-- SpeedRateSight 2.0x = scope tracking is smooth, not snappy (long range needs precision)
local AIM_FIELD_MULT = {
    Speed           = 2.20,  -- smooth strong tracking (not jerky)
    SpeedRate       = 1.80,  -- hip-fire tracking
    SpeedRateSight  = 2.00,  -- SCOPE: smooth precision tracking (not twitchy)
    RangeRate       = 2.00,  -- hip/red-dot detection zone
    RangeRateSight  = 6.00,  -- SCOPE: pulls enemy from FAR distance
    CrouchRate      = 1.30,  -- crouching enemy
    ProneRate       = 1.10,  -- prone enemy
    DyingRate       = 0,     -- default: knocked ignored (overridden by IgnoreKnocked toggle)
}
-- 180m hard cap: clamp range-class fields after multiplying
local AIM_RANGE_MAX = {
    RangeRate      = 8.0,    -- ~180m effective hip/red-dot
    RangeRateSight = 30.0,   -- ~180m effective scoped (high cap for wide scope pull)
}

local function ApplyAimAssist(force)
    pcall(function()
        local pc = GetActivePlayerController()
        local char = GetLocalPlayer(pc)
        if not Valid(char) then return end
        local wm = char.WeaponManagerComponent or (char.GetWeaponManager and char:GetWeaponManager())
        if not Valid(wm) then return end

        -- Collect all target weapons (current held weapon + inventory/loadout weapons for TDM & Classic)
        local targetWeapons = {}
        local curW = (wm.GetCurrentUsingWeapon and wm:GetCurrentUsingWeapon()) 
            or wm.CurrentWeaponReplicated 
            or (char.GetCurrentWeapon and char:GetCurrentWeapon())
        if Valid(curW) then targetWeapons[curW] = true end

        pcall(function()
            if wm.GetAllInventoryWeaponList then
                local list = wm:GetAllInventoryWeaponList(false)
                if list then
                    for _, w in pairs(list) do
                        if Valid(w) then targetWeapons[w] = true end
                    end
                end
            end
            for slot = 1, 3 do
                if wm.GetInventoryWeaponByPropSlot then
                    local w = wm:GetInventoryWeaponByPropSlot(slot)
                    if Valid(w) then targetWeapons[w] = true end
                end
            end
        end)

        -- State key: reapply when toggle/weapon/knock-setting changes
        local igKnock = _G.LexusConfig.IgnoreKnocked
        local currentState = tostring(_G.LexusConfig.AimAssistEnabled) .. "_" .. tostring(igKnock) .. "_" .. tostring(curW)
        if not force and currentState == _G.LastAimState then return end
        _G.LastAimState = currentState

        if not _G.LexusConfig.AimAssistEnabled then
            -- RESTORE: put back original AutoAimingConfig values
            for ent, ranges in pairs(aimOriginalCache) do
                if Valid(ent) and ent.AutoAimingConfig then
                    for _, range in ipairs({"OuterRange", "InnerRange"}) do
                        local cfg = ent.AutoAimingConfig[range]
                        local saved = ranges[range]
                        if cfg and saved then
                            for k, v in pairs(saved) do cfg[k] = v end
                        end
                    end
                end
            end
            -- Reset aac to default state
            pcall(function()
                local aac = char.AutoAimComp or char.BP_AutoAimingComponent
                if Valid(aac) then
                    aac.AutoAimType = 1
                    aac.bModifyCrossHair = false
                    if char.AimNormalBoneArray and aac.Bones then
                        aac.Bones = char.AimNormalBoneArray
                    end
                end
                if Valid(pc) then pc.AutoAimType = 1 end
            end)
            return
        end

        -- ENABLED: Force native AutoAimComp on (works in TDM/Arena too)
        pcall(function()
            if Valid(pc) then
                pc.AutoAimType = 1
                pc.bAutoAimAt = true
                pc.bEnableAutoAim = true
            end
            local aac = char.AutoAimComp or char.BP_AutoAimingComponent
            if Valid(aac) then
                aac.AutoAimType = 1
                aac.bEnableAutoAim = true
                aac.bAutoAim = true
                aac.bModifyCrossHair = true
                if aac.SetIsStartScopeAutoAimCheck then
                    aac:SetIsStartScopeAutoAimCheck(true)
                end
                -- BODY BONE: chest/spine target for normal headshot% stats
                -- Fallback to head bone if AimNormalBoneArray unavailable on this character
                if char.AimNormalBoneArray and aac.Bones then
                    aac.Bones = char.AimNormalBoneArray
                elseif char.AimHeadBoneArray and aac.Bones then
                    aac.Bones = char.AimHeadBoneArray
                end
            end
            char.bEnableAutoAim = true
            char.bAutoAim = true
        end)

        -- Enable in game settings (scope + hip aim both)
        pcall(function()
            local mm = ModuleManager or (pcall(require, "client.module_framework.ModuleManager") and require("client.module_framework.ModuleManager"))
            if mm and mm.GetModule then
                local sm = mm.GetModule(mm.CommonModuleConfig and mm.CommonModuleConfig.SettingModule or "SettingModule")
                if sm and sm.SetOptionValue then
                    sm:SetOptionValue("AimAssist", 1)
                    sm:SetOptionValue("bAimAssist", true)
                end
            end
        end)

        -- Determine DyingRate based on Ignore Knocked toggle
        local dyingRateValue = (igKnock ~= false) and 0 or nil  -- nil = use original

        -- Apply per-field multipliers with small humanizer variation
        local variation = 0.99 + math.random() * 0.02

        for w, _ in pairs(targetWeapons) do
            local entity = w.ShootWeaponEntityComp or w.ShootWeaponComponent or (w.GetShootWeaponComponent and w:GetShootWeaponComponent())
            if Valid(entity) and entity.AutoAimingConfig then
                if not aimOriginalCache[entity] then
                    local saved = {}
                    for _, range in ipairs({"OuterRange", "InnerRange"}) do
                        local cfg = entity.AutoAimingConfig[range]
                        if cfg then
                            saved[range] = {}
                            for k, defaultVal in pairs(AIM_BASE_VALUES) do
                                saved[range][k] = (cfg[k] ~= nil) and cfg[k] or defaultVal
                            end
                        end
                    end
                    aimOriginalCache[entity] = saved
                end

                local orig = aimOriginalCache[entity]
                if orig then
                    for _, range in ipairs({"OuterRange", "InnerRange"}) do
                        local cfg = entity.AutoAimingConfig[range]
                        local saved = orig[range]
                        if cfg and saved then
                            for k, origVal in pairs(saved) do
                                if k == "DyingRate" then
                                    -- Ignore Knocked: 0 = skip knocked targets, original = aim them
                                    cfg[k] = (dyingRateValue ~= nil) and dyingRateValue or origVal
                                else
                                    local fieldMult = AIM_FIELD_MULT[k]
                                    if fieldMult then
                                        local newVal = origVal * fieldMult * variation
                                        -- 180m DISTANCE CAP: clamp range-class fields
                                        local cap = AIM_RANGE_MAX[k]
                                        if cap and newVal > cap then newVal = cap end
                                        cfg[k] = newVal
                                    else
                                        cfg[k] = origVal  -- unknown field: keep stock
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
end
_G.ApplyAimAssist = ApplyAimAssist

local recoilOriginalCache = {}
local RECOIL_FIELDS = {
    "RecoilKick", "RecoilKickADS", "AnimationKick",
    "GameDeviationFactor", "RecoilModifierStand", "RecoilModifierCrouch", "RecoilModifierProne",
    "CameraShakeScale", "AimCameraShakeScale", "ShootCameraShakeScale", "FireCameraShakeScale",
    "GameDeviationAccuracy", "ShotGunHorizontalSpread", "ShotGunVerticalSpread", "DeviationMultiplier"
}
-- RECOIL_KEEP: 40% residual = 60% reduction. orig * RECOIL_KEEP applied per field.
-- Spread-class fields (GameDeviation, ShotGun) get 55% residual = 45% cut (more legit spray).
-- No RECOIL_TARGET_VALUES table needed: formula is always orig * constant.
local RECOIL_KEEP      = 0.40  -- main recoil fields (kick, camera shake)
local RECOIL_KEEP_SPR  = 0.55  -- spread/deviation fields (more legit)
-- Spread-class field set for special handling
local RECOIL_SPREAD_FIELDS = {
    GameDeviationFactor   = true,
    GameDeviationAccuracy = true,
    ShotGunHorizontalSpread = true,
    ShotGunVerticalSpread = true,
    DeviationMultiplier   = true,
}
local RECOIL_INFO_FIELDS = { "VerticalRecoilMin", "VerticalRecoilMax", "RecoilSpeedVertical", "RecoilSpeedHorizontal", "VerticalRecoveryMax" }

local function ApplyNoRecoil(force)
    pcall(function()
        local pc = GetActivePlayerController()
        local char = GetLocalPlayer(pc)
        if not Valid(char) then return end
        local wm = char.WeaponManagerComponent or (char.GetWeaponManager and char:GetWeaponManager())
        if not Valid(wm) then return end

        local targetWeapons = {}
        local curW = (wm.GetCurrentUsingWeapon and wm:GetCurrentUsingWeapon())
            or wm.CurrentWeaponReplicated
            or (char.GetCurrentWeapon and char:GetCurrentWeapon())
        if Valid(curW) then targetWeapons[curW] = true end

        pcall(function()
            if wm.GetAllInventoryWeaponList then
                local list = wm:GetAllInventoryWeaponList(false)
                if list then
                    for _, w in pairs(list) do
                        if Valid(w) then targetWeapons[w] = true end
                    end
                end
            end
            for slot = 1, 3 do
                if wm.GetInventoryWeaponByPropSlot then
                    local w = wm:GetInventoryWeaponByPropSlot(slot)
                    if Valid(w) then targetWeapons[w] = true end
                end
            end
        end)

        -- State key includes toggle + weapon
        local currentState = tostring(_G.LexusConfig.NoRecoilEnabled) .. "_" .. tostring(curW)
        if not force and currentState == _G.LastRecoilState then return end
        _G.LastRecoilState = currentState

        if not _G.LexusConfig.NoRecoilEnabled then
            -- RESTORE: put back original recoil values
            for ent, saved in pairs(recoilOriginalCache) do
                if Valid(ent) then
                    for k, v in pairs(saved) do
                        if k == "RecoilInfo" then
                            if ent.RecoilInfo then
                                for rk, rv in pairs(v) do ent.RecoilInfo[rk] = rv end
                            end
                        elseif k == "ShootCameraShakeScale" then
                            if ent.ShootCameraShake then ent.ShootCameraShake.Scale = v end
                        else
                            ent[k] = v
                        end
                    end
                end
            end
            return
        end

        -- ENABLED: Apply 60% recoil reduction (40% residual stays)
        for w, _ in pairs(targetWeapons) do
            local entity = w.ShootWeaponEntityComp or w.ShootWeaponComponent or (w.GetShootWeaponComponent and w:GetShootWeaponComponent())
            if Valid(entity) then
                if not recoilOriginalCache[entity] then
                    local saved = { RecoilInfo = {} }
                    for _, f in ipairs(RECOIL_FIELDS) do
                        if entity[f] ~= nil then saved[f] = entity[f] end
                    end
                    if entity.RecoilInfo then
                        for _, f in ipairs(RECOIL_INFO_FIELDS) do
                            if entity.RecoilInfo[f] ~= nil then saved.RecoilInfo[f] = entity.RecoilInfo[f] end
                        end
                    end
                    if entity.ShootCameraShake and entity.ShootCameraShake.Scale ~= nil then
                        saved.ShootCameraShakeScale = entity.ShootCameraShake.Scale
                    end
                    recoilOriginalCache[entity] = saved
                end

                local orig = recoilOriginalCache[entity]
                if orig then
                    -- Main recoil fields: orig * 0.40 (40% residual, 60% cut)
                    for _, f in ipairs(RECOIL_FIELDS) do
                        if entity[f] ~= nil and orig[f] ~= nil then
                            local keepRatio = RECOIL_SPREAD_FIELDS[f] and RECOIL_KEEP_SPR or RECOIL_KEEP
                            entity[f] = orig[f] * keepRatio
                        end
                    end
                    -- RecoilInfo fields: orig * 0.40
                    if entity.RecoilInfo and orig.RecoilInfo then
                        for _, f in ipairs(RECOIL_INFO_FIELDS) do
                            if entity.RecoilInfo[f] ~= nil and orig.RecoilInfo[f] ~= nil then
                                entity.RecoilInfo[f] = orig.RecoilInfo[f] * RECOIL_KEEP
                            end
                        end
                    end
                    -- CameraShake: orig * 0.40 (never zero — anti-flag)
                    if entity.ShootCameraShake and orig.ShootCameraShakeScale ~= nil then
                        entity.ShootCameraShake.Scale = orig.ShootCameraShakeScale * RECOIL_KEEP
                    end
                end
            end
        end
    end)
end

_G.ApplyNoRecoil = ApplyNoRecoil

local _iPadViewOrigFOV = nil
local function ApplyiPadView(force)
    pcall(function()
        local pc = GetActivePlayerController()
        local char = GetLocalPlayer(pc)
        if not Valid(char) then return end
        local cam = char.ThirdPersonCameraComponent 
            or (char.GetCameraComponent and char:GetCameraComponent())
            or char.FirstPersonCameraComponent
            or char.CameraComponent

        local SettingModule = nil
        pcall(function()
            local mm = ModuleManager or (pcall(require, "client.module_framework.ModuleManager") and require("client.module_framework.ModuleManager"))
            if mm and mm.GetModule then
                SettingModule = mm.GetModule(mm.CommonModuleConfig and mm.CommonModuleConfig.SettingModule or "SettingModule")
            end
        end)

        if not _G.LexusConfig.iPadViewEnabled then
            local defaultFov = (_iPadViewOrigFOV and _iPadViewOrigFOV <= 100) and _iPadViewOrigFOV or 90
            if SettingModule and SettingModule.SetOptionValue then
                pcall(SettingModule.SetOptionValue, SettingModule, "TpViewValue", defaultFov)
            end
            if char.SetTpCameraFov then pcall(char.SetTpCameraFov, char, defaultFov) end
            if char.SetFovInTPPSpringArm then pcall(char.SetFovInTPPSpringArm, char, defaultFov) end
            if pc and pc.NormalCameraModeData and pc.NormalCameraModeData.SwitchCameraData then
                pc.NormalCameraModeData.SwitchCameraData.CameraFOV = defaultFov
            end
            if Valid(cam) and cam.FieldOfView ~= defaultFov then cam.FieldOfView = defaultFov end
            return
        end

        if not _iPadViewOrigFOV then
            local currentFov = (Valid(cam) and cam.FieldOfView) or 90
            if currentFov <= 100 then _iPadViewOrigFOV = currentFov else _iPadViewOrigFOV = 90 end
        end

        local targetFov = _G.LexusConfig.iPadViewFOV or 110
        if SettingModule and SettingModule.SetOptionValue then
            pcall(SettingModule.SetOptionValue, SettingModule, "TpViewValue", targetFov)
        end
        if char.SetTpCameraFov then pcall(char.SetTpCameraFov, char, targetFov) end
        if char.SetFovInTPPSpringArm then pcall(char.SetFovInTPPSpringArm, char, targetFov) end
        if pc and pc.NormalCameraModeData and pc.NormalCameraModeData.SwitchCameraData then
            pc.NormalCameraModeData.SwitchCameraData.CameraFOV = targetFov
        end
        if Valid(cam) and cam.FieldOfView ~= targetFov then
            cam.FieldOfView = targetFov
        end
    end)
end
_G.ApplyiPadView = ApplyiPadView
-- ============================================================================
--  LAG-FREE ESP: NATIVE HEAD HP BAR (WALLHACK), BOX, MAP & VEHICLE
-- ============================================================================
_G.AK_Active_Marks_Cache = _G.AK_Active_Marks_Cache or {}
_G.AK_Active_HP_Marks = _G.AK_Active_HP_Marks or {}
_G.AK_Map_Marks = _G.AK_Map_Marks or {}

local GK_MAP_MARK_GROUP_ID = _G._GK_MAP_MARK_GID or (8000 + math.floor(math.random() * 1999))
_G._GK_MAP_MARK_GID = GK_MAP_MARK_GROUP_ID
local MAP_INIT_DONE = false

local function ApplyMarkConfigs(smc)
    if not smc or type(smc) ~= "table" then return end
    local FVec = FVector or (pcall(import, "Vector") and import("Vector")) or (pcall(import, "FVector") and import("FVector"))
    local vOffset1006 = (FVec and FVec(0, 0, 40)) or { X = 0, Y = 0, Z = 40 }
    local vOffsetMap = (FVec and FVec(0, 0, 90)) or { X = 0, Y = 0, Z = 90 }

    if smc[1006] then
        smc[1006].bBindBlocked = true
        smc[1006].bBindOutScreen = true
        smc[1006].MaxWidgetNum = 99
        smc[1006].MaxShowDistance = 40000
        smc[1006].bScaleByDistance = false
        smc[1006].BindSocketName = "head"
        smc[1006].bUseLuaWorldSocketName = true
        smc[1006].WorldPositionOffset = vOffset1006
    else
        smc[1006] = {
            UIPathName = "/Game/Mod/EvoBase/BluePrints/UI/ScreenMark/Item/HpBarUIBP.HpBarUIBP_C",
            MaxWidgetNum = 99,
            MaxShowDistance = 40000,
            bBindOutScreen = true,
            bBindBlocked = true,
            bIsBindingActor = true,
            bScaleByDistance = false,
            BindSocketName = "head",
            bUseLuaWorldSocketName = true,
            WorldPositionOffset = vOffset1006,
            bNeedPreLoad = true,
            Priority = 2
        }
    end

    local mapMarkConfig = {
        UIPathName = "/Game/Mod/EvoBase/BluePrints/UIBP/QuickSign/QuickSign_TipHitEnemy_UIBP_New.QuickSign_TipHitEnemy_UIBP_New_C",
        MaxWidgetNum = 99,
        MaxShowDistance = 40000,
        bBindOutScreen = true,
        bBindBlocked = true,
        bIsBindingActor = true,
        BindSocketName = "head",
        bUseLuaWorldSocketName = true,
        WorldPositionOffset = vOffsetMap,
        bNeedPreLoad = true,
        Priority = 2
    }

    smc[9999] = mapMarkConfig
    smc[8888] = mapMarkConfig
    if GK_MAP_MARK_GROUP_ID then smc[GK_MAP_MARK_GROUP_ID] = mapMarkConfig end
end

local function HookConfigProviders()
    pcall(function()
        if not GamePlayTools then
            local ok, gpt = pcall(require, "GameLua.Mod.BaseMod.Common.GamePlayTools")
            if ok and gpt then GamePlayTools = gpt end
        end
        if GamePlayTools and GamePlayTools.GetCurrentConfig and not GamePlayTools._gk_hooked then
            local orig = GamePlayTools.GetCurrentConfig
            GamePlayTools.GetCurrentConfig = function(Key)
                local res = orig(Key)
                if Key == "ScreenMarkConfig" and res and type(res) == "table" then
                    pcall(ApplyMarkConfigs, res)
                end
                return res
            end
            GamePlayTools._gk_hooked = true
        end
    end)
    pcall(function()
        local CGM = package.loaded["GameLua.GameCore.Main.ClientGameMain"]
        if not CGM then
            local ok, res = pcall(require, "GameLua.GameCore.Main.ClientGameMain")
            if ok and res then CGM = res end
        end
        if CGM and CGM.GetCurrentConfig and not CGM._gk_hooked then
            local orig = CGM.GetCurrentConfig
            CGM.GetCurrentConfig = function(Key)
                local res = orig(Key)
                if Key == "ScreenMarkConfig" and res and type(res) == "table" then
                    pcall(ApplyMarkConfigs, res)
                end
                return res
            end
            CGM._gk_hooked = true
        end
    end)
end

local function InitMapTracking()
    pcall(function()
        HookConfigProviders()

        if not InGameMarkTools then
            local ok, igmt = pcall(require, "GameLua.Mod.BaseMod.Common.InGameMarkTools")
            if ok and igmt then InGameMarkTools = igmt end
        end
        if not GamePlayTools then
            local ok, gpt = pcall(require, "GameLua.Mod.BaseMod.Common.GamePlayTools")
            if ok and gpt then GamePlayTools = gpt end
        end

        if GamePlayTools and GamePlayTools.GetCurrentConfig then 
            local smc = GamePlayTools.GetCurrentConfig("ScreenMarkConfig")
            if smc and type(smc) == "table" then
                ApplyMarkConfigs(smc)
            end 
        end

        pcall(function()
            local CGM = package.loaded["GameLua.GameCore.Main.ClientGameMain"]
            if CGM and CGM.CurrentConfig and CGM.CurrentConfig.ScreenMarkConfig then
                ApplyMarkConfigs(CGM.CurrentConfig.ScreenMarkConfig)
            end
        end)

        for mn2, md in pairs(package.loaded) do 
            if type(mn2) == "string" and string.find(mn2, "ScreenMarkConfig") and type(md) == "table" then 
                ApplyMarkConfigs(md)
            end 
        end

        pcall(function()
            if InGameMarkTools and InGameMarkTools.ScreenMarkManager and InGameMarkTools.ScreenMarkManager.OnInitMarkGroupData then
                pcall(InGameMarkTools.ScreenMarkManager.OnInitMarkGroupData, InGameMarkTools.ScreenMarkManager, 1006)
                pcall(InGameMarkTools.ScreenMarkManager.OnInitMarkGroupData, InGameMarkTools.ScreenMarkManager, 9999)
                if GK_MAP_MARK_GROUP_ID and GK_MAP_MARK_GROUP_ID ~= 9999 then
                    pcall(InGameMarkTools.ScreenMarkManager.OnInitMarkGroupData, InGameMarkTools.ScreenMarkManager, GK_MAP_MARK_GROUP_ID)
                end
            end
        end)

        MAP_INIT_DONE = true
        if _G.LexusState then _G.LexusState.NativeESPReady = true end
    end)
end
_G.InitMapTracking = InitMapTracking
_G.InitDistanceMarkerSystem = InitMapTracking
pcall(InitMapTracking)

local _1006_Marks = {}
local _HealthBarInitAttempts = 0

local function ClearAll1006Marks()
    pcall(function()
        if InGameMarkTools and InGameMarkTools.HideMapMark then
            for _, data in pairs(_1006_Marks) do
                local mId = (type(data) == "table" and data.markId) or data
                if mId then pcall(InGameMarkTools.HideMapMark, mId) end
            end
            local mgr = InGameMarkTools.GetMarkDispatchManager and InGameMarkTools.GetMarkDispatchManager()
            if mgr and mgr.ClearMarkDataByTypeID then
                local EMarkTypeIDClearType = import("EMarkTypeIDClearType")
                local clearType = (EMarkTypeIDClearType and EMarkTypeIDClearType.ETC_OWNER_ONLY) or 0
                pcall(mgr.ClearMarkDataByTypeID, mgr, 1006, clearType, nil)
            end
        end
    end)
    _1006_Marks = {}
    pcall(function()
        local _, _, hud = GetFrameCache()
        if Valid(hud) and hud.RemoveDebugText then
            local okPawns, allPawns = GetCachedPlayerPawns()
            if okPawns and allPawns then
                for _, p in ipairs(allPawns) do
                    if Valid(p) then pcall(hud.RemoveDebugText, hud, p, false) end
                end
            end
        end
    end)
end
_G.ClearAll1006Marks = ClearAll1006Marks

local function Tick_HealthBarESP()
    local isEnabled = _G.LexusConfig.ESP_All and _G.LexusConfig.HealthBarESPEnabled
    if not isEnabled then
        if next(_1006_Marks) ~= nil then ClearAll1006Marks() end
        _HealthBarInitAttempts = 0
        return
    end

    local localPawn, myPos, hud, pc, myTeamId, spectatedTarget = GetFrameCache()
    if not Valid(hud) then
        if slua_GameFrontendHUD and Valid(slua_GameFrontendHUD) then hud = slua_GameFrontendHUD
        elseif pc and Valid(pc) then pcall(function() hud = pc.MyHUD or (pc.GetHUD and pc:GetHUD()) end)
        elseif localPawn and Valid(localPawn) then pcall(function() hud = localPawn.MyHUD end)
        end
    end
    if not localPawn or not myPos then return end

    local okPawns, allPawns = GetCachedPlayerPawns()
    if not okPawns or not allPawns then return end

    if #allPawns > 1 and next(_1006_Marks) == nil and _HealthBarInitAttempts < 3 then
        _HealthBarInitAttempts = _HealthBarInitAttempts + 1
        MAP_INIT_DONE = false
        if InitMapTracking then pcall(InitMapTracking) end
    end

    local activeKeys = {}
    local FVec = FVector or (pcall(import, "Vector") and import("Vector")) or (pcall(import, "FVector") and import("FVector"))
    local zeroVec = (FVec and FVec(0, 0, 0)) or { X = 0, Y = 0, Z = 0 }

    for _, pawn in ipairs(allPawns) do
        if not Valid(pawn) or pawn == localPawn or (spectatedTarget and pawn == spectatedTarget) then goto continue_hp end

        local pKey = GetPawnKey(pawn)
        if not pKey then goto continue_hp end

        local pTeam = pawn.TeamID or (type(pawn.GetTeamID) == "function" and pawn:GetTeamID())
        if myTeamId and myTeamId > 0 and pTeam and pTeam > 0 and pTeam == myTeamId then goto continue_hp end

        if IsPawnDead(pawn) then goto continue_hp end

        local okPP, pPos = SafeMethodCall(pawn, "K2_GetActorLocation")
        if not (okPP and pPos) then goto continue_hp end

        local dx = pPos.X - myPos.X
        local dy = pPos.Y - myPos.Y
        local dz = pPos.Z - myPos.Z
        local distSq = dx * dx + dy * dy + dz * dz
        if distSq <= 0 or distSq > 1600000000 then goto continue_hp end

        activeKeys[pKey] = true

        -- Stable mark attachment keyed by immutable pKey (NEVER BLINKS)
        if not _1006_Marks[pKey] then
            if InGameMarkTools and InGameMarkTools.ClientAddMapMark then
                local okM, mId = pcall(InGameMarkTools.ClientAddMapMark, 1006, zeroVec, 0, "", 4, pawn)
                if okM and mId then
                    _1006_Marks[pKey] = { markId = mId, pawn = pawn }
                end
            end
        end

        if Valid(hud) and hud.RemoveDebugText then
            pcall(hud.RemoveDebugText, hud, pawn, false)
        end

        ::continue_hp::
    end

    -- Clean up dead / out-of-range pawns
    for pKey, data in pairs(_1006_Marks) do
        if not activeKeys[pKey] then
            if InGameMarkTools and InGameMarkTools.HideMapMark and data.markId then
                pcall(InGameMarkTools.HideMapMark, data.markId)
            end
            _1006_Marks[pKey] = nil
        end
    end
end
_G.Tick_HealthBarESP = Tick_HealthBarESP

-- BOX ESP (REPLAY FRAME - STABLE KEYED, ZERO BLINK)
local _BoxESPCache = {}

local function SetBoxFrameColor(pawn)
    if not Valid(pawn) then return end
    local col = (LinearColor and LinearColor(1, 0, 0, 1)) or { R = 1, G = 0, B = 0, A = 1 }
    pcall(function()
        if pawn.Replay_SetFrameUIColor then pawn:Replay_SetFrameUIColor(col)
        elseif pawn.SetEnemyFrameColor then pawn:SetEnemyFrameColor(col)
        elseif pawn.SetFrameColor then pawn:SetFrameColor(col)
        elseif pawn.SetOutlineColor then pawn:SetOutlineColor(col) end
    end)
end

local function ClearAllBoxESP()
    pcall(function()
        for _, p in pairs(_BoxESPCache) do
            if Valid(p) and p.Replay_SetVisiableOfFrameUI then
                pcall(p.Replay_SetVisiableOfFrameUI, p, false)
            end
        end
    end)
    _BoxESPCache = {}
end
_G.ClearAllBoxESP = ClearAllBoxESP

local function Tick_BoxESP()
    local isEnabled = _G.LexusConfig.ESP_All and _G.LexusConfig.BoxESPEnabled
    if not isEnabled then
        if next(_BoxESPCache) ~= nil then ClearAllBoxESP() end
        return
    end

    local localPawn, myPos, hud, pc, myTeamId, spectatedTarget = GetFrameCache()
    if not localPawn or not myPos then return end

    local okPawns, allPawns = GetCachedPlayerPawns()
    if not okPawns or not allPawns then return end

    local activeKeys = {}

    for _, pawn in ipairs(allPawns) do
        if not Valid(pawn) or pawn == localPawn or (spectatedTarget and pawn == spectatedTarget) then goto continue_box end

        local pKey = GetPawnKey(pawn)
        if not pKey then goto continue_box end

        local pTeam = pawn.TeamID or (type(pawn.GetTeamID) == "function" and pawn:GetTeamID())
        if myTeamId and myTeamId > 0 and pTeam and pTeam > 0 and pTeam == myTeamId then goto continue_box end

        if IsPawnDead(pawn) then goto continue_box end

        local okPP, pPos = SafeMethodCall(pawn, "K2_GetActorLocation")
        if not (okPP and pPos) then goto continue_box end

        local dx = pPos.X - myPos.X
        local dy = pPos.Y - myPos.Y
        local dz = pPos.Z - myPos.Z
        local distSq = dx * dx + dy * dy + dz * dz
        if distSq <= 0 or distSq > 1600000000 then goto continue_box end

        activeKeys[pKey] = true

        if not _BoxESPCache[pKey] then
            pcall(function()
                if pawn.Replay_IsEnemyFrameUIExisted and not pawn:Replay_IsEnemyFrameUIExisted() then
                    pawn:Replay_CreateEnemyFrameUI(true, true)
                end
                if pawn.Replay_SetVisiableOfFrameUI then
                    pawn:Replay_SetVisiableOfFrameUI(true)
                end
                SetBoxFrameColor(pawn)
            end)
            _BoxESPCache[pKey] = pawn
        end

        ::continue_box::
    end

    for pKey, pawn in pairs(_BoxESPCache) do
        if not activeKeys[pKey] then
            pcall(function()
                if Valid(pawn) and pawn.Replay_SetVisiableOfFrameUI and not IsPawnDead(pawn) then
                    pawn:Replay_SetVisiableOfFrameUI(false)
                end
            end)
            _BoxESPCache[pKey] = nil
        end
    end
end
_G.Tick_BoxESP = Tick_BoxESP

-- MAP ESP (DISTANCE & ENEMY TIP MARKER - STABLE KEYED, ZERO BLINK)
local _MapMarks = {}

local function ClearAllMapMarks()
    pcall(function()
        if InGameMarkTools and InGameMarkTools.HideMapMark then
            for _, data in pairs(_MapMarks) do
                local mId = (type(data) == "table" and data.markId) or data
                if mId then pcall(InGameMarkTools.HideMapMark, mId) end
            end
            local mgr = InGameMarkTools.GetMarkDispatchManager and InGameMarkTools.GetMarkDispatchManager()
            if mgr and mgr.ClearMarkDataByTypeID then
                local EMarkTypeIDClearType = import("EMarkTypeIDClearType")
                local clearType = (EMarkTypeIDClearType and EMarkTypeIDClearType.ETC_OWNER_ONLY) or 0
                pcall(mgr.ClearMarkDataByTypeID, mgr, 9999, clearType, nil)
                pcall(mgr.ClearMarkDataByTypeID, mgr, 8888, clearType, nil)
                if GK_MAP_MARK_GROUP_ID then
                    pcall(mgr.ClearMarkDataByTypeID, mgr, GK_MAP_MARK_GROUP_ID, clearType, nil)
                end
            end
        end
    end)
    _MapMarks = {}
end
_G.ClearAllMapMarks = ClearAllMapMarks

local function Tick_MapESP()
    local isEnabled = _G.LexusConfig.ESP_All and _G.LexusConfig.MapESPEnabled
    if not isEnabled then
        if next(_MapMarks) ~= nil then ClearAllMapMarks() end
        return
    end

    local localPawn, myPos, hud, pc, myTeamId, spectatedTarget = GetFrameCache()
    if not localPawn or not myPos then return end

    local okPawns, allPawns = GetCachedPlayerPawns()
    if not okPawns or not allPawns then return end

    local activeKeys = {}
    local FVec = FVector or (pcall(import, "Vector") and import("Vector")) or (pcall(import, "FVector") and import("FVector"))
    local zeroVec = (FVec and FVec(0, 0, 0)) or { X = 0, Y = 0, Z = 0 }

    for _, pawn in ipairs(allPawns) do
        if not Valid(pawn) or pawn == localPawn or (spectatedTarget and pawn == spectatedTarget) then goto continue_map end

        local pKey = GetPawnKey(pawn)
        if not pKey then goto continue_map end

        local pTeam = pawn.TeamID or (type(pawn.GetTeamID) == "function" and pawn:GetTeamID())
        if myTeamId and myTeamId > 0 and pTeam and pTeam > 0 and pTeam == myTeamId then goto continue_map end

        if IsPawnDead(pawn) then goto continue_map end

        local okPP, pPos = SafeMethodCall(pawn, "K2_GetActorLocation")
        if not (okPP and pPos) then goto continue_map end

        local dx = pPos.X - myPos.X
        local dy = pPos.Y - myPos.Y
        local dz = pPos.Z - myPos.Z
        local distSq = dx * dx + dy * dy + dz * dz
        if distSq <= 0 or distSq > 1600000000 then goto continue_map end

        activeKeys[pKey] = true

        if not _MapMarks[pKey] then
            if InGameMarkTools and InGameMarkTools.ClientAddMapMark then
                local okMark, mId = pcall(InGameMarkTools.ClientAddMapMark, GK_MAP_MARK_GROUP_ID, zeroVec, 0, "", 4, pawn)
                if okMark and mId then
                    _MapMarks[pKey] = { markId = mId, pawn = pawn }
                end
            end
        end
        ::continue_map::
    end

    for pKey, data in pairs(_MapMarks) do
        if not activeKeys[pKey] then
            if InGameMarkTools and InGameMarkTools.HideMapMark and data.markId then
                pcall(InGameMarkTools.HideMapMark, data.markId)
            end
            _MapMarks[pKey] = nil
        end
    end
end
_G.Tick_MapESP = Tick_MapESP

-- ============================================================================
-- LIVE ENEMY COUNTER (NATIVE UMG WIDGET - CACHED HUD DISPLAY)
-- ============================================================================
local COUNTER_WIDGET_BP = "/Game/UMG/UI_BP/Common/BaseComponent/CommonBaseComponent_TextButton_UIBP.CommonBaseComponent_TextButton_UIBP"
local _CounterWidget = nil
local _CounterText = nil
local _CounterLastString = nil
local _CounterLastAttempt = 0
local GOLD_COLOR = (LinearColor and LinearColor(1.0, 0.85, 0.0, 1.0)) or { R = 1.0, G = 0.85, B = 0.0, A = 1.0 }

local function DestroyCounterWidget()
    if _CounterWidget and Valid(_CounterWidget) then
        pcall(function()
            if _CounterWidget.RemoveFromParent then
                _CounterWidget:RemoveFromParent()
            end
        end)
    end
    _CounterWidget = nil
    _CounterText = nil
    _CounterLastString = nil
end
_G.DestroyCounterWidget = DestroyCounterWidget

local function GetOrCreateCounterWidget()
    if _CounterWidget and Valid(_CounterWidget) and _CounterText then
        return _CounterWidget, _CounterText
    end

    local now = os.clock()
    if now - _CounterLastAttempt < 5.0 then
        return nil, nil
    end
    _CounterLastAttempt = now

    DestroyCounterWidget()

    if not slua or not slua.loadUI then return nil, nil end

    local ok, btn = pcall(slua.loadUI, COUNTER_WIDGET_BP)
    if not (ok and btn and Valid(btn)) then return nil, nil end

    local attached = false
    pcall(function()
        local UIContainers = _G.UIContainers or package.loaded["client.slua.config.ClientMacros.UIContainers"]
        if not UIContainers then
            local okC, resC = pcall(require, "client.slua.config.ClientMacros.UIContainers")
            if okC then UIContainers = resC end
        end
        local hm = package.loaded["game_frontend_hud"] or require("game_frontend_hud")
        if hm and hm.AddToContainer and UIContainers and UIContainers.Top then
            hm.AddToContainer(UIContainers.Top, btn, 100)
            attached = true
        end
    end)
    if not attached and btn.AddToViewport then
        pcall(btn.AddToViewport, btn, 100)
    end

    local node_root = btn.UIRoot or btn
    local textWidget = node_root.RichText_Content or btn.RichText_Content
    local bgImage = node_root.Image_BtnBg or btn.Image_BtnBg

    local ESlateVisibility = UEnums and UEnums.ESlateVisibility or (pcall(import, "ESlateVisibility") and import("ESlateVisibility")) or nil
    local hitVis = ESlateVisibility and (ESlateVisibility.SelfHitTestInvisible or ESlateVisibility.HitTestInvisible)

    if hitVis then
        if btn.SetWidgetVisibility then pcall(btn.SetWidgetVisibility, btn, hitVis)
        elseif btn.SetVisibility then pcall(btn.SetVisibility, btn, hitVis) end
        if textWidget then
            if textWidget.SetWidgetVisibility then pcall(textWidget.SetWidgetVisibility, textWidget, hitVis)
            elseif textWidget.SetVisibility then pcall(textWidget.SetVisibility, textWidget, hitVis) end
        end
    end

    if bgImage and ESlateVisibility then
        if bgImage.SetVisibility then pcall(bgImage.SetVisibility, bgImage, ESlateVisibility.Collapsed)
        elseif bgImage.SetWidgetVisibility then pcall(bgImage.SetWidgetVisibility, bgImage, ESlateVisibility.Collapsed) end
    end
    if btn.SetBackgroundColor then
        pcall(btn.SetBackgroundColor, btn, (LinearColor and LinearColor(0, 0, 0, 0)) or { R = 0, G = 0, B = 0, A = 0 })
    end

    pcall(function()
        local FAnchors = _G.FAnchors or (pcall(import, "Anchors") and import("Anchors"))
        local FVector2D = _G.FVector2D or (pcall(import, "Vector2D") and import("Vector2D"))
        local WLL = pcall(import, "WidgetLayoutLibrary") and import("WidgetLayoutLibrary")
        if WLL and WLL.SlotAsCanvasSlot and FAnchors and FVector2D then
            local slot = WLL.SlotAsCanvasSlot(btn)
            if slot then
                if slot.SetAnchors then slot:SetAnchors(FAnchors(0.5, 0, 0.5, 0)) end
                if slot.SetAlignment then slot:SetAlignment(FVector2D(0.5, 0)) end
                if slot.SetPosition then slot:SetPosition(FVector2D(0, 36)) end
                if slot.SetSize then slot:SetSize(FVector2D(250, 26)) end
            end
        end
    end)

    pcall(function()
        local FAnchors = _G.FAnchors or (pcall(import, "Anchors") and import("Anchors"))
        local FVector2D = _G.FVector2D or (pcall(import, "Vector2D") and import("Vector2D"))
        if btn.SetAnchorsInViewport and FAnchors then pcall(btn.SetAnchorsInViewport, btn, FAnchors(0.5, 0, 0.5, 0)) end
        if btn.SetAlignmentInViewport and FVector2D then pcall(btn.SetAlignmentInViewport, btn, FVector2D(0.5, 0)) end
        if btn.SetPositionInViewport and FVector2D then pcall(btn.SetPositionInViewport, btn, FVector2D(0, 36), false) end
    end)

    if textWidget then
        pcall(function()
            local fi = textWidget.Font
            if fi then
                fi.Size = 16
                textWidget:SetFont(fi)
            end
            local SlateColor = (pcall(import, "SlateColor") and import("SlateColor")) or _G.FSlateColor
            if SlateColor and textWidget.SetColorAndOpacity then
                textWidget:SetColorAndOpacity(SlateColor(GOLD_COLOR))
            end
            local FVector2D = _G.FVector2D or (pcall(import, "Vector2D") and import("Vector2D"))
            if textWidget.SetShadowOffset and FVector2D then
                textWidget:SetShadowOffset(FVector2D(1, 1))
            end
            if textWidget.SetShadowColorAndOpacity then
                textWidget:SetShadowColorAndOpacity((LinearColor and LinearColor(0, 0, 0, 0.8)) or { R = 0, G = 0, B = 0, A = 0.8 })
            end
        end)
    end

    _CounterWidget = btn
    _CounterText = textWidget
    _CounterLastString = nil
    return _CounterWidget, _CounterText
end

local function Tick_EnemyCounter()
    local isEnabled = _G.LexusConfig.ESP_All and _G.LexusConfig.EnemyCounterEnabled
    if not isEnabled then
        if _CounterWidget then DestroyCounterWidget() end
        return
    end

    local localPawn, myPos, hud, pc, myTeamId, spectatedTarget = GetFrameCache()
    if not localPawn or not myPos then return end

    local okPawns, allPawns = GetCachedPlayerPawns()
    if not okPawns or not allPawns then return end

    local enemyCount = 0
    local botCount = 0

    for _, pawn in ipairs(allPawns) do
        if Valid(pawn) and pawn ~= localPawn and pawn ~= spectatedTarget then
            local pTeam = pawn.TeamID or (type(pawn.GetTeamID) == "function" and pawn:GetTeamID())
            if not (myTeamId and myTeamId > 0 and pTeam and pTeam > 0 and pTeam == myTeamId) then
                if not IsPawnDead(pawn) then
                    local okPP, pPos = SafeMethodCall(pawn, "K2_GetActorLocation")
                    if okPP and pPos then
                        local dx = pPos.X - myPos.X
                        local dy = pPos.Y - myPos.Y
                        local dz = pPos.Z - myPos.Z
                        local distSq = dx * dx + dy * dy + dz * dz
                        if distSq > 0 and distSq <= 1600000000 then
                            local isAI = false
                            pcall(function()
                                if _G.Game and _G.Game.IsAI then isAI = _G.Game:IsAI(pawn)
                                elseif pawn.bIsAI then isAI = true end
                            end)
                            if isAI then
                                botCount = botCount + 1
                            else
                                enemyCount = enemyCount + 1
                            end
                        end
                    end
                end
            end
        end
    end

    local newText
    if enemyCount == 0 and botCount == 0 then
        newText = "ZONE CLEAR"
    else
        newText = string.format("%d ENEMY  |  %d BOT", enemyCount, botCount)
    end

    if newText ~= _CounterLastString then
        local widget, txt = GetOrCreateCounterWidget()
        if txt and Valid(txt) then
            pcall(function()
                txt:SetText(newText)
                _CounterLastString = newText
            end)
        end
    end
end
_G.Tick_EnemyCounter = Tick_EnemyCounter

-- ============================================================================
-- VEHICLE ESP (CARS, BIKES, BOATS - 400M RANGE, 10.0S INTERVAL, DEDICATED TIMER)
-- ============================================================================
local _ActiveVehicleActors = {}
local _VEH_CACHE = nil
local _VEH_CACHE_TIME = 0
local FVecVeh = FVector or (pcall(import, "Vector") and import("Vector")) or (pcall(import, "FVector") and import("FVector"))
local VEH_TEXT_OFFSET = (FVecVeh and FVecVeh(0, 0, 100)) or { X = 0, Y = 0, Z = 100 }
local C_VEH_YELLOW = { R = 255, G = 215, B = 0, A = 255 }

local VEH_NAMES = {
    [1000] = "Buggy", [2000] = "Dacia", [3000] = "Motorcycle", [4000] = "Motorcycle (Sidecar)",
    [5000] = "UAZ (Hardtop)", [6000] = "UAZ (Open)", [7000] = "UAZ (Soft)", [8000] = "Pickup (Open)",
    [9000] = "Pickup (Cover)", [10000] = "Mirado (Open)", [11000] = "Mirado (Hardtop)", [12000] = "Van",
    [13000] = "Scooter", [14000] = "Rony", [15000] = "Snowmobile", [16000] = "Tukshai",
    [17000] = "BRDM-2", [18000] = "Monster Truck", [19000] = "Coupe RB", [20000] = "Motor Glider",
    [21000] = "PG-117", [22000] = "Aquarail", [23000] = "Airboat"
}

local function ClearAllVehicleESP()
    pcall(function()
        local _, _, hud = GetFrameCache()
        if Valid(hud) and hud.RemoveDebugText then
            for veh, _ in pairs(_ActiveVehicleActors) do
                if Valid(veh) then pcall(hud.RemoveDebugText, hud, veh, false) end
            end
        end
    end)
    _ActiveVehicleActors = {}
end
_G.ClearAllVehicleESP = ClearAllVehicleESP

local function GetVehicleDisplayName(veh)
    if not Valid(veh) then return "Vehicle" end
    local n = veh.DisplayName
    if n and type(n) == "string" and n ~= "" then return n end

    pcall(function()
        local av = veh.VehicleAvatar
        if Valid(av) and av.GetDefaultAvatarID then
            local okId, id = pcall(av.GetDefaultAvatarID, av)
            if okId and id and id > 0 then
                local baseId = math.floor(id / 1000) * 1000
                n = VEH_NAMES[baseId] or VEH_NAMES[id]
            end
        end
    end)
    if n and n ~= "" then return n end

    local clsName = ""
    pcall(function()
        local clsObj = veh:GetClass()
        if clsObj and clsObj.GetName then clsName = clsObj:GetName() end
    end)
    if not clsName or clsName == "" then
        pcall(function() clsName = type(veh.GetName) == "function" and veh:GetName() or tostring(veh) end)
    end

    if clsName:find("UAZ") then return "UAZ"
    elseif clsName:find("Buggy") then return "Buggy"
    elseif clsName:find("Dacia") then return "Dacia"
    elseif clsName:find("Motorcycle") or clsName:find("Motorbike") or clsName:find("Bike01") then return "Motorcycle"
    elseif clsName:find("Coupe") then return "Coupe RB"
    elseif clsName:find("Mirado") then return "Mirado"
    elseif clsName:find("Monster") then return "Monster Truck"
    elseif clsName:find("BRDM") then return "BRDM-2"
    elseif clsName:find("Rony") then return "Rony"
    elseif clsName:find("Tuk") then return "Tukshai"
    elseif clsName:find("Scooter") then return "Scooter"
    elseif clsName:find("Snowmobile") then return "Snowmobile"
    elseif clsName:find("Glider") then return "Glider"
    elseif clsName:find("Boat") or clsName:find("PG117") then return "Boat"
    elseif clsName:find("JetSki") or clsName:find("Aqua") then return "Jet Ski"
    elseif clsName:find("UTV") then return "UTV"
    elseif clsName:find("Bike") then return "Bike"
    elseif clsName:find("Hovercraft") then return "Hovercraft"
    elseif clsName:find("Tank") then return "Tank"
    end
    return "Vehicle"
end
local function Tick_VehicleESP()
    local isEnabled = _G.LexusConfig and _G.LexusConfig.VehicleESPEnabled
    if not isEnabled then
        if next(_ActiveVehicleActors) ~= nil then ClearAllVehicleESP() end
        return
    end

    local localPawn, myPos, hud, pc = GetFrameCache()
    if not Valid(hud) then
        if slua_GameFrontendHUD and Valid(slua_GameFrontendHUD) then hud = slua_GameFrontendHUD
        elseif pc and Valid(pc) then pcall(function() hud = pc.MyHUD or (pc.GetHUD and pc:GetHUD()) end)
        elseif localPawn and Valid(localPawn) then pcall(function() hud = localPawn.MyHUD end)
        end
    end
    if not localPawn or not myPos or not Valid(hud) then return end

    local nowSec = os.time()
    if (nowSec - _VEH_CACHE_TIME) >= 10 or not _VEH_CACHE then
        _VEH_CACHE_TIME = nowSec
        local vehList = nil
        pcall(function()
            if Game and Game.GetAllVehicles then vehList = Game:GetAllVehicles()
            elseif _G.Game and _G.Game.GetAllVehicles then vehList = _G.Game:GetAllVehicles()
            elseif CGame and CGame.GetAllVehicles then vehList = CGame:GetAllVehicles() end
        end)
        if not vehList then
            pcall(function()
                local cls = import("/Script/ShadowTrackerExtra.STExtraVehicleBase") or import("STExtraVehicleBase")
                if cls and Game and Game.GetActorsByClass then
                    vehList = Game:GetActorsByClass(cls)
                end
            end)
        end
        local flat = {}
        if vehList then
            local n = nil
            pcall(function() if type(vehList.Num) == "function" then n = vehList:Num() end end)
            if n and n > 0 then
                for i = 0, n - 1 do
                    local v = nil
                    pcall(function() v = vehList:Get(i) end)
                    if v and Valid(v) then flat[#flat + 1] = v end
                end
            elseif type(vehList) == "table" then
                for _, v in pairs(vehList) do
                    if v and Valid(v) then flat[#flat + 1] = v end
                end
            end
        end
        _VEH_CACHE = flat
    end

    local currentVehicles = {}
    for _, veh in ipairs(_VEH_CACHE or {}) do
        if Valid(veh) then
            local okLoc, vPos = SafeMethodCall(veh, "K2_GetActorLocation")
            if okLoc and vPos then
                local dx = vPos.X - myPos.X
                local dy = vPos.Y - myPos.Y
                local dz = vPos.Z - myPos.Z
                local distSq = dx * dx + dy * dy + dz * dz
                local maxVDist = (_G.LexusConfig and _G.LexusConfig.VehicleDistance) or 400
                local maxVDistSq = (maxVDist * 100) * (maxVDist * 100)
                if distSq > 0 and distSq <= maxVDistSq then
                    local vDist = math.floor(math.sqrt(distSq) / 100.0 + 0.5)
                    local vName = GetVehicleDisplayName(veh)
                    local txt
                    if _G.LexusConfig and _G.LexusConfig.VehicleShowDist == false then
                        txt = vName
                    else
                        txt = string.format("%s [%dm]", vName, vDist)
                    end
                    SafeMethodCall(hud, "AddDebugText", txt, veh, 11.5, VEH_TEXT_OFFSET, VEH_TEXT_OFFSET, C_VEH_YELLOW, false, false, true, nil, 0.65, true)
                    currentVehicles[veh] = true
                end
            end
        end
    end

    for veh, _ in pairs(_ActiveVehicleActors) do
        if not currentVehicles[veh] then
            if Valid(hud) and hud.RemoveDebugText and Valid(veh) then
                pcall(hud.RemoveDebugText, hud, veh, false)
            end
            _ActiveVehicleActors[veh] = nil
        end
    end
    for veh, _ in pairs(currentVehicles) do
        _ActiveVehicleActors[veh] = true
    end
end
_G.Tick_VehicleESP = Tick_VehicleESP

_G.VEH_TIMER = nil
_G.VEH_TIMER_OWNER = nil

local function StopVehicleTimer()
    if _G.VEH_TIMER and Valid(_G.VEH_TIMER_OWNER) and _G.VEH_TIMER_OWNER.RemoveGameTimer then
        pcall(_G.VEH_TIMER_OWNER.RemoveGameTimer, _G.VEH_TIMER_OWNER, _G.VEH_TIMER)
    end
    _G.VEH_TIMER = nil
    _G.VEH_TIMER_OWNER = nil
    ClearAllVehicleESP()
end
_G.StopVehicleTimer = StopVehicleTimer

local function StartVehicleTimer(pc)
    local timerOwner = GetActivePlayerController(pc)
    if not Valid(timerOwner) or not timerOwner.AddGameTimer then return end
    if _G.VEH_TIMER and _G.VEH_TIMER_OWNER == timerOwner then return end
    if _G.VEH_TIMER and Valid(_G.VEH_TIMER_OWNER) and _G.VEH_TIMER_OWNER.RemoveGameTimer then
        pcall(_G.VEH_TIMER_OWNER.RemoveGameTimer, _G.VEH_TIMER_OWNER, _G.VEH_TIMER)
    end
    _G.VEH_TIMER_OWNER = timerOwner
    _G.VEH_TIMER = timerOwner:AddGameTimer(10.0, true, function()
        pcall(Tick_VehicleESP)
    end)
    pcall(Tick_VehicleESP)
end
_G.StartVehicleTimer = StartVehicleTimer

-- ============================================================================
-- CURATED HIGH-TIER LOOT ESP (STRICT 60M RANGE, 10.0S INTERVAL, DEDICATED TIMER)
-- ============================================================================
local _ActiveLootActors = {}
local _PickUpWrapperClass = nil
local FVecLoot = FVector or (pcall(import, "Vector") and import("Vector")) or (pcall(import, "FVector") and import("FVector"))
local LOOT_TEXT_OFFSET = (FVecLoot and FVecLoot(0, 0, 35)) or { X = 0, Y = 0, Z = 35 }

local C_LOOT_COLOR = { R = 0, G = 230, B = 255, A = 255 } -- Single static Vibrant Cyan (distinct from Vehicle Yellow)

local HighTierLoot = {
    -- Flare Guns
    [106007] = "Flare Gun",
    [106009] = "Flare Gun",
    [106103] = "Flare Gun",
    [106107] = "Respawn Flare",
    -- Air Drop Weapons
    [103003] = "AWM",
    [103012] = "AMR",
    [101005] = "Groza",
    [101006] = "AUG",
    [105010] = "MG3",
    [103007] = "Mk14",
    [102105] = "P90",
    -- Popular Rifles / Snipers
    [101004] = "M416",
    [101001] = "AKM",
    [101008] = "M762",
    [103001] = "Kar98K",
    [103002] = "M24",
    -- Level 3 Gear
    [501003] = "Lv3 Backpack",
    [502003] = "Lv3 Helmet",
    [503003] = "Lv3 Armor",
    -- Scopes
    [203004] = "4x Scope",
    [203005] = "6x Scope",
    [203006] = "8x Scope",
    -- Medical
    [601005] = "Med Kit",
    [601003] = "Adrenaline"
}

local function ClearAllLootESP()
    pcall(function()
        local _, _, hud = GetFrameCache()
        if Valid(hud) and hud.RemoveDebugText then
            for itm, _ in pairs(_ActiveLootActors) do
                if Valid(itm) then pcall(hud.RemoveDebugText, hud, itm, false) end
            end
        end
    end)
    _ActiveLootActors = {}
end
_G.ClearAllLootESP = ClearAllLootESP

local function GetPickUpWrapperClass()
    if _PickUpWrapperClass then return _PickUpWrapperClass end
    local candidates = {
        "/Script/ShadowTrackerExtra.PickUpWrapperActor",
        "PickUpWrapperActor",
        "/Script/ShadowTrackerExtra.STExtraPickUpWrapperActor",
        "STExtraPickUpWrapperActor"
    }
    for _, path in ipairs(candidates) do
        local ok, cls = pcall(import, path)
        if ok and cls then
            _PickUpWrapperClass = cls
            return cls
        end
    end
    if slua and slua.loadClass then
        for _, path in ipairs(candidates) do
            local ok, cls = pcall(slua.loadClass, path)
            if ok and cls then
                _PickUpWrapperClass = cls
                return cls
            end
        end
    end
    return nil
end

local function ResolveItemName(item)
    if not Valid(item) then return nil end
    local id = nil

    -- 1. Direct DefineID / ItemDefineID on wrapper
    pcall(function()
        if item.DefineID then
            id = item.DefineID.TypeSpecificID or item.DefineID.ID or item.DefineID
        end
    end)
    if not id then
        pcall(function()
            if item.ItemDefineID then
                id = item.ItemDefineID.TypeSpecificID or item.ItemDefineID.ID
            end
        end)
    end
    if not id then
        pcall(function()
            if item.GetItemDefineID then
                local def = item:GetItemDefineID()
                if def then id = def.TypeSpecificID or def.ID end
            end
        end)
    end
    if not id then
        pcall(function()
            if item.GetPickUpDataList then
                local list = item:GetPickUpDataList()
                if list then
                    local first = (type(list.Get) == "function" and list:Get(0)) or list[1]
                    if first then
                        local fId = first.ID or first.DefineID
                        if fId then id = fId.TypeSpecificID or fId.ID or fId end
                    end
                end
            end
        end)
    end
    if not id then
        pcall(function() if item.DefineId then id = item.DefineId end end)
    end
    if not id then
        pcall(function() if item.ItemID then id = item.ItemID end end)
    end

    if type(id) == "number" and id > 0 and HighTierLoot[id] then
        return HighTierLoot[id]
    end

    -- 2. Name-based resolution from Actor Name / Class Name
    local name = ""
    pcall(function()
        if type(item.GetName) == "function" then name = item:GetName()
        else name = tostring(item) end
    end)
    if not name or name == "" then
        pcall(function()
            local cls = item:GetClass()
            if cls and cls.GetName then name = cls:GetName() end
        end)
    end

    if name and name ~= "" then
        local lower = name:lower()
        if lower:find("flare") then return "Flare Gun"
        elseif lower:find("awm") then return "AWM"
        elseif lower:find("amr") then return "AMR"
        elseif lower:find("groza") then return "Groza"
        elseif lower:find("aug") then return "AUG"
        elseif lower:find("mg3") then return "MG3"
        elseif lower:find("mk14") then return "Mk14"
        elseif lower:find("p90") then return "P90"
        elseif lower:find("m416") then return "M416"
        elseif lower:find("akm") then return "AKM"
        elseif lower:find("m762") then return "M762"
        elseif lower:find("kar98") then return "Kar98K"
        elseif lower:find("m24") then return "M24"
        elseif lower:find("armor_3") or lower:find("armor_lv3") or lower:find("vest_3") or lower:find("vest3") then return "Lv3 Armor"
        elseif lower:find("helmet_3") or lower:find("helmet_lv3") or lower:find("head_3") or lower:find("head3") then return "Lv3 Helmet"
        elseif lower:find("bag_3") or lower:find("bag_lv3") or lower:find("backpack_3") then return "Lv3 Backpack"
        elseif lower:find("scope_4x") or lower:find("4x") or lower:find("largeequip_4x") then return "4x Scope"
        elseif lower:find("scope_6x") or lower:find("6x") or lower:find("largeequip_6x") then return "6x Scope"
        elseif lower:find("scope_8x") or lower:find("8x") or lower:find("largeequip_8x") then return "8x Scope"
        elseif lower:find("medkit") or lower:find("firstaid") then return "Med Kit"
        elseif lower:find("adrenaline") then return "Adrenaline"
        end
    end
    return nil
end


local function IsLootAllowed(itemName)
    local cfg = _G.LexusConfig
    if not cfg then return true end
    if itemName:find("Flare") then
        return cfg.LootFlares ~= false
    elseif itemName:find("Lv3") or itemName:find("Armor") or itemName:find("Helmet") or itemName:find("Backpack") then
        return cfg.LootArmor ~= false
    elseif itemName:find("Scope") then
        return cfg.LootScopes ~= false
    elseif itemName:find("Med") or itemName:find("Adrenaline") then
        return cfg.LootMeds ~= false
    else
        return cfg.LootWeapons ~= false
    end
end

local function Tick_LootESP()
    local isEnabled = _G.LexusConfig and _G.LexusConfig.LootESPEnabled
    if not isEnabled then
        if next(_ActiveLootActors) ~= nil then ClearAllLootESP() end
        return
    end

    local localPawn, myPos, hud, pc = GetFrameCache()
    if not Valid(hud) then
        if slua_GameFrontendHUD and Valid(slua_GameFrontendHUD) then hud = slua_GameFrontendHUD
        elseif pc and Valid(pc) then pcall(function() hud = pc.MyHUD or (pc.GetHUD and pc:GetHUD()) end)
        elseif localPawn and Valid(localPawn) then pcall(function() hud = localPawn.MyHUD end)
        end
    end
    if not localPawn or not myPos or not Valid(hud) then return end

    local cls = GetPickUpWrapperClass()
    if not cls then return end

    local actors = nil
    pcall(function()
        if Game and Game.GetActorsByClass then
            actors = Game:GetActorsByClass(cls)
        elseif _G.Game and _G.Game.GetActorsByClass then
            actors = _G.Game:GetActorsByClass(cls)
        elseif CGame and CGame.GetActorsByClass then
            actors = CGame:GetActorsByClass(cls)
        end
    end)

    if not actors then
        pcall(function()
            local gi = (slua_GameFrontendHUD and slua_GameFrontendHUD.GetGameInstance and slua_GameFrontendHUD:GetGameInstance())
                or (pc and pc.GetGameInstance and pc:GetGameInstance())
            if GameplayStatics and cls and gi then
                local arr = (slua and slua.Array and UEnums and UEnums.EPropertyClass and slua.Array(UEnums.EPropertyClass.Object, cls)) or {}
                actors = GameplayStatics.GetAllActorsOfClass(gi, cls, arr)
            end
        end)
    end

    if not actors then return end

    local currentLoot = {}
    local displayedCount = 0

    local function ProcessItem(item)
        if not (item and Valid(item)) then return end
        local dist = nil
        pcall(function()
            dist = localPawn:GetDistanceTo(item) / 100.0
        end)
        if not dist then
            local okLoc, iPos = SafeMethodCall(item, "K2_GetActorLocation")
            if okLoc and iPos and myPos then
                local dx = iPos.X - myPos.X
                local dy = iPos.Y - myPos.Y
                local dz = iPos.Z - myPos.Z
                dist = math.sqrt(dx * dx + dy * dy + dz * dz) / 100.0
            end
        end

        local maxLootDist = (_G.LexusConfig and _G.LexusConfig.LootDistance) or 60.0
        if dist and dist <= maxLootDist then
            local itemName = ResolveItemName(item)
            if itemName and IsLootAllowed(itemName) then
                local distM = math.floor(dist + 0.5)
                local txt = string.format("%s [%dm]", itemName, distM)
                SafeMethodCall(hud, "AddDebugText", txt, item, 11.5, LOOT_TEXT_OFFSET, LOOT_TEXT_OFFSET, C_LOOT_COLOR, false, false, true, nil, 0.70, true)
                currentLoot[item] = true
                displayedCount = displayedCount + 1
            end
        end
    end

    local n = nil
    pcall(function() if type(actors.Num) == "function" then n = actors:Num() end end)
    if n and n > 0 then
        for i = 0, n - 1 do
            local item = nil
            pcall(function() item = actors:Get(i) end)
            if item then
                ProcessItem(item)
                if displayedCount >= 20 then break end
            end
        end
    elseif type(actors) == "table" then
        for _, item in pairs(actors) do
            ProcessItem(item)
            if displayedCount >= 20 then break end
        end
    end

    for itm, _ in pairs(_ActiveLootActors) do
        if not currentLoot[itm] then
            if Valid(hud) and hud.RemoveDebugText and Valid(itm) then
                pcall(hud.RemoveDebugText, hud, itm, false)
            end
            _ActiveLootActors[itm] = nil
        end
    end
    for itm, _ in pairs(currentLoot) do
        _ActiveLootActors[itm] = true
    end
end
_G.Tick_LootESP = Tick_LootESP

_G.LOOT_TIMER = nil
_G.LOOT_TIMER_OWNER = nil

local function StopLootTimer()
    if _G.LOOT_TIMER and Valid(_G.LOOT_TIMER_OWNER) and _G.LOOT_TIMER_OWNER.RemoveGameTimer then
        pcall(_G.LOOT_TIMER_OWNER.RemoveGameTimer, _G.LOOT_TIMER_OWNER, _G.LOOT_TIMER)
    end
    _G.LOOT_TIMER = nil
    _G.LOOT_TIMER_OWNER = nil
    ClearAllLootESP()
end
_G.StopLootTimer = StopLootTimer

local function StartLootTimer(pc)
    local timerOwner = GetActivePlayerController(pc)
    if not Valid(timerOwner) or not timerOwner.AddGameTimer then return end
    if _G.LOOT_TIMER and _G.LOOT_TIMER_OWNER == timerOwner then return end
    if _G.LOOT_TIMER and Valid(_G.LOOT_TIMER_OWNER) and _G.LOOT_TIMER_OWNER.RemoveGameTimer then
        pcall(_G.LOOT_TIMER_OWNER.RemoveGameTimer, _G.LOOT_TIMER_OWNER, _G.LOOT_TIMER)
    end
    _G.LOOT_TIMER_OWNER = timerOwner
    _G.LOOT_TIMER = timerOwner:AddGameTimer(10.0, true, function()
        pcall(Tick_LootESP)
    end)
    pcall(Tick_LootESP)
end
_G.StartLootTimer = StartLootTimer

local function ClearESPTimers()
    ClearAll1006Marks()
    ClearAllMapMarks()
    ClearAllBoxESP()
    DestroyCounterWidget()
    ClearModTimers()
    if _G.StopSnaplineLoop then pcall(_G.StopSnaplineLoop) end
    if _G.ClearAllSnapLines then pcall(_G.ClearAllSnapLines) end
end
_G.ClearESPTimers = ClearESPTimers

local function StartESPTimers(pc)
    local timerOwner = GetActivePlayerController(pc)
    if not Valid(timerOwner) then return end
    ClearModTimers(timerOwner)
    AddModTimer(timerOwner, 2.0, true, Tick_HealthBarESP)
    AddModTimer(timerOwner, 2.0, true, Tick_BoxESP)
    AddModTimer(timerOwner, 3.0, true, Tick_MapESP)
    AddModTimer(timerOwner, 3.0, true, Tick_EnemyCounter)
end
_G.StartESPTimers = StartESPTimers
-- ============================================================================
--  COLOR PALETTE & UTILITY (SHARED BY WALLHACK + SNAPLINE)
-- ============================================================================
local COLOR_PALETTE = {
    [0] = { R = 255, G = 0,   B = 0   }, -- Red
    [1] = { R = 0,   G = 255, B = 255 }, -- Cyan
    [2] = { R = 255, G = 255, B = 0   }, -- Yellow
    [3] = { R = 0,   G = 255, B = 0   }, -- Green
    [4] = { R = 128, G = 0,   B = 255 }, -- Purple
    [5] = { R = 255, G = 255, B = 255 }, -- White
    [6] = { R = 255, G = 0,   B = 140 }, -- Pink
    [7] = { R = 55,  G = 255, B = 20  }, -- Lime
}
_G._WH_ConfigVersion = _G._WH_ConfigVersion or 0
local _WH_LINEAR_COLOR_CACHE = {}
local _WH_LINEAR_COLOR_CACHE_COUNT = 0
local _WH_LC_Class = LinearColor or (pcall(import, "LinearColor") and import("LinearColor")) or nil

local function GetLinearColor(idx)
    local intensity = (_G.LexusConfig and _G.LexusConfig.GlowIntensity) or 60
    local cacheKey = (idx or 0) * 1000 + intensity
    if not _G._WH_ForceUpdate and _WH_LINEAR_COLOR_CACHE[cacheKey] then
        return _WH_LINEAR_COLOR_CACHE[cacheKey]
    end
    local c = COLOR_PALETTE[idx] or COLOR_PALETTE[0]
    local mult = 1.0 + (intensity / 100.0) * 39.52
    local r = (c.R / 255.0) * mult
    local g = (c.G / 255.0) * mult
    local b = (c.B / 255.0) * mult
    local lc = nil
    if _WH_LC_Class then
        local ok, res = pcall(_WH_LC_Class, r, g, b, 1.0)
        if ok and res ~= nil then lc = res end
    end
    if not lc then
        lc = { R = r, G = g, B = b, A = 1.0, r = r, g = g, b = b, a = 1.0 }
    end
    if _WH_LINEAR_COLOR_CACHE_COUNT < 128 then
        _WH_LINEAR_COLOR_CACHE[cacheKey] = lc
        _WH_LINEAR_COLOR_CACHE_COUNT = _WH_LINEAR_COLOR_CACHE_COUNT + 1
    end
    return lc
end

local function GetSnaplineColor(idx, alpha)
    local a = alpha or 0.95
    local c = COLOR_PALETTE[idx] or COLOR_PALETTE[0]
    local r, g, b = c.R / 255.0, c.G / 255.0, c.B / 255.0
    if _WH_LC_Class then
        local ok, res = pcall(_WH_LC_Class, r, g, b, a)
        if ok and res ~= nil then return res end
    end
    return { R = r, G = g, B = b, A = a }
end

local _ASTExtraVehicleBase = (pcall(import, "STExtraVehicleBase") and import("STExtraVehicleBase")) or nil

local function IsVehicleActor(actor)
    if not actor or not Valid(actor) then return true end
    if _G.Game and type(_G.Game.IsVehicle) == "function" then
        local ok, isV = pcall(_G.Game.IsVehicle, _G.Game, actor)
        if ok and isV == true then return true end
    end
    if _ASTExtraVehicleBase and type(actor.IsA) == "function" then
        local ok, isA = pcall(actor.IsA, actor, _ASTExtraVehicleBase)
        if ok and isA == true then return true end
    end
    if actor.VehicleCommon or actor.VehicleMovement or actor.VehicleSeatComponent or actor.bIsVehicle then
        return true
    end
    if type(actor.GetVehicleCommon) == "function" then
        local ok, vc = pcall(actor.GetVehicleCommon, actor)
        if ok and Valid(vc) then return true end
    end
    local hasCharMove = false
    if actor.STCharacterMovement or actor.CharacterMovement then
        hasCharMove = true
    elseif type(actor.GetCharacterMovement) == "function" then
        local ok, cm = pcall(actor.GetCharacterMovement, actor)
        if ok and Valid(cm) then hasCharMove = true end
    end
    if not hasCharMove then return true end
    return false
end

-- ============================================================================
--  V13 CRASH-FREE WALLHACK (NATIVE DYEING + OUTLINE + HIGHLIGHT)
-- ============================================================================
local CONSOLE_READY = false
local _WH_MarkData = setmetatable({}, { __mode = "k" })
local _WH_MeshDyeState = setmetatable({}, { __mode = "k" })
local _WH_ModifiedPawns = setmetatable({}, { __mode = "k" })
_G.WH_TIMER = nil
_G.WH_TIMER_OWNER = nil
local TICK_INTERVAL = 2.5
local MAX_PAWNS_PER_TICK = 15

-- Cache imported types once at module level
local _ci_SkeletalMeshClass = (pcall(import, "SkeletalMeshComponent") and import("SkeletalMeshComponent")) or nil
local _ci_SlotViewAvatarComp = (pcall(import, "SlotViewAvatarComponent") and import("SlotViewAvatarComponent"))
    or (pcall(import, "CharacterAvatarComponent") and import("CharacterAvatarComponent")) or nil

local function SetupConsole()
    if CONSOLE_READY then return end
    pcall(function()
        local ui_util = pcall(require, "client.common.ui_util") and require("client.common.ui_util")
        local gi = (slua_GameFrontendHUD and slua_GameFrontendHUD.GetGameInstance and slua_GameFrontendHUD:GetGameInstance())
            or (ui_util and ui_util.GetGameInstance and ui_util.GetGameInstance())
            or (_G.GameInstance)
            or (GameplayStatics and GameplayStatics.GetGameInstance and _slua and _slua.getWorld and GameplayStatics.GetGameInstance(_slua.getWorld()))
        if gi and gi.ExecuteCMD then
            gi:ExecuteCMD("r.EnableDrawDyeingColor", 1)
            gi:ExecuteCMD("r.CustomDepth", 3)
            gi:ExecuteCMD("r.IdeaOutline.Enable", 1)
            gi:ExecuteCMD("r.Highlight.Enable", 1)
        end
        local STExtraGameInstance = pcall(import, "STExtraGameInstance") and import("STExtraGameInstance")
        if STExtraGameInstance and STExtraGameInstance.GetInstance then
            local gi2 = STExtraGameInstance.GetInstance()
            if gi2 and gi2.ExecuteCMD then
                gi2:ExecuteCMD("r.EnableDrawDyeingColor", 1)
                gi2:ExecuteCMD("r.CustomDepth", 3)
                gi2:ExecuteCMD("r.IdeaOutline.Enable", 1)
                gi2:ExecuteCMD("r.Highlight.Enable", 1)
            end
        end
        local KSL = UKismetSystemLibrary or import("KismetSystemLibrary")
        local world = _slua and _slua.getWorld and _slua.getWorld()
        if KSL and world then
            KSL.ExecuteConsoleCommand(world, "r.EnableDrawDyeingColor 1")
            KSL.ExecuteConsoleCommand(world, "r.CustomDepth 3")
            KSL.ExecuteConsoleCommand(world, "r.IdeaOutline.Enable 1")
            KSL.ExecuteConsoleCommand(world, "r.Highlight.Enable 1")
        end
        CONSOLE_READY = true
    end)
end

local function DisableConsole()
    pcall(function()
        local ui_util = pcall(require, "client.common.ui_util") and require("client.common.ui_util")
        local gi = (slua_GameFrontendHUD and slua_GameFrontendHUD.GetGameInstance and slua_GameFrontendHUD:GetGameInstance())
            or (ui_util and ui_util.GetGameInstance and ui_util.GetGameInstance())
            or (_G.GameInstance)
            or (GameplayStatics and GameplayStatics.GetGameInstance and _slua and _slua.getWorld and GameplayStatics.GetGameInstance(_slua.getWorld()))
        if gi and gi.ExecuteCMD then
            gi:ExecuteCMD("r.EnableDrawDyeingColor", 0)
            gi:ExecuteCMD("r.CustomDepth", 0)
            gi:ExecuteCMD("r.IdeaOutline.Enable", 0)
            gi:ExecuteCMD("r.Highlight.Enable", 0)
        end
        local KSL = UKismetSystemLibrary or import("KismetSystemLibrary")
        local world = _slua and _slua.getWorld and _slua.getWorld()
        if KSL and world then
            KSL.ExecuteConsoleCommand(world, "r.EnableDrawDyeingColor 0")
            KSL.ExecuteConsoleCommand(world, "r.CustomDepth 0")
            KSL.ExecuteConsoleCommand(world, "r.IdeaOutline.Enable 0")
            KSL.ExecuteConsoleCommand(world, "r.Highlight.Enable 0")
        end
        CONSOLE_READY = false
    end)
end

local function DyeMesh(mesh, vis, occ, stateKey)
    if not Valid(mesh) then return end
    if stateKey and _WH_MeshDyeState[mesh] == stateKey and not _G._WH_ForceUpdate then return end
    pcall(function()
        if type(mesh.SetDrawDyeing) == "function" then mesh:SetDrawDyeing(true) end
        if type(mesh.SetDrawDyeingMode) == "function" then mesh:SetDrawDyeingMode(1) end
        if type(mesh.SetRenderCustomDepth) == "function" then mesh:SetRenderCustomDepth(true) end
        if type(mesh.SetCustomDepthStencilValue) == "function" then mesh:SetCustomDepthStencilValue(255) end
        if type(mesh.SetDyeingColorFadeDistance) == "function" then mesh:SetDyeingColorFadeDistance(99999.0) end
        if vis and type(mesh.SetVisibleDyeingColor) == "function" then mesh:SetVisibleDyeingColor(vis) end
        if occ and type(mesh.SetOccludedDyeingColor) == "function" then mesh:SetOccludedDyeingColor(occ) end
        if type(mesh.SetDyeingColorMinMaxDistance) == "function" then mesh:SetDyeingColorMinMaxDistance(0.0, 99999.0) end
        if type(mesh.SetDrawHighlight) == "function" then mesh:SetDrawHighlight(true) end
        if vis and type(mesh.OverrideHighlightColor) == "function" then mesh:OverrideHighlightColor(vis) end
        if type(mesh.SetHighlightCanBeOccluded) == "function" then mesh:SetHighlightCanBeOccluded(false) end
        if type(mesh.SetDrawIdeaOutline) == "function" then mesh:SetDrawIdeaOutline(true) end
        if type(mesh.SetIdeaOutlineNew) == "function" then mesh:SetIdeaOutlineNew(true) end
        if type(mesh.SetIdeaOutlineOcclusionHighlight) == "function" then mesh:SetIdeaOutlineOcclusionHighlight(true) end
        if vis and type(mesh.OverrideIdeaOutlineColor) == "function" then mesh:OverrideIdeaOutlineColor(vis) end
        if occ and type(mesh.SetIdeaOutlineOcclusionColor) == "function" then mesh:SetIdeaOutlineOcclusionColor(occ) end
        if type(mesh.OverrideIdeaOutlineThickness) == "function" then mesh:OverrideIdeaOutlineThickness(20.0) end
        if type(mesh.SetIdeaOverrideOutlineAndOcclusion) == "function" then mesh:SetIdeaOverrideOutlineAndOcclusion(true) end
        pcall(function() mesh.PrimitiveShadingStrategy = 1; mesh.ShadingRate = 6 end)
    end)
    if stateKey then _WH_MeshDyeState[mesh] = stateKey end
end

local function UnDyeMesh(mesh)
    if not Valid(mesh) then return end
    pcall(function()
        if type(mesh.SetDrawDyeing) == "function" then mesh:SetDrawDyeing(false) end
        if type(mesh.SetRenderCustomDepth) == "function" then mesh:SetRenderCustomDepth(false) end
        if type(mesh.SetDrawHighlight) == "function" then mesh:SetDrawHighlight(false) end
        if type(mesh.SetDrawIdeaOutline) == "function" then mesh:SetDrawIdeaOutline(false) end
        if type(mesh.OverrideIdeaOutlineThickness) == "function" then mesh:OverrideIdeaOutlineThickness(0.0) end
        pcall(function() mesh.PrimitiveShadingStrategy = 0; mesh.ShadingRate = 1 end)
    end)
    _WH_MeshDyeState[mesh] = nil
end

local function GetAllSkeletalMeshes(enemy, markData)
    if not Valid(enemy) then return {} end
    local curTime = os.clock()
    if markData and markData.CachedMeshes and markData.CachedMeshTime and (curTime - markData.CachedMeshTime < 4.0) then
        local validMeshes = {}
        for _, m in ipairs(markData.CachedMeshes) do
            if Valid(m) then validMeshes[#validMeshes + 1] = m end
        end
        if #validMeshes > 0 then
            markData.CachedMeshes = validMeshes
            return validMeshes
        end
    end
    local meshes = {}
    local seen = {}
    local function SafeAdd(m)
        if m and Valid(m) and not seen[m] then
            seen[m] = true
            meshes[#meshes + 1] = m
        end
    end
    SafeAdd(enemy.Mesh)
    SafeAdd(enemy.MasterMesh)
    local avatarComp = enemy.CharacterAvatarComp2_BP or enemy._SX_AVATAR_CACHE
    if not avatarComp and type(enemy.getAvatarComponent2) == "function" then
        local ok, comp = pcall(enemy.getAvatarComponent2, enemy)
        if ok and Valid(comp) then
            avatarComp = comp
            enemy._SX_AVATAR_CACHE = comp
        end
    end
    if not avatarComp and _ci_SlotViewAvatarComp and type(enemy.GetComponentByClass) == "function" then
        local ok, comp = pcall(enemy.GetComponentByClass, enemy, _ci_SlotViewAvatarComp)
        if ok and Valid(comp) then avatarComp = comp end
    end
    if Valid(avatarComp) and type(avatarComp.GetMeshCompBySlot) == "function" then
        for slot = 0, 7 do
            local ok, slotMesh = pcall(avatarComp.GetMeshCompBySlot, avatarComp, slot)
            if ok and Valid(slotMesh) then SafeAdd(slotMesh) end
        end
    elseif Valid(avatarComp) and type(avatarComp.GetMeshCompBySlotID) == "function" then
        for slot = 0, 7 do
            local ok, slotMesh = pcall(avatarComp.GetMeshCompBySlotID, avatarComp, slot)
            if ok and Valid(slotMesh) then SafeAdd(slotMesh) end
        end
    end
    pcall(function()
        local smClass = _ci_SkeletalMeshClass or import("SkeletalMeshComponent")
        if smClass and type(enemy.GetComponentsByClass) == "function" then
            local childs = enemy:GetComponentsByClass(smClass)
            if childs then
                local count = type(childs.Num) == "function" and childs:Num() or #childs
                for i = 1, count do
                    local comp = type(childs.Get) == "function" and childs:Get(i - 1) or childs[i]
                    if Valid(comp) then SafeAdd(comp) end
                end
            end
        end
    end)
    if markData then
        markData.CachedMeshes = meshes
        markData.CachedMeshTime = curTime
    end
    return meshes
end

local function ClearWallHack(pawn)
    if not pawn then return end
    _WH_ModifiedPawns[pawn] = nil
    local markData = _WH_MarkData[pawn]
    local meshes = markData and markData.CachedMeshes
    if meshes then
        for _, comp in ipairs(meshes) do
            if Valid(comp) then UnDyeMesh(comp) end
        end
    else
        if Valid(pawn) and Valid(pawn.Mesh) then UnDyeMesh(pawn.Mesh) end
    end
    _WH_MarkData[pawn] = nil
end
_G.ClearWallHack = ClearWallHack

local function ClearAllWallhackState()
    for p, _ in pairs(_WH_ModifiedPawns) do
        if Valid(p) then pcall(ClearWallHack, p) end
    end
    _WH_ModifiedPawns = setmetatable({}, { __mode = "k" })
    _WH_MarkData = setmetatable({}, { __mode = "k" })
    _WH_MeshDyeState = setmetatable({}, { __mode = "k" })
    _WH_LINEAR_COLOR_CACHE = {}
    _WH_LINEAR_COLOR_CACHE_COUNT = 0
end
_G.ClearAllWallhackState = ClearAllWallhackState

local AI_CACHE = {}
local AI_CACHE_SIZE = 0
local function ResolveIsAI(pKey_or_pawn, maybe_pawn)
    local pawn = maybe_pawn or pKey_or_pawn
    local pKey = maybe_pawn and pKey_or_pawn or (pawn and pawn.PlayerKey)
    if pKey and pKey ~= 0 and AI_CACHE[pKey] ~= nil then return AI_CACHE[pKey] end
    local isAI = false
    local g = _G.Game or Game
    if g and g.IsAI and pawn then
        local s, r = pcall(g.IsAI, g, pawn)
        if s and r == true then isAI = true end
    end
    if not isAI and pawn then
        if pawn.bIsAI == true or pawn.bAI == true then isAI = true end
        if not isAI and type(pawn.IsBot) == "function" then isAI = pawn:IsBot() end
        if not isAI and type(pawn.IsAI) == "function" then
            local s, r = pcall(pawn.IsAI, pawn)
            if s and r == true then isAI = true end
        end
        if not isAI and (not pKey or pKey == 0) then
            pcall(function()
                if pawn.PlayerState and (pawn.PlayerState.bIsABot == true or pawn.PlayerState.bIsAI == true) then
                    isAI = true
                end
            end)
        end
    end
    if pKey and pKey ~= 0 and (AI_CACHE_SIZE or 0) < 512 then
        AI_CACHE_SIZE = (AI_CACHE_SIZE or 0) + 1
        AI_CACHE[pKey] = isAI
    end
    return isAI
end

-- Forward declaration
local _pbc_Cleanup

local function PBCtick()
    if not _G.LexusConfig.WallHackEnabled then
        if _pbc_Cleanup then _pbc_Cleanup() end
        return
    end
    pcall(function()
        local localPawn = GetLocalPlayer()
        if not Valid(localPawn) then return end
        SetupConsole()

        -- Clean dead pawns
        for pawn, _ in pairs(_WH_ModifiedPawns) do
            if not Valid(pawn) or IsPawnDead(pawn) then
                if Valid(pawn) then ClearWallHack(pawn) end
                _WH_ModifiedPawns[pawn] = nil
            end
        end

        local myTeamId = localPawn.TeamID or 0
        local allPawns = GetAllEnemies(localPawn)
        local processedCount = 0
        local cfg = _G.LexusConfig

        for _, enemy in ipairs(allPawns) do
            if processedCount >= MAX_PAWNS_PER_TICK then break end
            if not Valid(enemy) or enemy == localPawn then goto wh_continue end

            -- CRITICAL: Skip local player
            if type(enemy.IsLocallyControlled) == "function" and enemy:IsLocallyControlled() then goto wh_continue end
            if type(enemy.IsLocal) == "function" and enemy:IsLocal() then goto wh_continue end

            -- CRITICAL: Skip vehicles
            if IsVehicleActor(enemy) then goto wh_continue end

            if not IsPawnDead(enemy) and enemy.TeamID and enemy.TeamID ~= myTeamId then
                local isAI = ResolveIsAI(enemy)

                local eVisIdx = isAI and (cfg.ColorBotWHVis or 1) or (cfg.ColorEnemyWHVis or 0)
                local eOccIdx = isAI and (cfg.ColorBotWHOcc or 3) or (cfg.ColorEnemyWHOcc or 2)
                local stateKey = (_G._WH_ConfigVersion or 0) * 10000 + (isAI and 1000 or 0) + eVisIdx * 10 + eOccIdx

                local markData = _WH_MarkData[enemy]
                if not markData then
                    markData = {}
                    _WH_MarkData[enemy] = markData
                end

                local meshes = GetAllSkeletalMeshes(enemy, markData)
                if not meshes or #meshes == 0 then
                    meshes = {}
                    if Valid(enemy.Mesh) then meshes[1] = enemy.Mesh end
                end

                -- Hibernation: skip if nothing changed
                local meshCount = #meshes
                local stateHash = (isAI and 1 or 0) * 100000 + meshCount * 100 + stateKey
                if markData.LastHash == stateHash and markData.Applied and not _G._WH_ForceUpdate then
                    goto wh_continue -- 0% CPU
                end
                markData.LastHash = stateHash
                markData.Applied = true

                local vis = GetLinearColor(eVisIdx)
                local occ = GetLinearColor(eOccIdx)

                local count = 0
                for _, comp in ipairs(meshes) do
                    if count >= 14 then break end
                    if Valid(comp) then
                        DyeMesh(comp, vis, occ, stateKey)
                        count = count + 1
                    end
                end

                _WH_ModifiedPawns[enemy] = true
                processedCount = processedCount + 1
            end
            ::wh_continue::
        end
        _G._WH_ForceUpdate = nil
    end)
end

local function StartPBC()
    local timerOwner = GetActivePlayerController()
    if not Valid(timerOwner) or not timerOwner.AddGameTimer then return false end
    if _G.WH_TIMER and _G.WH_TIMER_OWNER == timerOwner then return true end
    if _G.WH_TIMER and Valid(_G.WH_TIMER_OWNER) and _G.WH_TIMER_OWNER.RemoveGameTimer then
        pcall(_G.WH_TIMER_OWNER.RemoveGameTimer, _G.WH_TIMER_OWNER, _G.WH_TIMER)
    end
    _G.WH_TIMER = nil
    SetupConsole()
    _G.WH_TIMER_OWNER = timerOwner
    _G.WH_TIMER = timerOwner:AddGameTimer(TICK_INTERVAL, true, PBCtick)
    return true
end

_pbc_Cleanup = function()
    if _G.WH_TIMER then
        if _G.WH_TIMER_OWNER and Valid(_G.WH_TIMER_OWNER) and _G.WH_TIMER_OWNER.RemoveGameTimer then
            pcall(_G.WH_TIMER_OWNER.RemoveGameTimer, _G.WH_TIMER_OWNER, _G.WH_TIMER)
        end
        pcall(function()
            local pc = GetActivePlayerController()
            if Valid(pc) and pc.RemoveGameTimer then pc:RemoveGameTimer(_G.WH_TIMER) end
        end)
        _G.WH_TIMER = nil
    end
    _G.WH_TIMER_OWNER = nil
    DisableConsole()
    ClearAllWallhackState()
    CONSOLE_READY = false
end
_G._pbc_Cleanup = _pbc_Cleanup
_G.StopWallhack = _pbc_Cleanup

function _G.StartNewWallhack()
    local timerOwner = GetActivePlayerController()
    if _G.WH_TIMER and _G.WH_TIMER_OWNER == timerOwner and Valid(timerOwner) then return end
    StartPBC()
end

-- ============================================================================
-- ============================================================================
--  SNAPLINE ESP SYSTEM (High-Performance DungLua Working Engine + Match2 Fix)
-- ============================================================================
local _ci_MeshComponent = import("MeshComponent") or import("SkeletalMeshComponent") or import("/Script/Engine.MeshComponent")
local _ci_KSL = UKismetSystemLibrary or import("KismetSystemLibrary")
local _ci_GameplayStatics = GameplayStatics or import("GameplayStatics")
local _ci_HitResultClass = import("HitResult") or import("/Script/Engine.HitResult")
local _ci_FVector = FVector or import("Vector") or import("/Script/CoreUObject.Vector")
local _ci_SBL = SlateBlueprintLibrary or import("SlateBlueprintLibrary") or import("/Script/UMG.SlateBlueprintLibrary")
local _ci_WLL = WidgetLayoutLibrary or import("WidgetLayoutLibrary") or import("/Script/UMG.WidgetLayoutLibrary")
local slua = _slua or rawget(_G, "slua") or slua or { isValid = Valid }
local UEnums = UEnums or rawget(_G, "UEnums") or { ESlateVisibility = { Collapsed = 1, SelfHitTestInvisible = 2 } }
local _cached_GameplayData = _cached_GameplayData or GameplayData

local FLinearColor = import("LinearColor") or _G.FLinearColor or LinearColor
local FVector2D = import("Vector2D") or _G.FVector2D
local FVector = import("Vector") or _G.FVector

local _SnaplinePawnsPool = {}
local _tempHeadLoc = FVector and FVector(0, 0, 0) or { X = 0, Y = 0, Z = 0 }
local CK_BOT_VIS, CK_BOT_HID = "BOT_VIS", "BOT_HID"
local CK_ENEMY_VIS, CK_ENEMY_HID = "ENEMY_VIS", "ENEMY_HID"

local SnaplineESP = {
    ESPCanvas = nil,
    _CurrentBaseUI = nil,
    SnapLineWidgets = {},
    _WidgetPool = {},
    bUseSnapLines = true,
    SnapLineThickness = 1.5,
    SnapLineOriginY = 50.0,
    SnapLineOriginOffsetX = 0.0,
    SnapLineHeadOffsetX = 0.0,
    SnapLineHeadOffsetY = -14.0,
    SnapLineEnemyColor = FLinearColor and FLinearColor(1.0, 0.15, 0.15, 0.85) or nil,        -- Red (Invisible Enemy)
    SnapLineEnemyVisibleColor = FLinearColor and FLinearColor(0.0, 1.0, 0.2, 0.95) or nil,  -- Green (Visible Enemy)
    SnapLineBotColor = FLinearColor and FLinearColor(1.0, 1.0, 1.0, 0.85) or nil,           -- White (Invisible Bot)
    SnapLineBotVisibleColor = FLinearColor and FLinearColor(0.0, 0.9, 1.0, 0.95) or nil,   -- Cyan (Visible Bot)
    _CanvasScaleX = 1.0,
    _CanvasScaleY = 1.0,
    _CanvasOffsetX = 0.0,
    _CanvasOffsetY = 0.0,
    _lastTransformTime = 0,
    _CachedTopCenterPixel = FVector2D and FVector2D(0, 0) or { X = 0, Y = 0 },
    _cachedViewportW = 1920,
    _cachedViewportH = 1080,
    _CachedFromX = 0,
    _CachedFromY = 0,
    _lastStartPosTime = 0,
    _tempScreenPixelPos = FVector2D and FVector2D(0, 0) or { X = 0, Y = 0 },
    _tempCanvasPos = FVector2D and FVector2D(0, 0) or { X = 0, Y = 0 },
    _ZeroVector = nil,
    _CachedHitResult = nil,
}
_G.SnaplineESP = SnaplineESP

-- Self-contained helper methods with module-level caching and multi-match fallback
function SnaplineESP.GetMyControllerAndPlayer()
    local pc, player = nil, nil
    local GDP = _cached_GameplayData
    if not GDP then
        local ok; ok, GDP = pcall(require, "GameLua.GameCore.Data.GameplayData")
        if ok then _cached_GameplayData = GDP end
    end
    if GDP then
        if GDP.GetPlayerController then pc = GDP.GetPlayerController() end
        if GDP.GetPlayerCharacter then player = GDP.GetPlayerCharacter() end
    end
    if (not pc or not slua.isValid(pc)) and slua_GameFrontendHUD then
        pcall(function() pc = slua_GameFrontendHUD:GetPlayerController() end)
    end
    if (not pc or not slua.isValid(pc)) and GetActivePlayerController then
        pc = GetActivePlayerController()
    end
    if pc and (not player or not slua.isValid(player)) and pc.GetPlayerCharacterSafety then
        pcall(function() player = pc:GetPlayerCharacterSafety() end)
    end
    if pc and (not player or not slua.isValid(player)) and pc.GetPawn then
        pcall(function() player = pc:GetPawn() end)
    end
    if (not player or not slua.isValid(player)) and GetLocalPlayer then
        player = GetLocalPlayer(pc)
    end
    return pc, player
end

function SnaplineESP.GetAllPawns()
    -- Zero-allocation table pool (returns valid Lua array for # and ipairs compatibility)
    for i = 1, #_SnaplinePawnsPool do _SnaplinePawnsPool[i] = nil end
    local count = 0
    pcall(function()
        local g = _G.Game or Game
        if g and g.GetAllPlayerPawns then
            local pawns = g:GetAllPlayerPawns()
            if pawns then
                for _, p in pairs(pawns) do
                    if p and slua.isValid(p) then
                        count = count + 1
                        _SnaplinePawnsPool[count] = p
                    end
                end
            end
        end
    end)
    if count == 0 then
        pcall(function()
            local ok, GS = pcall(require, "GameLua.GameCore.Data.CGameState")
            if ok and GS and GS.GetAllCharacters then
                local chars = GS:GetAllCharacters()
                if chars then
                    for _, c in pairs(chars) do
                        if c and slua.isValid(c) then
                            count = count + 1
                            _SnaplinePawnsPool[count] = c
                        end
                    end
                end
            end
        end)
    end
    return _SnaplinePawnsPool
end

function SnaplineESP.ClearAllSnapLines()
    for KeyStr, LineData in pairs(SnaplineESP.SnapLineWidgets) do
        if LineData and LineData.Widget and slua.isValid(LineData.Widget) then
            pcall(function() LineData.Widget:SetWidgetVisibility(UEnums.ESlateVisibility.Collapsed) end)
            local pool = SnaplineESP._WidgetPool
            if not pool then pool = {}; SnaplineESP._WidgetPool = pool end
            table.insert(pool, LineData)
        end
    end
    SnaplineESP.SnapLineWidgets = {}
end
SnaplineESP.Clear = SnaplineESP.ClearAllSnapLines

function SnaplineESP.Reset()
    SnaplineESP.ClearAllSnapLines()
    SnaplineESP.ESPCanvas = nil
    SnaplineESP._WidgetPool = {}
    SnaplineESP._CurrentBaseUI = nil
    SnaplineESP._lastTransformTime = 0
    SnaplineESP._lastStartPosTime = 0
    SnaplineESP._CachedFromX = 0
    SnaplineESP._CachedFromY = 0
end

function SnaplineESP.InitESPCanvas()
    local ok, InGameUITools = pcall(require, "GameLua.Mod.BaseMod.Common.UI.InGameUITools")
    if not ok or not InGameUITools then return false end
    local MainControlBaseUI = nil
    pcall(function() MainControlBaseUI = InGameUITools.GetMainControlBaseUI and InGameUITools.GetMainControlBaseUI() end)
    if not MainControlBaseUI or not slua.isValid(MainControlBaseUI) then return false end

    -- Match switch detection: if MainControlBaseUI changed, the previous canvas is dead!
    if SnaplineESP._CurrentBaseUI ~= MainControlBaseUI then
        SnaplineESP.Reset()
        SnaplineESP._CurrentBaseUI = MainControlBaseUI
    end

    if SnaplineESP.ESPCanvas and slua.isValid(SnaplineESP.ESPCanvas) then return true end

    local ParentCanvas = nil
    if MainControlBaseUI.CanvasPanel_0 and slua.isValid(MainControlBaseUI.CanvasPanel_0) then 
        ParentCanvas = MainControlBaseUI.CanvasPanel_0
    elseif MainControlBaseUI.CanvasPanel_42 and slua.isValid(MainControlBaseUI.CanvasPanel_42) then 
        ParentCanvas = MainControlBaseUI.CanvasPanel_42 
    end

    if not ParentCanvas or not slua.isValid(ParentCanvas) then return false end
    SnaplineESP.ESPCanvas = ParentCanvas
    return true
end

function SnaplineESP.UpdateCanvasTransform(PC)
    if not SnaplineESP.ESPCanvas or not slua.isValid(SnaplineESP.ESPCanvas) then return end
    local now = os.clock()
    if SnaplineESP._lastTransformTime and (now - SnaplineESP._lastTransformTime < 1.0) and SnaplineESP._CanvasScaleX and SnaplineESP._CanvasScaleX > 0 then
        return
    end
    SnaplineESP._lastTransformTime = now

    local success = false
    pcall(function()
        local SBL = _ci_SBL
        if SBL and SBL.AbsoluteToLocal then
            local cg = SnaplineESP.ESPCanvas:GetCachedGeometry()
            if cg then
                if not SnaplineESP._tempScreenPixelPos then SnaplineESP._tempScreenPixelPos = FVector2D and FVector2D(0, 0) or {X=0, Y=0} end
                SnaplineESP._tempScreenPixelPos.X = 0; SnaplineESP._tempScreenPixelPos.Y = 0
                local pt0 = SBL.AbsoluteToLocal(cg, SnaplineESP._tempScreenPixelPos)
                SnaplineESP._tempScreenPixelPos.X = 100; SnaplineESP._tempScreenPixelPos.Y = 100
                local pt1 = SBL.AbsoluteToLocal(cg, SnaplineESP._tempScreenPixelPos)
                if pt0 and pt1 then
                    SnaplineESP._CanvasScaleX = (pt1.X - pt0.X) / 100
                    SnaplineESP._CanvasScaleY = (pt1.Y - pt0.Y) / 100
                    SnaplineESP._CanvasOffsetX = pt0.X
                    SnaplineESP._CanvasOffsetY = pt0.Y
                    success = true
                end
            end
        end
    end)

    if not success then
        pcall(function()
            local WLL = _ci_WLL
            if WLL and WLL.ScreenToWidgetLocal then
                local cg = SnaplineESP.ESPCanvas:GetCachedGeometry()
                if cg then
                    local pt0 = FVector2D and FVector2D(0, 0) or {X=0, Y=0}
                    local pt1 = FVector2D and FVector2D(0, 0) or {X=0, Y=0}
                    local in0 = FVector2D and FVector2D(0, 0) or {X=0, Y=0}
                    local in1 = FVector2D and FVector2D(100, 100) or {X=100, Y=100}
                    WLL.ScreenToWidgetLocal(PC, cg, in0, pt0)
                    WLL.ScreenToWidgetLocal(PC, cg, in1, pt1)
                    SnaplineESP._CanvasScaleX = (pt1.X - pt0.X) / 100
                    SnaplineESP._CanvasScaleY = (pt1.Y - pt0.Y) / 100
                    SnaplineESP._CanvasOffsetX = pt0.X
                    SnaplineESP._CanvasOffsetY = pt0.Y
                    success = true
                end
            end
        end)
    end

    if not success then
        local scale = 1.0
        local WLL = _ci_WLL
        if WLL and WLL.GetViewportScale then scale = WLL.GetViewportScale(PC) or 1.0 end
        SnaplineESP._CanvasScaleX = 1.0 / scale
        SnaplineESP._CanvasScaleY = 1.0 / scale
        SnaplineESP._CanvasOffsetX = 0
        SnaplineESP._CanvasOffsetY = 0
    end
end

function SnaplineESP.ScreenPixelToCanvasLocal(PC, ScreenPixelPos)
    if not ScreenPixelPos then return SnaplineESP._tempCanvasPos end
    local scaleX = SnaplineESP._CanvasScaleX or 1.0
    local scaleY = SnaplineESP._CanvasScaleY or 1.0
    local offsetX = SnaplineESP._CanvasOffsetX or 0
    local offsetY = SnaplineESP._CanvasOffsetY or 0
    local x = ScreenPixelPos.X * scaleX + offsetX
    local y = ScreenPixelPos.Y * scaleY + offsetY
    if not SnaplineESP._tempCanvasPos then
        SnaplineESP._tempCanvasPos = (FVector2D and FVector2D(x, y)) or {X = x, Y = y}
    else
        SnaplineESP._tempCanvasPos.X = x
        SnaplineESP._tempCanvasPos.Y = y
    end
    return SnaplineESP._tempCanvasPos
end

function SnaplineESP.ProjectWorldToCanvasLocal(PC, WorldLoc)
    if not PC or not slua.isValid(PC) or not WorldLoc then return false, SnaplineESP._tempCanvasPos end
    if not SnaplineESP._tempScreenPixelPos then SnaplineESP._tempScreenPixelPos = FVector2D and FVector2D(0, 0) or {X=0, Y=0} end
    SnaplineESP._tempScreenPixelPos.X = 0; SnaplineESP._tempScreenPixelPos.Y = 0
    local bOK = false
    pcall(function()
        local res = PC:ProjectWorldLocationToScreen(WorldLoc, SnaplineESP._tempScreenPixelPos, true)
        if res == true or res == 1 then bOK = true end
    end)
    if not bOK or (SnaplineESP._tempScreenPixelPos.X == 0 and SnaplineESP._tempScreenPixelPos.Y == 0) then return false, SnaplineESP._tempCanvasPos end
    local CanvasLocalPos = SnaplineESP.ScreenPixelToCanvasLocal(PC, SnaplineESP._tempScreenPixelPos)
    return true, CanvasLocalPos
end

function SnaplineESP.GetSnapLineStartPos(PC)
    local now = os.clock()
    if SnaplineESP._lastStartPosTime and (now - SnaplineESP._lastStartPosTime < 0.5) and SnaplineESP._CachedFromX and SnaplineESP._CachedFromX > 0 then
        return SnaplineESP._CachedFromX, SnaplineESP._CachedFromY
    end
    SnaplineESP._lastStartPosTime = now

    local screenPixelW, screenPixelH = 0, 0
    local scale = 1.0

    pcall(function()
        if PC and PC.GetViewportSize then
            local vs = SnaplineESP._tempScreenPixelPos or (FVector2D and FVector2D(0, 0) or {X=0,Y=0})
            PC:GetViewportSize(vs)
            if vs and vs.X and vs.X > 200 then screenPixelW = vs.X; screenPixelH = vs.Y end
        end
    end)
    if screenPixelW <= 200 then
        pcall(function()
            local WLL = _ci_WLL
            if WLL and WLL.GetViewportSize then
                local vs = WLL.GetViewportSize(PC)
                if vs and vs.X and vs.X > 200 then screenPixelW = vs.X; screenPixelH = vs.Y end
            end
        end)
    end
    pcall(function()
        local WLL = _ci_WLL
        if WLL and WLL.GetViewportScale then
            local s = WLL.GetViewportScale(PC)
            if s and type(s) == "number" and s > 0 then scale = s end
        end
    end)
    if screenPixelW <= 200 then
        screenPixelW = (SnaplineESP._cachedViewportW or 1920) * scale
        screenPixelH = (SnaplineESP._cachedViewportH or 1080) * scale
    end

    if not SnaplineESP._CachedTopCenterPixel then SnaplineESP._CachedTopCenterPixel = FVector2D and FVector2D(0, 0) or {X=0,Y=0} end
    SnaplineESP._CachedTopCenterPixel.X = screenPixelW / 2.0
    SnaplineESP._CachedTopCenterPixel.Y = (SnaplineESP.SnapLineOriginY or 50) * scale

    local fromCanvasPos = SnaplineESP.ScreenPixelToCanvasLocal(PC, SnaplineESP._CachedTopCenterPixel)
    local fromX = fromCanvasPos.X + (SnaplineESP.SnapLineOriginOffsetX or 0)
    local fromY = fromCanvasPos.Y

    SnaplineESP._CachedFromX = fromX
    SnaplineESP._CachedFromY = fromY
    return fromX, fromY
end

function SnaplineESP.CreateSnapLine()
    if not SnaplineESP.InitESPCanvas() then return nil end
    
    local pool = SnaplineESP._WidgetPool
    if not pool then
        pool = {}
        SnaplineESP._WidgetPool = pool
    end
    
    local Border = nil
    local Slot = nil
    
    -- Try to get from pool, verifying widget is attached to current canvas
    for i = #pool, 1, -1 do
        local pooled = pool[i]
        if pooled and pooled.Widget and slua.isValid(pooled.Widget) and pooled.Slot and slua.isValid(pooled.Slot) then
            local isCurrent = false
            pcall(function()
                if pooled.Widget.GetParent and pooled.Widget:GetParent() == SnaplineESP.ESPCanvas then
                    isCurrent = true
                end
            end)
            if isCurrent then
                Border = pooled.Widget
                Slot = pooled.Slot
                table.remove(pool, i)
                break
            else
                table.remove(pool, i)
            end
        else
            table.remove(pool, i)
        end
    end
    
    -- Create new if pool empty or belonged to old match canvas
    if not Border or not slua.isValid(Border) then
        pcall(function() Border = CGame:NewObjectFromPath("/Script/UMG.Border", SnaplineESP.ESPCanvas) end)
        if not Border or not slua.isValid(Border) then
            pcall(function() Border = CGame.NewObjectFromPath("/Script/UMG.Border", SnaplineESP.ESPCanvas) end)
        end
        Slot = nil
    end
    if not Border or not slua.isValid(Border) then return nil end

    local color = SnaplineESP.SnapLineEnemyColor or (FLinearColor and FLinearColor(1.0, 0.15, 0.15, 0.85) or nil)
    if color then pcall(function() Border:SetBrushColor(color) end) end
    pcall(function() Border:SetWidgetVisibility(UEnums.ESlateVisibility.SelfHitTestInvisible) end)
    pcall(function() Border.RenderTransformPivot = FVector2D and FVector2D(0.0, 0.5) or {X=0,Y=0.5} end)
    pcall(function() Border:SetRenderTransformPivot(FVector2D and FVector2D(0.0, 0.5) or {X=0,Y=0.5}) end)

    if not Slot or not slua.isValid(Slot) then
        pcall(function()
            Slot = SnaplineESP.ESPCanvas:AddChildToCanvas(Border)
            if Slot then Slot:SetAutoSize(false); Slot:SetZOrder(1) end
        end)
    end
    return { Widget = Border, Slot = Slot }
end

function SnaplineESP.IsPlayerVisible(PC, Character)
    if not PC or not slua.isValid(PC) or not Character or not slua.isValid(Character) then return false end
    local now = os.clock()
    if Character._lastVisTime and (now - Character._lastVisTime) < 0.6 then
        return Character._cachedIsVisible or false
    end
    Character._lastVisTime = now
    local bVis = false
    pcall(function()
        if PC.LineOfSightTo then
            if not SnaplineESP._ZeroVector then
                local VT = _ci_FVector
                if VT then SnaplineESP._ZeroVector = VT(0, 0, 0) end
            end
            bVis = PC:LineOfSightTo(Character, SnaplineESP._ZeroVector, false)
        end
    end)
    if not bVis then
        local KismetSystemLibrary = _ci_KSL
        if KismetSystemLibrary and KismetSystemLibrary.LineTraceSingle then
            pcall(function()
                local camMgr = nil
                local GameplayStatics = _ci_GameplayStatics
                if GameplayStatics and GameplayStatics.GetPlayerCameraManager then
                    camMgr = GameplayStatics.GetPlayerCameraManager(PC, 0)
                end
                local startLoc = camMgr and camMgr:GetCameraLocation() or (PC.GetPlayerCharacter and PC:GetPlayerCharacter() and PC:GetPlayerCharacter():K2_GetActorLocation())
                local loc = Character.K2_GetActorLocation and Character:K2_GetActorLocation()
                if startLoc and loc then
                    local hOffset = 75
                    if Character.bIsCrouched then hOffset = 50
                    elseif Character.IsProne and Character:IsProne() then hOffset = 25 end
                    _tempHeadLoc.X = loc.X; _tempHeadLoc.Y = loc.Y; _tempHeadLoc.Z = loc.Z + hOffset
                    if not SnaplineESP._CachedHitResult then
                        local HitResultClass = _ci_HitResultClass
                        SnaplineESP._CachedHitResult = HitResultClass and HitResultClass() or {}
                    end
                    local bHit = KismetSystemLibrary.LineTraceSingle(PC, startLoc, _tempHeadLoc, 0, false, nil, 0, SnaplineESP._CachedHitResult, true)
                    if bHit then
                        local hitActor = nil
                        if type(SnaplineESP._CachedHitResult.GetActor) == "function" then hitActor = SnaplineESP._CachedHitResult:GetActor()
                        elseif SnaplineESP._CachedHitResult.Actor then hitActor = SnaplineESP._CachedHitResult.Actor end
                        if hitActor and (hitActor == Character or (type(hitActor.IsChildOf) == "function" and hitActor:IsChildOf(Character))) then
                            bVis = true
                        end
                    else
                        bVis = true
                    end
                end
            end)
        end
    end
    Character._cachedIsVisible = bVis
    return bVis
end

function SnaplineESP.UpdateSnapLine(KeyStr, CanvasPos, bOnScreen, fromX, fromY, Character, PC, isAI)
    if not SnaplineESP.ESPCanvas or not slua.isValid(SnaplineESP.ESPCanvas) then return end

    local LineData = SnaplineESP.SnapLineWidgets[KeyStr]

    if not bOnScreen or not CanvasPos or not Character or not slua.isValid(Character) or not PC or not slua.isValid(PC) then
        if LineData and LineData.Widget and slua.isValid(LineData.Widget) then
            pcall(function() LineData.Widget:SetWidgetVisibility(UEnums.ESlateVisibility.Collapsed) end)
        end
        return
    end

    local bIsNew = false
    if not LineData then
        LineData = SnaplineESP.CreateSnapLine()
        if not LineData or not LineData.Widget or not LineData.Slot then return end
        SnaplineESP.SnapLineWidgets[KeyStr] = LineData
        bIsNew = true
    end

    local Widget = LineData.Widget
    local Slot = LineData.Slot

    pcall(function() Widget:SetWidgetVisibility(UEnums.ESlateVisibility.SelfHitTestInvisible) end)

    if not LineData._PivotSet then
        pcall(function() Widget.RenderTransformPivot = FVector2D and FVector2D(0.0, 0.5) or {X=0,Y=0.5} end)
        pcall(function() Widget:SetRenderTransformPivot(FVector2D and FVector2D(0.0, 0.5) or {X=0,Y=0.5}) end)
        LineData._PivotSet = true
    end

    local bTargetVisible = SnaplineESP.IsPlayerVisible(PC, Character)
    local lineColor
    local cfg = _G.LexusConfig
    if cfg and cfg.WallHackEnabled then
        local colorIdx
        if isAI then
            colorIdx = bTargetVisible and (cfg.ColorBotWHVis or 1) or (cfg.ColorBotWHOcc or 3)
        else
            colorIdx = bTargetVisible and (cfg.ColorEnemyWHVis or 0) or (cfg.ColorEnemyWHOcc or 2)
        end
        lineColor = GetSnaplineColor(colorIdx, 0.95)
    else
        if isAI then
            lineColor = bTargetVisible and SnaplineESP.SnapLineBotVisibleColor or SnaplineESP.SnapLineBotColor
        else
            lineColor = bTargetVisible and SnaplineESP.SnapLineEnemyVisibleColor or SnaplineESP.SnapLineEnemyColor
        end
    end

    local colorKey = isAI and (bTargetVisible and CK_BOT_VIS or CK_BOT_HID) or (bTargetVisible and CK_ENEMY_VIS or CK_ENEMY_HID)
    if LineData._cachedColorKey ~= colorKey and lineColor then
        pcall(function() Widget:SetBrushColor(lineColor) end)
        LineData._cachedColorKey = colorKey
    end

    local toX = CanvasPos.X + (SnaplineESP.SnapLineHeadOffsetX or 0)
    local toY = CanvasPos.Y + (SnaplineESP.SnapLineHeadOffsetY or 0)

    local dx = toX - fromX
    local dy = toY - fromY
    local length = math.sqrt(dx * dx + dy * dy)
    local thickness = SnaplineESP.SnapLineThickness or 1.5

    local angle_rad = (math.atan2 and math.atan2(dy, dx)) or math.atan(dy, dx)
    local angle = angle_rad * 57.29577951308232

    if not LineData._CachedPosVec then
        LineData._CachedPosVec = FVector2D and FVector2D(fromX, fromY - thickness / 2.0) or {X=fromX, Y=fromY - thickness / 2.0}
        LineData._CachedSizeVec = FVector2D and FVector2D(length, thickness) or {X=length, Y=thickness}
    else
        LineData._CachedPosVec.X = fromX; LineData._CachedPosVec.Y = fromY - thickness / 2.0
        LineData._CachedSizeVec.X = length; LineData._CachedSizeVec.Y = thickness
    end

    pcall(function() 
        Slot:SetPosition(LineData._CachedPosVec) 
        Slot:SetSize(LineData._CachedSizeVec)
        if bIsNew then Slot:SetZOrder(1) end
    end)
    pcall(function() Widget:SetRenderAngle(angle) end)
end

function SnaplineESP.RemoveSnapLine(KeyStr)
    local LineData = SnaplineESP.SnapLineWidgets[KeyStr]
    if LineData and LineData.Widget and slua.isValid(LineData.Widget) then
        pcall(function() LineData.Widget:SetWidgetVisibility(UEnums.ESlateVisibility.Collapsed) end)
        local pool = SnaplineESP._WidgetPool
        if not pool then pool = {}; SnaplineESP._WidgetPool = pool end
        table.insert(pool, LineData)
        SnaplineESP.SnapLineWidgets[KeyStr] = nil
    end
end

local _SnaplineSeen = {}
local function Tick_SnaplineESP()
    if not (_G.LexusConfig and _G.LexusConfig.SnaplineESPEnabled) then
        SnaplineESP.ClearAllSnapLines()
        return
    end

    local pc, localPawn = SnaplineESP.GetMyControllerAndPlayer()
    if not pc or not slua.isValid(pc) or not localPawn or not slua.isValid(localPawn) then return end

    local myPos = nil
    pcall(function() myPos = localPawn:K2_GetActorLocation() end)
    if not myPos then return end

    local myTeamId = nil
    pcall(function() myTeamId = localPawn.TeamID or (localPawn.GetTeamID and localPawn:GetTeamID()) end)

    if not SnaplineESP.InitESPCanvas() then return end
    SnaplineESP.UpdateCanvasTransform(pc)

    -- SnaplineESP uses Lua array table (_SnaplinePawnsPool) for # and ipairs compatibility.
    local allPawns = SnaplineESP.GetAllPawns()
    if not allPawns or #allPawns == 0 then return end

    local fromX, fromY = SnaplineESP.GetSnapLineStartPos(pc)

    for k in pairs(_SnaplineSeen) do _SnaplineSeen[k] = nil end

    for _, pawn in ipairs(allPawns) do
        if not pawn or not slua.isValid(pawn) or pawn == localPawn then goto continue end
        local hs = pawn.HealthStatus
        if not (pawn.TeamID and (myTeamId == nil or pawn.TeamID ~= myTeamId) and hs and hs ~= 2 and hs ~= 3) then goto continue end

        local pKey = pawn.PlayerKey
        if not pKey or pKey == 0 then goto continue end  -- Skip if no valid PlayerKey
        local isAI = ResolveIsAI(pKey, pawn)  -- [OPT-P2] Centralized AI helper

        local pLoc = nil
        pcall(function() pLoc = pawn:K2_GetActorLocation() end)
        if not pLoc then goto continue end

        local dx = pLoc.X - myPos.X
        local dy = pLoc.Y - myPos.Y
        local dz = pLoc.Z - myPos.Z
        local distSq = dx * dx + dy * dy + dz * dz
        if distSq <= 0 or distSq > 1600000000 then goto continue end

        local hOffset = 75
        if pawn.bIsCrouched then hOffset = 50
        elseif pawn.IsProne and pawn:IsProne() then hOffset = 25 end
        _tempHeadLoc.X = pLoc.X; _tempHeadLoc.Y = pLoc.Y; _tempHeadLoc.Z = pLoc.Z + hOffset

        local bOnScreen, CanvasPos = SnaplineESP.ProjectWorldToCanvasLocal(pc, _tempHeadLoc)
        local key = tostring(pKey)

        _SnaplineSeen[key] = true
        SnaplineESP.UpdateSnapLine(key, CanvasPos, bOnScreen, fromX, fromY, pawn, pc, isAI)
        ::continue::
    end

    for key, LineData in pairs(SnaplineESP.SnapLineWidgets) do
        if not _SnaplineSeen[key] then
            if LineData and LineData.Widget and slua.isValid(LineData.Widget) then
                pcall(function() LineData.Widget:SetWidgetVisibility(UEnums.ESlateVisibility.Collapsed) end)
            end
        end
    end
end

-- Self-contained independent Snapline timer loop (Pure C++ AddGameTimer, no time_ticker)
_G._SnaplineLoopRunning = false
_G._snaplineTimerStarted = false
_G._snaplineTimerHandle = nil
_G._snaplineTimerOwner = nil

local function StartSnaplineLoop(passedOwner)
    -- If timer owner is dead or detached, clean it first
    if _G._snaplineTimerStarted and _G._snaplineTimerOwner and not Valid(_G._snaplineTimerOwner) then
        _G.StopSnaplineLoop()
    end
    if _G._snaplineTimerStarted and _G._snaplineTimerHandle then return end

    local timerOwner = nil
    if _G.Game and _G.Game.AddGameTimer then
        timerOwner = _G.Game
    elseif passedOwner and passedOwner.AddGameTimer and Valid(passedOwner) then
        timerOwner = passedOwner
    else
        local pc = GetActivePlayerController and GetActivePlayerController()
        if Valid(pc) and pc.AddGameTimer then timerOwner = pc end
        if not timerOwner and slua_GameFrontendHUD then
            pcall(function()
                local pc2 = slua_GameFrontendHUD:GetPlayerController()
                if Valid(pc2) and pc2.AddGameTimer then timerOwner = pc2 end
            end)
        end
    end

    if not Valid(timerOwner) or not timerOwner.AddGameTimer then return end

    local ok, h = pcall(function()
        return timerOwner:AddGameTimer(0.1, true, function()
            pcall(Tick_SnaplineESP)
        end)
    end)

    if ok and h then
        _G._snaplineTimerHandle = h
        _G._snaplineTimerOwner = timerOwner
        _G._snaplineTimerStarted = true
        _G._SnaplineLoopRunning = true
    end
end

local function StopSnaplineLoop()
    _G._SnaplineLoopRunning = false
    _G._snaplineTimerStarted = false

    if _G._snaplineTimerHandle and _G._snaplineTimerOwner and Valid(_G._snaplineTimerOwner) then
        pcall(function()
            if _G._snaplineTimerOwner.RemoveGameTimer then
                _G._snaplineTimerOwner:RemoveGameTimer(_G._snaplineTimerHandle)
            end
        end)
    end
    _G._snaplineTimerHandle = nil
    _G._snaplineTimerOwner = nil

    if SnaplineESP and SnaplineESP.Reset then
        pcall(SnaplineESP.Reset)
    end
end

_G.StartSnaplineLoop = StartSnaplineLoop
_G.StopSnaplineLoop = StopSnaplineLoop
_G.ClearAllSnapLines = function() if SnaplineESP and SnaplineESP.Reset then SnaplineESP.Reset() end end
_G.Tick_SnaplineESP = Tick_SnaplineESP
_G.PlayerMapMarker = SnaplineESP

-- ============================================================================
-- MATCH DETECTION & VIP MOD MENU SETUP
-- ============================================================================
local function StartMatchFeatures(pc, pawn)
    pcall(InitMapTracking)
    pcall(ApplyEnvironment)
    if _G.LexusConfig.AimAssistEnabled then ApplyAimAssist(true) end
    if _G.LexusConfig.NoRecoilEnabled then ApplyNoRecoil(true) end
    if _G.LexusConfig.iPadViewEnabled then ApplyiPadView(true) end
    -- ESP Timers (HP, Box, Map, Counter)
    if _G.LexusConfig.ESP_All then
        StartESPTimers(pc)
    end
    -- Vehicle ESP (Independent)
    if _G.LexusConfig.VehicleESPEnabled then
        StartVehicleTimer(pc)
    end
    -- Loot ESP (Independent)
    if _G.LexusConfig.LootESPEnabled then
        StartLootTimer(pc)
    end
    -- Wallhack
    if _G.LexusConfig.WallHackEnabled and not _G.WH_TIMER then
        _G.StartNewWallhack()
    end
    -- Snapline ESP
    if _G.LexusConfig.SnaplineESPEnabled then
        if _G.StartSnaplineLoop then _G.StartSnaplineLoop(pc) end
    end
end


local function ApplyFPSLimit(targetFps)
    targetFps = tonumber(targetFps) or (_G.LexusConfig and _G.LexusConfig.TargetFPS) or 165
    _G.LexusConfig.TargetFPS = targetFps
    pcall(function()
        local ui_util = pcall(require, "client.common.ui_util") and require("client.common.ui_util")
        local gi = (slua_GameFrontendHUD and slua_GameFrontendHUD.GetGameInstance and slua_GameFrontendHUD:GetGameInstance())
            or (ui_util and ui_util.GetGameInstance and ui_util.GetGameInstance())
            or (_G.GameInstance)
            or (GameplayStatics and GameplayStatics.GetGameInstance and _slua and _slua.getWorld and GameplayStatics.GetGameInstance(_slua.getWorld()))
        if gi and gi.ExecuteCMD then
            local fpsStr = tostring(targetFps)
            gi:ExecuteCMD("t.MaxFPS", fpsStr)
            gi:ExecuteCMD("r.FrameRateLimit", fpsStr)
        end
    end)
    _G.LexusState.DirtyConfig = true
end
_G.ApplyFPSLimit = ApplyFPSLimit

function _G.InitModMenuTab()
    if _G.ModMenuInitialized then return end
    _G.ModMenuInitialized = true
    _G.LexusState.CustomTextData = _G.LexusState.CustomTextData or {
        SkinSuit = 1, SkinBag = 1, SkinHelmet = 1,
        SkinM416 = 1, SkinAKM = 1, SkinSCAR = 1, SkinM762 = 1, SkinAUG = 1, SkinUMP = 1,
        SkinUZI = 1, SkinGroza = 1, SkinS12K = 1, SkinDBS = 1, SkinASM = 1, SkinQBZ = 1,
        SkinHoney = 1, SkinM16A4 = 1, SkinACE32 = 1, SkinKar98k = 1, SkinM24 = 1, SkinAWM = 1,
        SkinDacia = 1, SkinUAZ = 1, SkinCoupe = 1, SkinBuggy = 1, SkinMirado = 1,
        AimPower = 50,
        iPadViewFOV = 110
    }
    local LocUtil = _G.LocUtil
    if not LocUtil and package.loaded["client.common.LocUtil"] then
        LocUtil = require("client.common.LocUtil")
    end
    local FakeTextMap = {
        [999000] = "ULTIMATE VIP MENU",
        [999001] = "Visuals & ESP",
        [999005] = "Vehicle & Loot",
        [999002] = "Combat & Aim",
        [999003] = "Graphics & FPS",
        [999004] = "Skins & Outfits"
    }
    if LocUtil and not LocUtil._IsModMenuHooked then
        local hookFuncs = {"GetLocalizeResStr", "GetText", "GetTextByID", "GetLocalText", "GetLocalizeStr", "ResolveText"}
        for _, funcName in ipairs(hookFuncs) do
            if LocUtil[funcName] then
                local old_func = LocUtil[funcName]
                LocUtil[funcName] = function(id)
                    if FakeTextMap[id] then return FakeTextMap[id] end
                    if type(id) == "string" and not tonumber(id) then return id end
                    if old_func then return old_func(id) end
                    return ""
                end
            end
        end
        LocUtil._IsModMenuHooked = true
    end

    local SettingPageDefine = require("client.logic.NewSetting.SettingPageDefine")
    local SettingCatalog = require("client.logic.NewSetting.SettingCatalog")
    local AliasMap = require("client.slua.umg.NewSetting.Item.AliasMap")

    local function HandleToggle(key, v, onEnable, onDisable)
        local val = (v ~= nil) and v or false
        if type(val) ~= "boolean" then val = (val == true or val == 1) end
        _G.LexusConfig[key] = val
        if val then
            if onEnable then pcall(onEnable) end
        else
            if onDisable then pcall(onDisable) end
        end
        _G.LexusState.DirtyConfig = true
        return true
    end

    local colNames = {"Red", "Cyan", "Yellow", "Green", "Purple", "White"}
    local colVals = {0, 1, 2, 3, 4, 5}

        local StackESP = {
        { UI = AliasMap.Title, Text = "--- PLAYER VISUALS ---" },
        { Key = "ModMenu_ESP_All", UI = AliasMap.Switcher, Text = "Player ESP (Master Switch)", ExpandIndex = 0,
          GetFunc = function() return _G.LexusConfig.ESP_All end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("ESP_All", val, 
                  function() local pc = GetActivePlayerController(); if pc and StartESPTimers then StartESPTimers(pc) end end,
                  function() if ClearESPTimers then ClearESPTimers() end; ClearAll1006Marks(); ClearAllMapMarks(); ClearAllBoxESP(); DestroyCounterWidget() end
              )
          end 
        },
        { Key = "ModMenu_ESP_Box", UI = AliasMap.Switcher, Text = "   Box ESP (Player Bounds)", ExpandHandle = "ModMenu_ESP_All", 
          GetFunc = function() return _G.LexusConfig.BoxESPEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("BoxESPEnabled", val, nil, ClearAllBoxESP)
          end 
        },
        { Key = "ModMenu_ESP_HealthBar", UI = AliasMap.Switcher, Text = "   Health Bar (Wall Penetrating)", ExpandHandle = "ModMenu_ESP_All", 
          GetFunc = function() return _G.LexusConfig.HealthBarESPEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("HealthBarESPEnabled", val, nil, ClearAll1006Marks)
          end 
        },
        { Key = "ModMenu_ESP_Counter", UI = AliasMap.Switcher, Text = "   Enemy Counter (Nearby Threats)", ExpandHandle = "ModMenu_ESP_All", 
          GetFunc = function() return _G.LexusConfig.EnemyCounterEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("EnemyCounterEnabled", val, nil, DestroyCounterWidget)
          end 
        },
        { Key = "ModMenu_ESP_Map", UI = AliasMap.Switcher, Text = "   MiniMap Radar Tracker", ExpandHandle = "ModMenu_ESP_All", 
          GetFunc = function() return _G.LexusConfig.MapESPEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("MapESPEnabled", val, nil, ClearAllMapMarks)
          end 
        },
        { Key = "ModMenu_Snapline", UI = AliasMap.Switcher, Text = "   Snapline Tracer (Visibility Check)", ExpandHandle = "ModMenu_ESP_All",
          GetFunc = function() return _G.LexusConfig.SnaplineESPEnabled end,
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("SnaplineESPEnabled", val,
                  function() local pc = GetActivePlayerController(); if _G.StartSnaplineLoop then _G.StartSnaplineLoop(pc) end end,
                  function() if _G.StopSnaplineLoop then _G.StopSnaplineLoop() end end
              )
          end
        },
        { UI = AliasMap.Title, Text = "--- CHAMS WALLHACK ---" },
        { Key = "ModMenu_WallHack", UI = AliasMap.Switcher, Text = "Chams Wallhack (X-Ray Vision)", ExpandIndex = 0,
          GetFunc = function() return _G.LexusConfig.WallHackEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("WallHackEnabled", val, 
                  function() if _G.StartNewWallhack then _G.StartNewWallhack() end end, 
                  function() if _G._pbc_Cleanup then _G._pbc_Cleanup() elseif _pbc_Cleanup then _pbc_Cleanup() end end
              )
          end 
        },
        { Key = "ModMenu_WH_GlowIntensity", UI = AliasMap.Slider, Text = "   Glow Intensity (10%-100%)", ExpandHandle = "ModMenu_WallHack", Min = 10, Max = 100, MinValue = 10, MaxValue = 100,
          GetFunc = function() return _G.LexusConfig.GlowIntensity or 60 end,
          SetFunc = function(c, v)
              local val = tonumber(v or c) or 60
              _G.LexusConfig.GlowIntensity = val
              _WH_LINEAR_COLOR_CACHE = {}
              _G._WH_ConfigVersion = (_G._WH_ConfigVersion or 0) + 1
              _G._WH_ForceUpdate = true
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { Key = "ModMenu_WH_EnemyVisColor", UI = AliasMap.Switcher, Text = "   Enemy Visible Color", ExpandHandle = "ModMenu_WallHack",
          SwitcherText = colNames, SwitcherValue = colVals,
          GetFunc = function() return _G.LexusConfig.ColorEnemyWHVis or 0 end,
          SetFunc = function(c, v)
              _G.LexusConfig.ColorEnemyWHVis = v
              _WH_LINEAR_COLOR_CACHE = {}
              _G._WH_ConfigVersion = (_G._WH_ConfigVersion or 0) + 1
              _G._WH_ForceUpdate = true
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { Key = "ModMenu_WH_EnemyOccColor", UI = AliasMap.Switcher, Text = "   Enemy Hidden Color", ExpandHandle = "ModMenu_WallHack",
          SwitcherText = colNames, SwitcherValue = colVals,
          GetFunc = function() return _G.LexusConfig.ColorEnemyWHOcc or 2 end,
          SetFunc = function(c, v)
              _G.LexusConfig.ColorEnemyWHOcc = v
              _WH_LINEAR_COLOR_CACHE = {}
              _G._WH_ConfigVersion = (_G._WH_ConfigVersion or 0) + 1
              _G._WH_ForceUpdate = true
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { Key = "ModMenu_WH_BotVisColor", UI = AliasMap.Switcher, Text = "   Bot Visible Color", ExpandHandle = "ModMenu_WallHack",
          SwitcherText = colNames, SwitcherValue = colVals,
          GetFunc = function() return _G.LexusConfig.ColorBotWHVis or 1 end,
          SetFunc = function(c, v)
              _G.LexusConfig.ColorBotWHVis = v
              _WH_LINEAR_COLOR_CACHE = {}
              _G._WH_ConfigVersion = (_G._WH_ConfigVersion or 0) + 1
              _G._WH_ForceUpdate = true
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { Key = "ModMenu_WH_BotOccColor", UI = AliasMap.Switcher, Text = "   Bot Hidden Color", ExpandHandle = "ModMenu_WallHack",
          SwitcherText = colNames, SwitcherValue = colVals,
          GetFunc = function() return _G.LexusConfig.ColorBotWHOcc or 3 end,
          SetFunc = function(c, v)
              _G.LexusConfig.ColorBotWHOcc = v
              _WH_LINEAR_COLOR_CACHE = {}
              _G._WH_ConfigVersion = (_G._WH_ConfigVersion or 0) + 1
              _G._WH_ForceUpdate = true
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
    }

        local StackWorld = {
        { UI = AliasMap.Title, Text = "--- VEHICLE RADAR ---" },
        { Key = "ModMenu_ESP_Vehicle", UI = AliasMap.Switcher, Text = "Vehicle ESP (Master Switch)", ExpandIndex = 0,
          GetFunc = function() return _G.LexusConfig.VehicleESPEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("VehicleESPEnabled", val, 
                  function() local pc = GetActivePlayerController(); if StartVehicleTimer then StartVehicleTimer(pc) end end,
                  function() if StopVehicleTimer then StopVehicleTimer() end end
              )
          end 
        },
        { Key = "ModMenu_Veh_Dist", UI = AliasMap.Slider, Text = "   Max Vehicle Distance (m)", ExpandHandle = "ModMenu_ESP_Vehicle",
          Min = 100, Max = 400, MinValue = 100, MaxValue = 400,
          GetFunc = function() return _G.LexusConfig.VehicleDistance or 400 end,
          SetFunc = function(c, v)
              _G.LexusConfig.VehicleDistance = tonumber(v or c) or 400
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { Key = "ModMenu_Veh_ShowDist", UI = AliasMap.Switcher, Text = "   Show Distance Label [150m]", ExpandHandle = "ModMenu_ESP_Vehicle",
          GetFunc = function() return _G.LexusConfig.VehicleShowDist ~= false end,
          SetFunc = function(c, v)
              _G.LexusConfig.VehicleShowDist = (v ~= nil and v or c)
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { UI = AliasMap.Title, Text = "--- LOOT DETECTION ---" },
        { Key = "ModMenu_ESP_Loot", UI = AliasMap.Switcher, Text = "Loot ESP (Master Switch)", ExpandIndex = 0,
          GetFunc = function() return _G.LexusConfig.LootESPEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("LootESPEnabled", val, 
                  function() local pc = GetActivePlayerController(); if StartLootTimer then StartLootTimer(pc) end end,
                  function() if StopLootTimer then StopLootTimer() end end
              )
          end 
        },
        { Key = "ModMenu_Loot_Dist", UI = AliasMap.Slider, Text = "   Max Loot Distance (m)", ExpandHandle = "ModMenu_ESP_Loot",
          Min = 20, Max = 100, MinValue = 20, MaxValue = 100,
          GetFunc = function() return _G.LexusConfig.LootDistance or 60 end,
          SetFunc = function(c, v)
              _G.LexusConfig.LootDistance = tonumber(v or c) or 60
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { Key = "ModMenu_Loot_Flares", UI = AliasMap.Switcher, Text = "   Filter: Flare Gun & Air Drops", ExpandHandle = "ModMenu_ESP_Loot",
          GetFunc = function() return _G.LexusConfig.LootFlares ~= false end,
          SetFunc = function(c, v) _G.LexusConfig.LootFlares = (v ~= nil and v or c); _G.LexusState.DirtyConfig = true return true end
        },
        { Key = "ModMenu_Loot_Weapons", UI = AliasMap.Switcher, Text = "   Filter: High Tier Weapons", ExpandHandle = "ModMenu_ESP_Loot",
          GetFunc = function() return _G.LexusConfig.LootWeapons ~= false end,
          SetFunc = function(c, v) _G.LexusConfig.LootWeapons = (v ~= nil and v or c); _G.LexusState.DirtyConfig = true return true end
        },
        { Key = "ModMenu_Loot_Armor", UI = AliasMap.Switcher, Text = "   Filter: Level 3 Armor & Helmets", ExpandHandle = "ModMenu_ESP_Loot",
          GetFunc = function() return _G.LexusConfig.LootArmor ~= false end,
          SetFunc = function(c, v) _G.LexusConfig.LootArmor = (v ~= nil and v or c); _G.LexusState.DirtyConfig = true return true end
        },
        { Key = "ModMenu_Loot_Scopes", UI = AliasMap.Switcher, Text = "   Filter: Scopes (4x / 6x / 8x)", ExpandHandle = "ModMenu_ESP_Loot",
          GetFunc = function() return _G.LexusConfig.LootScopes ~= false end,
          SetFunc = function(c, v) _G.LexusConfig.LootScopes = (v ~= nil and v or c); _G.LexusState.DirtyConfig = true return true end
        },
        { Key = "ModMenu_Loot_Meds", UI = AliasMap.Switcher, Text = "   Filter: Medical Supplies", ExpandHandle = "ModMenu_ESP_Loot",
          GetFunc = function() return _G.LexusConfig.LootMeds ~= false end,
          SetFunc = function(c, v) _G.LexusConfig.LootMeds = (v ~= nil and v or c); _G.LexusState.DirtyConfig = true return true end
        },
    }

        local StackCombat = {
        { UI = AliasMap.Title, Text = "--- AIM ASSIST ---" },
        { Key = "ModMenu_AimAssist", UI = AliasMap.Switcher, Text = "Aim Assist (ON/OFF)", ExpandIndex = 0,
          GetFunc = function() return _G.LexusConfig.AimAssistEnabled end,
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("AimAssistEnabled", val,
                  function() ApplyAimAssist(true) end,
                  function() ApplyAimAssist(true) end
              )
          end
        },
        { Key = "ModMenu_IgnoreKnocked", UI = AliasMap.Switcher, Text = "   Ignore Knocked Enemies", ExpandHandle = "ModMenu_AimAssist",
          GetFunc = function() return _G.LexusConfig.IgnoreKnocked ~= false end,
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              _G.LexusConfig.IgnoreKnocked = val
              ApplyAimAssist(true)
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { Key = "ModMenu_IgnoreBot", UI = AliasMap.Switcher, Text = "   Ignore Bots (ESP Filter)", ExpandHandle = "ModMenu_AimAssist",
          GetFunc = function() return _G.LexusConfig.IgnoreBot == true end,
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              _G.LexusConfig.IgnoreBot = val
              _G.LexusState.DirtyConfig = true
              return true
          end
        },
        { UI = AliasMap.Title, Text = "--- RECOIL CONTROL ---" },
        { Key = "ModMenu_NoRecoil", UI = AliasMap.Switcher, Text = "Recoil Control (ON/OFF)", ExpandIndex = 0,
          GetFunc = function() return _G.LexusConfig.NoRecoilEnabled end,
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("NoRecoilEnabled", val,
                  function() ApplyNoRecoil(true) end,
                  function() ApplyNoRecoil(true) end
              )
          end
        },
    }



    local fpsNames = {"60 FPS", "90 FPS", "120 FPS", "144 FPS", "165 FPS (Ultra)"}
    local fpsVals = {60, 90, 120, 144, 165}

        local StackGraphics = {
        { UI = AliasMap.Title, Text = "--- DISPLAY & PERSPECTIVE ---" },
        { Key = "ModMenu_iPadView", UI = AliasMap.Switcher, Text = "Enable iPad Perspective", ExpandIndex = 0,
          GetFunc = function() return _G.LexusConfig.iPadViewEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("iPadViewEnabled", val, ApplyiPadView, ApplyiPadView)
          end 
        },
        { Key = "ModMenu_iPadFOV", UI = AliasMap.Slider, Text = "   Field of View (110 - 130 FOV)", ExpandHandle = "ModMenu_iPadView", Min = 0, Max = 100, MinValue = 0, MaxValue = 100, 
          GetFunc = function() local val = _G.LexusConfig.iPadViewFOV or 110; return ((val - 110) / 20) * 100 end, 
          SetFunc = function(c, v) 
              local val = tonumber(v or c) or 0; if val > 100 then val = 100 end; if val < 0 then val = 0 end; 
              _G.LexusConfig.iPadViewFOV = 110 + (val / 100) * 20; ApplyiPadView(); _G.LexusState.DirtyConfig = true return true 
          end 
        },
        { UI = AliasMap.Title, Text = "--- PERFORMANCE & REFRESH RATE ---" },
        { Key = "ModMenu_TargetFPS", UI = AliasMap.Switcher, Text = "Target Frame Rate (FPS)",
          SwitcherText = fpsNames, SwitcherValue = fpsVals,
          GetFunc = function() return _G.LexusConfig.TargetFPS or 165 end,
          SetFunc = function(c, v)
              local val = tonumber(v or c) or 165
              ApplyFPSLimit(val)
              return true
          end
        },
        { Key = "ModMenu_NoGrass", UI = AliasMap.Switcher, Text = "Visual Cleanup (Remove Dense Grass)", 
          GetFunc = function() return _G.LexusConfig.VisualCleanupEnabled end, 
          SetFunc = function(c, v)
              local val = (v ~= nil) and v or c
              return HandleToggle("VisualCleanupEnabled", val, 
                  function() ApplyEnvironment(true) end, 
                  function() ApplyEnvironment(true) end
              )
          end 
        },
    }
                local StackSkin = {
        { Key = "ModMenu_ModSkin", UI = AliasMap.TitleSwitcher, Text = "Custom Skin Armory (Master Switch)", ExpandIndex = 0, GetFunc = function() return _G.LexusConfig.ModSkin end, SetFunc = function(c,v) _G.LexusConfig.ModSkin = v; _G.LexusState.DirtyConfig = true return true end },
        
        -- Category 1: Character Apparel
        { UI = AliasMap.Title, Text = "--- CHARACTER APPAREL ---", ExpandHandle = "ModMenu_ModSkin" },
        { Key = "ModMenu_Skin_Suit", UI = AliasMap.Slider, Text = "   Outfit Suit (X-Suit & Mythics)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 80, MinValue = 1, MaxValue = 80, GetFunc = function() return _G.LexusState.CustomTextData.SkinSuit or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinSuit = v; if _G.OutfitSkins and _G.OutfitSkins.Suit[v] then _G.OutfitMap.Suit = _G.OutfitSkins.Suit[v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_Bag", UI = AliasMap.Slider, Text = "   Backpack (Lv1 - Lv3 Skins)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 16, MinValue = 1, MaxValue = 16, GetFunc = function() return _G.LexusState.CustomTextData.SkinBag or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinBag = v; if _G.OutfitSkins and _G.OutfitSkins.Bag[v] then _G.OutfitMap.Bag = _G.OutfitSkins.Bag[v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_Helmet", UI = AliasMap.Slider, Text = "   Helmet (Lv1 - Lv3 Skins)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 11, MinValue = 1, MaxValue = 11, GetFunc = function() return _G.LexusState.CustomTextData.SkinHelmet or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinHelmet = v; if _G.OutfitSkins and _G.OutfitSkins.Helmet[v] then _G.OutfitMap.Helmet = _G.OutfitSkins.Helmet[v] end; _G.LexusState.DirtyConfig = true return true end },
        
        -- Category 2: Assault Rifles (AR)
        { UI = AliasMap.Title, Text = "--- ASSAULT RIFLES (AR) ---", ExpandHandle = "ModMenu_ModSkin" },
        { Key = "ModMenu_Skin_M416", UI = AliasMap.Slider, Text = "   M416 (Glacier, Shinobi, etc.)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 9, MinValue = 1, MaxValue = 9, GetFunc = function() return _G.LexusState.CustomTextData.SkinM416 or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinM416 = v; if _G.skinIdMappings[101004] and _G.skinIdMappings[101004][v] then _G.WeaponSkinMap[101004] = _G.skinIdMappings[101004][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_AKM", UI = AliasMap.Slider, Text = "   AKM (Hellfire, Glacier, etc.)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 8, MinValue = 1, MaxValue = 8, GetFunc = function() return _G.LexusState.CustomTextData.SkinAKM or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinAKM = v; if _G.skinIdMappings[101001] and _G.skinIdMappings[101001][v] then _G.WeaponSkinMap[101001] = _G.skinIdMappings[101001][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_SCAR", UI = AliasMap.Slider, Text = "   SCAR-L (Water Blaster, etc.)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 8, MinValue = 1, MaxValue = 8, GetFunc = function() return _G.LexusState.CustomTextData.SkinSCAR or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinSCAR = v; if _G.skinIdMappings[101003] and _G.skinIdMappings[101003][v] then _G.WeaponSkinMap[101003] = _G.skinIdMappings[101003][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_M762", UI = AliasMap.Slider, Text = "   Beryl M762 (Concerto, etc.)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 9, MinValue = 1, MaxValue = 9, GetFunc = function() return _G.LexusState.CustomTextData.SkinM762 or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinM762 = v; if _G.skinIdMappings[101008] and _G.skinIdMappings[101008][v] then _G.WeaponSkinMap[101008] = _G.skinIdMappings[101008][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_AUG", UI = AliasMap.Slider, Text = "   AUG A3 (Evangelion, etc.)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 7, MinValue = 1, MaxValue = 7, GetFunc = function() return _G.LexusState.CustomTextData.SkinAUG or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinAUG = v; if _G.skinIdMappings[101006] and _G.skinIdMappings[101006][v] then _G.WeaponSkinMap[101006] = _G.skinIdMappings[101006][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_Groza", UI = AliasMap.Slider, Text = "   Groza (Godzilla)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 2, MinValue = 1, MaxValue = 2, GetFunc = function() return _G.LexusState.CustomTextData.SkinGroza or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinGroza = v; if _G.skinIdMappings[101005] and _G.skinIdMappings[101005][v] then _G.WeaponSkinMap[101005] = _G.skinIdMappings[101005][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_QBZ", UI = AliasMap.Slider, Text = "   QBZ-95 (Blazing Cham)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 6, MinValue = 1, MaxValue = 6, GetFunc = function() return _G.LexusState.CustomTextData.SkinQBZ or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinQBZ = v; if _G.skinIdMappings[101007] and _G.skinIdMappings[101007][v] then _G.WeaponSkinMap[101007] = _G.skinIdMappings[101007][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_ACE32", UI = AliasMap.Slider, Text = "   ACE32 (Cyber Core)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 6, MinValue = 1, MaxValue = 6, GetFunc = function() return _G.LexusState.CustomTextData.SkinACE32 or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinACE32 = v; if _G.skinIdMappings[101102] and _G.skinIdMappings[101102][v] then _G.WeaponSkinMap[101102] = _G.skinIdMappings[101102][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_M16A4", UI = AliasMap.Slider, Text = "   M16A4 (Aurora Pulse)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 5, MinValue = 1, MaxValue = 5, GetFunc = function() return _G.LexusState.CustomTextData.SkinM16A4 or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinM16A4 = v; if _G.skinIdMappings[101002] and _G.skinIdMappings[101002][v] then _G.WeaponSkinMap[101002] = _G.skinIdMappings[101002][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_Honey", UI = AliasMap.Slider, Text = "   Honey Badger (Neon)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 2, MinValue = 1, MaxValue = 2, GetFunc = function() return _G.LexusState.CustomTextData.SkinHoney or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinHoney = v; if _G.skinIdMappings[101012] and _G.skinIdMappings[101012][v] then _G.WeaponSkinMap[101012] = _G.skinIdMappings[101012][v] end; _G.LexusState.DirtyConfig = true return true end },

        -- Category 3: Submachine Guns & Shotguns
        { UI = AliasMap.Title, Text = "--- SMG & SHOTGUNS ---", ExpandHandle = "ModMenu_ModSkin" },
        { Key = "ModMenu_Skin_UMP", UI = AliasMap.Slider, Text = "   UMP45 (EMP, Marine, etc.)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 5, MinValue = 1, MaxValue = 5, GetFunc = function() return _G.LexusState.CustomTextData.SkinUMP or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinUMP = v; if _G.skinIdMappings[102002] and _G.skinIdMappings[102002][v] then _G.WeaponSkinMap[102002] = _G.skinIdMappings[102002][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_UZI", UI = AliasMap.Slider, Text = "   Micro UZI (Pro Ice)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 2, MinValue = 1, MaxValue = 2, GetFunc = function() return _G.LexusState.CustomTextData.SkinUZI or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinUZI = v; if _G.skinIdMappings[102001] and _G.skinIdMappings[102001][v] then _G.WeaponSkinMap[102001] = _G.skinIdMappings[102001][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_DBS", UI = AliasMap.Slider, Text = "   DBS (Beast, Sandsinger)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 3, MinValue = 1, MaxValue = 3, GetFunc = function() return _G.LexusState.CustomTextData.SkinDBS or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinDBS = v; if _G.skinIdMappings[104004] and _G.skinIdMappings[104004][v] then _G.WeaponSkinMap[104004] = _G.skinIdMappings[104004][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_S12K", UI = AliasMap.Slider, Text = "   S12K (Atomic)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 2, MinValue = 1, MaxValue = 2, GetFunc = function() return _G.LexusState.CustomTextData.SkinS12K or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinS12K = v; if _G.skinIdMappings[104003] and _G.skinIdMappings[104003][v] then _G.WeaponSkinMap[104003] = _G.skinIdMappings[104003][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_ASM", UI = AliasMap.Slider, Text = "   ASM Abakan (Steel Core)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 2, MinValue = 1, MaxValue = 2, GetFunc = function() return _G.LexusState.CustomTextData.SkinASM or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinASM = v; if _G.skinIdMappings[101101] and _G.skinIdMappings[101101][v] then _G.WeaponSkinMap[101101] = _G.skinIdMappings[101101][v] end; _G.LexusState.DirtyConfig = true return true end },

        -- Category 4: Sniper Rifles
        { UI = AliasMap.Title, Text = "--- SNIPER RIFLES (SR) ---", ExpandHandle = "ModMenu_ModSkin" },
        { Key = "ModMenu_Skin_AWM", UI = AliasMap.Slider, Text = "   AWM (Godzilla, Rainbow, etc.)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 11, MinValue = 1, MaxValue = 11, GetFunc = function() return _G.LexusState.CustomTextData.SkinAWM or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinAWM = v; if _G.skinIdMappings[103003] and _G.skinIdMappings[103003][v] then _G.WeaponSkinMap[103003] = _G.skinIdMappings[103003][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_Kar98k", UI = AliasMap.Slider, Text = "   Kar98k (Moonlit, Dragon, etc.)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 8, MinValue = 1, MaxValue = 8, GetFunc = function() return _G.LexusState.CustomTextData.SkinKar98k or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinKar98k = v; if _G.skinIdMappings[103001] and _G.skinIdMappings[103001][v] then _G.WeaponSkinMap[103001] = _G.skinIdMappings[103001][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_M24", UI = AliasMap.Slider, Text = "   M24 (Pharaoh, Lady Butterfly)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 7, MinValue = 1, MaxValue = 7, GetFunc = function() return _G.LexusState.CustomTextData.SkinM24 or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinM24 = v; if _G.skinIdMappings[103002] and _G.skinIdMappings[103002][v] then _G.WeaponSkinMap[103002] = _G.skinIdMappings[103002][v] end; _G.LexusState.DirtyConfig = true return true end },

        -- Category 5: Vehicles & Supercars
        { UI = AliasMap.Title, Text = "--- VEHICLES & SUPERCARS ---", ExpandHandle = "ModMenu_ModSkin" },
        { Key = "ModMenu_Skin_Coupe", UI = AliasMap.Slider, Text = "   Coupe RB Sports Car (1-56)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 56, MinValue = 1, MaxValue = 56, GetFunc = function() return _G.LexusState.CustomTextData.SkinCoupe or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinCoupe = v; if _G.VehicleSkins[1961001] and _G.VehicleSkins[1961001][v] then _G.VehicleSkinMap[1961001] = _G.VehicleSkins[1961001][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_Dacia", UI = AliasMap.Slider, Text = "   Dacia Classic Sedan (1-34)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 34, MinValue = 1, MaxValue = 34, GetFunc = function() return _G.LexusState.CustomTextData.SkinDacia or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinDacia = v; if _G.VehicleSkins[1903001] and _G.VehicleSkins[1903001][v] then _G.VehicleSkinMap[1903001] = _G.VehicleSkins[1903001][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_UAZ", UI = AliasMap.Slider, Text = "   UAZ Armored 4x4 (1-16)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 16, MinValue = 1, MaxValue = 16, GetFunc = function() return _G.LexusState.CustomTextData.SkinUAZ or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinUAZ = v; if _G.VehicleSkins[1908001] and _G.VehicleSkins[1908001][v] then _G.VehicleSkinMap[1908001] = _G.VehicleSkins[1908001][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_Buggy", UI = AliasMap.Slider, Text = "   Buggy Desert Racer (1-11)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 11, MinValue = 1, MaxValue = 11, GetFunc = function() return _G.LexusState.CustomTextData.SkinBuggy or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinBuggy = v; if _G.VehicleSkins[1907002] and _G.VehicleSkins[1907002][v] then _G.VehicleSkinMap[1907002] = _G.VehicleSkins[1907002][v] end; _G.LexusState.DirtyConfig = true return true end },
        { Key = "ModMenu_Skin_Mirado", UI = AliasMap.Slider, Text = "   Mirado Muscle Car (1-5)", ExpandHandle = "ModMenu_ModSkin", Min = 1, Max = 5, MinValue = 1, MaxValue = 5, GetFunc = function() return _G.LexusState.CustomTextData.SkinMirado or 1 end, SetFunc = function(c,v) _G.LexusState.CustomTextData.SkinMirado = v; if _G.VehicleSkins[1915004] and _G.VehicleSkins[1915004][v] then _G.VehicleSkinMap[1915004] = _G.VehicleSkins[1915004][v] end; _G.LexusState.DirtyConfig = true return true end }
    }
    -- PAGE DEFINITION
    if not SettingPageDefine.ModMenu then
        SettingPageDefine.ModMenu = {
            Key = "ModMenu",
            Text = 999000,
            UIKey = "Setting_Page_Privacy", 
            Category = {
                { Key = "Cat_ESP", Text = 999001, Stack = StackESP },
                { Key = "Cat_World", Text = 999005, Stack = StackWorld },
                { Key = "Cat_Combat", Text = 999002, Stack = StackCombat },
                { Key = "Cat_Graphics", Text = 999003, Stack = StackGraphics },
                { Key = "Cat_Skin", Text = 999004, Stack = StackSkin }
            }
        }
        table.insert(SettingCatalog, SettingPageDefine.ModMenu)
    end
    -- UIMANAGER HOOK
    local UIManager = _G.UIManager
    if UIManager and not UIManager._IsModMenuHooked then
        local old_ShowUI = UIManager.ShowUI
        UIManager.ShowUI = function(config, ...)
            local args = {...}
            local n = select('#', ...) 
            if config and config.keyName and (string.find(string.lower(config.keyName), "setting_main") or string.find(string.lower(config.keyName), "setting")) then
                local catalog = args[1]
                if type(catalog) == "table" then
                    local hasModMenu = false
                    for _, page in ipairs(catalog) do
                        if type(page) == "table" and page.Key == "ModMenu" then
                            hasModMenu = true
                            break
                        end
                    end
                    if not hasModMenu then
                        table.insert(catalog, 1, SettingPageDefine.ModMenu)
                    end
                end
            end
            local table_unpack = table.unpack or unpack
            return old_ShowUI(config, table_unpack(args, 1, n))
        end
        UIManager._IsModMenuHooked = true
    end
end

-- ============================================================================
-- MAIN LOOP & LIFECYCLE MANAGEMENT (SEAMLESS NEW MATCH AUTO-ADAPTATION)
-- ============================================================================
local function CleanupMatchState()
    for ownerKey, list in pairs(TimerManager._byOwner) do
        local firstId = list[1]
        if firstId and TimerManager._byId[firstId] then
            local owner = TimerManager._byId[firstId].owner
            if owner then
                TimerManager:ClearAllForOwner(owner)
            end
        end
    end
    if _G.LexusState and _G.LexusState.ModTimers then
        ClearModTimers()
        _G.LexusState.ModTimers = {}
    end
    if ClearESPTimers then
        ClearESPTimers()
    end
    _pbc_Cleanup()
    if _G.StopSnaplineLoop then pcall(_G.StopSnaplineLoop) end
    if _G.ClearAllSnapLines then pcall(_G.ClearAllSnapLines) end
    if _G.ClearAllWallhackState then pcall(_G.ClearAllWallhackState) end
    _G._SnaplineLoopRunning = false
    _G.LexusState._WH_TIMER_RUNNING = false
    _G.LexusState.MatchStarted = false
    _G.LexusState.VisualsStarted = false
    _G.LastAimState = nil
    _G.LastRecoilState = nil
    pcall(function()
        if aimOriginalCache then aimOriginalCache = {} end
        if recoilOriginalCache then recoilOriginalCache = {} end
        _ENV_LAST_GRASS_STATE = nil
        _ENV_ONCE_DONE = false
    end)
    pcall(collectgarbage, "collect")
end

local function MainLoop() 
    if _G.LexusState.CustomTextData == nil then 
        _G.LexusState.CustomTextData = {
            SkinSuit = 1, SkinBag = 1, SkinHelmet = 1,
            SkinM416 = 1, SkinAKM = 1, SkinSCAR = 1, SkinM762 = 1, SkinAUG = 1, SkinUMP = 1,
            SkinUZI = 1, SkinGroza = 1, SkinS12K = 1, SkinDBS = 1, SkinASM = 1, SkinQBZ = 1,
            SkinHoney = 1, SkinM16A4 = 1, SkinACE32 = 1, SkinKar98k = 1, SkinM24 = 1, SkinAWM = 1,
            SkinDacia = 1, SkinUAZ = 1, SkinCoupe = 1, SkinBuggy = 1, SkinMirado = 1,
            AimPower = 50,
            iPadViewFOV = 110
        }
    end
    local pc = GetActivePlayerController()
    local localPlayer = GetLocalPlayer(pc)
    if not Valid(pc) or not Valid(localPlayer) then 
        return 
    end

    -- ========================================================================
    --  SEAMLESS NEW MATCH DETECTION & CONTROLLER ADAPTATION (ZERO AUTO-OFF)
    -- ========================================================================
    if _G.LexusState.ActivePC ~= pc then
        _G.LexusState.ActivePC = pc
        _G.LexusState.MatchStarted = false
        _G.LexusState.CurrentPawn = localPlayer
        _G._LastCheckedPlayer = localPlayer
        _G._LastCheckedWeaponKey = nil
        _G.LastAimState = nil
        _G.LastRecoilState = nil

        -- Invalidate all caches from the previous match
        InvalidatePawnCache()
        _1006_Marks = {}
        _MapMarks = {}
        _BoxESPCache = {}
        DestroyCounterWidget()
        StopVehicleTimer()
        StopLootTimer()
        _ActiveVehicleActors = {}
        _ActiveLootActors = {}
        _VEH_CACHE = nil
        if _G.ClearAllWallhackState then pcall(_G.ClearAllWallhackState) end
        if _G.StopSnaplineLoop then pcall(_G.StopSnaplineLoop) end
        if _G.ClearAllSnapLines then pcall(_G.ClearAllSnapLines) end
        _G._SnaplineLoopRunning = false

        -- Clear dead timers from the previous controller
        ClearModTimers()
        _G.LexusState.ModTimers = {}
        _G.WH_TIMER = nil
        _G.WH_TIMER_OWNER = nil

        -- Immediately start all enabled features on the new match controller!
        _G.LexusState.MatchStarted = true
        pcall(StartMatchFeatures, pc, localPlayer)
    end

    if not _G.LexusState.MatchStarted then
        _G.LexusState.MatchStarted = true
        pcall(StartMatchFeatures, pc, localPlayer)
    end

    -- Respawn Detection for TDM / Arena maps (new pawn possessed after death)
    if _G.LexusState.CurrentPawn ~= localPlayer then
        _G.LexusState.CurrentPawn = localPlayer
        _G._LastCheckedPlayer = localPlayer
        _G._LastCheckedWeaponKey = nil
        _G.LastAimState = nil
        _G.LastRecoilState = nil
        ApplyAimAssist(true)
        ApplyNoRecoil(true)
        ApplyiPadView(true)
        pcall(ApplyEnvironment)
    end
    if not _G.ModMenuInitialized then
        _G.InitModMenuTab()
    end

    -- ==================== MOD SKIN SYSTEM ====================
    if _G.LexusConfig.ModSkin then
        if not _G.TDSkinLoopStarted then
            if _G.InitializeSkinModSystem then _G.InitializeSkinModSystem() end
            if _G.ForceRefreshSkinMaps then _G.ForceRefreshSkinMaps() end
            _G.TDSkinLoopStarted = true
        end
        _G.LexusState.SkinWasApplied = true
        local curTime = os.clock()
        if not _G.LastSkinUpdateTime or (curTime - _G.LastSkinUpdateTime) > 3.0 then
            _G.LastSkinUpdateTime = curTime
            pcall(function()
                local isAlive = type(localPlayer.IsAlive) == "function" and localPlayer:IsAlive() or true
                if isAlive then
                    if _G.ReadLiveConfig then _G.ReadLiveConfig() end
                    if not _G.KillInfoCounterHacked and _G.ForceEnableKillCounterUI then _G.ForceEnableKillCounterUI() end
                    if _G.equip_character_avatar then _G.equip_character_avatar(localPlayer) end
                    if _G.ApplyWeaponSkins then _G.ApplyWeaponSkins(localPlayer) end
                    if _G.ApplyVehicleSkins then _G.ApplyVehicleSkins(localPlayer) end
                    if _G.HandlePetLogic then _G.HandlePetLogic() end                    
                end
            end)
        end
    else
        if _G.LexusState.SkinWasApplied then
            _G.OutfitMap = {}
            _G.WeaponSkinMap = {}
            _G.VehicleSkinMap = {}
            pcall(function()
                local WeaponManager = (localPlayer.GetWeaponManager and localPlayer:GetWeaponManager()) or localPlayer.WeaponManagerComponent
                if Valid(WeaponManager) then
                    for slot = 1, 3 do
                        local Weapon = WeaponManager:GetInventoryWeaponByPropSlot(slot)
                        if Valid(Weapon) and Valid(Weapon.synData) then
                            local WeaponID = Weapon:GetWeaponID()
                            local SkinData = Weapon.synData:Get(7)
                            if SkinData and SkinData.defineID then
                                SkinData.defineID.TypeSpecificID = WeaponID
                                Weapon.synData:Set(7, SkinData)
                                if Weapon.SetWeaponAvatarID then pcall(function() Weapon:SetWeaponAvatarID(WeaponID) end) end
                                if Weapon.DelayHandleAvatarMeshChanged then pcall(function() Weapon:DelayHandleAvatarMeshChanged() end) end
                            end
                        end
                    end
                end
                local Vehicle = localPlayer:GetCurrentVehicle()
                if Valid(Vehicle) then
                    local VehicleAvatar = Vehicle.VehicleAvatar or Vehicle.VehicleAvatarComponent_BP or Vehicle:GetAvatarComponent()
                    if Valid(VehicleAvatar) and type(VehicleAvatar.GetDefaultAvatarID) == "function" then
                        local defId = VehicleAvatar:GetDefaultAvatarID()
                        if VehicleAvatar.ChangeItemAvatar then VehicleAvatar:ChangeItemAvatar(defId, true) end
                    end
                end
                if localPlayer.AvatarComponent2 and type(localPlayer.AvatarComponent2.OnRep_BodySlotStateChanged) == "function" then
                    localPlayer.AvatarComponent2:OnRep_BodySlotStateChanged()
                end
            end)
            _G.LexusState.SkinWasApplied = false
        end
        _G.TDSkinLoopStarted = false
    end

    -- ==================== WATCHDOGS & WEAPON SWAP CHECK ====================
    -- Check if held weapon changed using stable weapon ID/unique key (ZERO GC LAG)
    local curW = nil
    local curWKey = nil
    if Valid(localPlayer) then
        local wm = localPlayer.WeaponManagerComponent or (localPlayer.GetWeaponManager and localPlayer:GetWeaponManager())
        if Valid(wm) then
            curW = (wm.GetCurrentUsingWeapon and wm:GetCurrentUsingWeapon()) or wm.CurrentWeaponReplicated or (localPlayer.GetCurrentWeapon and localPlayer:GetCurrentWeapon())
        end
    end
    if Valid(curW) then
        curWKey = (curW.GetUniqueID and curW:GetUniqueID()) or (curW.GetWeaponID and curW:GetWeaponID()) or curW
    end
    if curWKey and curWKey ~= _G._LastCheckedWeaponKey then
        _G._LastCheckedWeaponKey = curWKey
        if _G.LexusConfig.AimAssistEnabled then ApplyAimAssist(true) end
        if _G.LexusConfig.NoRecoilEnabled then ApplyNoRecoil(true) end
    end

    -- Check if character respawned in TDM
    if Valid(localPlayer) and localPlayer ~= _G._LastCheckedPlayer then
        _G._LastCheckedPlayer = localPlayer
        if _G.LexusConfig.iPadViewEnabled then ApplyiPadView(true) end
        if _G.LexusConfig.AimAssistEnabled then ApplyAimAssist(true) end
        if _G.LexusConfig.NoRecoilEnabled then ApplyNoRecoil(true) end
    end

    -- ==================== BOT GUARD (Ignore Bot for Aimbot) ====================
    -- When IgnoreBot is ON: check nearby enemies via pawn cache.
    -- If ONLY bots visible → disable aim component (aimbot won't lock).
    -- If ANY real player visible → re-enable aim component (aimbot works).
    -- Safety: real player presence = aim always ON. No false negatives.
    if _G.LexusConfig.AimAssistEnabled and _G.LexusConfig.IgnoreBot then
        pcall(function()
            if not Valid(localPlayer) then return end
            local aac = localPlayer.AutoAimComp or localPlayer.BP_AutoAimingComponent
            if not Valid(aac) then return end
            local myTeamId = localPlayer.TeamID or -1
            local hasRealPlayer = false
            local hasAnyEnemy = false
            local okCache, pawns = GetCachedPlayerPawns()
            if okCache and pawns then
                for _, pawn in ipairs(pawns) do
                    if Valid(pawn) and pawn ~= localPlayer and not IsPawnDead(pawn) then
                        local theirTeam = pawn.TeamID
                        if theirTeam and theirTeam ~= myTeamId then
                            hasAnyEnemy = true
                            if not ResolveIsAI(pawn) then
                                hasRealPlayer = true
                                break  -- found real player, no need to check more
                            end
                        end
                    end
                end
            end
            if hasAnyEnemy and not hasRealPlayer then
                -- Only bots nearby: disable aim component
                aac.bEnableAutoAim = false
                aac.bAutoAim = false
            else
                -- Real player nearby (or no enemies at all): ensure aim is active
                aac.bEnableAutoAim = true
                aac.bAutoAim = true
            end
        end)
    end

    -- Watchdog: ensure ESP state matches menu setting on the active controller
    if _G.LexusConfig.ESP_All then
        if not _G.LexusState.ModTimers or #_G.LexusState.ModTimers == 0 then
            StartESPTimers(pc)
        end
    else
        if _G.LexusState.ModTimers and #_G.LexusState.ModTimers > 0 then
            ClearESPTimers()
        end
    end

    -- Watchdog: ensure Vehicle ESP matches menu setting on the active controller
    if _G.LexusConfig.VehicleESPEnabled then
        if not _G.VEH_TIMER or _G.VEH_TIMER_OWNER ~= pc then
            StartVehicleTimer(pc)
        end
    else
        if _G.VEH_TIMER then
            StopVehicleTimer()
        end
    end

    -- Watchdog: ensure Loot ESP matches menu setting on the active controller
    if _G.LexusConfig.LootESPEnabled then
        if not _G.LOOT_TIMER or _G.LOOT_TIMER_OWNER ~= pc then
            StartLootTimer(pc)
        end
    else
        if _G.LOOT_TIMER then
            StopLootTimer()
        end
    end

    -- Watchdog: ensure Wallhack matches menu setting on the active controller
    if _G.LexusConfig.WallHackEnabled then
        if not _G.WH_TIMER or _G.WH_TIMER_OWNER ~= pc then
            _G.StartNewWallhack()
        end
    else
        if _G.WH_TIMER or CONSOLE_READY then
            if _pbc_Cleanup then _pbc_Cleanup() end
        end
    end

    -- Watchdog: ensure Snapline matches menu setting (auto-heals in Match 2)
    if _G.LexusConfig.SnaplineESPEnabled then
        if not _G._snaplineTimerStarted or not _G._snaplineTimerHandle or (_G._snaplineTimerOwner and not Valid(_G._snaplineTimerOwner)) then
            if _G.StartSnaplineLoop then _G.StartSnaplineLoop(pc) end
        end
    else
        if _G._snaplineTimerStarted then
            if _G.StopSnaplineLoop then _G.StopSnaplineLoop() end
        end
    end
end

_G.LexusState.LoopToken = (_G.LexusState.LoopToken or 0) + 1 
local myToken = _G.LexusState.LoopToken
local function FastTick() 
    if myToken ~= _G.LexusState.LoopToken then return end
    pcall(MainLoop) 
    local okTicker, ticker = pcall(require, "common.time_ticker") 
    if okTicker and ticker and ticker.AddTimerOnce then 
        ticker.AddTimerOnce(4.0, FastTick) 
    end 
end
FastTick() 

return true
