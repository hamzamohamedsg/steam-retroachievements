# Third-party notices

## rcheevos

`Vendor/rcheevos/` is copied from https://github.com/RetroAchievements/rcheevos at tag v12.5.0. It's MIT licensed; the full license text is in `Vendor/rcheevos/LICENSE`.

## libchdr

`Vendor/libchdr/` is copied from https://github.com/rtissera/libchdr at commit 47d7941 (without its build files, tests and the optional micro-flac backend). It reads `.chd` disc images and is BSD-3-Clause licensed; the license text is in `Vendor/libchdr/LICENSE.txt`. It bundles:

- LZMA SDK's `LzmaDec` (public domain; `Vendor/libchdr/deps/lzma-26.02/LICENSE`)
- miniz 3.1.2 (MIT; the license is at the top of `Vendor/libchdr/deps/miniz-3.1.2/miniz.c`)
- zstd 1.5.7's single-file decoder (BSD-3-Clause or GPLv2, used under BSD-3-Clause; the license is at the top of `Vendor/libchdr/deps/zstd-1.5.7/zstddeclib.c`)
- dr_flac (public domain or MIT-0; the license is at the bottom of `Vendor/libchdr/include/dr_libs/dr_flac.h`)

`Vendor/libchdr/include/libchdr/chdr.h` is the only file added: an umbrella header for SwiftPM.

## LZMA SDK

`Vendor/lzma-sdk-26.06/C/` holds the 7z decoder files from 7-Zip 26.06's source (https://github.com/ip7z/7zip, release 26.06). They read `.7z` archives and are placed in the public domain by Igor Pavlov, as each file's header states. Only the decoder files are copied.

## achievement-companion

The Steam panel's colour palette (`steam/inject.js`) follows `frontend/styles/panelCss.ts` from https://github.com/otowm/achievement-companion. The project's README states it is MIT licensed. The repository has no LICENSE file, so the README is the source of that statement. No code was copied; only colour values were reused.
