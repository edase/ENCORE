-- tests/Forever/ellesmere_bindings_spec.lua: the EllesmereUI branch of the keybinding reader (Engine/Sim/Events.lua,
-- ns.ReadKeybindings). EllesmereUI's bars 1-8 press Blizzard's slots through Blizzard's binding commands (the default
-- bars' reading); its bars 9 and 10 have their own commands, EUI_BAR9_BUTTONn (slots 13-24, page 2) and
-- EUI_BAR10_BUTTONn (slots 109-120, page 10). A slot one of them claims gets no default-bar copy.
local headless = require("Game.harness.headless")
local ww = require("Forever.helpers.warrior_world")
local fake = require("Game.State.helpers.fake_api")

local world

local fakeNew = fake.new
local function boot(loaded)
    fake.new = function(...)
        local api, ctl = fakeNew(...)
        api.GetActionInfo = function(slot)
            local id = world.actions[slot]
            if id then
                return "spell", id
            end
        end
        api.GetBindingKey = function(command)
            return world.keys[command]
        end
        return api, ctl
    end
    local H = headless.new({ character = ww.character(), pack = ww.PACK })
    fake.new = fakeNew
    assert.are.same({}, H.loadErrors)
    H.ns.Facade.C_AddOns.IsAddOnLoaded = function(name)
        return name == loaded
    end
    return H
end

local function id(H, name)
    return H.Encore.Engine.Registry.Abilities()[name].id
end

describe("EllesmereUI keybinding discovery", function()
    before_each(function()
        world = { actions = {}, keys = {} }
    end)

    it("reads bars 9 and 10 from EllesmereUI's own commands and bars 1-8 from Blizzard's", function()
        local H = boot("EllesmereUIActionBars")
        world.actions[14] = id(H, "mortal_strike") -- bar 9, button 2
        world.actions[110] = id(H, "overpower") -- bar 10, button 2
        world.actions[3] = id(H, "slam") -- the main bar, button 3
        world.keys.EUI_BAR9_BUTTON2 = "SHIFT-Q"
        world.keys.EUI_BAR10_BUTTON2 = "CTRL-E"
        world.keys.ACTIONBUTTON2 = "2" -- what the default reading would name for slots 14 and 110
        world.keys.ACTIONBUTTON3 = "3"
        assert.has_no.errors(function()
            H.ns.ReadKeybindings()
        end)
        local info = H.Encore.KeybindInfo
        assert.are.equal("SQ", info.mortal_strike.upper[2])
        assert.are.equal("CE", info.overpower.upper[10])
        assert.are.equal("3", info.slam.upper[1])
    end)

    it("leaves slots 13-24 and 109-120 to the default reading without EllesmereUI", function()
        local H = boot(nil)
        world.actions[14] = id(H, "mortal_strike")
        world.actions[110] = id(H, "overpower")
        world.keys.EUI_BAR9_BUTTON2 = "SHIFT-Q"
        world.keys.ACTIONBUTTON2 = "2"
        H.ns.ReadKeybindings()
        local info = H.Encore.KeybindInfo
        assert.are.equal("2", info.mortal_strike.upper[2])
        assert.are.equal("2", info.overpower.upper[10])
    end)
end)
