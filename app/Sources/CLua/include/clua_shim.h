#ifndef CLUA_SHIM_H
#define CLUA_SHIM_H

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/*
 * Non-macro wrappers around the parts of the Lua 5.4 C API that ship as
 * preprocessor macros (lua_pcall, lua_pop, lua_pushcfunction, lua_upvalueindex,
 * the LUA_MASK* hook constants, …). Swift's C importer does not surface
 * function-like macros, so the Lua runtime wrapper calls these instead.
 * See docs/ADR-002-extensibility.md.
 */

/* lua_pcall(L,n,r,m) -> lua_pcallk(L,n,r,m,0,NULL) */
int          clua_pcall(lua_State *L, int nargs, int nresults, int msgh);
/* lua_pop(L,n) -> lua_settop(L,-(n)-1) */
void         clua_pop(lua_State *L, int n);
/* lua_pushcfunction(L,f) -> lua_pushcclosure(L,f,0) */
void         clua_pushcfunction(lua_State *L, lua_CFunction f);
/* lua_tostring(L,i) -> lua_tolstring(L,i,NULL) */
const char  *clua_tostring(lua_State *L, int idx);
/* lua_isfunction / lua_isnil predicates (return 1/0) */
int          clua_isfunction(lua_State *L, int idx);
int          clua_isnil(lua_State *L, int idx);
/* lua_upvalueindex(i) — pseudo-index for the i-th C-closure upvalue. */
int          clua_upvalueindex(int i);
/* #1126: arm the per-call instruction budget on the main thread before a host call (a count below 1
** is taken as 1), disarm it after; disarm returns 1 if the budget is spent. #1154: arm returns 1 when it armed, 0 when
** a budget is already armed (a call from inside a host call runs on it); disarm removes the hook only when 'armed'. */
int          clua_budget_arm(lua_State *L, int count);
int          clua_budget_disarm(lua_State *L, int armed);
/* #1126: the sandbox's setmetatable (refuses a metatable with __gc) and collectgarbage (count and
** isrunning only; every other option does nothing and returns 0). */
int          clua_sandbox_setmetatable(lua_State *L);
int          clua_sandbox_collectgarbage(lua_State *L);

/* #1127: the per-runtime memory cap. A counting lua_Alloc over realloc/free; growth past 'cap' is refused (NULL,
** which Lua turns into "not enough memory" for that call) only while 'enforce' is set. Touch it only on the thread
** that runs the state. */
typedef struct clua_mem {
    size_t used;    /* bytes in live blocks */
    size_t peak;    /* highest 'used' so far */
    size_t cap;     /* growth past this is refused while 'enforce' is set */
    int    enforce; /* set by the host around protected calls only */
    int    refused; /* a growth was refused since the last clua_mem_settle */
    size_t work;      /* #1145: library work charged in the armed call, in units (clua_work) */
    size_t worklimit; /* #1145: units the armed call may charge; 0 when no budget is armed */
    lua_State *main;  /* the state's main thread, for the allocator's charge */
} clua_mem;
void        *clua_mem_alloc(void *ud, void *ptr, size_t osize, size_t nsize);
/* lua_newstate with clua_mem_alloc and a fresh counter (cap not enforced); NULL if out of memory. */
lua_State   *clua_newstate(size_t cap);
/* lua_close, then free the counter. */
void         clua_close(lua_State *L);
clua_mem    *clua_mem_of(lua_State *L);
/* Set or clear enforcement; returns the previous setting. */
int          clua_mem_enforce(lua_State *L, int on);
/* After a call: if a growth was refused, collect fully so the refused call's garbage is gone. */
void         clua_mem_settle(lua_State *L);
/* Pops two upvalues for f (pushed by the caller) and pushes a closure that runs f with the cap off and fails
** with "not enough memory" after f returns if the runtime is then over its cap. f reads upvalues 1 and 2. */
void         clua_pushhostfunction(lua_State *L, lua_CFunction f);
/* #1145: work a library C function does inside one instruction, charged in units against a limit of
** budget * CLUA_WORK_PER_INSTRUCTION, armed and cleared with the budget (one per outermost call, every thread).
** One unit is about 1 ns of that work at -O2 on an Apple M4 Pro (measured per site, 0.3-1.5 ns), so a full default
** budget (10M) of library work ends in about 0.5 s and the event-tap budget (500k) in about 25 ms. Weights cover the
** slow case of a site (an element reached through a C metamethod, a quoted control byte), not the common one.
** Weights are units per step; *_BYTES are bytes per unit; *_MIN is the size below which nothing is charged (the
** instruction that does it is counted already). */
#define CLUA_WORK_PER_INSTRUCTION 50
#define CLUA_WORK_MATCH           8     /* one entry into the pattern matcher */
#define CLUA_WORK_SCAN            2     /* one subject character tried by a repetition */
#define CLUA_WORK_CLASS_BYTES     2     /* bytes of a [set] class per unit, per character tested */
#define CLUA_WORK_FIND_BYTES      16    /* bytes of a plain find's needle per unit, per candidate position */
#define CLUA_WORK_REP             2     /* one copy made by string.rep */
#define CLUA_WORK_QUOTE           40    /* one byte quoted by string.format %q */
#define CLUA_WORK_ELEMENT         48    /* one element moved by table.insert/remove/move or joined by concat */
#define CLUA_WORK_COMPARE         24    /* one table.sort comparison */
#define CLUA_WORK_STRING_BYTES    16    /* bytes of a long-string comparison per unit (lvm.c) */
#define CLUA_WORK_STRING_MIN      4096
#define CLUA_WORK_ALLOC_BYTES     64    /* bytes of an allocation per unit (clua_mem_alloc) */
#define CLUA_WORK_ALLOC_MIN       4096
/* #1166 (same unit; the measured ns per step in parentheses) */
#define CLUA_WORK_BYTE            1     /* one byte decoded by utf8.len (0.9-1.1) or hashed as a long-string key (1.2) */
#define CLUA_WORK_SKIP_BYTES      2     /* bytes per unit walked by utf8.offset/codes (0.25-0.3) or by upper, lower,
                                           reverse (0.34-0.38) */
#define CLUA_WORK_ADDCHAR         2     /* one byte of string.format literal text (1.9) or string.pack padding (2.1) */
#define CLUA_WORK_NUMERAL         3     /* one byte of a string read as a number (1.0-2.7, strtod the slow case) */
#define CLUA_WORK_OPTION          5     /* one string.pack/packsize/unpack option (2.3-4.3) */
#define CLUA_WORK_VALUE           5     /* one value of string.byte/char or one byte of utf8.codepoint (2.1-5.0) */
#define CLUA_WORK_UTF8_CHAR       32    /* one argument of utf8.char (29-31) */
/* Charge count * weight units (saturating). Raises "execution budget exceeded" when the armed limit is passed and
** leaves the budget spent; does nothing when no budget is armed or the cap is off (state setup, host functions). */
void         clua_work(lua_State *L, size_t count, size_t weight);
/* #1166: the same charge where no lua_State is at hand (ltable.c), against the state whose Lua runs on this OS thread.
** It never raises: over the limit the budget is spent, so the next instruction of any thread raises. */
void         clua_work_nostate(size_t count, size_t weight);
/* Two strings of la and lb bytes compared by one instruction (lvm.c). */
#define CLUA_WORK_STRINGS(L, la, lb) do { size_t clua_l_ = (la) < (lb) ? (la) : (lb); \
    if (clua_l_ >= CLUA_WORK_STRING_MIN) clua_work((L), clua_l_ / CLUA_WORK_STRING_BYTES, 1); } while (0)

/* R1127-3: lua_getglobal / lua_setglobal, raw (no metamethod of the globals table runs). */
int          clua_rawgetglobal(lua_State *L, const char *name);
void         clua_rawsetglobal(lua_State *L, const char *name);

#endif /* CLUA_SHIM_H */
