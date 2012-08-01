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

static OP *
pp_stub_marker (pTHX)
{
  croak("FAIL");
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

  topicalise = SvTRUE(*av_fetch((AV *)SvRV(args), 0, 0));
  if (topicalise) {
    OP *pvarop;

    pvarop = newOP(OP_PADSV, 0);
    pvarop->op_targ = pad_findmy_pvs("$Gather::Once::current_topic", 0);

    if (pvarop->op_targ == NOT_IN_PAD)
      croak("outside topicaliser"); /* FIXME */

    condop = op_append_elem(OP_LIST, condop, pvarop);
  }

  predicate_cv_ref = *av_fetch((AV *)SvRV(args), 1, 0);
  condop = newUNOP(OP_ENTERSUB, OPf_STACKED,
                   op_append_elem(OP_LIST, condop,
                                  newCVREF(0, newSVOP(OP_CONST, 0,
                                                      SvREFCNT_inc(predicate_cv_ref)))));

  OP *stub = newSTATEOP(0, NULL, newOP(OP_NULL, 0));
  condop = newCONDOP(0, condop, blkop, stub);
  condop->op_ppaddr = pp_stub_marker;

  return condop;
}

static OP *
is_take_stmt (pTHX_ OP *stmt)
{
  if (stmt->op_type != OP_LINESEQ
      || !cLISTOPx(stmt)->op_last
      || cLISTOPx(stmt)->op_last->op_type == OP_COND_EXPR)
    return NULL;

  OP *nullop = cLISTOPx(stmt)->op_last;
  if (nullop->op_type != OP_NULL
      || !(nullop->op_flags & OPf_KIDS)
      || !cLISTOPx(nullop)->op_first
      || nullop->op_ppaddr != pp_stub_marker)
    return NULL;

  OP *condop = cLISTOPx(nullop)->op_first;
  if (condop->op_type != OP_COND_EXPR || !(condop->op_flags & OPf_KIDS))
    return NULL;

  return condop;
  OP *stub = condop->op_next; /* falseop */

  return stub;
}

static OP *
myparse_args_gather (pTHX_ GV *namegv, SV *topicalise, U32 *flagsp)
{
  OP *topicaliser, *topblkop, *curblkop, *initop, *assignop;
  int blk_floor;

  PERL_UNUSED_ARG(namegv);
  PERL_UNUSED_ARG(flagsp);

  if (SvTRUE(topicalise)) {
    demand_unichar('(', 0);
    topicaliser = parse_fullexpr(0);
    demand_unichar(')', 0);
  }

  demand_unichar('{', 0);
  blk_floor = Perl_block_start(aTHX_ 1);

  if (SvTRUE(topicalise)) {
    initop = newOP(OP_PADSV, (OPpLVAL_INTRO<<8));
    initop->op_targ = pad_add_my_scalar_pvn("$Gather::Once::current_topic",
                                            sizeof("$Gather::Once::current_topic")-1);

    assignop = newASSIGNOP(0, initop, 0, topicaliser);
  }

  topblkop = curblkop = parse_fullstmt(0);
  lex_read_space(0);
  while (lex_peek_unichar(0) != '}') {
    OP *stub, *stmt = parse_fullstmt(0);

    curblkop = op_append_elem(OP_LINESEQ, curblkop, stmt);

    if ((stub = is_take_stmt(aTHX_ stmt))) {
      curblkop = stub->op_next;
    }

    //op_dump(curblkop);
    lex_read_space(0);
  }

  demand_unichar('}', DEMAND_IMMEDIATE);

  if (SvTRUE(topicalise))
    topblkop = op_prepend_elem(OP_LINESEQ, assignop, topblkop);

  topblkop = op_scope(Perl_block_end(aTHX_ blk_floor, topblkop));

  //return newGIVENOP(SvTRUE(topicalise) ? topicaliser : newOP(OP_NULL, 0),
  //blkop, initop->op_targ);

  return topblkop;
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
