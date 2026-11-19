-- tests/Forever/content_spec.lua (restructure plan, Task 8): Engine/Content.lua, the content loader OnInitialize runs:
-- it loads Hekili_Shared first, then picks Hekili_<Class> by the player's class and loads it when its
-- X-Hekili-ContentAPI matches, and keeps a notice (shown at OnEnable by ns.ContentNotice) when the shared load fails,
-- the class cannot be read, or the pack is missing, of another content API (not loaded), or fails to load; once per
-- session. A fake C_AddOns records the calls.
local addons = require("helpers.addons")

describe("Engine/Content.lua", function()
    local WARRIOR = { "load Encore_Shared", "meta Encore_Warrior X-Encore-ContentAPI", "load Encore_Warrior" }
    local calls, notes, meta, loadResult, classToken, saved, ns

    -- a fresh load of Content.lua (its once-per-session flag reset), LoadContent, then ContentNotice; `again` repeats
    -- both calls on the same load, as OnInitialize and a disable/enable's OnEnable would
    local function run(again)
        calls, notes = {}, {}
        ns = {
            L = require("helpers.english"),
            Facade = {
                UnitClass = function(unit)
                    assert.are.equal("player", unit)
                    return "Name", classToken, 1
                end,
                C_AddOns = {
                    GetAddOnMetadata = function(name, key)
                        calls[#calls + 1] = "meta " .. name .. " " .. key
                        return meta[name] and meta[name][key]
                    end,
                    LoadAddOn = function(name)
                        calls[#calls + 1] = "load " .. name
                        return loadResult(name)
                    end,
                },
            },
        }
        _G.Encore = {
            Notify = function(_, text)
                notes[#notes + 1] = text
            end,
        }
        assert(loadfile("src/Encore/Engine/Content.lua"))("Encore", ns)
        for i = 1, again and 2 or 1 do
            ns.LoadContent()
            ns.ContentNotice()
            if i == 1 and type(again) == "function" then
                again()
            end
        end
    end

    after_each(function()
        _G.Encore = saved or nil
    end)

    before_each(function()
        saved = rawget(_G, "Encore") or false
        meta = {}
        for _, name in ipairs(addons.CONTENT) do
            meta[name] = addons.meta(name)
        end
        loadResult = function()
            return true
        end
        classToken = "WARRIOR"
    end)

    it("loads Encore_Warrior for a Warrior, whose TOC declares the core's content API", function()
        run()
        assert.are.same(WARRIOR, calls)
        assert.are.same({}, notes)
        classToken = "DRUID"
        run()
        assert.are.same({ "load Encore_Shared", "meta Encore_Druid X-Encore-ContentAPI", "load Encore_Druid" }, calls)
    end)

    it("Notifies once for a class with no pack installed, and loads only the shared content", function()
        classToken = "NOPACK" -- a synthetic class with no content addon
        run()
        assert.are.same({ "load Encore_Shared", "meta Encore_Nopack X-Encore-ContentAPI" }, calls)
        assert.are.same({ "no Forever pack for Nopack; install Encore_Nopack" }, notes)
    end)

    it("Notifies a content API mismatch and does not load the pack", function()
        meta.Encore_Warrior["X-Encore-ContentAPI"] = "6"
        run()
        assert.are.same({ "load Encore_Shared", "meta Encore_Warrior X-Encore-ContentAPI" }, calls)
        assert.are.same(1, #notes)
        assert.is_truthy(notes[1]:find("Encore_Warrior", 1, true))
        assert.is_truthy(notes[1]:find("content API 6", 1, true))
    end)

    it("Notifies a failed pack load, whether LoadAddOn refuses or raises", function()
        loadResult = function(name)
            return name == "Encore_Shared", "DISABLED"
        end
        run()
        assert.are.same(WARRIOR, calls)
        assert.are.same({ "could not load Encore_Warrior (DISABLED)" }, notes)
        loadResult = function(name)
            if name ~= "Encore_Shared" then
                error("boom", 0)
            end
            return true
        end
        run()
        assert.are.same({ "could not load Encore_Warrior (boom)" }, notes)
    end)

    it("Notifies a failed shared load and tries no pack (it depends on the shared content)", function()
        loadResult = function()
            return false, "DISABLED"
        end
        run()
        assert.are.same({ "load Encore_Shared" }, calls)
        assert.are.same({ "could not load Encore_Shared (DISABLED)" }, notes)
        loadResult = function()
            error("boom", 0)
        end
        run()
        assert.are.same({ "could not load Encore_Shared (boom)" }, notes)
    end)

    it("records the loaded pack's addon (its string table labels the built-in priorities)", function()
        run()
        assert.are.equal("Encore_Warrior", ns.PackAddon)
        classToken = "NOPACK"
        run()
        assert.is_nil(ns.PackAddon)
    end)

    it("runs once per session: a second call loads nothing and repeats no notice", function()
        run(true)
        assert.are.same(WARRIOR, calls)
        classToken = "NOPACK" -- a synthetic class with no content addon
        run(true)
        assert.are.same({ "load Encore_Shared", "meta Encore_Nopack X-Encore-ContentAPI" }, calls)
        assert.are.same({ "no Forever pack for Nopack; install Encore_Nopack" }, notes)
    end)

    it("declares one content API in every content TOC", function()
        for _, name in ipairs(addons.CONTENT) do
            assert.are.equal("16", addons.meta(name)["X-Encore-ContentAPI"], name)
        end
        local src = assert(io.open("src/Encore/Engine/Content.lua")):read("*a")
        assert.is_truthy(src:find("\nlocal CONTENT_API = 16\n", 1, true))
    end)

    it("without a class token, loads the shared content only and Notifies once to /reload (nothing retries)", function()
        classToken = nil
        run(function()
            classToken = "WARRIOR"
        end)
        assert.are.same({ "load Encore_Shared" }, calls)
        assert.are.same({ "could not read your class at load; /reload" }, notes)
    end)
end)
