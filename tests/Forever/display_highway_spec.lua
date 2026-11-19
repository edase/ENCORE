-- tests/Forever/display_highway_spec.lua: Encore's highway display style (UI/Styles/Highway.lua). Map pins ride the
-- rail toward the target ring in time order (off-GCD spells below it), three in color and two ghosts after them; they
-- keep their spell from publish to publish (a cast goes through the ring, a dropped pick fades), count down red,
-- yellow, green, tint out of range, fade when short of their resource (when that look is on), fill the tracked spell's
-- half circle from its cooldown, run a demo while the options are open, and allocate nothing per frame.
local headless = require("Game.harness.headless")
local ww = require("Forever.helpers.warrior_world")

local function boot(setup)
    local H = headless.new({ character = ww.character(), pack = ww.PACK })
    assert.are.same({}, H.loadErrors)
    H.ctl.inRange.target, H.ctl.level.target = true, 60
    H.Fire("PLAYER_TARGET_CHANGED")
    assert(headless.cycle(H, H.ctl.now + 0.2))
    local conf = H.Encore.DB.profile.displays.Primary
    conf.style = "highway"
    if setup then
        setup(conf.highway)
    end
    H.Encore:BuildUI()
    local d = rawget(H.env, "EncoreDisplayPrimary")
    return H, d, d.styleFrames.highway, conf.highway
end

-- Records { action, seconds from now, cost, rage floor, offGCD }; `edit( s )` changes them before the publish.
local SET = {
    { "mortal_strike", 0, 30, 40 },
    { "overpower", 1.5, 5, 50 },
    { "slam", 3.0, 15, 60 },
    { "rend", 4.5, 10, 70 },
    { "whirlwind", 6.0, 25, 80 },
    { "heroic_strike", 7.5, 15, 90, true },
}

local KEYS = { "K1", "K2", "K3", "K4", "K5", "K6" } -- held here: no string is built (or collected) per publish

-- Ability ids by action, read once per world (an ability's id can be computed on each read).
local IDS = setmetatable({}, { __mode = "k" })

local function publish(H, set, edit)
    local ids = IDS[H]
    if not ids then
        ids = {}
        for k, a in pairs(H.Encore.Engine.Registry.Abilities()) do
            ids[k] = a.id
        end
        IDS[H] = ids
    end
    local now = H.ctl.now
    local s = H.ns.Output.Begin("Primary")
    for i, e in ipairs(set) do
        local r = s[i]
        r.actionName, r.actionID = e[1], ids[e[1]]
        r.texture, r.keybind = e[1], KEYS[i] -- the action's name stands in for its texture
        r.time, r.exact_time = e[2], now + e[2]
        r.resource_type, r.cost, r.floors.rage = "rage", e[3], e[4]
        r.offGCD = e[5] == true
        r.alts.n = 0
    end
    if edit then
        edit(s)
    end
    H.ns.Output.Publish("Primary", #set)
end

local function frame(H, d, dt)
    dt = dt or 0.05
    H.ctl.now = H.ctl.now + dt
    d.__scripts.OnUpdate(d, dt)
end

-- The set as it stands `dt` seconds later: every time shifted, the first `cast` records gone.
local function later(set, dt, cast)
    local out = {}
    for i = (cast or 0) + 1, #set do
        local e = set[i]
        out[#out + 1] = { e[1], math.max(0, e[2] - dt), e[3], e[4], e[5] }
    end
    return out
end

local function live(T)
    local n = 0
    for _, b in ipairs(T.notes) do
        if b.state == "live" then
            n = n + 1
        end
    end
    return n
end

describe("the highway display style", function()
    it("is the default style and serves its options from displays[ id ].highway", function()
        local H = headless.new({ character = ww.character(), pack = ww.PACK })
        assert.are.same({}, H.loadErrors)
        local conf = H.Encore.DB.profile.displays.Primary
        assert.are.equal("highway", conf.style)
        local h = conf.highway
        assert.are.equal("LEFT", h.direction)
        assert.are.equal(3, h.maxIcons)
        assert.are.equal(2, h.ghosts)
        assert.is_true(h.lanes)
        assert.are.equal("pin", h.shape)
        assert.are.equal(1, h.farScale) -- one size all the way
        assert.are.equal(36, h.ring.size)
        assert.is_true(h.countdown.enabled)
        assert.is_false(h.waiting.enabled)
        assert.are.equal("pulse", h.glow.mode)
        assert.are.equal("", h.tracked.spell)
        assert.is_true(h.keybindings.enabled)
        assert.is_true(h.keybindings.queued)
        assert.is_true(h.demo)
        local get = function(path)
            return H.Encore:GetDisplayOption(path)
        end
        local P = { "displays", "Primary", "highway" }
        local function path(...)
            local t = { unpack(P) }
            for _, k in ipairs({ ... }) do
                t[#t + 1] = k
            end
            return t
        end
        assert.are.equal(40, get(path("tab_highway", "sec_layout", "size")))
        assert.are.equal(0.75, get(path("tab_highway", "ring", "idleAlpha")))
        assert.are.equal(8, get(path("tab_highway", "rail", "thickness")))
        assert.are.equal(0.6, get(path("tab_look", "countdown", "nearAt")))
        assert.are.equal("pulse", get(path("glow", "mode")))
        assert.are.equal(12, get(path("keybindings", "fontSize")))
        assert.are.equal("", get(path("tracked", "spell")))
        local r, g, b, a =
            H.Encore:GetDisplayOption(setmetatable(path("range", "color"), { __index = { type = "color" } }))
        assert.are.same({ 1, 0.25, 0.25, 1 }, { r, g, b, a })
        H.Encore:SetDisplayOption(path("tab_highway", "sec_layout", "maxIcons"), 2)
        assert.are.equal(2, h.maxIcons)
        H.Encore:SetDisplayOption(path("tab_highway", "rail", "thickness"), 6)
        assert.are.equal(6, h.rail.thickness)
        H.Encore:SetDisplayOption(path("tab_look", "countdown", "enabled"), false)
        assert.is_false(h.countdown.enabled)
        H.Encore:SetDisplayOption(path("tab_look", "waiting", "enabled"), true)
        assert.is_true(h.waiting.enabled)
        H.Encore:EmbedDisplayOptions()
        local tabs = H.Encore.Options.args.displays.plugins.Primary.Primary.args.highway.args
        for _, k in ipairs({ "tab_highway", "tab_look", "keybindings", "glow", "range", "tracked", "gamepad" }) do
            assert.is_table(tabs[k], k)
        end
        assert.is_true(tabs.tab_highway.args.ring.inline)
        assert.is_table(tabs.keybindings.args.queued)
        assert.are.same({}, H.errors)
    end)

    it("draws three pins in color and two ghosts in time order, one size, the first on the ring", function()
        local H, d, T, h = boot()
        publish(H, SET)
        frame(H, d)
        assert.are.equal(5, T.count)
        assert.are.equal(5, live(T))
        local n1, n2, n3, g4, g5 = T.order[1], T.order[2], T.order[3], T.order[4], T.order[5]
        assert.are.equal("mortal_strike", n1.Action)
        assert.are.equal("overpower", n2.Action)
        assert.are.equal("slam", n3.Action)
        assert.are.equal("rend", g4.Action)
        assert.are.equal(1, n1.recIndex)
        assert.are.equal(3, n3.recIndex)
        assert.is_false(n3.ghost)
        assert.is_true(g4.ghost and g5.ghost)
        assert.is_true(n1.x < 1) -- due: at the ring
        assert.is_true(n1.x < n2.x and n2.x < n3.x and n3.x < g4.x)
        assert.are.equal(n2.k, n3.k) -- one size all the way (farScale 1)
        assert.are.equal(1, n2.k)
        assert.is_true(math.abs(n1.k - 1) < 0.08) -- the pulse aside
        assert.are.equal(1, n1.lane)
        assert.are.equal(T.y1, h.rail.thickness / 2 + 74 / 88 * h.size) -- the tail's tip on the rail
        for _ = 1, 20 do
            frame(H, d)
        end
        assert.is_true(T.ringA > 0.95) -- due: the ring at full brightness
        assert.are.equal("K1", n1.Keybind)
        assert.are.same({}, H.errors)
    end)

    it("keeps each note on its spell: a cast goes through the ring, the next one moves up", function()
        local H, d, T = boot()
        publish(H, SET)
        frame(H, d)
        local n1, n2, n3 = T.order[1], T.order[2], T.order[3]
        H.ctl.now = H.ctl.now + 1.45
        H.ns.Output.Acted() -- our cast: the next publish shows its icons at once (no steady hold)
        publish(H, later(SET, 1.5, 1))
        frame(H, d)
        assert.are.equal(n2, T.order[1])
        assert.are.equal(n3, T.order[2])
        assert.are.equal("rend", T.order[3].Action)
        assert.are.equal("hit", n1.state)
        for _ = 1, 6 do
            frame(H, d)
        end
        assert.is_false(n1.state) -- through the ring and gone
        assert.are.same({}, H.errors)
    end)

    it("never drags a due note back for a later cast of the same spell", function()
        local H, d, T = boot()
        local set = { { "mortal_strike", 0, 30, 40 }, { "overpower", 1.5, 5, 50 }, { "mortal_strike", 3.0, 30, 60 } }
        publish(H, set)
        frame(H, d)
        local first, third = T.order[1], T.order[3]
        H.ctl.now = H.ctl.now + 1.45
        H.ns.Output.Acted()
        publish(H, { { "overpower", 0, 5, 50 }, { "mortal_strike", 1.5, 30, 60 }, { "slam", 3.0, 15, 60 } })
        frame(H, d)
        assert.are.equal("hit", first.state)
        assert.are.equal(third, T.order[2])
        assert.are.same({}, H.errors)
    end)

    it("fades a pick that is no longer chosen where it is", function()
        local H, d, T = boot()
        publish(H, SET)
        frame(H, d)
        local n2 = T.order[2]
        local x
        local function swap(s)
            s[2].actionName, s[2].actionID = "sunder_armor", H.Encore.Engine.Registry.Abilities().sunder_armor.id
        end
        publish(H, later(SET, 0.05), swap) -- Output's steady icons hold the shown pick one publish
        publish(H, later(SET, 0.05), swap)
        frame(H, d)
        assert.are.equal("drop", n2.state)
        x = n2.x
        frame(H, d)
        assert.are.equal("drop", n2.state)
        assert.are.equal(x, n2.x) -- it fades where it was
        for _ = 1, 4 do
            frame(H, d)
        end
        assert.is_false(n2.state)
        assert.are.same({}, H.errors)
    end)

    it("fades a pick short of its rage when that look is on, and tints one out of range", function()
        local H, d, T, h = boot()
        local function short(s)
            s[2].floors.rage = 2 -- overpower costs 5
        end
        publish(H, SET, short)
        frame(H, d)
        assert.are.equal(1, T.order[2].dim) -- off by default: the countdown colors only
        h.waiting.enabled = true
        publish(H, SET, short)
        frame(H, d)
        assert.are.equal(1, T.order[1].dim)
        assert.are.equal(h.waiting.alpha, T.order[2].dim)
        assert.is_false(T.order[1].far)
        H.ctl.inRange.target = false
        frame(H, d, 0.3) -- the 0.25 s pulse reads range again
        assert.is_true(T.order[1].far)
        assert.are.same({}, H.errors)
    end)

    it("fills the tracked spell's half circle from its cooldown and turns it gold when ready", function()
        local H, d, T, h = boot(function(hw)
            hw.tracked.spell = "mortal_strike"
        end)
        local id = H.Encore.Engine.Registry.Abilities().mortal_strike.id
        assert.are.equal(id, T.trackedID)
        id = H.ns.VirtualState.KnownID(id) -- the client is asked by the known rank (the facade's hybrid)
        assert.is_true(T.dotCount >= 7)
        H.ctl.cooldown[id] = { isActive = true, isOnGCD = false, startTime = H.ctl.now - 3, duration = 6 }
        frame(H, d, 0.2)
        assert.is_false(T.gaugeReady)
        assert.is_true(math.abs(T.lit - math.floor(T.dotCount * 3.2 / 6)) <= 1)
        H.ctl.cooldown[id] = { isActive = false, isOnGCD = false, startTime = 0, duration = 0 }
        frame(H, d, 0.2)
        assert.is_true(T.gaugeReady)
        assert.are.equal(T.dotCount, T.lit)
        -- the GCD alone reads ready
        H.ctl.cooldown[id] = { isActive = true, isOnGCD = true, startTime = H.ctl.now, duration = 1.5 }
        frame(H, d, 0.2)
        assert.is_true(T.gaugeReady)
        assert.are.same({}, H.errors)
    end)

    it("runs a demo while the options are open out of combat, then draws the records again", function()
        local H, d, T = boot()
        publish(H, SET)
        frame(H, d)
        H.Encore.Config = true
        frame(H, d)
        assert.is_true(T.demoOn)
        assert.are.equal(5, T.count) -- three in color, two ghosts
        assert.is_true(T.order[1].Action:match("^encore_demo_") ~= nil)
        local head = T.order[1]
        for _ = 1, 40 do -- two seconds: the head goes through the ring
            frame(H, d)
        end
        assert.are_not.equal(head, T.order[1])
        H.Encore.Config = false
        frame(H, d)
        assert.is_false(T.demoOn)
        frame(H, d)
        assert.are.equal("mortal_strike", T.order[1] and T.order[1].Action)
        assert.are.same({}, H.errors)
    end)

    it("mirrors with direction RIGHT: the ring on the right, icons travelling left to right", function()
        local H, d, T = boot(function(hw)
            hw.direction = "RIGHT"
        end)
        assert.are.equal("RIGHT", T.pt)
        assert.are.equal(-1, T.sx)
        publish(H, SET)
        frame(H, d)
        assert.is_true(T.order[3].x > T.order[1].x)
        assert.are.same({}, H.errors)
    end)

    it("draws one or two icons when maxIcons says so, and clears on a blank publish", function()
        local H, d, T = boot(function(hw)
            hw.maxIcons, hw.ghosts = 1, 0
        end)
        publish(H, SET)
        frame(H, d)
        assert.are.equal(1, T.count)
        assert.are.equal(1, live(T))
        H.ns.Output.Begin("Primary")
        H.ns.Output.Publish("Primary", 0)
        frame(H, d)
        assert.are.equal(0, T.count)
        assert.are.same({}, H.errors)
    end)

    it("hides everything it built on Clear and shows again on the next publish", function()
        local H, d, T = boot()
        publish(H, SET)
        frame(H, d)
        d.style.Clear(d)
        assert.is_true(T.cleared)
        assert.are.equal(0, live(T))
        publish(H, SET)
        frame(H, d)
        assert.is_false(T.cleared)
        assert.are.equal(5, T.count) -- three in color, two ghosts
        assert.are.same({}, H.errors)
    end)

    it("counts a pin down red, yellow, then green on the ring, with its seconds beside it", function()
        local H, d, T, h = boot()
        publish(H, { { "overpower", 1.0, 5, 50 }, { "slam", 2.5, 15, 60 } })
        frame(H, d)
        local b = T.order[1]
        assert.are.equal(1, b.tone) -- red: on its way
        assert.are.equal(10, b.etaK) -- "1.0": within the 1.5 s window
        local ghost = T.order[2] -- slam is the second of only two: in color
        assert.are.equal(1, ghost.tone)
        for _ = 1, 9 do -- to 0.5 s
            frame(H, d)
        end
        assert.are.equal(2, b.tone) -- yellow: close
        for _ = 1, 11 do -- past its time
            frame(H, d)
        end
        assert.are.equal(3, b.tone) -- green: press now
        assert.are.equal(0, b.etaK) -- no seconds once due
        assert.are.same({}, H.errors)
    end)

    it("draws ghosts dark with no keybind or seconds, and off-GCD picks below the rail", function()
        local H, d, T, h = boot()
        publish(H, SET, function(s)
            s[2].offGCD = true
        end)
        frame(H, d)
        assert.are.equal(2, T.order[2].lane) -- overpower, off the GCD: below
        assert.are.equal(1, T.order[3].lane)
        assert.is_true(T.order[3].x < T.order[2].x + 200) -- its own row: the main row is not pushed by it
        local g = T.order[5]
        assert.is_true(g.ghost)
        assert.are.equal(0, g.tone)
        assert.are.equal(h.ghost.alpha, g.dim)
        assert.is_true(g.etaK <= 0)
        h.lanes = false
        publish(H, SET, function(s)
            s[2].offGCD = true
        end)
        frame(H, d)
        assert.are.equal(1, T.order[2].lane) -- one row with the rows off
        assert.are.same({}, H.errors)
    end)

    it("allocates nothing over 1,000 display frames after the first publish, the demo included", function()
        local H, d, T = boot(function(hw)
            hw.tracked.spell = "mortal_strike"
            hw.countdown.enabled = true
        end)
        publish(H, SET)
        for _ = 1, 5 do
            frame(H, d, 0.2)
        end
        -- warm: one demo start and stop, one cast
        H.Encore.Config = true
        for _ = 1, 40 do
            frame(H, d)
        end
        H.Encore.Config = false
        frame(H, d)
        publish(H, later(SET, 0.1, 1))
        frame(H, d)
        local status = H.Encore.Engine.Output.status
        -- built before the count (the test's own tables), six records each so every record table keeps its keys
        local seven = { unpack(SET) }
        seven[7] = { "sunder_armor", 9.0, 15, 90 }
        local full = later(seven, 0.1, 0)
        full[7] = nil
        local sets = { full, later(seven, 0.1, 1) }
        publish(H, sets[1]) -- warm: each set's first publish
        frame(H, d)
        publish(H, sets[2])
        frame(H, d)
        collectgarbage("collect")
        collectgarbage("stop")
        local before = collectgarbage("count")
        local shift = 0
        for n = 1, 1000 do
            if n % 100 == 50 then
                shift = (shift + 1) % 2
                publish(H, sets[shift + 1])
            end
            if n == 300 then
                status.combat = true
            elseif n == 700 then
                status.combat = false
            end
            H.ctl.now = H.ctl.now + 0.01
            d.__scripts.OnUpdate(d, 0.01)
        end
        local bytes = (collectgarbage("count") - before) * 1024
        collectgarbage("restart")
        assert.are.same({}, H.errors)
        assert.are.equal(0, bytes)
    end)
end)
