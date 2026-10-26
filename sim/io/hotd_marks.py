# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R960: The House of the Dead's GUN MARK CHECK marks (sim/io/mame_m2_hotd_marks.lua
# snapshots): the centre of each player's ring (P1 red / orange, P2 blue),
# outside the screen's text, per snapshot against the coordinates forced then.
# usage: python3 -I hotd_marks.py <snapdir> <file holding the TS_GUNAT string>
import sys, os
from PIL import Image
snapdir, gunat = sys.argv[1], sys.argv[2]
pts=[]
for item in open(gunat).read().strip().strip(';').split(';'):
    t, vals = item.split('='); pts.append((float(t), [int(x,16) for x in vals.split(',')]))
boxes=[(170,40,316,60),(75,75,390,140),(145,345,356,365)]
def inbox(x,y): return any(a<=x<=c and b<=y<=d for a,b,c,d in boxes)
for f in sorted(f for f in os.listdir(snapdir) if f.endswith('.png')):
    t=float(f[1:-4]); v=None
    for tt,vv in pts:
        if t>=tt: v=vv
    if v is None: continue
    im=Image.open(os.path.join(snapdir,f)).convert('RGB'); px=im.load()
    for who,cond in (('P2',lambda r,g,b: b>=200 and r<=120),('P1',lambda r,g,b: r>=200 and b<=120)):
        l=[(x,y) for y in range(384) for x in range(496) if not inbox(x,y) and cond(*px[x,y])]
        if not l: print(f,who,'X=%d Y=%d'%(v[0],v[1]) if who=='P1' else 'X=%d Y=%d'%(v[2],v[3]),'none'); continue
        xs=[p[0] for p in l]; ys=[p[1] for p in l]
        print(f,who,'X=%d Y=%d'%((v[0],v[1]) if who=='P1' else (v[2],v[3])),'mark %.1f %.1f bbox %d-%d %d-%d n=%d'%((min(xs)+max(xs))/2,(min(ys)+max(ys))/2,min(xs),max(xs),min(ys),max(ys),len(l)))
