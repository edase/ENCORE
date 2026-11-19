local _, ns = ...
local L = ns.L
-- UI/Styles/Highway.lua: Encore's highway display style, a rhythm-game note highway. Spell icons ride map pins along a
-- bronze rail toward a gold target ring (right to left by default): the main rotation above the rail, off-GCD spells
-- and cooldowns below it. A pin counts down in colour (red while it comes, yellow when close, green on the ring, with
-- the seconds beside it) and the ring brightens when the first one is due. Each pin is a note that keeps its spell from
-- publish to publish (a cast goes through the ring, a dropped pick fades where it was), so nothing slides backwards
-- when the queue moves up; dark ghost pins show the picks after the first few. One tracked spell shows as a half
-- circle of dots behind the ring that fills as its cooldown recovers, all gold once ready. With the options open (out
-- of combat) a demo loop runs so every setting can be seen moving.
-- Built on the timeline style (UI/Styles/Timeline.lua): the keybinding text, glow and range handling and the option
-- builders follow it and Hekili's classic renderer (UI/Styles/Classic.lua, by Hekili's authors and maintainers).
-- Written for Encore by Chad (edase). Its config is displays[ id ].highway; its frames live on d.styleFrames.highway.
-- It reads only the published records, d.resolved, its config and the facade (cooldowns: the hybrid rows, plain
-- numbers in combat too), never the engine's own tables.

local Facade = ns.Facade
local CreateFrame = Facade.CreateFrame
local C_Spell = Facade.C_Spell
local GetTime = Facade.GetTime

local Registry = Encore.Engine.Registry
local Status = Encore.Engine.Output.status
local SO = ns.StyleOptions
local Button_OnMouseDown, Button_OnMouseUp = ns.UI.Button_OnMouseDown, ns.UI.Button_OnMouseUp
local LSM = LibStub( "LibSharedMedia-3.0", true )
local Glower = LibStub( "LibCustomGlow-1.0" )

local exp, floor, ceil, abs, sin, cos, pi = math.exp, math.floor, math.ceil, math.abs, math.sin, math.cos, math.pi
local mmax, mmin = math.max, math.min

local MAX_ICONS, MAX_GHOSTS = 5, 3
local MAX_ORDER = MAX_ICONS + MAX_GHOSTS -- the notes on the rail, in queue order
local NOTES = MAX_ORDER + 4 -- and a few leaving it
local MAX_DOTS, MAX_TICKS = 24, 31
local READY_EPS = Encore.Engine.READY -- a note due within this is the press: green, and the ring brightens
local DUE_MATCH = 0.5 -- a due note stays itself only for a record due within this (else it was cast)
local MATCH = 1.5 -- a record keeps the note of its spell whose time is within this many seconds
local SPACING = 0.9 -- pins in one row keep 90% of their size apart
local MOVE_EPS, SCALE_EPS, ALPHA_EPS = 0.2, 0.004, 0.01
local HIT_TIME, DROP_TIME, SPAWN_TIME = 0.2, 0.15, 0.15
local FLASH_DECAY = 0.25 -- seconds for the ring's flash to fall to 1/e
local GCD_MAX = 1.6 -- a cooldown this short or shorter is the GCD: the tracked spell reads ready
local GAUGE_STEP = 0.1 -- seconds between the tracked spell's reads
local DEMO_GAP, DEMO_HOLD, DEMO_CYCLE, DEMO_FILL = 1.5, 0.3, 7.5, 6
local CROP = 0.08
-- the pin art (tools/encore/make_textures.py): a 128 px square, the disc's centre at (64, 50) with radius 44, the tail's
-- tip at (64, 124); so per disc diameter D the art is TEX * D wide, its centre OFF * D below the disc's, the tip TIP * D
local PIN_TEX, PIN_OFF, PIN_TIP = 128 / 88, 14 / 88, 74 / 88
local ICON_IN = 0.8 -- the icon's share of the pin's disc
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local ART = "Interface\\AddOns\\Encore\\Textures\\"
local RING, RING_IN, HALO, DOT, PIN = ART .. "HighwayRing2", ART .. "HighwayRing1", ART .. "HighwayHalo", ART .. "HighwayDot", ART .. "HighwayPin"
local GOLD = { 1, 0.8, 0.1 }

-- Countdown labels in 0.1 s steps up to 10 s, built once ("" for none, "10+" past); whole seconds for the gauge.
local ETA, ETA_INT = {}, {}
for k = 0, 100 do
    ETA[ k ] = k == 0 and "" or string.format( "%.1f", k / 10 )
    ETA_INT[ k ] = k == 0 and "" or tostring( ceil( k / 10 ) )
end
ETA[ 101 ], ETA_INT[ 101 ] = "10+", "10+"

local function etaStep( t )
    if t <= READY_EPS then return 0 end
    local k = floor( t * 10 + 0.5 )
    if k > 100 then return 101 end
    return k
end

-- The demo's note names (a note keeps its spell by name) and its fallback keybinds, built once.
local DEMO_NAMES, DEMO_KEYS = {}, { "1", "2", "3", "Q", "E", "F" }
for j = 1, 64 do DEMO_NAMES[ j ] = "encore_demo_" .. j end

local ZONES = { "icons" }
local SHARED = { "range", "keybindings", "gamepad" }

local Highway = {
    label = L["Highway"],
    defaults = SO.defaults( SHARED, ZONES ),
}

do
    local d = Highway.defaults
    d.direction = "LEFT" -- the way the pins travel: LEFT (right to left, the ring on the left) or RIGHT
    d.maxIcons = 3 -- pins in colour
    d.ghosts = 2 -- dark pins for the picks after them
    d.lanes = true -- off-GCD spells and cooldowns ride below the rail
    d.size = 40 -- a pin's disc (the icon and its coloured rim)
    d.farScale = 1 -- a pin's size at the far end, a fraction of size (1: the same size all the way)
    d.length = 380 -- pixels from the ring's centre to the rail's far end
    d.horizon = 4.5 -- seconds the rail spans
    d.offGCDScale = 0.9
    d.glide = 0.08 -- seconds a pin takes to settle on a new predicted time (0: jump)
    d.shape = "pin" -- pin, round or square
    d.demo = true -- a moving sample while the options are open, out of combat
    d.rail = { enabled = true, thickness = 8, color = { 0.45, 0.29, 0.13, 1 }, edge = { 0.12, 0.07, 0.03, 1 }, ticks = true, tickColor = { 1, 1, 1, 0.5 } }
    d.ring = { enabled = true, size = 36, color = { 1, 0.62, 0.18, 1 }, idleAlpha = 0.75, flash = true, crosshair = true }
    d.iconBorder = { thickness = 3 } -- round and square: the coloured rim's thickness
    d.countdown = {
        enabled = true, -- the seconds beside a pin
        window = 1.5, -- shown once a pin is this close
        nearAt = 0.6, -- yellow from here, red before
        farColor = { 0.86, 0.22, 0.2, 1 },
        nearColor = { 0.98, 0.8, 0.15, 1 },
        dueColor = { 0.22, 0.72, 0.26, 1 },
        font = "Friz Quadrata TT",
        size = 13,
        style = "OUTLINE",
    }
    d.ghost = { color = { 0.06, 0.06, 0.07, 0.85 }, alpha = 0.55 }
    d.waiting = { enabled = false, alpha = 0.45, desaturate = true }
    d.glow = { mode = "pulse", lib = "autocast", procs = true, color = { 1, 0.85, 0.3, 1 } }
    d.tracked = {
        spell = "",
        gap = 4,
        dot = 5,
        fillColor = { 0.85, 0.85, 0.85, 1 },
        readyColor = { GOLD[ 1 ], GOLD[ 2 ], GOLD[ 3 ], 1 },
        emptyColor = { 0.25, 0.25, 0.25, 0.6 },
        text = false,
        textSize = 12,
    }
    d.range.color = { 1, 0.25, 0.25, 1 }
    d.keybindings.anchor, d.keybindings.x, d.keybindings.y, d.keybindings.fontSize = "BOTTOM", 0, 2, 12
end

local function track( T, region, label )
    local n = #T.widgets + 1
    T.widgets[ n ], T.labels[ n ] = region, label
    return region
end

-- Anchors region `f` (on the root, unscaled) with its centre at ( x, y ) from the ring's centre, x toward the far end.
local function place( T, f, x, y )
    f:ClearAllPoints()
    f:SetPoint( "CENTER", T.root, T.pt, T.sx * ( T.x0 + x ), y )
end

local function setFont( fs, font, size, style, color )
    fs:SetFont( LSM:Fetch( "font", font ), size, ns.UI.FontFlags( style ) )
    if color then fs:SetTextColor( color[ 1 ], color[ 2 ], color[ 3 ], color[ 4 ] ) end
    fs:SetWordWrap( false )
end

local function newNote( d, T, i )
    local name = "Encore_" .. d.id .. "_HW" .. i
    local L = "N" .. i
    local b = track( T, CreateFrame( "Button", name, T.root ), L )
    b.display, b.index = d.id, i
    b.Halo = track( T, b:CreateTexture( nil, "BACKGROUND", nil, -3 ), L .. ".Halo" )
    b.Halo:SetTexture( HALO )
    b.Halo:SetBlendMode( "ADD" )
    b.Halo:SetPoint( "CENTER", b, "CENTER", 0, 0 )
    b.Edge = track( T, b:CreateTexture( nil, "BACKGROUND", nil, -2 ), L .. ".Edge" ) -- the pin's dark outline
    b.Pin = track( T, b:CreateTexture( nil, "BACKGROUND", nil, -1 ), L .. ".Pin" ) -- the pin, in its countdown colour
    b.Border = track( T, b:CreateTexture( nil, "BACKGROUND" ), L .. ".Border" ) -- round and square: the coloured rim
    b.Border:SetTexture( WHITE )
    b.Texture = track( T, b:CreateTexture( nil, "ARTWORK" ), L .. ".Texture" )
    b.Texture:SetTexCoord( CROP, 1 - CROP, CROP, 1 - CROP )
    b.Mask = b:CreateMaskTexture()
    b.Mask:SetTexture( CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE" )
    b.BorderMask = b:CreateMaskTexture()
    b.BorderMask:SetTexture( CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE" )
    b.masked = false
    b.Keybinding = track( T, b:CreateFontString( name .. "_KB", "OVERLAY" ), L .. ".Keybinding" )
    b.Countdown = track( T, b:CreateFontString( name .. "_CD", "OVERLAY" ), L .. ".Countdown" )
    b.glowColor = { 0, 0, 0, 0 }
    b.glowing = false
    b.state = false -- false (free), "live", "hit" (cast: through the ring) or "drop" (no longer picked: fades)
    b.recIndex, b.isFocus, b.timersHidden = 0, false, true -- the button contract (UI/Styles.lua): no own timers
    b.etaK, b.haloA, b.tone, b.lane, b.ghost = -1, 0, false, 0, false
    b.x, b.k, b.a = -1, -1, -1

    b:SetScript( "OnMouseDown", Button_OnMouseDown )
    b:SetScript( "OnMouseUp", Button_OnMouseUp )
    b:SetScript( "OnEnter", function()
        if Encore.Pause and b.state == "live" and b.Recommendation then Encore:ShowDiagnosticTooltip( b.Recommendation ) end
    end )
    b:SetScript( "OnLeave", function() EncoreTooltip:Hide() end )
    Encore:ProfileFrame( name, b )
    b:EnableMouse( false )
    b:SetMovable( false )
    b:Hide()
    return b
end

-- Round (pins too) or square: the icon and its rim masked by the circle, or not (Build only).
local function shapeMask( b, round )
    if round == b.masked then return end
    if round then
        b.Texture:AddMaskTexture( b.Mask )
        b.Border:AddMaskTexture( b.BorderMask )
    else
        b.Texture:RemoveMaskTexture( b.Mask )
        b.Border:RemoveMaskTexture( b.BorderMask )
    end
    b.masked = round
end

local function glowOn( b, g )
    local c = b.glowColor
    c[ 1 ], c[ 2 ], c[ 3 ], c[ 4 ] = g.color[ 1 ], g.color[ 2 ], g.color[ 3 ], g.color[ 4 ]
    if g.lib == "pixel" then
        Glower.PixelGlow_Start( b, c )
        b.glowStop = Glower.PixelGlow_Stop
    elseif g.lib == "button" then
        Glower.ButtonGlow_Start( b, c )
        b.glowStop = Glower.ButtonGlow_Stop
    else
        Glower.AutoCastGlow_Start( b, c )
        b.glowStop = Glower.AutoCastGlow_Stop
    end
    b.glowing = true
end

local function glowOff( b )
    if b.glowing then
        if b.glowStop then b:glowStop() end
        b.glowing = false
    end
end

local function setHalo( b, a )
    if abs( a - b.haloA ) >= ALPHA_EPS then
        b.haloA = a
        b.Halo:SetAlpha( a )
        b.Halo:SetShown( a > 0 )
    end
end

-- Note `b`'s row: 1 above the rail, 2 below it (pins point at the rail from either side; the art flips for row 2).
local function setLane( T, b, lane )
    if lane == b.lane then return end
    b.lane = lane
    local up = lane == 1
    local size = T.size
    if T.pin then
        local tex = PIN_TEX * size
        for _, t in ipairs( b.pinParts ) do
            t:ClearAllPoints()
            t:SetTexCoord( 0, 1, up and 0 or 1, up and 1 or 0 )
        end
        b.Pin:SetPoint( "CENTER", b, "CENTER", 0, ( up and -1 or 1 ) * PIN_OFF * size )
        b.Pin:SetSize( tex, tex )
        b.Edge:SetPoint( "CENTER", b, "CENTER", 0, ( up and -1 or 1 ) * PIN_OFF * size )
        b.Edge:SetSize( tex * 1.1, tex * 1.08 )
    end
    b.Countdown:ClearAllPoints()
    if up then b.Countdown:SetPoint( "BOTTOM", b, "TOP", 0, 2 ) else b.Countdown:SetPoint( "TOP", b, "BOTTOM", 0, -2 ) end
    b.x = -1 -- a new row: a new y
end

local function dress( T, b, h )
    local size = T.size
    b:SetSize( size, size )
    b:SetScale( 1 )
    shapeMask( b, h.shape ~= "square" )
    b.round = h.shape ~= "square"
    b.pinParts = b.pinParts or { b.Pin, b.Edge }

    b.Pin:SetTexture( PIN )
    b.Edge:SetTexture( PIN )
    b.Edge:SetVertexColor( 0, 0, 0, 0.85 )
    b.Pin:SetShown( T.pin )
    b.Edge:SetShown( T.pin )

    local inner = T.pin and size * ICON_IN or size
    b.Texture:ClearAllPoints()
    b.Texture:SetPoint( "CENTER", b, "CENTER", 0, 0 )
    b.Texture:SetSize( inner, inner )
    b.Mask:ClearAllPoints()
    b.Mask:SetPoint( "CENTER", b, "CENTER", 0, 0 )
    b.Mask:SetSize( inner, inner )
    local th = h.iconBorder.thickness
    b.Border:ClearAllPoints()
    b.Border:SetPoint( "TOPLEFT", b, "TOPLEFT", -th, th )
    b.Border:SetPoint( "BOTTOMRIGHT", b, "BOTTOMRIGHT", th, -th )
    b.BorderMask:ClearAllPoints()
    b.BorderMask:SetPoint( "TOPLEFT", b, "TOPLEFT", -th, th )
    b.BorderMask:SetPoint( "BOTTOMRIGHT", b, "BOTTOMRIGHT", th, -th )
    b.Border:SetShown( not T.pin )

    local gc = h.glow.color
    b.Halo:SetSize( size * 1.9, size * 1.9 )
    b.Halo:SetVertexColor( gc[ 1 ], gc[ 2 ], gc[ 3 ], 1 )
    b.Halo:SetAlpha( 0 )
    b.Halo:Hide()
    b.haloA = 0

    local kb = h.keybindings
    setFont( b.Keybinding, kb.font, kb.fontSize, kb.fontStyle, kb.color )
    b.Keybinding:ClearAllPoints()
    b.Keybinding:SetPoint( kb.anchor, b, kb.anchor, kb.x, kb.y )
    b.Keybinding.kbAnchor = nil -- Build set the points: the next text sets them again if it differs
    b.Keybinding:SetText( nil )

    local cd = h.countdown
    setFont( b.Countdown, cd.font, cd.size, cd.style )
    b.Countdown:SetText( "" )
    b.Countdown:SetShown( cd.enabled )
    b.etaK = -1

    b.lane = 0
    setLane( T, b, 1 )
    glowOff( b )
    b:Hide()
    b:SetAlpha( 1 )
    b.state, b.claimed, b.ghost, b.tone = false, false, false, false
    b.Action, b.Recommendation, b.Key, b.Keybind, b.actionID = nil, nil, nil, nil, nil
    b.recIndex, b.isFocus = 0, false
    b.x, b.k, b.a = -1, -1, -1
    b.gated, b.unusable, b.far, b.proc, b.offGCD, b.dim = false, false, false, false, false, 1
end

-- Shows what Clear hid: from Build, from the first publish after a Clear and when the demo starts.
local function reveal( T )
    T.root:Show()
    T.cleared = false
end

--- Builds (or reuses) the root, the rail and its ticks, the ring, the tracked spell's dots and the notes on `d`, sizes
--- `d` and returns the note buttons.
function Highway.Build( d, conf )
    local h = conf.highway
    local T = d.styleFrames.highway
    if not T then
        T = { widgets = {}, labels = {}, notes = {}, order = {}, dots = {}, ticks = {}, fake = {}, fakeRes = {}, demoTex = {}, demoKey = {} }
        d.styleFrames.highway = T
        T.d = d
        T.root = track( T, CreateFrame( "Frame", nil, d ), "Root" )
        T.railEdge = track( T, T.root:CreateTexture( nil, "BACKGROUND", nil, -2 ), "Rail.Edge" )
        T.rail = track( T, T.root:CreateTexture( nil, "BACKGROUND", nil, -1 ), "Rail" )
        T.railHi = track( T, T.root:CreateTexture( nil, "BACKGROUND" ), "Rail.Light" )
        for k = 1, MAX_TICKS do
            T.ticks[ k ] = track( T, T.root:CreateTexture( nil, "BORDER" ), "Tick" .. k )
        end
        T.bloom = track( T, T.root:CreateTexture( nil, "BORDER", nil, 1 ), "Bloom" )
        T.bloom:SetTexture( HALO )
        T.bloom:SetBlendMode( "ADD" )
        T.cross = track( T, T.root:CreateTexture( nil, "ARTWORK", nil, -1 ), "Ring.Cross" )
        T.ring = track( T, T.root:CreateTexture( nil, "ARTWORK" ), "Ring" )
        T.ringIn = track( T, T.root:CreateTexture( nil, "ARTWORK" ), "Ring.Inner" )
        T.ringDot = track( T, T.root:CreateTexture( nil, "ARTWORK" ), "Ring.Dot" )
        for k = 1, MAX_DOTS do
            local t = track( T, T.root:CreateTexture( nil, "ARTWORK" ), "Dot" .. k )
            t:SetTexture( DOT )
            T.dots[ k ] = t
        end
        T.gaugeText = track( T, T.root:CreateFontString( nil, "OVERLAY" ), "Gauge.Text" )
        for i = 1, NOTES do T.notes[ i ] = newNote( d, T, i ) end
        for i = 1, MAX_ORDER do
            T.fake[ i ] = { actionName = "", actionID = 1, texture = QUESTION, keybind = "", exact_time = 0, offGCD = false, floors = {}, cost = 0 }
            T.fakeRes[ i ] = { inRange = true, inMelee = true, usable = true, glow = false }
            T.order[ i ] = false
        end
    end

    local s = Encore:GetScale()
    local size = h.size
    T.size, T.pin = size, h.shape == "pin"
    local rl, rg, tr = h.rail, h.ring, h.tracked
    local railH = rl.enabled and rl.thickness or 2
    local ringS = rg.size
    local ability = tr.spell ~= "" and Registry.Abilities()[ tr.spell ]
    local id = ability and rawget( ability, "id" )
    T.trackedID = type( id ) == "number" and id > 0 and id or nil
    local gaugeR = ringS / 2 + tr.gap + tr.dot / 2

    -- the rows: a pin's disc centre above (row 1) or below (row 2) the rail, its tail's tip on the rail's edge; round and
    -- square icons ride on the rail, row 2 one icon below
    if T.pin then
        T.y1 = railH / 2 + PIN_TIP * size
        T.y2 = -T.y1
    else
        T.y1, T.y2 = 0, -( size + 4 )
    end
    local reach = mmax( abs( T.y1 ), abs( T.y2 ) ) + size / 2 + h.countdown.size + 6
    local back = ceil( mmax( ringS * 0.8, size / 2 + 4, T.trackedID and gaugeR + tr.dot / 2 + 2 or 0 ) )
    local height = ceil( mmax( 2 * reach, ringS * 1.6, T.trackedID and 2 * gaugeR + tr.dot or 0 ) ) + 4
    local width = back + h.length + ceil( size / 2 ) + 4

    local left = h.direction ~= "RIGHT" -- the ring on the left, pins travelling right to left
    T.pt, T.sx, T.x0 = left and "LEFT" or "RIGHT", left and 1 or -1, back
    d:SetSize( width * s, height * s )
    T.root:ClearAllPoints()
    T.root:SetAllPoints( d )
    T.root:SetScale( s )
    T.root:SetFrameLevel( d:GetFrameLevel() + 3 ) -- above config mode's backdrop, so the demo shows over it

    -- the rail: a dark edge, the bronze fill and a light line along its top, from behind the ring to the far end
    local x1, x2 = -ringS / 2, h.length + size / 2
    local mid, span = ( x1 + x2 ) / 2, x2 - x1
    T.railEdge:SetTexture( WHITE )
    T.railEdge:SetVertexColor( rl.edge[ 1 ], rl.edge[ 2 ], rl.edge[ 3 ], rl.edge[ 4 ] )
    T.railEdge:SetSize( span + 2, railH + 2 )
    place( T, T.railEdge, mid, 0 )
    T.rail:SetTexture( WHITE )
    T.rail:SetVertexColor( rl.color[ 1 ], rl.color[ 2 ], rl.color[ 3 ], rl.color[ 4 ] )
    T.rail:SetSize( span, railH )
    place( T, T.rail, mid, 0 )
    T.railHi:SetTexture( WHITE )
    T.railHi:SetVertexColor( 1, 0.85, 0.6, 0.22 * rl.color[ 4 ] )
    T.railHi:SetSize( span, mmax( 1, floor( railH / 4 ) ) )
    place( T, T.railHi, mid, railH / 2 - mmax( 1, floor( railH / 4 ) ) / 2 - 0.5 )
    T.railEdge:SetShown( rl.enabled )
    T.rail:SetShown( rl.enabled )
    T.railHi:SetShown( rl.enabled )
    local tc, secs = rl.tickColor, floor( h.horizon )
    for k = 1, MAX_TICKS do
        local t = T.ticks[ k ]
        if rl.enabled and rl.ticks and k <= secs then
            t:SetTexture( WHITE )
            t:SetVertexColor( tc[ 1 ], tc[ 2 ], tc[ 3 ], tc[ 4 ] )
            t:SetSize( 2, railH )
            place( T, t, k / h.horizon * h.length, 0 )
            t:Show()
        else
            t:Hide()
        end
    end

    -- the target: an outer and an inner ring, a centre dot and a thin upright line through it
    local c = rg.color
    for _, t in ipairs( { T.ring, T.ringIn, T.ringDot, T.cross } ) do
        t:SetVertexColor( c[ 1 ], c[ 2 ], c[ 3 ], 1 )
        t:SetShown( rg.enabled )
        place( T, t, 0, 0 )
    end
    T.ring:SetTexture( RING )
    T.ring:SetSize( ringS, ringS )
    T.ringIn:SetTexture( RING_IN )
    T.ringIn:SetSize( ringS * 0.55, ringS * 0.55 )
    T.ringDot:SetTexture( DOT )
    T.ringDot:SetSize( ringS * 0.16, ringS * 0.16 )
    T.cross:SetTexture( WHITE )
    T.cross:SetSize( 1.5, mmin( height - 8, 2 * reach - 2 * h.countdown.size ) )
    T.cross:SetShown( rg.enabled and rg.crosshair )
    T.ringA = rg.idleAlpha
    T.ring:SetAlpha( T.ringA * c[ 4 ] )
    T.ringIn:SetAlpha( T.ringA * c[ 4 ] )
    T.ringDot:SetAlpha( T.ringA * c[ 4 ] )
    T.cross:SetAlpha( 0.35 * c[ 4 ] )
    T.bloom:SetSize( ringS * 2, ringS * 2 )
    T.bloom:SetVertexColor( c[ 1 ], c[ 2 ], c[ 3 ], 1 )
    place( T, T.bloom, 0, 0 )
    T.bloom:SetAlpha( 0 )
    T.bloom:SetShown( rg.enabled )
    T.flash, T.bloomA = 0, 0

    -- the tracked spell's half circle: dots from the bottom to the top, on the side away from the incoming pins
    local n = mmin( MAX_DOTS, mmax( 7, floor( pi * gaugeR / ( tr.dot * 1.6 ) ) ) )
    T.dotCount = T.trackedID and n or 0
    for k = 1, MAX_DOTS do
        local t = T.dots[ k ]
        if k <= T.dotCount then
            local a = -pi / 2 + pi * ( k - 1 ) / ( n - 1 )
            t:SetSize( tr.dot, tr.dot )
            place( T, t, -gaugeR * cos( a ), gaugeR * sin( a ) )
            t:Show()
        else
            t:Hide()
        end
    end
    setFont( T.gaugeText, h.countdown.font, tr.textSize, "OUTLINE", tr.readyColor )
    place( T, T.gaugeText, -( gaugeR + tr.dot / 2 + tr.textSize * 0.6 ), 0 )
    T.gaugeText:SetText( "" )
    T.gaugeText:SetShown( T.trackedID ~= nil and tr.text )
    T.lit, T.gaugeReady, T.gaugeTimer, T.gaugeK = -1, nil, 0, -1

    for i = 1, NOTES do dress( T, T.notes[ i ], h ) end
    for i = 1, MAX_ORDER do T.order[ i ] = false end
    T.count, T.demoOn, T.demoHead = 0, false, 0
    reveal( T )

    local out = Encore.Engine.Output[ d.id ]
    if out and out.count > 0 then d.NewRecommendations = true end -- redraw what is published with the new layout

    return T.notes
end

-- A pin's size at x pixels from the ring: full at the ring, farScale at the far end (1 by default: one size).
local function sizeAt( h, x )
    local g = 1 - x / h.length
    if g < 0 then g = 0 end
    return h.size * ( h.farScale + ( 1 - h.farScale ) * g * g )
end

local function setKb( b, kb, g, i, text )
    local show = text ~= nil and text ~= "" and not b.ghost and kb.enabled and ( i == 1 or kb.queued )
    ns.UI.SetKeybindingText( b.Keybinding, b, show and text or nil, kb.anchor, kb.x, kb.y, g )
end

-- The countdown tone of a pin `t` seconds out: 3 due (green), 2 close (yellow), 1 coming (red); 0 for a ghost.
local function toneOf( b, cd, t )
    if b.ghost then return 0 end
    if t <= READY_EPS then return 3 end
    if t <= cd.nearAt then return 2 end
    return 1
end

-- The pin (or the rim) and the seconds in tone `tone`.
local function setTone( b, h, tone )
    if tone == b.tone then return end
    b.tone = tone
    local cd = h.countdown
    local c = tone == 3 and cd.dueColor or tone == 2 and cd.nearColor or tone == 1 and cd.farColor or h.ghost.color
    b.Pin:SetVertexColor( c[ 1 ], c[ 2 ], c[ 3 ], c[ 4 ] )
    b.Border:SetVertexColor( c[ 1 ], c[ 2 ], c[ 3 ], c[ 4 ] )
    b.Countdown:SetTextColor( c[ 1 ], c[ 2 ], c[ 3 ], 1 )
end

-- The icon's tint and fade from its flags: a ghost dark, out of range in the range colour, short of its resource faded
-- (when the waiting look is on).
local function paint( b, h )
    local w = h.waiting
    local fade = w.enabled and ( b.gated or b.unusable )
    if b.ghost then
        b.Texture:SetVertexColor( 1, 1, 1, 1 )
        b.Texture:SetDesaturated( true )
        b.dim = h.ghost.alpha
    elseif b.far then
        local c = h.range.color
        b.Texture:SetVertexColor( c[ 1 ], c[ 2 ], c[ 3 ], c[ 4 ] )
        b.Texture:SetDesaturated( true )
        b.dim = fade and w.alpha or 1
    else
        b.Texture:SetVertexColor( 1, 1, 1, 1 )
        b.Texture:SetDesaturated( fade and w.desaturate or false )
        b.dim = fade and w.alpha or 1
    end
end

-- The flags of note `b` from its resolved record `rr` (range, usability, the overlay glow).
local function flags( b, h, rr )
    if not rr then return end
    local range = h.range
    b.far = range.enabled and ( range.type == "melee" and not rr.inMelee or range.type == "ability" and not rr.inRange ) or false
    b.unusable = not rr.usable
    b.proc = rr.glow and true or false
end

-- A free note, or the leaving note that left first.
local function take( T )
    local oldest
    for i = 1, NOTES do
        local b = T.notes[ i ]
        if not b.state then return b end
        if b.state ~= "live" and ( not oldest or b.t0 < oldest.t0 ) then oldest = b end
    end
    if oldest then
        glowOff( oldest )
        oldest:Hide()
        oldest.state = false
        return oldest
    end
end

local function spawn( b, exact, now )
    b.state, b.at, b.Key, b.born = "live", exact, exact, now
    b.x, b.k, b.a = -1, -1, -1
    b.etaK, b.tone = -1, false
    b:SetAlpha( 0 )
    b:Show()
end

-- A note no record kept: through the ring (it was due: cast) or faded where it is.
local function leave( T, h, b, now )
    local hit = not b.ghost and b.Key - now <= READY_EPS + 0.15
    b.state = hit and "hit" or "drop"
    b.t0, b.k0, b.a0 = now, b.k > 0 and b.k or 1, b.a > 0 and b.a or 1
    b.recIndex, b.Recommendation = 0, nil
    glowOff( b )
    setHalo( b, 0 )
    b.Keybinding:SetText( nil )
    b.Countdown:SetText( "" )
    b.etaK = 0
    b:SetFrameLevel( T.root:GetFrameLevel() + 2 * MAX_ORDER + 4 ) -- the flash over the next pin
    if hit and h.ring.flash then T.flash = 1 end
end

-- Whether record `r` rides below the rail: an off-GCD spell or a cooldown (its toggle), with the rows on.
local function lower( h, r, action )
    if not h.lanes then return false end
    if r.offGCD then return true end
    local a = Registry.Abilities()[ action ]
    return a ~= nil and rawget( a, "toggle" ) == "cooldowns"
end

-- A publish (or a demo step): the first maxIcons + ghosts records with an action and a time keep their notes by spell
-- and time; a record no note matches takes a free one, and a live note no record kept leaves.
local function sync( T, h, recs, count, res, now )
    local notes = T.notes
    for i = 1, NOTES do notes[ i ].claimed = false end
    local n, colored = 0, mmin( MAX_ICONS, h.maxIcons )
    local maxN, kb = colored + mmin( MAX_GHOSTS, h.ghosts ), h.keybindings
    for i = 1, count do
        if n >= maxN then break end
        local r = recs[ i ]
        local action, exact = r.actionName, r.exact_time
        local id = r.actionID
        local twin = false -- a held record (Output's steady icons) can repeat the pick before it: drawn once
        for k = 1, n do
            local o = T.order[ k ]
            if o.Action == action and abs( o.Key - ( exact or 0 ) ) < 0.05 then twin = true end
        end
        if action and exact and id and not twin and not ( id < 0 and id > -100 and action ~= "cancel_buff" ) then
            n = n + 1
            local best, bestD = nil, MATCH
            local dueRec = exact - now <= DUE_MATCH
            for k = 1, NOTES do
                local b = notes[ k ]
                if b.state == "live" and not b.claimed and b.Action == action and ( dueRec or b.Key - now > READY_EPS + 0.05 ) then
                    local dd = abs( b.Key - exact )
                    if dd < bestD then best, bestD = b, dd end
                end
            end
            if not best then
                best = take( T )
                spawn( best, exact, now )
            end
            best.claimed = true
            best.ghost = n > colored
            best.Key, best.Action, best.actionID, best.recIndex = exact, action, id, i
            best.Recommendation, best.offGCD = r, r.offGCD == true
            best.Texture:SetTexture( r.iconOverride or r.texture )
            setLane( T, best, lower( h, r, action ) and 2 or 1 )
            local rt = r.resource_type
            local have = rt and r.floors[ rt ]
            best.gated = have ~= nil and have < r.cost
            best.Keybind = r.keybind
            setKb( best, kb, h.gamepad, i, r.keybind )
            if best.ghost then
                best.far, best.unusable, best.proc = false, false, false
                best.Countdown:SetText( "" )
                best.etaK = 0
            else
                flags( best, h, res and res[ i ] )
            end
            paint( best, h )
            T.order[ n ] = best
        end
    end
    for k = n + 1, MAX_ORDER do T.order[ k ] = false end
    T.count = n
    for k = 1, NOTES do
        local b = notes[ k ]
        if b.state == "live" and not b.claimed then leave( T, h, b, now ) end
    end
    local base = T.root:GetFrameLevel() + 2
    for k = 1, n do T.order[ k ]:SetFrameLevel( base + 2 * ( MAX_ORDER - k + 1 ) ) end -- the nearer pin on top
end

-- Every live note leaves (a blank publish).
local function dropAll( T, h, now )
    for k = 1, NOTES do
        local b = T.notes[ k ]
        if b.state == "live" then leave( T, h, b, now ) end
    end
    for k = 1, MAX_ORDER do T.order[ k ] = false end
    T.count = 0
end

local function finish( b )
    glowOff( b )
    setHalo( b, 0 )
    b:Hide()
    b.state = false
    b.Action, b.Key, b.actionID = nil, nil, nil
end

local function setNote( T, b, x, scale, a )
    if scale < 0.05 then scale = 0.05 end
    if abs( scale - b.k ) >= SCALE_EPS then
        b.k = scale
        b:SetScale( scale )
        b.x = -1 -- the offsets are in the note's own (scaled) units
    end
    if abs( x - b.x ) >= MOVE_EPS then
        b.x = x
        b:ClearAllPoints()
        b:SetPoint( "CENTER", T.root, T.pt, T.sx * ( T.x0 + x ) / b.k, ( b.lane == 2 and T.y2 or T.y1 ) / b.k )
    end
    if abs( a - b.a ) >= ALPHA_EPS then
        b.a = a
        b:SetAlpha( a )
    end
end

-- The press and proc glows of live note `b`; returns the pulse's scale factor.
local function glowLook( b, h, due, now )
    local g = h.glow
    local mode = g.mode
    local press = due and mode ~= "none"
    local proc = b.proc and g.procs and mode ~= "none"
    local pulse, halo = 1, 0
    if press and mode == "pulse" then pulse = 1 + 0.07 * sin( now * 2 * pi * 1.6 ) end
    if mode == "halo" and ( press or proc ) then halo = 0.55 + 0.3 * sin( now * 2 * pi * 1.2 )
    elseif mode == "pulse" and proc then halo = 0.55 end
    setHalo( b, halo )
    local custom = mode == "custom" and ( press or proc )
    if custom ~= b.glowing then
        if custom then glowOn( b, g ) else glowOff( b ) end
    end
    return pulse
end

-- The seconds beside a coloured pin, once it is within the countdown window.
local function countdown( b, cd, t )
    if not cd.enabled or b.ghost then return end
    local k = t <= cd.window and etaStep( t ) or 0
    if k ~= b.etaK then
        b.etaK = k
        b.Countdown:SetText( ETA[ k ] )
    end
end

-- Every frame: the live notes toward their times (spaced in their row, sized, faded and coloured), the leaving ones
-- through their exit, the ring's brightness and flash.
local function animate( T, h, now, elapsed )
    local keep = h.glide > 0 and exp( -elapsed / h.glide ) or 0
    local len, hz, cd = h.length, h.horizon, h.countdown
    local px1, ps1, px2, ps2 -- the previous pin's x and size in rows 1 and 2
    local first = T.order[ 1 ]
    local due = first and first.Key - now <= READY_EPS or false
    for k = 1, T.count do
        local b = T.order[ k ]
        b.at = b.Key + ( b.at - b.Key ) * keep
        local t = b.at - now
        if t < 0 then t = 0 end
        local x = t / hz * len
        if x > len then x = len end
        local sz = sizeAt( h, x )
        local prevX, prevS
        if b.lane == 2 then prevX, prevS = px2, ps2 else prevX, prevS = px1, ps1 end
        if prevX then
            local minX = prevX + 0.5 * ( prevS + sz ) * SPACING
            if x < minX then
                x = minX < len and minX or len
                sz = sizeAt( h, x )
            end
        end
        if b.lane == 2 then px2, ps2 = x, sz else px1, ps1 = x, sz end
        local scale = sz / h.size
        if b.offGCD then scale = scale * h.offGCDScale end
        local a = b.dim
        local u = x / len
        if u > 0.85 then a = a * ( 1 - ( u - 0.85 ) / 0.15 * 0.7 ) end -- fades in from the far end
        local age = now - b.born
        if age < SPAWN_TIME then a = a * age / SPAWN_TIME end
        local left = b.Key - now
        setTone( b, h, toneOf( b, cd, left ) )
        if not b.ghost then scale = scale * glowLook( b, h, k == 1 and due, now ) end
        setNote( T, b, x, scale, a )
        countdown( b, cd, left )
    end
    for i = 1, NOTES do
        local b = T.notes[ i ]
        local st = b.state
        if st == "hit" or st == "drop" then
            local p = ( now - b.t0 ) / ( st == "hit" and HIT_TIME or DROP_TIME )
            if p >= 1 then
                finish( b )
            elseif st == "hit" then
                setNote( T, b, 0, b.k0 * ( 1 + 0.3 * p ), b.a0 * ( 1 - p ) )
            else
                setNote( T, b, b.x, b.k, b.a0 * ( 1 - p ) )
            end
        end
    end

    local rg = h.ring
    if rg.enabled then
        local target = due and 1 or rg.idleAlpha
        local ra = T.ringA + ( target - T.ringA ) * mmin( 1, elapsed * 12 )
        if abs( ra - T.ringA ) >= 0.002 then
            T.ringA = ra
            local a = ra * rg.color[ 4 ]
            T.ring:SetAlpha( a )
            T.ringIn:SetAlpha( a )
            T.ringDot:SetAlpha( a )
        end
        T.flash = T.flash * exp( -elapsed / FLASH_DECAY )
        local bloom = mmax( T.flash, due and 0.35 or 0 )
        if abs( bloom - T.bloomA ) >= ALPHA_EPS then
            T.bloomA = bloom
            T.bloom:SetAlpha( bloom )
        end
    end
end

-- The tracked spell's half circle: lit from the bottom as its cooldown recovers, every dot gold once it is ready.
local function gauge( T, h, now, elapsed )
    T.gaugeTimer = T.gaugeTimer - elapsed
    if T.gaugeTimer > 0 then return end
    T.gaugeTimer = GAUGE_STEP
    local p, left = 1, 0
    if T.demoOn then
        local c = ( now - T.demoT0 ) % DEMO_CYCLE
        p, left = c / DEMO_FILL, DEMO_FILL - c
    else
        local info = C_Spell.GetSpellCooldown( T.trackedID ) -- the hybrid: plain times, modelled when secret
        local start, duration = 0, 0
        if info then start, duration = info.startTime or 0, info.duration or 0 end
        if start > 0 and duration > GCD_MAX then
            p, left = ( now - start ) / duration, start + duration - now
        end
    end
    if p > 1 then p = 1 elseif p < 0 then p = 0 end
    local ready = p >= 1
    local n = T.dotCount
    local lit = ready and n or floor( p * n )
    if lit ~= T.lit or ready ~= T.gaugeReady then
        T.lit, T.gaugeReady = lit, ready
        local tr = h.tracked
        for k = 1, n do
            local c = ready and tr.readyColor or ( k <= lit and tr.fillColor or tr.emptyColor )
            T.dots[ k ]:SetVertexColor( c[ 1 ], c[ 2 ], c[ 3 ], c[ 4 ] )
        end
    end
    if h.tracked.text then
        local k = ready and 0 or etaStep( left )
        if k ~= T.gaugeK then
            T.gaugeK = k
            T.gaugeText:SetText( ETA_INT[ k ] )
        end
    end
end

-- The demo's sample spells: the textures (and keybinds) of what the display shows now, else the class's abilities.
local function demoSpells( T, out )
    local tex, keys = T.demoTex, T.demoKey
    for i = #tex, 1, -1 do tex[ i ], keys[ i ] = nil, nil end
    local recs = out.recs
    for i = 1, out.count do
        local r = recs[ i ]
        local t = r.iconOverride or r.texture
        local seen = t == nil
        for k = 1, #tex do
            if tex[ k ] == t then seen = true end
        end
        if not seen and #tex < 6 then
            tex[ #tex + 1 ] = t
            keys[ #tex ] = type( r.keybind ) == "string" and r.keybind ~= "" and r.keybind or DEMO_KEYS[ #tex ]
        end
    end
    if #tex < 3 then
        local abilities = Registry.Abilities()
        for key in pairs( Registry.AbilityList() ) do
            local a = abilities[ key ]
            local t = a and rawget( a, "texture" )
            local id = a and rawget( a, "id" )
            if t and type( id ) == "number" and id > 0 and #tex < 6 then
                tex[ #tex + 1 ] = t
                keys[ #tex ] = DEMO_KEYS[ #tex ]
            end
        end
    end
    if #tex == 0 then tex[ 1 ], keys[ 1 ] = QUESTION, DEMO_KEYS[ 1 ] end
end

-- One demo step: the notes due from `head` on, every DEMO_GAP seconds, with a few short of rage, out of range, off the
-- GCD (below the rail) or proccing, so each look can be seen.
local function demoStep( T, h, now )
    local head = floor( ( now - T.demoT0 - DEMO_HOLD ) / DEMO_GAP ) + 1
    if head < 1 then head = 1 end
    if head == T.demoHead then return end
    T.demoHead = head
    local tex, keys, nTex = T.demoTex, T.demoKey, #T.demoTex
    for k = 1, MAX_ORDER do
        local j = head + k - 1
        local r, rr = T.fake[ k ], T.fakeRes[ k ]
        local m = ( j - 1 ) % nTex + 1
        r.actionName = DEMO_NAMES[ ( j - 1 ) % #DEMO_NAMES + 1 ]
        r.texture, r.keybind = tex[ m ], keys[ m ]
        r.offGCD = j % 4 == 2
        r.exact_time = T.demoT0 + j * DEMO_GAP - ( r.offGCD and DEMO_GAP / 2 or 0 )
        if j % 5 == 3 then
            r.resource_type, r.floors.demo, r.cost = "demo", 0, 1
        else
            r.resource_type, r.cost = nil, 0
        end
        rr.inRange, rr.inMelee = j % 7 ~= 5, j % 7 ~= 5
        rr.glow = j % 8 == 6
    end
    sync( T, h, T.fake, MAX_ORDER, T.fakeRes, now )
end

-- Starts or stops the demo: its notes replace the real ones until it stops, then the published records come back.
local function setDemo( d, T, h, out, on, now )
    T.demoOn = on
    for k = 1, NOTES do finish( T.notes[ k ] ) end
    for k = 1, MAX_ORDER do T.order[ k ] = false end
    T.count, T.lit, T.gaugeReady, T.gaugeTimer = 0, -1, nil, 0
    if on then
        demoSpells( T, out )
        T.demoT0, T.demoHead = now, 0
        reveal( T )
    else
        d.NewRecommendations = true
    end
end

--- Every frame: the demo (options open, out of combat), the notes' motion and the tracked spell's half circle.
function Highway.Tick( d, conf, out, now, elapsed )
    local T = d.styleFrames.highway
    local h = conf.highway
    local demo = Encore.Config and h.demo and not Status.combat or false
    if demo ~= T.demoOn then setDemo( d, T, h, out, demo, now ) end
    if T.cleared then return end
    if demo then demoStep( T, h, now ) end
    animate( T, h, now, elapsed )
    if T.dotCount > 0 then gauge( T, h, now, elapsed ) end
end

--- On a publish (d.NewRecommendations, which Draw consumes) or the 0.25 s pulse: the notes from the records, then
--- range, usability and procs from d.resolved.
function Highway.Draw( d, conf, out, status )
    local T, h = d.styleFrames.highway, conf.highway
    if T.demoOn then
        d.NewRecommendations = nil
        return
    end
    local now = GetTime()
    if d.NewRecommendations then
        d.NewRecommendations = nil
        if out.count == 0 or out.version == d.blankVersion then
            dropAll( T, h, now )
            return
        end
        if T.cleared then reveal( T ) end
        sync( T, h, out.recs, out.count, d.resolved, now )
        animate( T, h, now, 0 ) -- placed at once (Tick ran before this publish)
        return
    end
    local res = d.resolved
    for k = 1, T.count do
        local b = T.order[ k ]
        if not b.ghost then
            flags( b, h, res and res[ b.recIndex ] )
            paint( b, h )
        end
    end
end

function Highway.OnGameEvent( d, conf, event, ... )
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local T = d.styleFrames.highway
        if T.demoOn then return end
        local show, id = event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", ...
        for k = 1, T.count do
            local b = T.order[ k ]
            if b.actionID == id and not b.ghost then b.proc = show end
        end
    end
end

function Highway.UpdateKeybindings( d )
    local T = d.styleFrames.highway
    if not T or T.demoOn then return end
    local conf = Encore.DB.profile.displays[ d.id ]
    local h = conf.highway
    for k = 1, T.count do
        local b = T.order[ k ]
        if b.Action then
            b.Keybind = Encore:GetBindingForAction( b.Action, conf, b.recIndex )
            setKb( b, h.keybindings, h.gamepad, b.recIndex, b.Keybind )
        end
    end
end

--- Hides every frame and region it built (unsubscribe, Deactivate, a style switch).
function Highway.Clear( d )
    local T = d.styleFrames.highway
    if not T then return end
    for k = 1, NOTES do
        local b = T.notes[ k ]
        finish( b )
        b.recIndex, b.Recommendation = 0, nil
    end
    for k = 1, MAX_ORDER do T.order[ k ] = false end
    T.count, T.demoOn = 0, false
    T.root:Hide()
    T.cleared = true
end

--- The display frame itself: Build sizes it to the highway.
function Highway.Perimeter( d )
    return d, d, d, d
end

local function optRange( name, desc, min, max, step, order, width )
    return { type = "range", name = name, desc = desc, min = min, max = max, step = step, order = order, width = width or 1.49 }
end

local function optToggle( name, desc, order, width )
    return { type = "toggle", name = name, desc = desc, order = order, width = width or 1.49 }
end

local function optSelect( name, desc, values, order, width )
    return { type = "select", name = name, desc = desc, values = values, order = order, width = width or 1.49 }
end

local function optColor( name, desc, order )
    return { type = "color", name = name, desc = desc, hasAlpha = true, order = order, width = 1.49 }
end

local function section( name, order, args )
    return { type = "group", inline = true, name = name, order = order, args = args }
end

local function tab( name, desc, order, args )
    return { type = "group", name = name, desc = desc, order = order, args = args }
end

-- The spells the half circle can track: the class's listed abilities with a cooldown or charges.
local function trackable()
    local values = { [ "" ] = L["None"] }
    local abilities = Registry.Abilities()
    for key, label in pairs( Registry.AbilityList() ) do
        local a = abilities[ key ]
        if a then
            local id, cd, charges, funcs = rawget( a, "id" ), rawget( a, "cooldown" ), rawget( a, "charges" ), rawget( a, "funcs" )
            local timed = type( cd ) == "number" and cd > 0 or type( charges ) == "number" and charges > 1
            if not timed and type( funcs ) == "table" then timed = funcs.cooldown ~= nil or funcs.charges ~= nil end
            if type( id ) == "number" and id > 0 and timed then values[ key ] = label end
        end
    end
    return values
end

--- The style's tabs, keyed so the path finds the config: a tab or inline group named like a config subtable (rail,
--- ring, countdown, ghost, glow, tracked, keybindings, range, gamepad) holds that subtable's options; the rest are flat
--- in highway.
function Highway.Options( id, conf )
    local P = ns.UI.DisplayOptionParts
    local fe = P.fontElements
    local h = conf.highway

    local highway = {
        sec_layout = section( L["Layout"], 1, {
            direction = optSelect( L["Direction"], L["Which way the pins travel; the target ring sits at the end they travel to."], { LEFT = L["Right to Left"], RIGHT = L["Left to Right"] }, 1 ),
            maxIcons = optRange( L["Pins"], L["How many pins ride the rail in color."], 1, MAX_ICONS, 1, 2 ),
            ghosts = optRange( L["Ghost Pins"], L["How many dark pins show the spells after them."], 0, MAX_GHOSTS, 1, 3 ),
            lanes = optToggle( L["Off-GCD Below"], L["Spells off the global cooldown and cooldowns ride below the rail, the rest above it."], 4 ),
            shape = optSelect( L["Shape"], L["Map pins pointing at the rail, or round or square icons riding on it."], { pin = L["Pin"], round = L["Round"], square = L["Square"] }, 5 ),
            size = optRange( L["Pin Size"], L["The size of a pin's icon disc."], 16, 96, 1, 6 ),
            farScale = optRange( L["Far Size"], L["A pin's size at the far end of the rail, a fraction of its size at the ring (1: the same size all the way)."], 0.2, 1, 0.01, 7 ),
            length = optRange( L["Length"], L["The rail's length in pixels, from the ring to the far end."], 80, 800, 1, 8 ),
            horizon = optRange( L["Seconds Shown"], L["How many seconds ahead the rail reaches; a later pin waits at the far end."], 1.5, 10, 0.1, 9 ),
            offGCDScale = optRange( L["Off-GCD Size"], L["The size of a spell that does not trigger the global cooldown, a fraction of a normal pin's."], 0.5, 1, 0.01, 10 ),
            glide = optRange( L["Glide"], L["Seconds a pin takes to settle on a new predicted time (0: jump)."], 0, 0.5, 0.01, 11 ),
            demo = optToggle( L["Demo While Options Are Open"], L["Out of combat, run a moving sample on the highway while the options are open, so each change shows at once."], 12 ),
        } ),
        rail = section( L["Rail"], 2, {
            enabled = optToggle( L["Show Rail"], L["Show the rail the pins ride."], 1 ),
            thickness = optRange( L["Thickness"], L["The rail's thickness in pixels."], 2, 16, 1, 2 ),
            color = optColor( L["Color"], L["The rail's color."], 3 ),
            edge = optColor( L["Edge Color"], L["The rail's outline."], 4 ),
            ticks = optToggle( L["Second Ticks"], L["A mark on the rail every second."], 5 ),
            tickColor = optColor( L["Tick Color"], L["The color of the second marks."], 6 ),
        } ),
        ring = section( L["Target Ring"], 3, {
            enabled = optToggle( L["Show Ring"], L["Show the target the pins travel to."], 1 ),
            size = optRange( L["Size"], L["The target ring's size."], 16, 96, 1, 2 ),
            color = optColor( L["Color"], L["The target ring's color."], 3 ),
            idleAlpha = optRange( L["Resting Brightness"], L["The ring's brightness while nothing is due; it goes full when a pin is due."], 0, 1, 0.05, 4 ),
            flash = optToggle( L["Flash on Cast"], L["Flash the ring when a pin goes through it."], 5 ),
            crosshair = optToggle( L["Crosshair"], L["A thin upright line through the ring."], 6 ),
        } ),
        iconBorder = section( L["Round and Square Icons"], 4, {
            thickness = optRange( L["Rim Thickness"], L["The colored rim around a round or square icon (the Countdown colors)."], 1, 8, 1, 1 ),
        } ),
    }

    local countdownFont = {
        enabled = optToggle( L["Show Seconds"], L["Show the seconds beside a pin as it comes in."], 1 ),
        window = optRange( L["Show From"], L["The seconds show once a pin is this close."], 0.5, 10, 0.1, 2 ),
        nearAt = optRange( L["Yellow From"], L["A pin turns from red to yellow this many seconds before it is due; green once it is due."], 0.1, 3, 0.05, 3 ),
        farColor = optColor( L["Coming Color"], L["A pin on its way (red by default)."], 4 ),
        nearColor = optColor( L["Close Color"], L["A pin about to be due (yellow by default)."], 5 ),
        dueColor = optColor( L["Due Color"], L["A pin due now: press it (green by default)."], 6 ),
        font = ns.tableCopy( fe.font ),
        style = ns.tableCopy( fe.fontStyle ),
        size = ns.tableCopy( fe.fontSize ),
    }
    countdownFont.font.order, countdownFont.style.order, countdownFont.size.order = 7, 8, 9

    local look = {
        countdown = section( L["Countdown"], 1, countdownFont ),
        ghost = section( L["Ghost Pins"], 2, {
            color = optColor( L["Color"], L["The color of a ghost pin."], 1 ),
            alpha = optRange( L["Icon Opacity"], L["The opacity of a ghost pin's icon."], 0.1, 1, 0.05, 2 ),
        } ),
        waiting = section( L["Waiting on Resources"], 3, {
            enabled = optToggle( L["Fade When Short"], L["Fade a pin whose spell you cannot afford yet (rage or mana)."], 1 ),
            alpha = optRange( L["Opacity"], L["The opacity of a pin still short of its rage or mana."], 0.1, 1, 0.05, 2 ),
            desaturate = optToggle( L["Grey Out"], L["Also take the color out of its icon."], 3 ),
        } ),
    }

    local keybindings = SO.keybindings( "highway", ZONES, 3, id, conf )
    keybindings.args.queued = optToggle( L["Enabled for Queued Icons"], L["Show keybinds on the pins behind the first one too."], 2 )
    keybindings.args.queued.disabled = function() return h.keybindings.enabled == false end

    local glow = {
        mode = optSelect( L["Glow"], L["How the pin at the ring shows that it is due: None, a gentle Pulse, a soft Halo, or a Custom glow (LibCustomGlow)."],
            { none = L["None"], pulse = L["Pulse"], halo = L["Halo"], custom = L["Custom"] }, 1 ),
        lib = optSelect( L["Custom Glow"], L["The LibCustomGlow effect the Custom glow uses."], { autocast = L["AutoCast Shine"], pixel = L["Pixel Glow"], button = L["Action Button Glow"] }, 2 ),
        procs = optToggle( L["Glow on Procs"], L["Also glow any pin on the rail whose spell is lit up by a proc."], 3 ),
        color = optColor( L["Color"], L["The glow's color."], 4 ),
    }
    glow.lib.hidden = function() return h.glow.mode ~= "custom" end

    local range = SO.range( "highway", ZONES, 5, id, conf )
    range.args.color = optColor( L["Out of Range Color"], L["The tint of an icon whose spell cannot reach your target."], 10 )

    local tracked = {
        spell = optSelect( L["Spell"], L["The spell the half circle behind the ring tracks: it fills as the spell's cooldown recovers and turns gold once the spell is ready."], trackable, 1 ),
        gap = optRange( L["Gap"], L["The space between the ring and the half circle."], 0, 24, 1, 2 ),
        dot = optRange( L["Dot Size"], L["The size of each dot of the half circle."], 2, 16, 1, 3 ),
        fillColor = optColor( L["Recovering Color"], L["The dots that have filled while the spell recovers."], 4 ),
        readyColor = optColor( L["Ready Color"], L["Every dot once the spell is ready."], 5 ),
        emptyColor = optColor( L["Empty Color"], L["The dots still to fill."], 6 ),
        text = optToggle( L["Show Seconds"], L["Show the seconds until the spell is ready, beside the half circle."], 7 ),
        textSize = optRange( L["Text Size"], L["The size of the seconds beside the half circle."], 6, 32, 1, 8 ),
    }

    return {
        tab_highway = tab( L["Highway"], L["The rail, the target ring and the pins."], 1, highway ),
        tab_look = tab( L["Countdown"], L["The pins' countdown colors and seconds, the ghost pins and the waiting look."], 2, look ),
        keybindings = keybindings,
        glow = tab( L["Glow"], L["How the pin at the ring and proccing pins glow."], 4, glow ),
        range = range,
        tracked = tab( L["Tracked Spell"], L["One spell shown as a half circle behind the ring that fills as its cooldown recovers."], 6, tracked ),
        gamepad = SO.gamepad( "highway", ZONES, 7, id, conf ),
    }
end

Highway.api = Encore.DisplayStyleAPI
Encore:RegisterDisplayStyle( "highway", Highway )
