-- tests/Forever/movement_toggle_spec.lua (re-pin plan, Task 6; design §2.1): the Movement toggle, a generic setting
-- (`toggle.movement`, default ON) a spec opts into through its NewClass entry (`movement = true`, ruling R3: per spec,
-- never per class kit). Its options row and minimap entry show only for a spec that opted in; the value is the
-- profile's, so switching spec leaves it as it was.
local headless = require("Game.harness.headless")
local ww = require("Forever.helpers.warrior_world")

local FURY = 100012

local function boot(saved)
    local H = headless.new({ character = ww.character(), pack = ww.PACK, saved = saved })
    assert.are.same({}, H.loadErrors)
    return H
end

local function defaults(H)
    local t = H.Encore.DB.profile.toggles
    assert.is_true(t.movement.value)
    assert.are.equal("", t.movement.key)
    assert.is_true(H.Encore.State.toggle.movement)
end

describe("the Movement toggle", function()
    it("is ON with no key on a fresh profile", function()
        defaults(boot())
    end)

    it("is ON with no key on a saved profile that has no movement key", function()
        defaults(boot({ profiles = { Default = { toggles = { potions = { key = "", value = true } } } } }))
    end)

    it("flips with FireToggle and is set by /encore set movement on", function()
        local H = boot()
        H.Encore:FireToggle("movement")
        assert.is_false(H.Encore.State.toggle.movement)
        H.Encore:CmdLine("set movement on")
        assert.is_true(H.Encore.State.toggle.movement)
        assert.are.same({}, H.errors)
    end)

    it("gates a priority line that reads toggle.movement", function()
        local H = boot()
        H.ctl.inRange.target, H.ctl.level.target = true, 60
        H.Fire("PLAYER_TARGET_CHANGED")
        local t = H.ctl.now + 0.2
        assert(headless.cycle(H, t))
        -- a free line (Bloodrage), so only the toggle decides it, never the belief's rage band
        local lines = H.Encore:ParseActionList("actions+=/bloodrage,if=toggle.movement")
        lines[1].enabled = true
        lines[2] = { enabled = true, action = "berserker_stance" }
        H.Encore.DB.profile.packs[ww.PACK].lists = { precombat = {}, default = lines }
        H.Encore:LoadScripts()
        H.Fire("PLAYER_REGEN_DISABLED")
        local out = H.Encore.Engine.Output.Primary
        assert.is_true(H.Encore.Engine.Subscribe("Primary", function() end))
        t = t + 0.2
        assert(headless.cycle(H, t))
        assert.are.equal("bloodrage", out.recs[1] and out.recs[1].actionName)
        H.Encore:FireToggle("movement", "off")
        t = t + 0.2
        assert(headless.cycle(H, t))
        assert.are.equal("berserker_stance", out.recs[1] and out.recs[1].actionName)
        assert.are.same({}, H.errors)
    end)

    it("answers per spec: an opted-in spec is true, the class's other specs stay false (R3)", function()
        local H = boot()
        local Registry = H.Encore.Engine.Registry
        assert.is_false(Registry.MovementSpec(ww.SPEC))
        Registry.Specs()[ww.SPEC].options.movement = true
        assert.is_true(Registry.MovementSpec(ww.SPEC))
        assert.is_false(Registry.MovementSpec(0)) -- no such spec
        -- a NewClass entry's `movement` reaches only its own spec, even when the kit registers options for every tree
        local kit = H.Encore:NewClass("WARRIOR", { specs = { { key = "a", movement = true }, { key = "b" } } })
        kit:RegisterOptions({ enabled = true })
        assert.is_true(Registry.MovementSpec(kit.trees[1].id))
        assert.is_false(Registry.MovementSpec(kit.trees[2].id))
    end)

    it("shows its options row only for an opted-in spec, and keeps its value across a spec switch", function()
        local H = boot()
        H.Encore:EmbedToggleOptions(H.Encore.Options)
        local row = H.Encore.Options.args.toggles.args.movement
        assert.is_true(row.hidden())
        H.Encore.Engine.Registry.Specs()[ww.SPEC].options.movement = true
        assert.is_false(row.hidden())
        H.Encore:FireToggle("movement", "off")
        assert.is_truthy(H.Encore:SetSpecChoice("fury"))
        H.Encore:SpecializationChanged()
        assert.are.equal(FURY, H.Encore.State.spec.id)
        assert.is_true(row.hidden()) -- Fury did not opt in
        assert.is_false(H.Encore.DB.profile.toggles.movement.value)
        assert.are.same({}, H.errors)
    end)
end)

-- the harness hook (tests/Game/harness/loop.lua): here, not in replay_spec, since the harness core names no class
describe("the Movement toggle in a headless run", function()
    local loop = require("Game.harness.loop")
    local scenarios = require("Game.harness.scenarios")
    it("is ON in a replay (wowsims's rotation moves) and OFF in a loop run", function()
        local L = loop.new(ww)
        local R = { pull = 3, duration = 1, decisions = {} }
        function R.world(wo, seed)
            return scenarios.world(wo, seed)
        end
        function R.next()
            return false
        end
        L.us.Encore.DB.profile.toggles.movement.value = false
        loop.replay(L, R)
        assert.is_true(L.us.Encore.State.toggle.movement)
        loop.run(L, 2, { duration = 1 }, { { H = L.us } })
        assert.is_false(L.us.Encore.State.toggle.movement)
    end)
end)
