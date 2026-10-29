#!/usr/bin/env python3
# Move a program's top level into one function body, so every item is frame-local:
#
#   tools/lift.py <in.mpl> <out.mpl>
#
# The program's `main` is called from the new body and a new `main` calls that, so a lifted
# fixture answers what the original does. `$import`s stay at the top level (§4.14 binds a module
# where it stands, and a local one would be a different program), rewritten relative to <out>'s
# directory so the copy can live anywhere. Exits 1, writing nothing, for a file with no
# top-level `$decl main $func`.
#
# The point is the frame: a construct that works at the top level, where a name is a global, can
# fail when the same name is a slot of an enclosing frame — §6a's trampoline, §4.15's `$try` in a
# lifted literal and template views were all found this way (tools/sweep.sh --lift).
import os
import re
import sys

src, out = sys.argv[1], sys.argv[2]
text = open(src).read()
if not re.search(r'^\$decl main \$func', text, re.M):
    sys.exit(1)
src_dir = os.path.dirname(os.path.abspath(src))
out_dir = os.path.dirname(os.path.abspath(out))
imports, rest = [], []
for line in text.splitlines():
    m = re.match(r'^\$decl (\w+)\s+\$import "([^"]+)"', line)
    if m:
        p = m.group(2)
        if not p.startswith('/'):
            p = os.path.relpath(os.path.join(src_dir, p), out_dir)
            p = p if p.startswith('.') else './' + p
        imports.append('$decl %s $import "%s"' % (m.group(1), p))
    else:
        rest.append(line)
with open(out, 'w') as f:
    f.write('\n'.join(imports) + '\n$decl lifted_body $func () {\n' + '\n'.join(rest) +
            '\n  $decl lifted_ret $call main ()\n}.lifted_ret\n'
            '$decl main $func () $call lifted_body ()\n')
