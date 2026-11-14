"""Turns a self-contained reactor's link into a runtime module and a feature
side module.

Usage:
  bazel aquery -c opt 'mnemonic(CppLink, deps(<the reactor's .wasm target>))' \
      --output=jsonproto > link.json
  split_link.py link.json <reactor output name> <feature archive or autolink
      file name>... --out <dir> [--wasm-ld <patched wasm-ld>] [--strip]

Writes, in <dir>:
  link_runtime.sh  the reactor's own link without the feature's archives,
                   exporting what side modules link against: every public
                   symbol (--export-dynamic, nothing dead-stripped), the table
                   (growable), the stack pointer, the allocator and the libc
                   functions features were seen to need; the app's entry
                   (__main_argc_argv) left an import a side module satisfies.
  link_side.sh     the feature's archives as a side module (wasm-ld
                   --experimental-pic -shared -Bsymbolic, the runtime's symbols
                   imported). Swift's relative pointers need wasm-ld with
                   tools/patches/lld_wasm_pic_locrel.patch (--wasm-ld).
Run both from Bazel's execution root (`bazel info execution_root`) after
building the reactor, so the archives exist.
"""
import argparse, json, os, shlex

parser = argparse.ArgumentParser()
parser.add_argument('aquery')
parser.add_argument('reactor')
parser.add_argument('feature', nargs='+', help='archive or autolink file names (basenames) that are the feature')
parser.add_argument('--out', required=True)
parser.add_argument('--wasm-ld', default='wasm-ld')
parser.add_argument('--strip', action='store_true', help='strip names (smaller; the profile tools need them)')
a = parser.parse_args()

actions = json.load(open(a.aquery)).get('actions', [])
args = next(x['arguments'] for x in actions if any(a.reactor in arg for arg in x['arguments']))
feature = tuple(a.feature)

# Libc functions the Storybook's stories call that the runtime itself
# doesn't (and the stack protector's): exported so features find them.
LIBC = ['malloc', 'free', 'aligned_alloc', 'getenv', 'round', 'malloc_usable_size', '__stack_chk_fail', '__stack_chk_guard']

runtime, archives, i = [], [], 0
while i < len(args):
    arg = args[i]
    if os.path.basename(arg).startswith(feature) or os.path.basename(arg.lstrip('@')).startswith(feature):
        if arg.endswith(('.a', '.lo')): archives.append(arg)
        if runtime and runtime[-1] == '-Wl,-whole-archive':
            runtime.pop(); i += 2; continue  # and its -no-whole-archive
        i += 1; continue
    if arg == '-Xlinker' and (args[i + 1] in ('--gc-sections', '--strip-all') or args[i + 1].startswith('--export=')):
        i += 2; continue
    if arg == '-o':
        runtime += ['-Wl,--export-dynamic', '-Wl,--no-gc-sections', '-Wl,--export-table', '-Wl,--growable-table',
                    '-Wl,--export=__stack_pointer', '-Wl,--allow-undefined']
        runtime += [f'-Wl,--export={name}' for name in LIBC]
        runtime += ['-Wl,--strip-all'] if a.strip else []
        runtime += ['-o', os.path.abspath(os.path.join(a.out, 'runtime.wasm'))]
        break
    runtime.append(arg); i += 1

swiftrt = next(x for x in args if x.endswith('/swiftrt.o'))
side = [a.wasm_ld, '--experimental-pic', '-shared', '-Bsymbolic', '--unresolved-symbols=import-dynamic',
        *(['--strip-all'] if a.strip else []),
        '-o', os.path.abspath(os.path.join(a.out, 'side.wasm')),
        '--whole-archive', *archives, '--no-whole-archive', swiftrt, '--export=__main_argc_argv']

os.makedirs(a.out, exist_ok=True)
for name, cmd in (('link_runtime.sh', runtime), ('link_side.sh', side)):
    with open(os.path.join(a.out, name), 'w') as f:
        f.write('#!/bin/sh\n# Run from Bazel\'s execution root.\nset -e\n' + ' '.join(shlex.quote(x) for x in cmd) + '\n')
    os.chmod(os.path.join(a.out, name), 0o755)
print(f'{len(archives)} feature archives; wrote link_runtime.sh and link_side.sh in {a.out}')
