"""Offline tests of tools/encore/rename.py: what it renames, what it never touches, and that it is idempotent."""

import importlib.util
import os
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
spec = importlib.util.spec_from_file_location("rename", os.path.join(ROOT, "tools", "encore", "rename.py"))
rename = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rename)


class Lua(unittest.TestCase):
    def test_code_and_strings_are_renamed(self):
        src = 'Hekili:Print( "Hekili Forever is ready" )\nlocal f = CreateFrame( "Frame", "HekiliEngine" )\n'
        self.assertEqual(
            rename.lua_rename(src),
            'Encore:Print( "Encore is ready" )\nlocal f = CreateFrame( "Frame", "EncoreEngine" )\n',
        )

    def test_comments_are_never_touched(self):
        src = "-- Hekili Forever, based on the original work by Hekili\n--[[ Hekili ]] x = Hekili\n"
        self.assertEqual(rename.lua_rename(src), "-- Hekili Forever, based on the original work by Hekili\n--[[ Hekili ]] x = Encore\n")

    def test_a_credit_line_keeps_its_text(self):
        src = 'name = L["a fork of the original Hekili project"] .. Hekili.Version\n'
        self.assertEqual(rename.lua_rename(src), 'name = L["a fork of the original Hekili project"] .. Encore.Version\n')

    def test_each_literal_decides_for_itself(self):
        src = '    ["src/Hekili/Engine/Sim/Targets.lua"] = "github%.com/hekili/hekili/issues/4845",\n'
        self.assertEqual(
            rename.lua_rename(src), '    ["src/Encore/Engine/Sim/Targets.lua"] = "github%.com/hekili/hekili/issues/4845",\n'
        )

    def test_the_issue_and_release_links_point_at_encore(self):
        src = 'get = function() return "https://github.com/zmsl/hekili/issues" end\n'
        self.assertEqual(rename.lua_rename(src), 'get = function() return "https://github.com/edase/encore/issues" end\n')

    def test_slash_commands(self):
        src = 'self:RegisterChatCommand( "hekili", "CmdLine" )\nself:RegisterChatCommand( "hek", "CmdLine" )\n'
        out = rename.lua_rename(src)
        self.assertIn('"encore"', out)
        self.assertIn('"enc"', out)

    def test_long_strings_and_escapes(self):
        src = 'a = [==[Hekili]==] b = "say \\"Hekili\\"" c = \'Hekili\'\n'
        self.assertEqual(rename.lua_rename(src), 'a = [==[Encore]==] b = "say \\"Encore\\"" c = \'Encore\'\n')

    def test_idempotent(self):
        src = 'Hekili.Engine = {} -- Hekili\nprint("HEKILI_TOGGLE", "/hekili")\n'
        once = rename.lua_rename(src)
        self.assertEqual(rename.lua_rename(once), once)


class Toc(unittest.TestCase):
    def test_encore_owns_its_metadata_and_drops_the_curse_project(self):
        toc = (
            "## Title: Hekili Forever - Paladin\n## Author: defzach\n## Notes: x\n"
            "## X-Curse-Project-ID: 1\n## Dependencies: Hekili, Hekili_Shared\n"
        )
        out = rename.toc_rename(toc, "src/Hekili_Paladin/Hekili_Paladin.toc")
        self.assertIn("## Title: Encore - Paladin\n", out)
        self.assertIn("## Author: Chad (edase), from Hekili Forever by defzach\n", out)
        self.assertIn("## Dependencies: Encore, Encore_Shared\n", out)
        self.assertNotIn("X-Curse-Project-ID", out)
        self.assertIn("based on the original work by Hekili", out)


class Tree(unittest.TestCase):
    def test_paths_move_and_docs_stay(self):
        with tempfile.TemporaryDirectory() as d:
            def put(rel, text):
                os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
                with open(os.path.join(d, rel), "w") as fh:
                    fh.write(text)

            put("src/Hekili/Hekili.lua", "Hekili = {}\n")
            put("docs/notes.md", "Hekili\n")
            subprocess.run(["git", "init", "-q", d], check=True)
            subprocess.run(["git", "-C", d, "add", "-A"], check=True)
            subprocess.run(["python3", os.path.join(ROOT, "tools", "encore", "rename.py"), d], check=True, capture_output=True)
            with open(os.path.join(d, "src/Encore/Encore.lua")) as fh:
                self.assertEqual(fh.read(), "Encore = {}\n")
            with open(os.path.join(d, "docs/notes.md")) as fh:
                self.assertEqual(fh.read(), "Hekili\n")


if __name__ == "__main__":
    unittest.main()
