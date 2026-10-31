# Balatro on Wii (unofficial)

An experiment that runs the original, unmodified Lua code of **Balatro** on a real Nintendo Wii.

This is not a port in the usual sense. I did not rewrite the game. Balatro is a LÖVE 11 game, so almost everything it does is Lua code calling the `love.*` API. This project is a small, Wii-only replacement for that API (written in C on top of devkitPPC / libogc) plus a Lua 5.1 interpreter, so the game's own scripts can run as they are. The game logic you see on screen is the original game logic.

> **No game files are included here, and none ever will be.** You need your own legal copy of Balatro. The loader reads the Lua files and textures that you extract from your own copy.

Not affiliated with LocalThunk or Playstack. Balatro is their work, please buy it.

## Status

It runs, it is playable, and I have finished runs with it on real hardware. It is also slow in places. Numbers from my own measurements on a Wii:

| Situation | What to expect |
|---|---|
| Main menu | about 55 fps |
| Hand selection, normal board | about 30 fps |
| Late game with a lot of cards on screen (lots of Perkeo copies, big decks) | 8 to 12 fps |

Everything below was developed and tested on one real Wii. I have not tested it on Dolphin, Wii U vWii or other setups.

Things that work: runs, shop, blinds, boosters, saving and loading, music and sound effects, seeded runs (seeds from the PC game give the same cards), Wiimote with IR pointer, sideways Wiimote, Classic Controller, GameCube pad and Nunchuk.

Things that are approximated or missing:
- The Wii has no shaders. Foil, Holographic, Polychrome, Negative and the debuff look are re-created with GX tricks (coloured sheen, colour inversion, darkening). They look close, not identical.
- Particles are off, text is mostly static, card movement is simpler (no spring wobble), Reduced Motion is forced on. All of this is for speed.
- The main menu background is a pre-rendered picture that rotates, not the real shader.
- USB storage support was written but is untested. Use an SD card.
- Long runs eventually hit the Wii's memory limit. The game then does short emergency garbage collections (you see a small freeze).

## What you need

- A Wii with the Homebrew Channel and an SD card (SDHC is fine)
- A legal copy of Balatro on PC (I built against the February 2025 version, LÖVE 11) to take the files from
- About 150 MB free on the card (the converted audio alone is around 120 MB)

## Installation guide (step by step)

You need your **own legal copy** of Balatro on PC.

### 1. Get the game's files
- Find `Balatro.exe` in your Steam install folder (Steam > Balatro > Manage > Browse local files).
- Open it with [7-Zip] and extract everything into a new folder, for example `C:\balatro\src`.
- You should now see `main.lua`, `game.lua`, `card.lua`, a `functions` folder and a `resources` folder inside `src`.
- This project was built against the February 2025 version. Other versions may need changes.

### 2. Convert the sounds
The Wii cannot read Balatro's `.ogg` files, so they are converted once to `.wav`.
1. Install [ffmpeg](https://ffmpeg.org/download.html) and make sure `ffmpeg` works in a Command Prompt.
2. Run `tools\convert_audio.bat "C:\balatro\src"`
3. It creates an `audio` folder with one `.wav` per sound (16-bit, 32 kHz, stereo for `music*`, mono for everything else). Expect roughly 120 MB.

**Important:** do not delete the original `resources\sounds` folder. The game still looks for the original sound names, and the `.wav` files are only a replacement for playback. Both must be on the card.

### 3. Copy everything to the SD card
```
sd:/apps/balatro-wii/boot.dol        the .dol you just built, renamed to boot.dol
sd:/balatro/src/                     the full contents of C:\balatro\src (Lua files + resources, including resources\sounds)
sd:/balatro/audio/                   the .wav files from step 2
sd:/balatro/wii/                     play.lua, love_stub.lua, opt.lua, srcpatch.lua, menu_swirl.png
```
`sd:/balatro/save` and `play-report.txt` are created by the game.

### 4. Run
Start it from the Homebrew Channel. The first start takes about 12 seconds to load.

### If there is no sound
- Check that `sd:/balatro/audio/` contains files like `music1.wav`.
- Check that the original `sd:/balatro/src/resources/sounds/` folder is still there.
- Run `ffprobe` on one `.wav`: it must say pcm_s16le, 32000 Hz.
- Look at `play-report.txt` after a run for audio lines.

## Setup (short version)

1. Extract the game's Lua files and `resources` folder from your own copy.
2. Convert the audio to WAV (the repo has `convert_audio.bat`; music is stereo 32 kHz, the rest mono 32 kHz).
3. Copy everything to the card using this layout:

```
sd:/apps/balatro-wii/boot.dol        the built homebrew app
sd:/balatro/src/                     the game's own Lua files and resources
sd:/balatro/audio/                   converted WAV files
sd:/balatro/wii/                     play.lua, love_stub.lua, opt.lua, srcpatch.lua, menu_swirl.png
sd:/balatro/save/                    created by the game
sd:/balatro/play-report.txt          written on every run
```

`menu_swirl.png` is the main menu background. Without it the loader falls back to the old procedural swirl.

## Controls

| Input | Action |
|---|---|
| IR pointer | mouse; A = left click, B = right click |
| PLUS / MINUS | Options / Run Info (they become R / L when the game shows Buy / Sell prompts) |
| Sideways Wiimote | 2 = A, 1 = B, A = Play Hand, B = Discard |
| Sideways Wiimote in the shop | A = Next Round, B = Reroll |
| Seed keyboard | 1 = Backspace, 2 = press a key, A = Enter, B = Back |
| HOME | back to the Homebrew Channel (use this to exit, see below) |
| Quit button in the menu | back to the Wii Menu |

**Always leave with HOME or Quit.** Saves and the report file are only guaranteed to be written on a clean exit. Pulling the SD card first can leave an empty report or a damaged save.

## How it works

- **C side** (`source/`): video and 2D drawing on GX, PNG to GX texture conversion (RGB5A3), FreeType fonts in three sizes, audio on ASND (short sounds cached in memory, music streamed from the card in a background thread), controller handling, and a small `wii` table exposed to Lua.
- **Lua side** (on the SD card, no rebuild needed to change):
  - `love_stub.lua` is the fake `love` module (filesystem, timer, window, audio, threads as coroutines, graphics calls mapped to the C functions).
  - `play.lua` is the entry point: loading screen, input, main loop, reports.
  - `opt.lua` holds runtime speed patches for the Wii.
  - `srcpatch.lua` applies small text patches to the game's Lua files while they are loaded. The files on the card are never modified.
- **Seeds:** the PC game runs on LuaJIT, whose `math.random` is a different generator from stock Lua 5.1. The same seed only gives the same cards if the generator matches, so LuaJIT's generator is reimplemented in C.
- **Speed:** almost all the time goes to Lua, not drawing calls. Things that helped: cheaper cursor and movement code (same results, fewer function calls), and putting cards to sleep when nothing touches them (deck, discard pile, consumables; they wake up the moment something changes). In my idle test scene this took the update step from 27 ms to 18 ms and the frame rate from about 23 to about 30.

## Debug and test files

Empty files you can drop into `sd:/balatro/`:

| File | Effect |
|---|---|
| `safe.txt` | turns off `opt.lua` and `srcpatch.lua` (plain behaviour) |
| `bench.txt` | starts a fixed test run and waits, for measuring |
| `nosleep.txt` | turns off the card sleeping |
| `nocull.txt` | draws every card of a big consumable stack instead of only some |

`play-report.txt` is rewritten at every start with frame times, memory, and a profile of where Lua time goes. If you report a bug, attach it.


## Credits

- Balatro by LocalThunk, published by Playstack
- devkitPro, devkitPPC and libogc
- Lua 5.1 by PUC-Rio
- LÖVE, used as the reference for the API that is imitated here
- FreeType, libpng, zlib

## Author

[ThatSkywalkerAbood](https://github.com/ThatSkywalkerAbood)

## License

The code in this repository (the C sources, the Lua files in `balatro/wii/` and the tools) is released under the [MIT License](LICENSE).

This does not cover Balatro. The game, its code, art, music and sounds belong to LocalThunk and Playstack, and none of them are included or licensed here.

### Third-party software
- Lua 5.1.5 (in `lualib/`), MIT license, Copyright (C) PUC-Rio. Keep its copyright notice with the source.
- Portions of this software are copyright (c) The FreeType Project (www.freetype.org). All rights reserved.
- libpng and zlib, under their own permissive licenses.
- devkitPro, devkitPPC and libogc, under their own licenses.
