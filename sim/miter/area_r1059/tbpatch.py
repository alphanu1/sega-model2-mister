import re,sys
# R1059: tb_i960_top.cpp for the i960_top miter -- the register pokes go to the new AND the old copy.
t=open(sys.argv[1]).read()
NEW='i960_top__DOT__u_new__DOT__'; OLD='i960_top__DOT__u_old__DOT__'
# rf access block
a=t.index('#define RFQ(x)'); b=t.index('uint32_t dreg(int i)')
blk='''#define RFQ(x) dut->rootp->%su_regs__DOT__##x
#define RFQO(x) dut->rootp->%su_regs__DOT__##x
#define RFB(b, c) RFQ(g_bank__BRA__##b##__KET____DOT__u_##c##__DOT__mem)
#define RFBO(b, c) RFQO(g_bank__BRA__##b##__KET____DOT__u_##c##__DOT__mem)
#if MIT_SHARE_O
#define RFBRO(b) RFBO(b, b2)
#elif MIT_GBR_O
#define RFBRO(b) RFQO(g_bank__BRA__##b##__KET____DOT__g_br__DOT__u_br__DOT__mem)
#else
#define RFBRO(b) RFBO(b, br)
#endif
#if MIT_SHARE
#define RFBR(b) RFB(b, b2)
#else
#define RFBR(b) RFQ(g_bank__BRA__##b##__KET____DOT__g_br__DOT__u_br__DOT__mem)
#endif
static IData &rf_cell(int b, int c, int a) {
  switch (b * 3 + c) {
  case 0: return RFB(0, b1)[a];  case 1: return RFB(0, b2)[a];  case 2: return RFBR(0)[a];
  case 3: return RFB(1, b1)[a];  case 4: return RFB(1, b2)[a];  case 5: return RFBR(1)[a];
  case 6: return RFB(2, b1)[a];  case 7: return RFB(2, b2)[a];  case 8: return RFBR(2)[a];
  case 9: return RFB(3, b1)[a];  case 10: return RFB(3, b2)[a]; default: return RFBR(3)[a];
  }
}
static IData &rf_cell_o(int b, int c, int a) {
  switch (b * 3 + c) {
  case 0: return RFBO(0, b1)[a];  case 1: return RFBO(0, b2)[a];  case 2: return RFBRO(0)[a];
  case 3: return RFBO(1, b1)[a];  case 4: return RFBO(1, b2)[a];  case 5: return RFBRO(1)[a];
  case 6: return RFBO(2, b1)[a];  case 7: return RFBO(2, b2)[a];  case 8: return RFBRO(2)[a];
  case 9: return RFBO(3, b1)[a];  case 10: return RFBO(3, b2)[a]; default: return RFBRO(3)[a];
  }
}
''' % (NEW, OLD)
t=t[:a]+blk+t[b:]
t=t.replace('''  for (int c = 0; c < 3; c++) rf_cell(i & 3, c, ((i >> 4) << 2) | ((i >> 2) & 3)) = v;''',
 '''  for (int c = 0; c < 3; c++) rf_cell(i & 3, c, ((i >> 4) << 2) | ((i >> 2) & 3)) = v;
  for (int c = 0; c < 3; c++) rf_cell_o(i & 3, c, ((i >> 4) << 2) | ((i >> 2) & 3)) = v;
  switch (i) { case 0: RFQO(r_pfp) = v; break; case 1: RFQO(r_sp) = v; break;
               case 2: RFQO(r_rip) = v; break; case 31: RFQO(g_fp) = v; break; default: break; }''')
# other pokes: duplicate to the old copy
out=[]; n=0
for l in t.split('\n'):
    m=re.match(r'^(\s*)dut->rootp->'+NEW+r'(\w+(?:\[[^\]]*\])?)\s*=\s*([^=;][^;]*);\s*$',l)
    if m:
        ind,lhs,rhs=m.groups(); n+=1
        out.append(f'{ind}{{ auto _pv = {rhs}; dut->rootp->{NEW}{lhs} = _pv; dut->rootp->{OLD}{lhs} = _pv; }}')
    else: out.append(l)
open(sys.argv[1],'w').write('\n'.join(out))
print('pokes duplicated:',n, file=sys.stderr)
