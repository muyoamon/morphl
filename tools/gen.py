#!/usr/bin/env python3
# Random well-typed morphl programs for the differential sweep:
#
#   tools/gen.py <dir> <count> [seed]
#
# Each program computes an `Int` from a handful of *shapes* — the constructs that have broken
# before: a closure over locals, local recursion named like an intrinsic, local names for
# intrinsics, a block whose prop reads its receiver, a trait over one, a `$func` template
# reading its frame, a `$union` template, a union taken apart by `$match`, a `$mut` cell,
# higher-order calls, `$try` stripping an error member, a `$defer` whose effect the answer
# reads, a template specialised inside another, and a module importing a module — each placed
# at the top level or inside `main` at random (an `$import` always at the top), and `main`
# answers their sum. A program's modules are written beside it, named after it. Everything stays inside stage 0's subset (BOOTSTRAP.md §1), so stage 0
# answers every program and tools/sweep.sh can compare it with the compiled one. Values stay
# small: `mul` is always taken `mod` a prime, and recursion runs on a fuel parameter.
import os
import random
import sys

out_dir, count = sys.argv[1], int(sys.argv[2])
seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
os.makedirs(out_dir, exist_ok=True)

# Intrinsics a shape may shadow: the expressions below never call these, so a local
# function spelled like one changes nothing but which binding the name means.
SHADOWABLE = ['len', 'byte', 'neg', 'bxor', 'shl', 'concat']


class Gen:
    def __init__(self, rnd, base):
        self.r = rnd
        self.n = 0
        self.base = base
        self.mods = []
        self.imports = []

    def fresh(self, p):
        self.n += 1
        return '%s%d' % (p, self.n)

    # An `Int` expression over the names in `scope`.
    def expr(self, scope, d=0):
        r = self.r
        k = r.randrange(6 if d < 3 else 2)
        if k == 0 or (k == 1 and not scope):
            return str(r.randrange(-9, 30))
        if k == 1:
            return r.choice(scope)
        a, b = self.expr(scope, d + 1), self.expr(scope, d + 1)
        if k == 2:
            return '$call add (%s, %s)' % (a, b)
        if k == 3:
            return '$call sub (%s, %s)' % (a, b)
        if k == 4:
            return '$call mod ($call mul (%s, %s), 997)' % (a, b)
        return '$if ($call lt (%s, %s)) %s %s' % (a, b, self.expr(scope, d + 1),
                                                   self.expr(scope, d + 1))

    # Each shape answers (items, expression): the items bind what the expression reads.
    def closure(self, scope):
        f = self.fresh('f')
        body = self.expr(scope + ['x'])
        return (['$decl %s $func ($decl x 0) %s' % (f, body)],
                '$call %s (%s)' % (f, self.expr(scope)))

    def recursion(self, scope):
        f = self.r.choice(SHADOWABLE + [self.fresh('r')] * 3)
        step = self.expr(scope + ['n', 'acc'])
        return (['$decl %s $func ($decl n 0, $decl acc 0)\n'
                 '    $if ($call lt (n, 1)) acc ($call %s ($call sub (n, 1), '
                 '$call mod (%s, 997)))' % (f, f, step)],
                '$call %s (%d, %s)' % (f, self.r.randrange(0, 40), self.expr(scope)))

    def alias(self, scope):
        a, b = self.fresh('a'), self.fresh('a')
        op = self.r.choice(['add', 'sub'])
        return (['$decl %s %s' % (a, op), '$decl %s %s' % (b, a)],
                '$call %s (%s, $call %s (%s, %s))' % (a, self.expr(scope), b, self.expr(scope),
                                                      self.expr(scope)))

    def props(self, scope):
        b = self.fresh('b')
        k = self.r.randrange(0, 50)
        body = self.expr([b + '.k', 'x'])
        return (['$decl %s { $decl k %d  $prop get $func ($decl x 0) %s }' % (b, k, body)],
                '$call %s.get (%s)' % (b, self.expr(scope)))

    def trait(self, scope):
        b, u = self.fresh('t'), self.fresh('u')
        k = self.r.randrange(0, 50)
        return (['$decl %s { $decl k %d  $prop get $func () %s.k }' % (b, k, b),
                 '$decl %s $func ($decl o $traitsof %s) $call add ($call o.get (), 1)' % (u, b)],
                '$call %s (%s)' % (u, b))

    def tmpl_fn(self, scope):
        t, s = self.fresh('tf'), self.fresh('sf')
        body = self.expr(scope + ['x'])
        return (['$decl %s $template T $func ($decl x T) %s' % (t, body),
                 '$decl %s $specialize %s 0' % (s, t)],
                '$call %s (%s)' % (s, self.expr(scope)))

    def tmpl_union(self, scope):
        t, o = self.fresh('to'), self.fresh('ov')
        return (['$decl %s $template T $union ({ $prop tag "some" $decl v T }, '
                 '{ $prop tag "none" })' % t,
                 '$decl %s $specialize %s (%s)' % (o, t, self.expr(scope))],
                '$match %s ($case {$prop tag "some"} %s.v, $case %s 0)' % (o, o, o))

    def union(self, scope):
        u = self.fresh('un')
        return (['$decl %s $if ($call lt (%s, %s)) { $prop tag "a" $decl v %s } '
                 '{ $prop tag "b" $decl w %s }' % (u, self.expr(scope), self.expr(scope),
                                                   self.expr(scope), self.expr(scope))],
                '$match %s ($case {$prop tag "a"} %s.v, $case {$prop tag "b"} %s.w)' % (u, u, u))

    def cell(self, scope):
        c, s = self.fresh('c'), self.fresh('s')
        return (['$decl %s $mut $alloc %s' % (c, self.expr(scope)),
                 '$decl %s $set %s ($call add ($call ival (%s), %s))'
                 % (s, c, c, self.expr(scope))],
                '$call ival (%s)' % c)

    def higher(self, scope):
        f = self.fresh('h')
        arg = self.r.choice(['neg1', f])
        return (['$decl %s $func ($decl x 0) %s' % (f, self.expr(scope + ['x']))],
                '$call ap1 (%s, %s)' % (arg, self.expr(scope)))

    # §4.15: the error member is stripped at the `$try`, and `main` takes the widened answer
    # apart with an `Int` pattern — a type, which narrows, where a catch-all name would not.
    def try_(self, scope):
        e, w, q = self.fresh('e'), self.fresh('w'), self.fresh('q')
        return (['$decl %s $func ($decl x 0) $if ($call lt (x, %d)) { $prop tag "bad" } '
                 '{ $prop tag "ok" $decl v %s }' % (e, self.r.randrange(-10, 30),
                                                    self.expr(['x'])),
                 '$decl %s $func ($decl x 0) {' % w,
                 '  $decl r   $try ($call %s (x)) { $prop tag "bad" }' % e,
                 '  $decl ret r.v',
                 '}.ret',
                 '$decl %s $call %s (%s)' % (q, w, self.expr(scope))],
                '$match %s ($case {$prop tag "bad"} 7, $case 0 %s)' % (q, q))

    # §4.15a: the deferral runs at the function's scope exit, before the cell is read.
    def defer(self, scope):
        d, k = self.fresh('d'), self.fresh('k')
        return (['$decl %s $mut $alloc %s' % (d, self.expr(scope)),
                 '$decl %s $func () {' % k,
                 '  $defer $set %s ($call add ($call ival (%s), %d))' % (d, d,
                                                                       self.r.randrange(1, 9)),
                 '  $decl ret 1',
                 '}.ret'],
                '{ $decl a $call %s ()  $decl ret2 $call add (a, $call ival (%s)) }.ret2' % (k, d))

    # §4.9: an instance body specialising another template at its own generic's value.
    def tmpl_nest(self, scope):
        b, c, s = self.fresh('tb'), self.fresh('tc'), self.fresh('sp')
        return (['$decl %s $template T { $decl v T  $decl w $call add (v, 1) }' % b,
                 '$decl %s $template U { $decl inner $specialize %s U  '
                 '$decl z $call add (inner.w, U) }' % (c, b),
                 '$decl %s $specialize %s (%s)' % (s, c, self.expr(scope))],
                '%s.z' % s)

    # §4.14: a module importing another, both written beside the program.
    def import_(self, scope):
        m, inner = self.fresh('M'), '%s_n%d' % (self.base, self.n)
        outer = '%s_m%d' % (self.base, self.n)
        c, k = self.r.randrange(2, 9), self.r.randrange(-5, 30)
        self.mods.append((inner, '$decl g $func ($decl y 0) $call mod ($call mul (y, %d), 997)\n' % c))
        self.mods.append((outer, '$decl N $import "%s"\n$decl k %d\n'
                          '$decl f $func ($decl x 0) $call add (x, $call N.g (k))\n' % (inner, k)))
        self.imports.append('$decl %s $import "%s"' % (m, outer))
        return ([], '$call add ($call %s.f (%s), %s.k)' % (m, self.expr(scope), m))

    SHAPES = ['closure', 'recursion', 'alias', 'props', 'trait', 'tmpl_fn', 'tmpl_union',
              'union', 'cell', 'higher', 'try_', 'defer', 'tmpl_nest', 'import_']

    def program(self):
        r = self.r
        top, body, parts = [], [], []
        top_scope, local_scope = [], []
        for i in range(r.randrange(2, 4)):
            v = self.fresh('g')
            top.append('$decl %s %d' % (v, r.randrange(-5, 40)))
            top_scope.append(v)
        for i in range(r.randrange(3, 7)):
            shape = r.choice(self.SHAPES)
            at_top = r.randrange(3) == 0
            scope = top_scope if at_top else top_scope + local_scope
            items, e = getattr(self, shape)(scope)
            if at_top:
                top += items
            else:
                body += items
                if r.randrange(2) == 0:
                    v = self.fresh('l')
                    body.append('$decl %s %s' % (v, self.expr(top_scope + local_scope)))
                    local_scope.append(v)
            parts.append(e)
        total = parts[0]
        for p in parts[1:]:
            total = '$call mod ($call add (%s, %s), 1000003)' % (total, p)
        pre = ['$decl ival $func ($decl x 0) x',
               '$decl neg1 $func ($decl x 0) $call sub (0, x)',
               '$decl ap1 $func ($decl f $func ($decl x 0) 0, $decl x 0) $call f (x)']
        lines = self.imports + pre + top + ['$decl main $func () {'] + ['  ' + b for b in body] + \
            ['  $decl ret %s' % total, '}.ret']
        return '\n'.join(lines) + '\n'


for i in range(count):
    base = 'gen_%d_%d' % (seed, i)
    g = Gen(random.Random(seed * 100003 + i), base)
    text = g.program()
    with open(os.path.join(out_dir, base + '.mpl'), 'w') as f:
        f.write(text)
    for name, mod in g.mods:
        with open(os.path.join(out_dir, name + '.mpl'), 'w') as f:
            f.write(mod)
