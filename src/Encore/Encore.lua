-- Hekili.lua
-- July 2024
--
-- Hekili Forever, based on the original work by Hekili and its maintainers (the original Hekili project),
-- distributed under the GNU General Public License, either version 3 of the License, or (at your option) any later
-- version (see LICENSE).
-- Modified for WoW Forever by defzach, from October 2026 (https://github.com/zmsl/hekili); this is a fork,
-- not the original project, made with the explicit permission of the original author.
-- Modified again as Encore by Chad (edase), from November 2026 (https://github.com/edase/encore): renamed from
-- Hekili Forever by tools/encore/rename.py and reshaped into a spell highway. A personal fork, not Hekili Forever.

local addon, ns = ...
local Facade = ns.Facade
local CreateFrame = Facade.CreateFrame
local AuraUtil, C_AddOns, C_UnitAuras = Facade.AuraUtil, Facade.C_AddOns, Facade.C_UnitAuras
local GetBuildInfo, GetFramerate, GetTime = Facade.GetBuildInfo, Facade.GetFramerate, Facade.GetTime
Encore = LibStub("AceAddon-3.0"):NewAddon( "Encore", "AceConsole-3.0", "AceSerializer-3.0" )
Encore.Version = C_AddOns.GetAddOnMetadata( "Encore", "Version" )
Encore.Flavor = C_AddOns.GetAddOnMetadata( "Encore", "X-Flavor" ) or "Forever"

--- The string table of content addon `app` (its folder name, "Hekili_Druid"): the AceLocale-3.0 app its
--- Locales/enUS.lua registers (silent: a key no table holds answers itself). Content calls it once, at load.
---@param app string
---@return table
function Encore:GetLocale( app )
    return LibStub( "AceLocale-3.0" ):GetLocale( app )
end

local format = string.format
local insert, concat = table.insert, table.concat


local buildStr, _, _, buildNum = GetBuildInfo()

Encore.CurrentBuild = buildNum

if Encore.Version == ( "@" .. "project-version" .. "@" ) then
    Encore.Version = format( "Dev-%s (%s)", buildStr, date( "%Y%m%d" ) )
    Encore.IsDev = true
end

Encore.AllowSimCImports = true

-- Public (the wiki's Integration overview): Hekili Forever runs only on the Forever client, so always true, whatever
-- Flavor holds. Retail Hekili has no IsForever, so other addons tell the two apart by its presence.
Encore.IsForever = function()
    return true
end
Encore.IsRetail = Encore.IsForever -- upstream's name, kept for WeakAuras and plug-ins that call it; internal

Encore.BuiltFor = 16001
Encore.GameBuild = buildStr

ns.PTR = false
Encore.IsPTR = ns.PTR

do
    local cpuProfileDB = {}

    function Encore:ProfileCPU( name, func )
        cpuProfileDB[ name ] = func
    end

	ns.cpuProfile = cpuProfileDB

	local frameProfileDB = {}

	function Encore:ProfileFrame( name, f )
		frameProfileDB[ name ] = f
	end

	ns.frameProfile = frameProfileDB
end


ns.lib = {
    Format = {}
}


-- 04072017:  Let's go ahead and cache aura information to reduce overhead.
ns.auras = {
    target = {
        buff = {},
        debuff = {}
    },
    player = {
        buff = {},
        debuff = {}
    }
}

Encore.Class = {
    specs = {},
    kit = false, -- the class pack's kit (Hekili:NewClass; Engine/Schema/Trees.lua); false: no class pack
    specByShare = {}, -- "<CLASS>:<spec key>" -> spec id, the share key export strings carry
    num = 0,

    file = "NONE",
    initialized = false,

	resources = {},
	resourceAuras = {},
    talents = {},
    pvptalents = {},
	auras = {},
	auraList = {},
    powers = {},
	gear = {},
    setBonuses = {},

	knownAuraAttributes = {},

    stateExprs = {},
    stateFuncs = {},
    stateTables = {},

	abilities = {},
	abilityByName = {},
    abilityList = {},
    itemList = {},
    itemMap = {},
    itemPack = {
        lists = {
            items = {}
        }
    },

    packs = {},
    retiredPacks = {}, -- kit:RetirePacks

    pets = {},
    totems = {},
    windows = {}, -- the active spec's rotation windows by name (RegisterWindow, Engine/Schema/Spec.lua)
    reactions = {}, -- the active spec's reactions by name (RegisterReaction, Engine/Schema/Spec.lua)

    potions = {},
    potionList = {},

	hooks = {},
    range = 8,
	settings = {},
    stances = {},
	toggles = {},
	variables = {},
}

Encore.Scripts = {
    DB = {},
    Channels = {},
    PackInfo = {},
}

Encore.State = {}

-- The game client as an addon may read it: ns.Facade (Game/API/Facade.lua) under its public name, the one engine
-- name the content addons use besides the registration API, State and Class (restructure plan, Task 8).
Encore.Client = Facade

-- The engine's public surface, filled by the Engine/ files: Output.lua (Output, Subscribe, Unsubscribe),
-- Registry.lua (Registry, Evaluate), Snapshot.lua (Snapshot), Settings.lua (Configure, settings).
Encore.Engine = {}

ns.hotkeys = {}
ns.keys = {}
ns.targets = {}
ns.TTD = {}

ns.UI = {
    Displays = {},
    Buttons = {}
}

ns.debug = {}
ns.snapshots = {}


function Encore:Query( ... )
	local output = ns

	for i = 1, select( '#', ... ) do
		output = output[ select( i, ... ) ]
    end

    return output
end


function Encore:Run( ... )
	local n = select( "#", ... )
	local fn = select( n, ... )

	local func = ns

	for i = 1, fn - 1 do
		func = func[ select( i, ... ) ]
    end

    return func( select( fn, ... ) )
end


local debug = ns.debug
local active_debug
local current_display

local lastIndent = 0

-- The belief's trace (event-facade spec §5; border batch 3): the belief imports nothing from Hekili, so the core
-- hands it this logger and reads it through Drain, Build, SetLog and the facade only. The belief fills `onOpen`.
local log = {
    active = function() return Encore.ActiveDebug end,
    write = function( ... ) Encore:Debug( ... ) end,
}
ns.VirtualState.SetLog( log )

-- The debug bridge (/run print(Hekili.Virtual.State.Snapshot()); ForeverProbe's Calib.lua and PerfKit read it): what the
-- logger carries. Not for content, which reads the client through Hekili.Client and the belief through environment names.
Encore.Virtual = log.debug

function Encore:SetupDebug( display )
    if not self.ActiveDebug then return end
    if not display then return end

    current_display = display

    debug[ current_display ] = debug[ current_display ] or {
        log = {},
        index = 1
    }
    active_debug = debug[ current_display ]
	active_debug.index = 1

	lastIndent = 0

	local pack = self.State.system.packName

    if pack then
	    self:Debug( "New Recommendations for [ %s ] requested at %s ( %.2f ); using %s( %s ) priority.", display, date( "%H:%M:%S"), GetTime(), self.DB.profile.packs[ pack ].builtIn and "built-in " or "", pack )
    end
    -- each display's log opens with the belief's own Snapshot() (event-facade spec §5)
    if log.onOpen then log.onOpen() end
end


function Encore:Debug( ... )
    if not self.ActiveDebug then return end
	if not active_debug then return end

	local indent, text = ...
	local start

	if type( indent ) ~= "number" then
		indent = lastIndent
		text = ...
		start = 2
	else
		lastIndent = indent
		start = 3
	end

	local prepend = format( indent > 0 and ( "%" .. ( indent * 4 ) .. "s" ) or "%s", "" )
	text = text:gsub("\n", "\n" .. prepend )
    text = format( "%" .. ( indent > 0 and ( 4 * indent ) or "" ) .. "s", "" ) .. text

    if select( start, ... ) ~= nil then
	    active_debug.log[ active_debug.index ] = format( text, select( start, ... ) )
    else
        active_debug.log[ active_debug.index ] = text
    end
    active_debug.index = active_debug.index + 1
end





ns.Tooltip = CreateFrame( "GameTooltip", "EncoreTooltip", UIParent, "GameTooltipTemplate" )
Encore:ProfileFrame( "EncoreTooltip", ns.Tooltip )
