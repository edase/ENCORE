local _, ns = ...
local L = ns.L
-- UI/Styles/Highway.lua: Encore's highway display style, a rhythm-game note highway. Up to three round spell icons
-- ride one thin line toward a gold hit ring, growing as they come (right to left by default); the ring brightens
-- when the first one is due. Each icon is a note that keeps its spell from publish to publish (a cast sends it
-- through the ring, a dropped pick fades where it was), so nothing slides backwards when the queue moves up. A pick
-- short of its resource rides faded, one out of range tinted, an off-GCD pick a little smaller. One tracked spell
-- shows as a half circle of dots behind the ring that fills as its cooldown recovers, all gold once ready. With the
-- options open (out of combat) a demo loop runs so every setting can be seen moving.
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

local NOTES = 6 -- note frames: up to three on the line and three leaving it
local MAX_ICONS = 3
local MAX_DOTS = 24
local READY_EPS = Encore.Engine.READY -- a note due within this is the press: the ring brightens
local DUE_MATCH = 0.5 -- a due note stays itself only for a record due within this (else it was cast)
local MATCH = 1.5 -- a record keeps the note of its spell whose time is within this many seconds
local SPACING = 0.85 -- neighbours may overlap by 15% of their sizes, never more
local MOVE_EPS, SCALE_EPS, ALPHA_EPS = 0.2, 0.004, 0.01
local HIT_TIME, DROP_TIME, SPAWN_TIME = 0.2, 0.15, 0.15
local FLASH_DECAY = 0.25 -- seconds for the ring's flash to fall to 1/e
local GCD_MAX = 1.6 -- a cooldown this short or shorter is the GCD: the tracked spell reads ready
local GAUGE_STEP = 0.1 -- seconds between the tracked spell's reads
local DEMO_GAP, DEMO_HOLD, DEMO_CYCLE, DEMO_FILL = 1.5, 0.3, 7.5, 6
local CROP = 0.08
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local ART = "Interface\\AddOns\\Encore\\Textures\\"
local RINGS = { thin = ART .. "HighwayRing1", medium = ART .. "HighwayRing2", thick = ART .. "HighwayRing3" }
local HALO, DOT = ART .. "HighwayHalo", ART .. "HighwayDot"
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
    d.direction = "LEFT" -- the way the icons travel: LEFT (right to left, the ring on the left) or RIGHT
    d.maxIcons = 3
    d.size = 56 -- an icon's diameter at the ring
    d.farScale = 0.33 -- an icon's size at the line's far end, a fraction of size
    d.length = 300 -- pixels from the ring's centre to the line's far end
    d.horizon = 3.5 -- seconds the line spans: three GCDs of icons fill it
    d.offGCDScale = 0.8
    d.glide = 0.08 -- seconds an icon takes to settle on a new predicted time (0: jump)
    d.shape = "round"
    d.demo = true -- a moving sample while the options are open, out of combat
    d.line = { enabled = true, thickness = 2, color = { 1, 1, 1, 0.3 } }
    d.ring = { enabled = true, style = "medium", color = { GOLD[ 1 ], GOLD[ 2 ], GOLD[ 3 ], 1 }, pad = 6, idleAlpha = 0.55, flash = true }
    d.iconBorder = { enabled = true, thickness = 2, color = { 0, 0, 0, 0.85 } }
    d.waiting = { alpha = 0.4, desaturate = true }
    d.countdown = { enabled = false, font = "Friz Quadrata TT", size = 14, style = "OUTLINE", color = { 1, 1, 1, 1 } }
    d.glow = { mode = "pulse", lib = "autocast", procs = true, color = { 1, 0.85, 0.3, 1 } }
    d.tracked = {
        spell = "",
        gap = 4,
        dot = 6,
        fillColor = { 0.85, 0.85, 0.85, 1 },
        readyColor = { GOLD[ 1 ], GOLD[ 2 ], GOLD[ 3 ], 1 },
        emptyColor = { 0.25, 0.25, 0.25, 0.6 },
        text = false,
        textSize = 12,
    }
    d.range.color = { 1, 0.25, 0.25, 1 }
    d.keybindings.anchor, d.keybindings.x, d.keybindings.y, d.keybindings.fontSize = "BOTTOM", 0, 3, 14
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
    b.Halo = track( T, b:CreateTexture( nil, "BACKGROUND", nil, -2 ), L .. ".Halo" )
    b.Halo:SetTexture( HALO )
    b.Halo:SetBlendMode( "ADD" )
    b.Halo:SetPoint( "CENTER", b, "CENTER", 0, 0 )
    b.Border = track( T, b:CreateTexture( nil, "BACKGROUND" ), L .. ".Border" )
    b.Border:SetTexture( WHITE )
    b.Texture = track( T, b:CreateTexture( nil, "ARTWORK" ), L .. ".Texture" )
    b.Texture:SetAllPoints( b )
    b.Texture:SetTexCoord( CROP, 1 - CROP, CROP, 1 - CROP )
    b.Mask = b:CreateMaskTexture()
    b.Mask:SetTexture( CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE" )
    b.Mask:SetAllPoints( b )
    b.BorderMask = b:CreateMaskTexture() -- anchored to b in dress, with the border's insets
    b.BorderMask:SetTexture( CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE" )
    b.masked = false
    b.Keybinding = track( T, b:CreateFontString( name .. "_KB", "OVERLAY" ), L .. ".Keybinding" )
    b.Countdown = track( T, b:CreateFontString( name .. "_CD", "OVERLAY" ), L .. ".Countdown" )
    b.glowColor = { 0, 0, 0, 0 }
    b.glowing = false
    b.state = false -- false (free), "live", "hit" (cast: through the ring) or "drop" (no longer picked: fades)
    b.recIndex, b.isFocus, b.timersHidden = 0, false, true -- the button contract (UI/Styles.lua): no own timers
    b.etaK, b.haloA = -1, 0
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

-- Round or square: the icon and its border masked by the circle, or not (Build only).
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

local function dress( T, b, h )
    local size = h.size
    b:SetSize( size, size )
    b:SetScale( 1 )
    shapeMask( b, h.shape == "round" )
    b.round = h.shape == "round"

    local bd = h.iconBorder
    local th = bd.thickness
    b.Border:ClearAllPoints()
    b.Border:SetPoint( "TOPLEFT", b, "TOPLEFT", -th, th )
    b.Border:SetPoint( "BOTTOMRIGHT", b, "BOTTOMRIGHT", th, -th )
    b.BorderMask:ClearAllPoints()
    b.BorderMask:SetPoint( "TOPLEFT", b, "TOPLEFT", -th, th )
    b.BorderMask:SetPoint( "BOTTOMRIGHT", b, "BOTTOMRIGHT", th, -th )
    b.Border:SetVertexColor( bd.color[ 1 ], bd.color[ 2 ], bd.color[ 3 ], bd.color[ 4 ] )
    b.Border:SetShown( bd.enabled )

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
    setFont( b.Countdown, cd.font, cd.size, cd.style, cd.color )
    b.Countdown:ClearAllPoints()
    b.Countdown:SetPoint( "CENTER", b, "CENTER", 0, 0 )
    b.Countdown:SetText( "" )
    b.Countdown:SetShown( cd.enabled )
    b.etaK = -1

    glowOff( b )
    b:Hide()
    b:SetAlpha( 1 )
    b.state, b.claimed = false, false
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

--- Builds (or reuses) the root, the line, the ring, the tracked spell's dots and the notes on `d`, sizes `d` and
--- returns the note buttons.
function Highway.Build( d, conf )
    local h = conf.highway
    local T = d.styleFrames.highway
    if not T then
        T = { widgets = {}, labels = {}, notes = {}, order = {}, dots = {}, fake = {}, fakeRes = {}, demoTex = {}, demoKey = {} }
        d.styleFrames.highway = T
        T.d = d
        T.root = track( T, CreateFrame( "Frame", nil, d ), "Root" )
        T.line = track( T, T.root:CreateTexture( nil, "BACKGROUND" ), "Line" )
        T.bloom = track( T, T.root:CreateTexture( nil, "BORDER" ), "Bloom" )
        T.bloom:SetTexture( HALO )
        T.bloom:SetBlendMode( "ADD" )
        T.ring = track( T, T.root:CreateTexture( nil, "ARTWORK" ), "Ring" )
        for k = 1, MAX_DOTS do
            local t = track( T, T.root:CreateTexture( nil, "ARTWORK" ), "Dot" .. k )
            t:SetTexture( DOT )
            T.dots[ k ] = t
        end
        T.gaugeText = track( T, T.root:CreateFontString( nil, "OVERLAY" ), "Gauge.Text" )
        for i = 1, NOTES do T.notes[ i ] = newNote( d, T, i ) end
        for i = 1, MAX_ICONS do
            T.fake[ i ] = { actionName = "", actionID = 1, texture = QUESTION, keybind = "", exact_time = 0, offGCD = false, floors = {}, cost = 0 }
            T.fakeRes[ i ] = { inRange = true, inMelee = true, usable = true, glow = false }
            T.order[ i ] = false
        end
    end

    local s = Encore:GetScale()
    local size, far = h.size, h.size * h.farScale
    local ringD = size + 2 * h.ring.pad
    local tr = h.tracked
    local ability = tr.spell ~= "" and Registry.Abilities()[ tr.spell ]
    local id = ability and rawget( ability, "id" )
    T.trackedID = type( id ) == "number" and id > 0 and id or nil
    local gaugeR = ringD / 2 + tr.gap + tr.dot / 2
    local back = ceil( mmax( ringD * 0.75, T.trackedID and gaugeR + tr.dot / 2 + 2 or 0 ) )
    local height = ceil( mmax( ringD * 1.5, size * 1.9, T.trackedID and 2 * gaugeR + tr.dot or 0 ) ) + 4
    local width = back + h.length + ceil( far / 2 ) + 4

    local left = h.direction ~= "RIGHT" -- the ring on the left, icons travelling right to left
    T.pt, T.sx, T.x0 = left and "LEFT" or "RIGHT", left and 1 or -1, back
    d:SetSize( width * s, height * s )
    T.root:ClearAllPoints()
    T.root:SetAllPoints( d )
    T.root:SetScale( s )
    T.root:SetFrameLevel( d:GetFrameLevel() + 3 ) -- above config mode's backdrop, so the demo shows over it

    local ln = h.line
    local start = ringD / 2
    T.line:SetTexture( WHITE )
    T.line:SetVertexColor( ln.color[ 1 ], ln.color[ 2 ], ln.color[ 3 ], ln.color[ 4 ] )
    T.line:SetSize( mmax( 1, h.length - start ), ln.thickness )
    place( T, T.line, ( start + h.length ) / 2, 0 )
    T.line:SetShown( ln.enabled )

    local rg = h.ring
    T.ring:SetTexture( RINGS[ rg.style ] or RINGS.medium )
    T.ring:SetSize( ringD, ringD )
    T.ring:SetVertexColor( rg.color[ 1 ], rg.color[ 2 ], rg.color[ 3 ], 1 )
    place( T, T.ring, 0, 0 )
    T.ring:SetShown( rg.enabled )
    T.ringA = rg.idleAlpha
    T.ring:SetAlpha( T.ringA * rg.color[ 4 ] )
    T.bloom:SetSize( ringD * 1.5, ringD * 1.5 )
    T.bloom:SetVertexColor( rg.color[ 1 ], rg.color[ 2 ], rg.color[ 3 ], 1 )
    place( T, T.bloom, 0, 0 )
    T.bloom:SetAlpha( 0 )
    T.bloom:SetShown( rg.enabled )
    T.flash, T.bloomA = 0, 0

    -- the tracked spell's half circle: dots from the bottom to the top, on the side away from the incoming icons
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
    setFont( T.gaugeText, h.countdown.font, tr.textSize, "OUTLINE", h.countdown.color )
    place( T, T.gaugeText, -( gaugeR + tr.dot / 2 + tr.textSize * 0.6 ), 0 )
    T.gaugeText:SetText( "" )
    T.gaugeText:SetShown( T.trackedID ~= nil and tr.text )
    T.lit, T.gaugeReady, T.gaugeTimer, T.gaugeK = -1, nil, 0, -1

    for i = 1, NOTES do dress( T, T.notes[ i ], h ) end
    for i = 1, MAX_ICONS do T.order[ i ] = false end
    T.count, T.demoOn, T.demoHead = 0, false, 0
    reveal( T )

    local out = Encore.Engine.Output[ d.id ]
    if out and out.count > 0 then d.NewRecommendations = true end -- redraw what is published with the new layout

    return T.notes
end

-- An icon's size at x pixels from the ring: full at the ring, farScale at the far end, growing faster near the ring.
local function sizeAt( h, x )
    local g = 1 - x / h.length
    if g < 0 then g = 0 end
    return h.size * ( h.farScale + ( 1 - h.farScale ) * g * g )
end

local function setKb( b, kb, g, i, text )
    local show = text ~= nil and text ~= "" and kb.enabled and ( i == 1 or kb.queued )
    ns.UI.SetKeybindingText( b.Keybinding, b, show and text or nil, kb.anchor, kb.x, kb.y, g )
end

-- The tint and fade of note `b` from its flags: out of range in the range colour, short of its resource faded.
local function paint( b, h )
    local fade = b.gated or b.unusable
    if b.far then
        local c = h.range.color
        b.Texture:SetVertexColor( c[ 1 ], c[ 2 ], c[ 3 ], c[ 4 ] )
        b.Texture:SetDesaturated( true )
    else
        b.Texture:SetVertexColor( 1, 1, 1, 1 )
        b.Texture:SetDesaturated( fade and h.waiting.desaturate or false )
    end
    b.dim = fade and h.waiting.alpha or 1
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
    b.etaK = -1
    b:SetAlpha( 0 )
    b:Show()
end

-- A note no record kept: through the ring (it was due: cast) or faded where it is.
local function leave( T, h, b, now )
    local hit = b.Key - now <= READY_EPS + 0.15
    b.state = hit and "hit" or "drop"
    b.t0, b.k0, b.a0 = now, b.k > 0 and b.k or 1, b.a > 0 and b.a or 1
    b.recIndex, b.Recommendation = 0, nil
    glowOff( b )
    setHalo( b, 0 )
    b.Keybinding:SetText( nil )
    b:SetFrameLevel( T.root:GetFrameLevel() + 2 * MAX_ICONS + 4 ) -- the flash over the next icon
    if hit and h.ring.flash then T.flash = 1 end
end

-- A publish (or a demo step): the first maxIcons records with an action and a time keep their notes by spell and
-- time; a record no note matches takes a free one, and a live note no record kept leaves.
local function sync( T, h, recs, count, res, now )
    local notes = T.notes
    for i = 1, NOTES do notes[ i ].claimed = false end
    local n, maxI, kb = 0, mmin( MAX_ICONS, h.maxIcons ), h.keybindings
    for i = 1, count do
        if n >= maxI then break end
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
            best.Key, best.Action, best.actionID, best.recIndex = exact, action, id, i
            best.Recommendation, best.offGCD = r, r.offGCD == true
            best.Texture:SetTexture( r.iconOverride or r.texture )
            local rt = r.resource_type
            local have = rt and r.floors[ rt ]
            best.gated = have ~= nil and have < r.cost
            best.Keybind = r.keybind
            setKb( best, kb, h.gamepad, i, r.keybind )
            flags( best, h, res and res[ i ] )
            paint( best, h )
            T.order[ n ] = best
        end
    end
    for k = n + 1, MAX_ICONS do T.order[ k ] = false end
    T.count = n
    for k = 1, NOTES do
        local b = notes[ k ]
        if b.state == "live" and not b.claimed then leave( T, h, b, now ) end
    end
    local base = T.root:GetFrameLevel() + 2
    for k = 1, n do T.order[ k ]:SetFrameLevel( base + 2 * ( MAX_ICONS - k + 1 ) ) end -- the nearer icon on top
end

-- Every live note leaves (a blank publish).
local function dropAll( T, h, now )
    for k = 1, NOTES do
        local b = T.notes[ k ]
        if b.state == "live" then leave( T, h, b, now ) end
    end
    for k = 1, MAX_ICONS do T.order[ k ] = false end
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
        b:SetPoint( "CENTER", T.root, T.pt, T.sx * ( T.x0 + x ) / b.k, 0 )
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

local function countdown( b, h, t )
    if not h.countdown.enabled then return end
    local k = etaStep( t )
    if k ~= b.etaK then
        b.etaK = k
        b.Countdown:SetText( ETA[ k ] )
    end
end

-- Every frame: the live notes toward their times (spaced, sized and faded), the leaving ones through their exit, the
-- ring's brightness and flash.
local function animate( T, h, now, elapsed )
    local keep = h.glide > 0 and exp( -elapsed / h.glide ) or 0
    local len, hz = h.length, h.horizon
    local prevX, prevS
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
        if prevX then
            local minX = prevX + 0.5 * ( prevS + sz ) * SPACING
            if x < minX then
                x = minX < len and minX or len
                sz = sizeAt( h, x )
            end
        end
        prevX, prevS = x, sz
        local scale = sz / h.size
        if b.offGCD then scale = scale * h.offGCDScale end
        local a = b.dim
        local u = x / len
        if u > 0.85 then a = a * ( 1 - ( u - 0.85 ) / 0.15 * 0.7 ) end -- fades in from the far end
        local age = now - b.born
        if age < SPAWN_TIME then a = a * age / SPAWN_TIME end
        scale = scale * glowLook( b, h, k == 1 and due, now )
        setNote( T, b, x, scale, a )
        countdown( b, h, b.Key - now )
    end
    for i = 1, NOTES do
        local b = T.notes[ i ]
        local st = b.state
        if st == "hit" or st == "drop" then
            local p = ( now - b.t0 ) / ( st == "hit" and HIT_TIME or DROP_TIME )
            if p >= 1 then
                finish( b )
            elseif st == "hit" then
                setNote( T, b, 0, b.k0 * ( 1 + 0.35 * p ), b.a0 * ( 1 - p ) )
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
            T.ring:SetAlpha( ra * rg.color[ 4 ] )
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

-- One demo step: the notes due from `head` on, every DEMO_GAP seconds, with a few faded, out of range, off the GCD
-- or proccing, so each look can be seen.
local function demoStep( T, h, now )
    local head = floor( ( now - T.demoT0 - DEMO_HOLD ) / DEMO_GAP ) + 1
    if head < 1 then head = 1 end
    if head == T.demoHead then return end
    T.demoHead = head
    local tex, keys, nTex = T.demoTex, T.demoKey, #T.demoTex
    for k = 1, MAX_ICONS do
        local j = head + k - 1
        local r, rr = T.fake[ k ], T.fakeRes[ k ]
        local m = ( j - 1 ) % nTex + 1
        r.actionName = DEMO_NAMES[ ( j - 1 ) % #DEMO_NAMES + 1 ]
        r.texture, r.keybind = tex[ m ], keys[ m ]
        r.exact_time = T.demoT0 + j * DEMO_GAP
        r.offGCD = j % 6 == 4
        if j % 5 == 3 then
            r.resource_type, r.floors.demo, r.cost = "demo", 0, 1
        else
            r.resource_type, r.cost = nil, 0
        end
        rr.inRange, rr.inMelee = j % 7 ~= 5, j % 7 ~= 5
        rr.glow = j % 8 == 6
    end
    sync( T, h, T.fake, MAX_ICONS, T.fakeRes, now )
end

-- Starts or stops the demo: its notes replace the real ones until it stops, then the published records come back.
local function setDemo( d, T, h, out, on, now )
    T.demoOn = on
    for k = 1, NOTES do finish( T.notes[ k ] ) end
    for k = 1, MAX_ICONS do T.order[ k ] = false end
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
        flags( b, h, res and res[ b.recIndex ] )
        paint( b, h )
    end
end

function Highway.OnGameEvent( d, conf, event, ... )
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local T = d.styleFrames.highway
        if T.demoOn then return end
        local show, id = event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", ...
        for k = 1, T.count do
            local b = T.order[ k ]
            if b.actionID == id then b.proc = show end
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
    for k = 1, MAX_ICONS do T.order[ k ] = false end
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

--- Five tabs, keyed so the path finds the config: a tab or inline group named like a config subtable (line, ring,
--- glow, tracked, keybindings, range, gamepad) holds that subtable's options; the rest are flat in highway.
function Highway.Options( id, conf )
    local P = ns.UI.DisplayOptionParts
    local fe = P.fontElements
    local h = conf.highway

    local countdown = {
        enabled = optToggle( L["Show Countdown"], L["Show the seconds until each icon is due, on the icon."], 1 ),
        font = ns.tableCopy( fe.font ),
        style = ns.tableCopy( fe.fontStyle ),
        size = ns.tableCopy( fe.fontSize ),
        color = ns.tableCopy( fe.color ),
    }
    countdown.font.order, countdown.style.order, countdown.size.order, countdown.color.order = 2, 3, 4, 5

    local highway = {
        sec_layout = section( L["Layout"], 1, {
            direction = optSelect( L["Direction"], L["Which way the icons travel; the hit ring sits at the end they travel to."], { LEFT = L["Right to Left"], RIGHT = L["Left to Right"] }, 1 ),
            maxIcons = optRange( L["Icons"], L["How many icons ride the line at once."], 1, 3, 1, 2 ),
            size = optRange( L["Icon Size"], L["An icon's size when it reaches the ring."], 16, 128, 1, 3 ),
            farScale = optRange( L["Far Size"], L["An icon's size at the far end of the line, a fraction of its size at the ring."], 0.2, 1, 0.01, 4 ),
            length = optRange( L["Length"], L["The line's length in pixels, from the ring to the far end."], 80, 800, 1, 5 ),
            horizon = optRange( L["Seconds Shown"], L["How many seconds ahead the line reaches; a later icon waits at the far end."], 1.5, 10, 0.1, 6 ),
            shape = optSelect( L["Shape"], L["Round or square icons."], { round = L["Round"], square = L["Square"] }, 7 ),
            offGCDScale = optRange( L["Off-GCD Size"], L["The size of a spell that does not trigger the global cooldown, a fraction of a normal icon's."], 0.5, 1, 0.01, 8 ),
            glide = optRange( L["Glide"], L["Seconds an icon takes to settle on a new predicted time (0: jump)."], 0, 0.5, 0.01, 9 ),
            demo = optToggle( L["Demo While Options Are Open"], L["Out of combat, run a moving sample on the highway while the options are open, so each change shows at once."], 10 ),
        } ),
        line = section( L["Line"], 2, {
            enabled = optToggle( L["Show Line"], L["Show the line the icons ride."], 1 ),
            thickness = optRange( L["Thickness"], L["The line's thickness in pixels."], 1, 8, 1, 2 ),
            color = optColor( L["Color"], L["The line's color."], 3 ),
        } ),
        ring = section( L["Hit Ring"], 3, {
            enabled = optToggle( L["Show Ring"], L["Show the ring the icons travel to."], 1 ),
            style = optSelect( L["Thickness"], L["The ring's thickness."], { thin = L["Thin"], medium = L["Medium"], thick = L["Thick"] }, 2 ),
            color = optColor( L["Color"], L["The ring's color."], 3 ),
            pad = optRange( L["Gap"], L["The space between an icon at the ring and the ring."], 0, 24, 1, 4 ),
            idleAlpha = optRange( L["Resting Brightness"], L["The ring's brightness while nothing is due; it goes full when an icon is due."], 0, 1, 0.05, 5 ),
            flash = optToggle( L["Flash on Cast"], L["Flash the ring when an icon goes through it."], 6 ),
        } ),
        iconBorder = section( L["Icon Border"], 4, {
            enabled = optToggle( L["Show Border"], L["Show a border around each icon."], 1 ),
            thickness = optRange( L["Thickness"], L["The border's thickness in pixels."], 1, 6, 1, 2 ),
            color = optColor( L["Color"], L["The border's color."], 3 ),
        } ),
        waiting = section( L["Waiting on Resources"], 5, {
            alpha = optRange( L["Opacity"], L["The opacity of an icon still short of its rage or mana."], 0.1, 1, 0.05, 1 ),
            desaturate = optToggle( L["Grey Out"], L["Also take the color out of an icon short of its rage or mana."], 2 ),
        } ),
    }

    local keybindings = SO.keybindings( "highway", ZONES, 2, id, conf )
    keybindings.args.queued = optToggle( L["Enabled for Queued Icons"], L["Show keybinds on the icons behind the first one too."], 2 )
    keybindings.args.queued.disabled = function() return h.keybindings.enabled == false end

    local text = {
        countdown = section( L["Countdown"], 1, countdown ),
    }

    local glow = {
        mode = optSelect( L["Glow"], L["How the icon at the ring shows that it is due: None, a gentle Pulse, a soft Halo, or a Custom glow (LibCustomGlow)."],
            { none = L["None"], pulse = L["Pulse"], halo = L["Halo"], custom = L["Custom"] }, 1 ),
        lib = optSelect( L["Custom Glow"], L["The LibCustomGlow effect the Custom glow uses."], { autocast = L["AutoCast Shine"], pixel = L["Pixel Glow"], button = L["Action Button Glow"] }, 2 ),
        procs = optToggle( L["Glow on Procs"], L["Also glow any icon on the line whose spell is lit up by a proc."], 3 ),
        color = optColor( L["Color"], L["The glow's color."], 4 ),
    }
    glow.lib.hidden = function() return h.glow.mode ~= "custom" end

    local range = SO.range( "highway", ZONES, 1, id, conf )
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
        tab_highway = tab( L["Highway"], L["The line, the hit ring and the icons."], 1, highway ),
        keybindings = keybindings,
        tab_text = tab( L["Countdown"], L["Seconds on the icons."], 3, text ),
        glow = tab( L["Glow"], L["How the icon at the ring and proccing icons glow."], 4, glow ),
        range = range,
        tracked = tab( L["Tracked Spell"], L["One spell shown as a half circle behind the ring that fills as its cooldown recovers."], 6, tracked ),
        gamepad = SO.gamepad( "highway", ZONES, 7, id, conf ),
    }
end

Highway.api = Encore.DisplayStyleAPI
Encore:RegisterDisplayStyle( "highway", Highway )
