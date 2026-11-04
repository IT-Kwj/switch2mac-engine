# switch2mac engine

The engine behind [switch2mac](https://github.com/azmasm/switch2mac)'s own builds of Nintendo Switch 2 games, starting with Mario Kart World 1.0.0: a fork of [nxnative](https://github.com/seedds/nxnative) by seedds, carried forward for Switch 2.

**To play a game, use [switch2mac](https://github.com/azmasm/switch2mac)**: it fetches this engine at the version a game needs and builds the app for you. This repository is for people working on the engine itself.

What switch2mac added to nxnative (commit `6a787668`): NVN2 graphics on Metal, Switch 2 mesh and task shaders, VP9 movies, sparse textures, the Ampere-to-Maxwell shader lowering hookup (Eglantine's `nx2_lower`), many shader translator fixes, the performance work that took Mario Kart World from 20 to about 58 fps on an M1 Max, the performance overlay and settings panel, and the shared shader list's Send offer. Only what switch2mac's builds use is kept here; nxnative's other games, docs and scripts are in nxnative.

## Where to send what

- Engine bugs and fixes (graphics, crashes, speed, the runtime): issues and pull requests **here**.
- Games, the app, building, docs and shared shader lists: [switch2mac](https://github.com/azmasm/switch2mac).
- Not sure? Open it on switch2mac; it gets moved here if it belongs here.

## Licences and credits

MIT (`LICENSE`), except `dm/gfx/tools/nx2_lower/` (GPL-3.0-or-later) and the third-party code in `dm/third_party/` (each under its own licence: `dm/third_party/README.md`). Details: [NOTICE.md](NOTICE.md).

This repository holds no game content: no game files, keys or shader code from any game.
