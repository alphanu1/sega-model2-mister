#!/usr/bin/env python3
"""Flag variable selects whose index can leave the declared range.

Reads a Verilator --json-only tree (after V3Param/V3Width, so parameters are
per-instance) and, for every user select:
  * ARRAYSEL  (unpacked element)     -- bitp interval vs element count
  * SEL with declRange (packed elem / bit / +: part-select)
                                       -- lsbp interval + width vs from width
computes an interval for the index expression. Verilator-inserted truncations
(SEL without declRange) are passed through, because that truncation IS the
wrap Verilator applies and Quartus does not.
"""
import json, sys, re, collections

tree = json.load(open(sys.argv[1]))
meta = json.load(open(sys.argv[2]))
only = sys.argv[3] if len(sys.argv) > 3 else None
files = {k: v['filename'] for k, v in meta['files'].items()}

nodes = {}
def collect(n):
    if isinstance(n, dict):
        if 'addr' in n:
            nodes[n['addr']] = n
        for v in n.values():
            collect(v)
    elif isinstance(n, list):
        for x in n:
            collect(x)
collect(tree)

def dwidth(a):
    d = nodes.get(a)
    if d is None:
        return None
    t = d['type']
    if t == 'BASICDTYPE':
        r = d.get('range')
        if r:
            hi, lo = map(int, r.split(':'))
            return abs(hi - lo) + 1
        kw = d.get('keyword')
        return {'int': 32, 'integer': 32, 'bit': 1, 'logic': 1, 'byte': 8,
                'shortint': 16, 'longint': 64}.get(kw, 32)
    if t in ('PACKARRAYDTYPE',):
        hi, lo = map(int, d['declRange'].strip('[]').split(':'))
        return (abs(hi - lo) + 1) * dwidth(d['refDTypep'])
    if t in ('REFDTYPE', 'TYPEDEFTYPE', 'CONSTDTYPE', 'ENUMDTYPE'):
        return dwidth(d.get('refDTypep') or d.get('dtypep') if d.get('refDTypep') != a else None)
    if t in ('STRUCTDTYPE', 'UNIONDTYPE'):
        return None
    return None

def ctype(a):
    d = nodes.get(a)
    return d['type'] if d else None

def loc(n):
    l = n.get('loc', '')
    m = re.match(r'(\w+),(\d+):(\d+)', l)
    if not m:
        return '?'
    return f"{files.get(m.group(1), m.group(1))}:{m.group(2)}:{m.group(3)}"

def cval(n):
    s = n['name']
    m = re.match(r"(\d+)'s?([hbdo])([0-9a-fA-FxXzZ_]+)", s)
    if not m:
        try:
            return int(s)
        except Exception:
            return None
    b = {'h': 16, 'b': 2, 'd': 10, 'o': 8}[m.group(2)]
    v = m.group(3).replace('_', '')
    if re.search('[xXzZ]', v):
        return None
    return int(v, b)

def kid(n, k):
    v = n.get(k)
    if isinstance(v, list) and v:
        return v[0]
    return None

import os
SRC = {}
def srcline(fid, ln):
    fn = meta['files'].get(fid, {}).get('realpath') or files.get(fid)
    if fn not in SRC:
        try: SRC[fn] = open(fn, errors='replace').read().split('\n')
        except Exception: SRC[fn] = []
    L = SRC[fn]
    return L[ln-1] if 0 < ln <= len(L) else ''
def lpos(n):
    m = re.match(r'(\w+),(\d+):(\d+)', n.get('loc', ''))
    return (m.group(1), int(m.group(2)), int(m.group(3))) if m else None
def user_sel(n, f):
    # a user part-select sits on a '[' AFTER the thing it selects from
    if f['type'] not in ('VARREF', 'ARRAYSEL', 'SEL', 'STRUCTSEL', 'MEMBERSEL'):
        return False
    a, b = lpos(n), lpos(f)
    if not a or not b: return True
    if (a[1], a[2]) <= (b[1], b[2]): return False
    line = srcline(a[0], a[1])
    return a[2]-1 < len(line) and line[a[2]-1] == '['
def elem_width(dt, level):
    d = nodes.get(dt)
    for _ in range(level):
        while d is not None and d['type'] in ('REFDTYPE',):
            d = nodes.get(d.get('refDTypep'))
        if d is None: return None
        if d['type'] == 'PACKARRAYDTYPE':
            d = nodes.get(d.get('refDTypep'))
        elif d['type'] == 'BASICDTYPE':
            return 1
        else:
            return None
    return dwidth(d['addr']) if d is not None else None
def user_width(n, f):
    a, b = lpos(n), lpos(f)
    if not a or not b or a[1] != b[1]: return None
    line = srcline(a[0], a[1])
    txt = line[a[2]-1:]
    m = re.match(r'\[\s*(\d+)\s*:\s*(\d+)\s*\]', txt)
    if m: return abs(int(m.group(1)) - int(m.group(2))) + 1
    m = re.match(r'\[[^\]]*[+-]:\s*(\d+)\s*\]', txt)
    if m: return int(m.group(1))
    if re.match(r'\[[^\]:]*\]', txt):
        # single index: element width at this bracket level of f's type
        seg = line[b[2]-1:a[2]-1]
        lvl = 1 + seg.count('[') - seg.count(']')   # brackets already crossed, unclosed ones are not ours
        lvl = 1 + sum(1 for _ in re.finditer(r'\[[^\[\]]*\]', seg))
        return elem_width(f.get('dtypep'), 1) if f['type'] != 'VARREF' else elem_width(f.get('dtypep'), lvl)
    return None
# intervals: (lo, hi, tags)
def full(n):
    w = dwidth(n.get('dtypep')) or 32
    return (0, (1 << w) - 1)

LOOPKW = ('integer', 'int', 'genvar')

def ival(n, tags):
    t = n['type']
    if t == 'CONST':
        v = cval(n)
        if v is None:
            return full(n)
        return (v, v)
    if t == 'VARREF':
        var = nodes.get(n.get('varp'))
        if var is not None:
            if var.get('isParam') or var.get('varType') in ('LPARAM', 'GPARAM'):
                vp = kid(var, 'valuep')
                if vp and vp['type'] == 'CONST':
                    return ival(vp, tags)
            if n['name'] in LOOPB:
                tags.add('loop:' + n['name'])
                return LOOPB[n['name']]
            dt = nodes.get(var.get('dtypep'))
            if dt is not None and dt.get('keyword') in LOOPKW:
                tags.add('loopvar:' + n['name'])
            else:
                tags.add('var:' + n['name'])
        return full(n)
    if t == 'SEL':
        f0 = kid(n, 'fromp')
        if n.get('declRange') is None and f0 is not None and not user_sel(n, f0):
            # verilator-inserted truncation: pass through (this is the wrap)
            return ival(f0, tags)
        if n.get('declRange') is None and f0 is not None:
            # a user select Verilator may have FOLDED with a truncation: the
            # width the user wrote, from the source, against the width kept
            uw = user_width(n, f0)
            wc = n.get('widthConst') or 1
            if uw is None or uw > wc:
                tags.add(('trunc:' if uw else 'trunc?:') + f0.get('name', f0['type']) + f'[{uw}->{wc}b]')
                return (0, (1 << (uw if uw else (dwidth(f0.get('dtypep')) or 32))) - 1)
        # user bit/part select of a variable: its value range
        f = kid(n, 'fromp')
        if f is not None and f['type'] == 'VARREF':
            tags.add('var:' + f['name'] + '[..]')
        else:
            ival(f, tags)
        return full(n)
    if t in ('EXTEND', 'EXTENDS', 'CCAST', 'CAST'):
        return ival(kid(n, 'lhsp') or kid(n, 'fromp'), tags)
    if t in ('ADD', 'SUB', 'MUL', 'SHIFTL', 'SHIFTR', 'AND', 'OR', 'XOR', 'MULS', 'SHIFTRS'):
        a = ival(kid(n, 'lhsp'), tags)
        b = ival(kid(n, 'rhsp'), tags)
        w = dwidth(n.get('dtypep')) or 32
        m = (1 << w) - 1
        if t == 'ADD':
            r = (a[0] + b[0], a[1] + b[1])
        elif t == 'SUB':
            r = (a[0] - b[1], a[1] - b[0])
        elif t in ('MUL', 'MULS'):
            r = (a[0] * b[0], a[1] * b[1])
        elif t == 'SHIFTL':
            r = (a[0] << b[0], a[1] << min(b[1], 64))
        elif t in ('SHIFTR', 'SHIFTRS'):
            r = (a[0] >> min(b[1], 64), a[1] >> b[0])
        elif t == 'AND':
            r = (0, min(a[1], b[1]))
        else:
            hi = max(a[1], b[1])
            r = (0, (1 << hi.bit_length()) - 1)
        # self-determined arithmetic wraps at the node's width (both tools)
        if t in ('ADD', 'SUB', 'MUL', 'MULS') and (r[1] > m or r[0] < 0):
            # but keep the negative / overflow visible if node is wide (32b)
            if w >= 32:
                return r
            return (0, m)
        return r
    if t == 'COND':
        a = ival(kid(n, 'thenp'), tags)
        b = ival(kid(n, 'elsep'), tags)
        ival(kid(n, 'condp'), tags)
        return (min(a[0], b[0]), max(a[1], b[1]))
    if t == 'CONCAT':
        a = ival(kid(n, 'lhsp'), tags)
        b = ival(kid(n, 'rhsp'), tags)
        wb = dwidth(kid(n, 'rhsp').get('dtypep')) or 32
        return ((a[0] << wb) + b[0], (a[1] << wb) + b[1])
    if t == 'ARRAYSEL':
        f = kid(n, 'fromp')
        if f is not None and f['type'] == 'VARREF':
            tags.add('mem:' + f['name'] + '[..]')
        return full(n)
    # anything else: full width of the node
    for k in ('lhsp', 'rhsp', 'fromp', 'exprp'):
        c = kid(n, k)
        if c is not None:
            ival(c, tags)
    return full(n)

LOOPB = {}
INIT = {}
CMP = {'GT':'gt','GTS':'gt','GTE':'ge','GTES':'ge','LT':'lt','LTS':'lt','LTE':'le','LTES':'le'}
def loopbound(loop):
    for st in loop.get('stmtsp', []):
        if st.get('type') == 'LOOPTEST':
            c = kid(st, 'condp')
            if c is None or c['type'] not in CMP: return None
            a, b = kid(c, 'lhsp'), kid(c, 'rhsp'); op = CMP[c['type']]
            # normalise to  var OP const
            if a['type'] == 'CONST' and b['type'] == 'VARREF':
                a, b = b, a; op = {'gt':'lt','ge':'le','lt':'gt','le':'ge'}[op]
            if a['type'] != 'VARREF' or b['type'] != 'CONST': return None
            v = cval(b)
            if v is None: return None
            if v >= 1 << 31: v -= 1 << 32
            name = a['name']
            if op == 'lt': return name, (min(INIT.get(name, 0), v-1) if INIT.get(name,0) >= 0 else 0, v - 1)
            if op == 'le': return name, (0, v)
            init = INIT.get(name)
            if init is None: return None
            return name, (v + (1 if op == 'gt' else 0), init)
    return None

def walk(n, mod, out, lval=False):
    if isinstance(n, list):
        for x in n:
            if isinstance(x, dict) and x.get('type') in ('ASSIGN',):
                l, r = kid(x, 'lhsp'), kid(x, 'rhsp')
                if l and r and l['type'] == 'VARREF' and r['type'] == 'CONST':
                    v = cval(r)
                    if v is not None:
                        INIT[l['name']] = v - (1 << 32) if v >= 1 << 31 else v
            walk(x, mod, out, lval)
        return
    if isinstance(n, dict) and n.get('type') == 'LOOP':
        lb = loopbound(n)
        if lb:
            old = LOOPB.get(lb[0]); LOOPB[lb[0]] = lb[1]
            for k, v in n.items():
                if isinstance(v, (list, dict)): walk(v, mod, out)
            if old is None: LOOPB.pop(lb[0])
            else: LOOPB[lb[0]] = old
            return
    if not isinstance(n, dict):
        return
    t = n.get('type')
    if t in ('MODULE', 'PACKAGE'):
        mod = n['name']
    if t == 'ARRAYSEL':
        f = kid(n, 'fromp'); b = kid(n, 'bitp')
        fd = nodes.get(f.get('dtypep')) if f else None
        # strip refdtype
        while fd is not None and fd['type'] in ('REFDTYPE',):
            fd = nodes.get(fd.get('refDTypep'))
        if fd is not None and fd['type'] == 'UNPACKARRAYDTYPE' and b is not None and b['type'] != 'CONST':
            hi, lo = map(int, fd['declRange'].strip('[]').split(':'))
            size = abs(hi - lo) + 1
            tags = set()
            iv = ival(b, tags)
            if iv[1] > size - 1 or iv[0] < 0:
                out.append(('ARRAYSEL', mod, loc(n), f.get('name', f['type']), f"{size} elems",
                            f"idx in [{iv[0]},{iv[1]}]", sorted(tags)))
    if t == 'SEL' and n.get('declRange') is not None:
        f = kid(n, 'fromp'); l = kid(n, 'lsbp')
        if l is not None and l['type'] != 'CONST':
            fw = dwidth(f.get('dtypep')) if f else None
            w = n.get('widthConst') or 1
            tags = set()
            iv = ival(l, tags)
            if fw is not None and (iv[1] + w > fw or iv[0] < 0):
                out.append(('SEL', mod, loc(n), f.get('name', f['type']),
                            f"{fw}b from, {w}b wide, decl {n.get('declRange')} el {n.get('declElWidth')}",
                            f"lsb in [{iv[0]},{iv[1]}]", sorted(tags)))
    for k, v in n.items():
        if k in ('dtypep', 'addr'):
            continue
        if isinstance(v, (list, dict)):
            walk(v, mod, out)

out = []
walk(tree['modulesp'], None, out)
seen = collections.OrderedDict()
for r in out:
    key = (r[0], r[2], r[3], r[4], r[5])
    seen.setdefault(key, (r, set()))[1].add(r[1])
for key, (r, mods) in seen.items():
    if only and only not in r[2]:
        continue
    print(f"{r[2]:42s} {r[0]:8s} {r[3]:22s} {r[4]:40s} {r[5]:28s} {','.join(r[6])}  [{' '.join(sorted(mods))}]")
