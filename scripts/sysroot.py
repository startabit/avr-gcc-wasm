"""Packs everything the compiler in the browser reads into dist/sysroot.tar, with dist/manifest.json:
  sysroot/...       GCC's and AVR-LibC's headers and the ATmega328P libraries, from Arduino's avr-gcc 7.3.0-atmel3.6.1-arduino7,
                    in the layout the WebAssembly tools were configured for (--prefix=/sysroot), with binutils' linker scripts
  arduino/core/...  the Arduino AVR core's headers and the board's pins_arduino.h; arduino/core.a, the core precompiled
  arduino/libraries/<Name>/...  each library's headers, and arduino/libraries/<Name>.a, the library precompiled
The core and the libraries are compiled here with Arduino's own native avr-gcc and the Arduino IDE's flags (no LTO,
which the WebAssembly tools have not got), so a sketch links against the same code as in the IDE.
  python3 scripts/sysroot.py <work dir> <out dir of build.sh> <dist dir>
"""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

WORK, OUT, DIST = (os.path.abspath(p) for p in sys.argv[1:4])
SUMS = dict(reversed(line.split()) for line in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'SHA256SUMS')) if line.strip())

TOOLCHAIN = ('avr-gcc', '7.3.0-atmel3.6.1-arduino7', 'https://downloads.arduino.cc/tools/avr-gcc-7.3.0-atmel3.6.1-arduino7-x86_64-pc-linux-gnu.tar.bz2')
CORE = ('Arduino AVR core', '1.8.8', 'https://downloads.arduino.cc/cores/staging/avr-1.8.8.tar.bz2')
# name, version, address, the folder (in the archive) with the library's code
LIBRARIES = [
    ('Wire', '1.8.8', None, 'libraries/Wire/src'),
    ('SPI', '1.8.8', None, 'libraries/SPI/src'),
    ('SoftwareSerial', '1.8.8', None, 'libraries/SoftwareSerial/src'),
    ('EEPROM', '1.8.8', None, 'libraries/EEPROM/src'),
    ('Servo', '1.3.0', 'https://codeload.github.com/arduino-libraries/Servo/tar.gz/refs/tags/1.3.0', 'src'),
    ('Adafruit_NeoPixel', '1.15.5', 'https://codeload.github.com/adafruit/Adafruit_NeoPixel/tar.gz/refs/tags/1.15.5', ''),
    ('HCSR04', '2.0.0', 'https://codeload.github.com/Martinsos/arduino-lib-hc-sr04/tar.gz/refs/tags/2.0.0', 'src'),
]
FILE_NAMES = {'Servo': 'Servo-1.3.0.tar.gz', 'Adafruit_NeoPixel': 'Adafruit_NeoPixel-1.15.5.tar.gz', 'HCSR04': 'arduino-lib-hc-sr04-2.0.0.tar.gz'}

BOARD = ['-mmcu=atmega328p', '-DF_CPU=16000000L', '-DARDUINO=10819', '-DARDUINO_AVR_UNO', '-DARDUINO_ARCH_AVR']
C_FLAGS = ['-c', '-Os', '-w', '-std=gnu11', '-ffunction-sections', '-fdata-sections']
CPP_FLAGS = ['-c', '-Os', '-w', '-std=gnu++11', '-fpermissive', '-fno-exceptions', '-ffunction-sections', '-fdata-sections',
             '-fno-threadsafe-statics', '-Wno-error=narrowing']
S_FLAGS = ['-c', '-x', 'assembler-with-cpp']


def fetch(url, name):
    path = os.path.join(WORK, 'src', name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path):
        with urllib.request.urlopen(url) as r, open(path, 'wb') as f:
            shutil.copyfileobj(r, f)
    digest = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    if SUMS.get(name) != digest:
        sys.exit('CHECKSUM MISMATCH or unknown file: %s (%s)' % (name, digest))
    return path


def unpack(path, into):
    if not os.path.isdir(into):
        with tarfile.open(path) as t:
            t.extractall(into, filter='data')
    top = [os.path.join(into, d) for d in os.listdir(into)]
    return top[0] if len(top) == 1 and os.path.isdir(top[0]) else into


toolchain = unpack(fetch(TOOLCHAIN[2], os.path.basename(TOOLCHAIN[2])), os.path.join(WORK, 'toolchain'))
core = unpack(fetch(CORE[2], os.path.basename(CORE[2])), os.path.join(WORK, 'core'))
bin_ = lambda name: os.path.join(toolchain, 'bin', 'avr-' + name)
CORE_INCLUDES = ['-I' + os.path.join(core, 'cores', 'arduino'), '-I' + os.path.join(core, 'variants', 'standard')]


def compile_all(folder, includes, archive):
    objects = []
    build = os.path.join(WORK, 'objects', os.path.basename(archive)[:-2])
    os.makedirs(build, exist_ok=True)
    for root, _, names in sorted(os.walk(folder)):
        if os.sep + 'examples' in root or os.sep + 'extras' in root:
            continue
        for name in sorted(names):
            ext = os.path.splitext(name)[1]
            flags = {'.c': C_FLAGS, '.cpp': CPP_FLAGS, '.S': S_FLAGS}.get(ext)
            if not flags:
                continue
            obj = os.path.join(build, os.path.relpath(os.path.join(root, name), folder).replace(os.sep, '_') + '.o')
            tool = bin_('g++') if ext == '.cpp' else bin_('gcc')
            subprocess.run([tool, *flags, *BOARD, *includes, os.path.join(root, name), '-o', obj], check=True)
            objects.append(obj)
    if objects:
        if os.path.exists(archive):
            os.remove(archive)
        subprocess.run([bin_('ar'), 'rcs', archive, *objects], check=True)
    return len(objects)


files = {}


def add_tree(root, prefix, keep=lambda rel: True):
    for folder, _, names in os.walk(root):
        for name in names:
            path = os.path.join(folder, name)
            rel = os.path.relpath(path, root).replace(os.sep, '/')
            if keep(rel):
                files[prefix + '/' + rel] = open(path, 'rb').read()


def header(rel):
    return rel.endswith('.h') or '.' not in rel.split('/')[-1]


uno_only = lambda rel: not re.match(r'^avr/include/avr/io[a-z0-9]+\.h$', rel) or rel.endswith(('/io.h', '/iom328p.h'))
add_tree(os.path.join(toolchain, 'lib', 'gcc', 'avr', '7.3.0', 'include'), 'sysroot/lib/gcc/avr/7.3.0/include')
add_tree(os.path.join(toolchain, 'lib', 'gcc', 'avr', '7.3.0', 'include-fixed'), 'sysroot/lib/gcc/avr/7.3.0/include-fixed')
add_tree(os.path.join(toolchain, 'avr', 'include'), 'sysroot/avr/include', lambda rel: uno_only('avr/include/' + rel))
for rel in ['lib/gcc/avr/7.3.0/avr5/libgcc.a', 'avr/lib/avr5/crtatmega328p.o', 'avr/lib/avr5/libc.a', 'avr/lib/avr5/libm.a', 'avr/lib/avr5/libatmega328p.a']:
    files['sysroot/' + rel] = open(os.path.join(toolchain, rel), 'rb').read()
add_tree(os.path.join(OUT, 'ldscripts'), 'sysroot/avr/lib/ldscripts')

# the core
add_tree(os.path.join(core, 'cores', 'arduino'), 'arduino/core', header)
add_tree(os.path.join(core, 'variants', 'standard'), 'arduino/variant', header)
archive = os.path.join(WORK, 'core.a')
count = compile_all(os.path.join(core, 'cores', 'arduino'), CORE_INCLUDES, archive)
files['arduino/core.a'] = open(archive, 'rb').read()
manifest = {'toolchain': TOOLCHAIN[1], 'core': CORE[1], 'coreObjects': count, 'libraries': {}}

# the libraries
roots = {}
for name, version, url, sub in LIBRARIES:
    base = core if url is None else unpack(fetch(url, FILE_NAMES[name]), os.path.join(WORK, 'lib-' + name))
    roots[name] = os.path.join(base, sub) if sub else base
for name, version, url, sub in LIBRARIES:
    root = roots[name]
    includes = CORE_INCLUDES + ['-I' + r for r in roots.values()] + ['-I' + os.path.join(roots['Wire'], 'utility')]
    archive = os.path.join(WORK, name + '.a')
    count = compile_all(root, includes, archive)
    add_tree(root, 'arduino/libraries/' + name, lambda rel: rel.endswith('.h') and not rel.startswith(('examples/', 'extras/')))
    if count:
        files['arduino/libraries/' + name + '.a'] = open(archive, 'rb').read()
    tops = sorted(n for n in os.listdir(root) if n.endswith('.h'))
    manifest['libraries'][name] = {'version': version, 'headers': tops, 'archive': count > 0}

os.makedirs(DIST, exist_ok=True)
data = io.BytesIO()
with tarfile.open(fileobj=data, mode='w', format=tarfile.USTAR_FORMAT) as t:
    for path in sorted(files):
        info = tarfile.TarInfo(path)
        info.size = len(files[path])
        info.mode = 0o644
        t.addfile(info, io.BytesIO(files[path]))
open(os.path.join(DIST, 'sysroot.tar'), 'wb').write(data.getvalue())
json.dump(manifest, open(os.path.join(DIST, 'manifest.json'), 'w'), indent=1)
print('sysroot.tar: %d files, %.2f MB' % (len(files), len(data.getvalue()) / 1e6))
print(json.dumps(manifest, indent=1))
