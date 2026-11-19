# Encore's fork tools

Encore is a personal fork of [Hekili Forever](https://github.com/zmsl/hekili) by defzach. These two tools keep it a
fork that can still take Hekili Forever's fixes.

## rename.py

Renames a Hekili Forever tree to Encore: the folders, TOCs, the global `Hekili` object, frame names, saved variables
(`EncoreDB`), the slash commands (`/encore`, `/enc`) and the player-visible text. It never touches Lua comments (the
file headers carry the GPL notices and the credits) or any line that credits the original projects. It is
deterministic, so the same upstream commit always renames to the same tree.

```sh
python3 tools/encore/rename.py <a Hekili Forever checkout> [--report]
```

## sync_upstream.sh

Brings zmsl/hekili's newest `forever` into Encore. It renames a fresh upstream checkout with `rename.py`, commits that
on the `upstream-renamed` branch, and merges the branch into yours, so the merge shows only what upstream changed.

```sh
tools/encore/sync_upstream.sh
```

The `upstream-renamed` branch starts at the commit "Encore: rename Hekili Forever to Encore (script output only)": the
rename of zmsl/hekili `314a87b8` (v0.10.0), Encore's starting point. Conflicts are normal where Encore deleted or
reshaped a file: keep Encore's side for anything Encore cut.

The rest of `docs/` is Hekili Forever's own documentation, kept as written: where it says `Hekili`, Encore's code says
`Encore`.
