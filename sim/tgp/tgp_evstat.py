import sys, struct, collections, gzip
p = sys.argv[1]
d = (gzip.open if p.endswith('.gz') else open)(p, 'rb').read()
n = len(d)//9
tot = collections.Counter(); per = []; cur = collections.Counter()
rkind = collections.Counter(); wkind = collections.Counter()
prev = None; stall_after_r = 0
for i in range(n):
    t, a, b = struct.unpack_from('<BII', d, i*9)
    c = chr(t)
    if c == 'F':
        if cur: per.append(cur)
        cur = collections.Counter(); continue
    cur[c] += 1; tot[c] += 1
    if c in 'RW':
        on = a >> 24; bk = (a >> 16) & 0xff; off = a & 0xffff
        if not on: k = 'math' if 0x20 <= off <= 0x2b else ('lo%02x' % off if off < 0x20 else 'other')
        else:
            adr = (bk << 16) | off
            k = 'rom' if adr & 0x800000 else ('buf' if adr & 0x400000 else 'zero')
        (rkind if c == 'R' else wkind)[k] += 1
    if c == 'S' and prev == 'R': stall_after_r += 1
    prev = c
if cur: per.append(cur)
print('records', n, 'totals', dict(tot))
print('io reads by target', dict(rkind)); print('io writes by target', dict(wkind))
print('stall immediately after io read:', stall_after_r)
for i, f in enumerate(per[:40]): print(i, dict(f))
