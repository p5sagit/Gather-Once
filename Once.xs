#include "EXTERN.h"
#include "perl.h"
#include "callchecker0.h"
#include "callparser.h"
#include "XSUB.h"

typedef struct payload_St {
  bool topicalise;
  CV *predicate_cv;
} payload_t;

#define SVt_PADNAME SVt_PVMG

#ifndef COP_SEQ_RANGE_LOW_set
# define COP_SEQ_RANGE_LOW_set(sv,val) \
  do { ((XPVNV*)SvANY(sv))->xnv_u.xpad_cop_seq.xlow = val; } while(0)
# define COP_SEQ_RANGE_HIGH_set(sv,val) \
  do { ((XPVNV*)SvANY(sv))->xnv_u.xpad_cop_seq.xhigh = val; } while(0)
#endif /* !COP_SEQ_RANGE_LOW_set */

#ifndef PERL_PADSEQ_INTRO
# define PERL_PADSEQ_INTRO I32_MAX
#endif /* !PERL_PADSEQ_INTRO */

#define pad_add_my_scalar_pvn(namepv, namelen) \
    THX_pad_add_my_scalar_pvn(aTHX_ namepv, namelen)
static PADOFFSET
THX_pad_add_my_scalar_pvn(pTHX_ char const *namepv, STRLEN namelen)
{
  PADOFFSET offset;
  SV *namesv, *myvar;
  myvar = *av_fetch(PL_comppad, AvFILLp(PL_comppad) + 1, 1);
  offset = AvFILLp(PL_comppad);
  SvPADMY_on(myvar);
  PL_curpad = AvARRAY(PL_comppad);
  namesv = newSV_type(SVt_PADNAME);
  sv_setpvn(namesv, namepv, namelen);
  COP_SEQ_RANGE_LOW_set(namesv, PL_cop_seqmax);
  COP_SEQ_RANGE_HIGH_set(namesv, PERL_PADSEQ_INTRO);
  PL_cop_seqmax++;
  av_store(PL_comppad_name, offset, namesv);
  return offset;
}

#define DEMAND_IMMEDIATE 0x00000001
#define DEMAND_NOCONSUME 0x00000002
#define demand_unichar(c, f) THX_demand_unichar(aTHX_ c, f)
static void
THX_demand_unichar (pTHX_ I32 c, U32 flags)
{
  if(!(flags & DEMAND_IMMEDIATE))
    lex_read_space(0);

  if(lex_peek_unichar(0) != c)
    croak("syntax error");

  if(!(flags & DEMAND_NOCONSUME))
    lex_read_unichar(0);
}

#define CXt_MOO 12
#define CXt_KOOH 13

static OP *
pp_entertake (pTHX)
{
  dSP;
  register PERL_CONTEXT *cx;
  const I32 gimme = GIMME_V;

  if ((0 == (PL_op->op_flags & OPf_SPECIAL)) && !SvTRUEx(POPs))
    RETURNOP(cLOGOP->op_other->op_next);

  ENTER;

  PUSHBLOCK(cx, CXt_KOOH, SP);
  cx->blk_givwhen.leave_op = cLOGOP->op_other;

  RETURN;
}

STATIC I32
S_dopoptogather(pTHX_ I32 startingblock)
{
    dVAR;
    I32 i;
    for (i = startingblock; i >= 0; i--) {
  register const PERL_CONTEXT *cx = &cxstack[i];
  switch (CxTYPE(cx)) {
  default:
      continue;
  case CXt_MOO:
      DEBUG_l( Perl_deb(aTHX_ "(dopoptogiven(): found given at cx=%ld)\n", (long)i));
      return i;

  case CXt_LOOP_PLAIN:
      assert(!CxFOREACHDEF(cx));
      break;
  case CXt_LOOP_LAZYIV:
  case CXt_LOOP_LAZYSV:
  case CXt_LOOP_FOR:/* FIXME */
      if (CxFOREACHDEF(cx)) {
    DEBUG_l( Perl_deb(aTHX_ "(dopoptogiven(): found foreach at cx=%ld)\n", (long)i));
    return i;
      }
  }
    }
    return i;
}

static OP *
pp_leavetake (pTHX)
{
  dSP;
  I32 cxix;
  register PERL_CONTEXT *cx;
  I32 gimme;
  SV **newsp;
  PMOP *newpm;

  cxix = S_dopoptogather(aTHX_ cxstack_ix);
  if (cxix < 0)
  /* diag_listed_as: Can't "when" outside a topicalizer */
  DIE(aTHX_ "Can't \"%s\" outside a topicalizer",
      PL_op->op_flags & OPf_SPECIAL ? "default" : "when");

  POPBLOCK(cx,newpm);
  assert(CxTYPE(cx) == CXt_KOOH);

  LEAVE;

  if (cxix < cxstack_ix)
    dounwind(cxix);

  cx = &cxstack[cxix];

  RETURNOP(cx->blk_givwhen.leave_op);
}

static OP *
myparse_args_take (pTHX_ GV *namegv, SV *args, U32 *flagsp)
{
  OP *condop, *blkop, *leaveop;
  LOGOP *enterop;
  SV *predicate_cv_ref;
  int blk_floor;
  bool topicalise;

  PERL_UNUSED_ARG(namegv);
  PERL_UNUSED_ARG(flagsp);

  demand_unichar('(', 0);
  condop = parse_fullexpr(0);
  demand_unichar(')', 0);

  demand_unichar('{', DEMAND_NOCONSUME);
  blk_floor = Perl_block_start(aTHX_ 1);
  blkop = parse_block(0);
  blkop = Perl_block_end(aTHX_ blk_floor, blkop);

  NewOp(1101, enterop, 1, LOGOP);
  enterop->op_type = OP_ENTERWHEN;
  enterop->op_ppaddr = pp_entertake;
  enterop->op_flags = OPf_KIDS;
  enterop->op_targ = -1;
  enterop->op_private = 0;

  leaveop = newUNOP(OP_LEAVEWHEN, 0, (OP *)enterop);
  leaveop->op_ppaddr = pp_leavetake;

  topicalise = SvTRUE(*av_fetch((AV *)SvRV(args), 0, 0));
  if (topicalise) {
    OP *pvarop;

    pvarop = newOP(OP_PADSV, 0);
    pvarop->op_targ = pad_findmy("$Gather::Once::current_topic",
                                 sizeof("$Gather::Once::current_topic")-1, 0);

    if (pvarop->op_targ == NOT_IN_PAD)
      croak("outside topicaliser"); /* FIXME */

    condop = op_append_elem(OP_LIST, condop, pvarop);
  }

  predicate_cv_ref = *av_fetch((AV *)SvRV(args), 1, 0);
  condop = newUNOP(OP_ENTERSUB, OPf_STACKED,
                   op_append_elem(OP_LIST, condop,
                                  newCVREF(0, newSVOP(OP_CONST, 0,
                                                      predicate_cv_ref))));

  enterop->op_first = condop;
  enterop->op_first->op_sibling = op_scope(blkop);
  leaveop->op_next = LINKLIST(enterop->op_first);
  enterop->op_first->op_next = (OP *)enterop;

  enterop->op_next = LINKLIST(enterop->op_first->op_sibling);
  enterop->op_first->op_sibling->op_next = enterop->op_other = leaveop;

  return leaveop;
}

static OP *
pp_entergather (pTHX)
{
  dSP; dTARGET;
  register PERL_CONTEXT *cx;
  const I32 gimme = GIMME_V;

  ENTER;
  if (PL_op->op_targ != NOT_IN_PAD)
    sv_setsv(TARG, POPs);

  PUSHBLOCK(cx, CXt_MOO, SP);
  cx->blk_givwhen.leave_op = cLOGOP->op_other;

  RETURN;
}

static OP *
pp_leavegather (pTHX)
{
  dSP;
  register PERL_CONTEXT *cx;
  I32 gimme;
  SV **newsp;
  PMOP *newpm;

  POPBLOCK(cx,newpm);
  assert(CxTYPE(cx) == CXt_MOO);

  //SP = adjust_stack_on_leave(newsp, SP, newsp, gimme, SVs_PADTMP|SVs_TEMP);
  //PL_curpm = newpm; /* Don't pop $1 et al till now */

  LEAVE;
  RETURN;
}

static OP *
myparse_args_gather (pTHX_ GV *namegv, SV *topicalise, U32 *flagsp)
{
  OP *topicaliser, *blkop, *initop = NULL;
  int blk_floor;

  PERL_UNUSED_ARG(namegv);
  PERL_UNUSED_ARG(flagsp);

  if (SvTRUE(topicalise)) {
    demand_unichar('(', 0);
    topicaliser = parse_fullexpr(0);
    demand_unichar(')', 0);
  }

  demand_unichar('{', DEMAND_NOCONSUME);
  blk_floor = Perl_block_start(aTHX_ 1);
  if (SvTRUE(topicalise)) {
    initop = newOP(OP_PADSV, (OPpLVAL_INTRO<<8));
    initop->op_targ = pad_add_my_scalar_pvn("$Gather::Once::current_topic",
                                            sizeof("$Gather::Once::current_topic")-1);
  }

  blkop = parse_block(0);
  if (initop)
    blkop = op_prepend_elem(OP_LINESEQ, initop, blkop);

  blkop = Perl_block_end(aTHX_ blk_floor, blkop);

  LOGOP *enterop;
  NewOp(1101, enterop, 1, LOGOP);
  enterop->op_type = OP_ENTERGIVEN;
  enterop->op_ppaddr = pp_entergather;
  enterop->op_flags = OPf_KIDS;
  enterop->op_targ = SvTRUE(topicalise) ? initop->op_targ : NOT_IN_PAD;
  enterop->op_private = 0;

  OP *leaveop;
  leaveop = newUNOP(OP_LEAVEGIVEN, 0, (OP *)enterop);
  leaveop->op_ppaddr = pp_leavegather;

  enterop->op_first = SvTRUE(topicalise) ? topicaliser : newOP(OP_NULL, 0);
  enterop->op_first->op_sibling = op_scope(blkop);
  leaveop->op_next = LINKLIST(enterop->op_first);
  enterop->op_first->op_next = (OP *)enterop;

  enterop->op_next = LINKLIST(enterop->op_first->op_sibling);
  enterop->op_first->op_sibling->op_next = enterop->op_other = leaveop;

  return leaveop;
}

static OP *
myck_gathertake (pTHX_ OP *entersubop, GV *namegv, SV *ckobj)
{
  OP *rv2cvop, *pushop, *blkop;

  PERL_UNUSED_ARG(namegv);
  PERL_UNUSED_ARG(ckobj);

  pushop = cUNOPx(entersubop)->op_first;
  if (!pushop->op_sibling)
    pushop = cUNOPx(pushop)->op_first;

  blkop = pushop->op_sibling;

  rv2cvop = blkop->op_sibling;
  blkop->op_sibling = NULL;
  pushop->op_sibling = rv2cvop;
  op_free(entersubop);

  return blkop;
}

MODULE = Gather::Once  PACKAGE = Gather::Once

void
setup_gather_hook (CV *gather_cv, SV *topicalise)
  CODE:
    cv_set_call_parser(gather_cv, myparse_args_gather, topicalise);
    cv_set_call_checker(gather_cv, myck_gathertake, &PL_sv_undef);

void
setup_take_hook (CV *take_cv, SV *args)
  CODE:
    cv_set_call_parser(take_cv, myparse_args_take, args);
    cv_set_call_checker(take_cv, myck_gathertake, &PL_sv_undef);
