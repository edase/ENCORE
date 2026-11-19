#!/usr/bin/env bash
# Fails when the engine reaches into the UI (restructure plan, Task 4): the engine publishes through Engine.Output and
# raises hooks; it never names a display frame (EncoreDisplay*), the UI's namespace (ns.UI.) or its DisplayPool.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
engine=(src/Encore/Engine/Sim/{Core,State,Targets,Scripts}.lua src/Encore/Engine/{Output,Registry,Snapshot,Driver}.lua)
for f in "${engine[@]}"; do
    [ -f "$f" ] || { echo "missing engine file: $f (renamed? update this list)"; fail=1; }
done
hits=$(grep -nE 'EncoreDisplay|ns\.UI\.|DisplayPool' "${engine[@]}")
[ -n "$hits" ] && { echo "$hits"; fail=1; }
# Profile port (Task 6): no engine file names the AceDB profile; the engine reads Engine.settings, which Options fills
# through Engine.Configure(profile). `self.DB.` with the dot, so Scripts' own `self.DB[ id ]` passes; comment lines
# pass. Exempt: Settings.lua, whose Configure takes the profile.
hits=$(grep -rnE 'Encore\.DB\b|self\.DB\.|\.profile\b' src/Encore/Engine --include='*.lua' |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*--|^src/Encore/Engine/Settings\.lua:')
[ -n "$hits" ] && { echo "$hits"; fail=1; }
# UI/Options direction (Task 5): the UI, Options, Integrations/ and Encore.lua read the engine only through Engine.Registry, the
# commands and Engine.Output, never the driver frame (ns.EngineFrame). `state.`/`class.` not after `.` or a name char,
# so `self.state` and `classes` pass.
# Exempt: Encore.lua's definitions of Encore.Class/Encore.State, DevTools' generated-text line, and DisplayPool in
# UI.lua (which owns it).
ui=(src/Encore/UI/UI.lua src/Encore/UI/Resolve.lua src/Encore/UI/Styles.lua src/Encore/UI/Styles/*.lua src/Encore/UI/Truth.lua src/Encore/Options/*.lua src/Encore/Integrations/*.lua src/Encore/Encore.lua)
hits=$(grep -nE '(^|[^.[:alnum:]_])(state[.:]|class\.)|Encore\.State\b|Encore\.Class\b|\bns\.queue|ns\.getNumberTargets|VirtualStateInternal|DisplayPool|EncoreDisplay[A-Za-z]*\.(RecommendationsStr|NewRecommendations|activeThread)|EncoreEngine\b|ns\.EngineFrame' "${ui[@]}" |
    grep -vE '^src/Encore/Encore\.lua:[0-9]+:Encore\.(Class|State) = |^src/Encore/Options/DevTools\.lua:[0-9]+:    self:Append\( "local class, state = Encore\.Class, Encore\.State" \)$|^src/Encore/UI/UI\.lua:[0-9]+:.*Encore\.DisplayPool\b')
[ -n "$hits" ] && { echo "$hits"; fail=1; }
[ $fail -eq 0 ] && echo "ok: the engine names no UI frame in ${#engine[@]} files and no profile; UI/Options read it through Engine in ${#ui[@]} files"
exit $fail
