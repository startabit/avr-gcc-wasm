# avr-gcc for the browser

The compiler of the Arduino IDE for the Arduino UNO and Nano, built as WebAssembly, so a sketch compiles in a web page.
The code editor of [startabit.com](https://www.startabit.com/code/) uses it: the program then runs on a simulated
ATmega328P.

## What is in a release

| File | What |
|---|---|
| `cc1plus.mjs`, `cc1plus.wasm.gz` | GNU GCC 7.3.0 with Arduino's `atmel-patches-gcc.7.3.0-arduino2.patch`: C++ to assembly |
| `as`, `ld`, `objcopy` (`.mjs`, `.wasm.gz`) | GNU binutils 2.42: the assembler, the linker, Intel HEX for uploading |
| `sysroot.tar.gz`, `manifest.json` | the headers and libraries they read: GCC's and AVR-LibC's (from Arduino's avr-gcc 7.3.0-atmel3.6.1-arduino7), the Arduino AVR core 1.8.8, and the libraries Wire, SPI, SoftwareSerial, EEPROM, Servo 1.3.0, Adafruit NeoPixel 1.15.5 and HCSR04 2.0.0, precompiled with Arduino's own avr-gcc and the Arduino IDE's flags (without LTO) |
| the source archives | everything above is built from them (checksums in `scripts/SHA256SUMS`) |

Each tool is an ES module whose default export makes one instance (`FS`, `callMain`), as Emscripten builds it.

## How it is built

[.github/workflows/build.yml](.github/workflows/build.yml) on GitHub's Ubuntu 24.04 with Emscripten 4.0.10:
[scripts/build.sh](scripts/build.sh) builds the tools from the GNU sources (the recipe of
[ajeetjain94608/avr-toolchain-wasm](https://github.com/ajeetjain94608/avr-toolchain-wasm)), and
[scripts/sysroot.py](scripts/sysroot.py) packs the sysroot. Every download is checked against `scripts/SHA256SUMS`.

## Licences

GCC and binutils: GNU GPL 3 ([COPYING](COPYING)); programs compiled with them are not covered by it (GCC Runtime
Library Exception). GMP, MPFR and MPC (inside cc1plus): GNU LGPL 3. libgcc: GPL 3 with the Runtime Library Exception,
and AVR-LibC: Modified BSD, both from Arduino's avr-gcc 7.3.0-atmel3.6.1-arduino7 (its source:
[arduino/toolchain-avr](https://github.com/arduino/toolchain-avr/tree/7.3.0-atmel3.6.1-arduino7)). The Arduino AVR
core, Wire, SPI, SoftwareSerial, EEPROM and Servo: GNU LGPL 2.1; Adafruit NeoPixel: GNU LGPL 3; HCSR04: MIT. Each
release has the source archives of all of them.
