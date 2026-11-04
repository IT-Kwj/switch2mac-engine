# switch2mac engine

The engine behind [switch2mac](https://github.com/azmasm/switch2mac)'s own builds of Nintendo Switch 2 games, starting with Mario Kart World 1.0.0: a fork of [nxnative](https://github.com/seedds/nxnative) by seedds, carried forward for Switch 2.

**To play a game, use [switch2mac](https://github.com/azmasm/switch2mac)**: it fetches this engine at the version a game needs and builds the app for you. This repository is for people working on the engine itself.

What switch2mac added to nxnative (commit `6a787668`): NVN2 graphics on Metal, Switch 2 mesh and task shaders, VP9 movies, sparse textures, the Ampere-to-Maxwell shader lowering hookup (Eglantine's `nx2_lower`), many shader translator fixes, the performance work that took Mario Kart World from 20 to about 58 fps on an M1 Max, the performance overlay and settings panel, and the shared shader list's Send offer. Only what switch2mac's builds use is kept here; nxnative's other games, docs and scripts are in nxnative.

## How it differs from nxnative today

> **The key finding.** nxnative's builds suit modern Macs, **M3 and newer**: they translate Switch 2 shaders directly, and those shaders need more GPU registers, which newer chips handle well. On **M1 and M2 Macs, even Max chips**, that costs a lot, and nxnative's builds currently struggle to reach 60 fps. switch2mac's way of translating removes that penalty, so with this engine **the chip's generation is not the main bottleneck: memory is**, followed by the size of the GPU (on an M1 Pro, docked mode still paces at 30 fps; handheld mode runs at a locked 60).

nxnative and this engine both run the game's own code natively and draw it with Metal 4. They differ in how they turn the game's Switch 2 shaders into Metal, and in how they handle memory, so they suit different Macs.

| | This engine (switch2mac) | nxnative today |
|---|---|---|
| Switch 2 shaders (NVIDIA Ampere code) | **Lowered to Switch 1 (Maxwell) code first** by Eglantine's `nx2_lower`, then translated by Ryujinx's long-tested Maxwell path into Metal | **Translated directly** by a new Ampere decoder in its Ryujinx translator: no detour, but younger code |
| Shader output | Tuned for the Mac's GPU: uniform reads hoisted, border-colour emulation off for Mario Kart World. Uses fewer GPU registers, which matters most on M1 and M2 | Reads the Switch 2 code as written; heavier on GPU registers in some passes (Mario Kart World's reflection filters) |
| Big terrain textures | Backed by tile as the game maps them, but **tiles are never freed**, and the same memory mapped in several places is copied for each: memory grows in long sessions | Since `1110473c` (Nov 4), tiles the game maps in several places **share one copy**: about a third of the terrain memory |
| Extras | Performance mode (skips one reflection update), a shared pipeline list prepared before the first frame, the run-time shaders taken from the dump, frame pacing fixed at 60 | Its own settings window at launch; per-game seed pipeline lists |
| Known picture problems | Lamp light through walls at night; one effect simulation produces nothing (what it draws is not confirmed: likely waves on a procedural surface) | Sky "streaks" (panels) in some places of Mario Kart World ([nxnative#1186](https://github.com/seedds/nxnative/issues/1186)) |

### What it means for your Mac (Mario Kart World)

Measured on the same race (Mario Bros. Circuit, 150cc) on an **M1 Max, 64 GB**:

| | This engine | nxnative |
|---|---|---|
| Frame rate | **59.9 fps** | 46.8 fps |
| GPU time per frame | ~11 ms | ~16.5 ms (the game also lowers its 3D resolution to 2048x1152 to cope) |
| Reflection filter passes | 1.7 ms | 5.4 ms |
| Memory in that race | 14.1 GB | 11.2 GB |

- **M1 and M2 Macs:** this engine is the faster one, by a wide margin in the reflection passes. Also tested: handheld mode on an M1 Pro (32 GB) runs races at a locked 60 fps.
- **M3 and newer:** players report nxnative close to 60 fps. These chips share GPU register space dynamically (Apple's Dynamic Caching), which is likely why nxnative's heavier shaders cost them little; the gap seen on M1 Max is not expected there. switch2mac's own builder defaults to nxnative's build on these Macs, with a note about the sky.
- **16 GB Macs:** memory is this engine's weak point. It uses 13-16 GB in races and up to about 20 GB in long free-roam sessions, so a 16 GB Mac can stutter or swap. nxnative's shared terrain tiles keep it lower (its authors report 60 fps races at 11.3 GB on a 16 GB M6). Bringing that idea here is the next piece of work.
- **24 GB or more:** both run; pick by chip as above.

These are measurements on a few Macs plus player reports, not a promise for every machine. switch2mac's app will collect opt-in reports of how each build runs per Mac, and its defaults will follow them.

## Where to send what

- Engine bugs and fixes (graphics, crashes, speed, the runtime): issues and pull requests **here**.
- Games, the app, building, docs and shared shader lists: [switch2mac](https://github.com/azmasm/switch2mac).
- Not sure? Open it on switch2mac; it gets moved here if it belongs here.

## Licences and credits

MIT (`LICENSE`), except `dm/gfx/tools/nx2_lower/` (GPL-3.0-or-later) and the third-party code in `dm/third_party/` (each under its own licence: `dm/third_party/README.md`). Details: [NOTICE.md](NOTICE.md).

This repository holds no game content: no game files, keys or shader code from any game.
