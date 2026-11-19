<p align="center"><img src="docs/publishing/icon-512.png" alt="Encore" width="160"></p>

# Encore

Encore is Chad's personal fork of [Hekili Forever](https://github.com/zmsl/hekili) by defzach, made into a
rhythm-game style spell highway for WoW Forever: the abilities to press next scroll toward a hit line, and you press
each one as it crosses. It keeps Hekili Forever's prediction engine, which reads what the Forever client still shows
and estimates the rest.

> **Encore is not Hekili Forever and not the original Hekili.** Please never report Encore problems to defzach or to
> the original Hekili authors. Encore's issues go to https://github.com/edase/encore/issues.

## Status

Hekili Forever v0.10.0, renamed and cut down to Paladin and Warrior, in English. It installs as its own addon, so it
can sit beside Hekili Forever. The spell highway comes next.

## Install

Download the zip from https://github.com/edase/encore/releases (or build it with `make package`) and extract it into
`_forever_\Interface\AddOns\` in the World of Warcraft folder: four folders, `Encore`, `Encore_Shared`,
`Encore_Paladin` and `Encore_Warrior`. (The repository's `src/` also holds Hekili Forever's other class packs, kept
only as test material: do not copy those.) Encore's settings are its own (`EncoreDB`); `/encore` (or `/enc`) opens
the options.

## Reporting a problem

- **Lua errors:** install BugSack and BugGrabber, reproduce the error, and paste BugSack's text into the issue.
- **A wrong recommendation:** type `/enc snap` while it is happening, then open `/encore` > **Snapshots
  (Troubleshooting)**, pick the snapshot, press Ctrl+A and Ctrl+C in its text box, and paste it into the issue.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for the headless checks, and [tools/encore/README.md](tools/encore/README.md)
for how Encore takes Hekili Forever's updates (`tools/encore/sync_upstream.sh`).

## Credits

- **Hekili Forever** by defzach: https://github.com/zmsl/hekili. Encore is built on it.
- **Hekili**, the original project: based on the original work by Hekili and its maintainers,
  https://github.com/Hekili/hekili. Hekili Forever was made with the original author's explicit permission.
- **wowsims/forever** (MIT): the default priorities are translated from its action lists
  (`src/Encore/LICENSE-wowsims.txt`).
- **Taco Dog Forever** and **Catnip** (Durts): code and secret-value research credited in the file headers.
- Bundled libraries (Ace3, LibStub, LibSharedMedia-3.0, LibDBIcon-1.0, LibDataBroker-1.1 and others) belong to their
  authors under their own licences: [src/Encore/Libs/CREDITS.md](src/Encore/Libs/CREDITS.md).

## Licence

[GNU General Public License version 3 or later](LICENSE): either version 3 of the License, or (at your option) any
later version. Modified for WoW Forever by defzach from October 2026; modified as Encore by Chad (edase) from November
2026.
