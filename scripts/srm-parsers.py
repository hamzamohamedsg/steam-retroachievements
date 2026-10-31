#!/usr/bin/env python3
"""Write one Steam ROM Manager parser per console, reading ~/ROMs/<console folder>/.

Run with Steam ROM Manager closed. Re-run after downloading RetroArch cores to pick the installed ones.
Folders and cores mirror Sources/RACore/Consoles.swift.
"""
import json, os, random, time

HOME = os.path.expanduser("~")
CORES = f"{HOME}/Library/Application Support/RetroArch/cores"
RETROARCH = "/Applications/RetroArch.app/Contents/MacOS/RetroArch"
ART = ["tall", "long", "hero", "logo", "icon"]
OUT = f"{HOME}/Library/Application Support/steam-rom-manager/userData/userConfigurations.json"

# shortcut: disc games listed as both .m3u and .cue show up twice; delete the extra one in SRM's preview.
DISC = "m3u chd cue iso cso pbp"
CONSOLES = [  # name, folders, cores (preferred first), extensions
    ("Mega Drive", "genesis megadrive md", "genesis_plus_gx picodrive", "md gen smd bin zip"),
    ("Nintendo 64", "n64", "mupen64plus_next parallel_n64", "z64 n64 v64 zip"),
    ("SNES", "snes sfc superfamicom", "snes9x bsnes mesen-s", "sfc smc zip"),
    ("Game Boy", "gb", "gambatte sameboy mgba gearboy", "gb zip"),
    ("Game Boy Advance", "gba", "mgba vbam gpsp", "gba zip"),
    ("Game Boy Color", "gbc", "gambatte sameboy mgba gearboy", "gbc zip"),
    ("NES", "nes famicom fc", "mesen fceumm nestopia", "nes unf unif zip"),
    ("PC Engine", "pce pcengine tg16", "mednafen_pce_fast mednafen_pce", "pce zip"),
    ("Sega CD", "segacd megacd", "genesis_plus_gx picodrive", DISC),
    ("32X", "sega32x 32x", "picodrive", "32x zip"),
    ("Master System", "mastersystem sms", "genesis_plus_gx picodrive gearsystem", "sms zip"),
    ("PlayStation", "psx ps1 playstation", "swanstation mednafen_psx_hw pcsx_rearmed", DISC),
    ("Atari Lynx", "lynx", "handy mednafen_lynx", "lnx zip"),
    ("Neo Geo Pocket", "ngp ngpc", "mednafen_ngp race", "ngp ngc zip"),
    ("Game Gear", "gamegear gg", "genesis_plus_gx gearsystem", "gg zip"),
    ("GameCube", "gamecube gc ngc", "dolphin", "iso gcm gcz rvz ciso"),
    ("Atari Jaguar", "jaguar", "virtualjaguar", "j64 jag zip"),
    ("Nintendo DS", "nds", "melondsds melonds desmume", "nds zip"),
    ("Wii", "wii", "dolphin", "iso wbfs rvz gcz"),
    ("PlayStation 2", "ps2", "pcsx2", "iso chd cso"),
    ("Odyssey 2", "odyssey2 videopac", "o2em", "bin zip"),
    ("Pokemon Mini", "pokemini", "pokemini", "min zip"),
    ("Atari 2600", "atari2600", "stella stella2014", "a26 bin zip"),
    ("DOS", "dos msdos", "dosbox_pure", "zip dosz exe"),
    ("Arcade", "arcade fbneo mame neogeo naomi atomiswave", "fbneo mame2003_plus mame", "zip 7z"),
    ("Virtual Boy", "virtualboy vb", "mednafen_vb", "vb zip"),
    ("MSX", "msx msx2", "bluemsx fmsx", "rom mx1 mx2 dsk zip"),
    ("Commodore 64", "c64", "vice_x64sc", "d64 t64 prg crt zip"),
    ("ZX81", "zx81", "81", "p tzx zip"),
    ("SG-1000", "sg1000", "genesis_plus_gx gearsystem", "sg zip"),
    ("VIC-20", "vic20", "vice_xvic", "20 prg crt d64 zip"),
    ("Amiga", "amiga", "puae", "adf hdf lha m3u zip"),
    ("Atari ST", "atarist", "hatari", "st msa stx zip"),
    ("Amstrad CPC", "amstradcpc cpc", "cap32 crocods", "dsk sna cdt zip"),
    ("Saturn", "saturn", "mednafen_saturn yabause kronos", DISC),
    ("Dreamcast", "dreamcast dc", "flycast", "m3u chd gdi cdi"),
    ("PSP", "psp", "ppsspp", "iso cso pbp chd"),
    ("CD-i", "cdi", "same_cdi", "chd cue iso"),
    ("3DO", "3do", "opera", DISC),
    ("ColecoVision", "colecovision coleco", "gearcoleco bluemsx", "col zip"),
    ("Intellivision", "intellivision", "freeintv", "int bin zip"),
    ("Vectrex", "vectrex", "vecx", "vec zip"),
    ("PC-8801", "pc88", "quasi88", "d88 zip"),
    ("PC-9801", "pc98", "np2kai", "d98 fdi hdi zip"),
    ("PC-FX", "pcfx", "mednafen_pcfx", DISC),
    ("Atari 5200", "atari5200", "a5200 atari800", "a52 bin zip"),
    ("Atari 7800", "atari7800", "prosystem", "a78 zip"),
    ("X68000", "x68000", "px68k", "dim xdf hdf zip"),
    ("WonderSwan", "wonderswan ws wsc", "mednafen_wswan", "ws wsc zip"),
    ("Neo Geo CD", "neogeocd", "neocd", "chd cue"),
    ("Fairchild Channel F", "channelf", "freechaf", "chf bin zip"),
    ("ZX Spectrum", "zxspectrum", "fuse", "tzx tap z80 sna zip"),
    ("Game & Watch", "gameandwatch", "gw", "mgw zip"),
    ("Nintendo 3DS", "3ds", "citra", "3ds cci cxi"),
    ("Watara Supervision", "supervision", "potator", "sv zip"),
    ("Sharp X1", "x1", "x1", "2d d88 zip"),
    ("TIC-80", "tic80", "tic80", "tic"),
    ("Thomson TO8", "to8 thomson", "theodore", "k7 fd sap zip"),
    ("Sega Pico", "pico", "picodrive", "md bin zip"),
    ("Mega Duck", "megaduck", "sameduck", "bin zip"),
    ("Arduboy", "arduboy", "arduous", "hex zip"),
    ("WASM-4", "wasm4", "wasm4", "wasm"),
    ("PC Engine CD", "pcenginecd pcecd tgcd", "mednafen_pce_fast mednafen_pce", DISC),
    ("Atari Jaguar CD", "jaguarcd", "virtualjaguar", "cue chd"),
    ("Nintendo DSi", "dsi", "melondsds", "nds dsi zip"),
    ("TI-83", "ti83", "numero", "8xp 8xk"),
    ("Uzebox", "uzebox", "uzem", "uze"),
    ("Famicom Disk System", "fds", "mesen fceumm nestopia", "fds zip"),
]


def any_case(words):
    return "|".join(sorted({v for w in words.split() for v in (w.lower(), w.upper())}))


def parser(name, folders, cores, exts):
    installed = [c for c in cores.split() if os.path.exists(f"{CORES}/{c}_libretro.dylib")]
    core = (installed or cores.split())[0]  # not installed: RetroArch says so on launch; get it in Online Updater
    return {
        "version": 29, "parserType": "Glob", "configTitle": f"{name} - RetroArch",
        "parserId": f"{int(time.time() * 1000)}{random.randrange(100000)}",
        "steamCategories": [], "steamDirectory": "${steamdirglobal}",
        "userAccounts": {"specifiedAccounts": ["Global"]},
        "romDirectory": f"{HOME}/ROMs",
        "parserInputs": {"glob": f"@({any_case(folders)})/**/${{title}}.@({any_case(exts)})"},
        # Steam on macOS launches games as x86_64; arch -arm64 keeps RetroArch native so arm64 cores load.
        # Args stay in launch options (not appended to the target) so the RetroAchievements panel can read them.
        "executable": {"path": "/usr/bin/arch", "shortcutPassthrough": False, "appendArgsToExecutable": False},
        "executableModifier": "\"${exePath}\"",
        "executableArgs": f"-arm64 \"{RETROARCH}\" -L \"{CORES}/{core}_libretro.dylib\" \"${{filePath}}\"",
        "startInDirectory": "", "titleModifier": "${fuzzyTitle}",
        "fuzzyMatch": {"removeCharacters": True, "removeBrackets": True, "replaceDiacritics": True},
        "onlineImageQueries": ["${fuzzyTitle}"], "imagePool": "${fuzzyTitle}",
        "imageProviders": ["sgdb"], "disabled": False, "group": "",
        # SRM's command line doesn't fill schema defaults, so every field it reads must be present.
        **{k: dict.fromkeys(ART) for k in ("defaultImage", "localImages", "overlayImages")},
        "imageProviderAPIs": {"sgdb": {"nsfw": False, "humor": False, "styles": [], "stylesHero": [], "stylesLogo": [],
                                       "stylesIcon": [], "imageMotionTypes": ["static"], "sizes": [], "sizesHero": [], "sizesIcon": []}},
        "titleFromVariable": {"limitToGroups": [], "skipFileIfVariableWasNotFound": False, "caseInsensitiveVariables": False},
        "sortAsFromVariable": {"limitToGroups": []},
        "drmProtect": False, "steamInputEnabled": "1", "controllers": {},
    }


if __name__ == "__main__":
    parsers = [parser(*c) for c in CONSOLES]
    assert len({p["configTitle"] for p in parsers}) == len(parsers)
    with open(OUT, "w") as f:
        json.dump(parsers, f, indent=4)
    print(f"Wrote {len(parsers)} parsers to {OUT}")
