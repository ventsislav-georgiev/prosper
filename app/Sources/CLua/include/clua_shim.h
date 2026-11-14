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
** is taken as 1), disarm it after; disarm returns 1 if the budget was spent during the call. */
void         clua_budget_arm(lua_State *L, int count);
int          clua_budget_disarm(lua_State *L);
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
/* R1127-3: lua_getglobal / lua_setglobal, raw (no metamethod of the globals table runs). */
int          clua_rawgetglobal(lua_State *L, const char *name);
void         clua_rawsetglobal(lua_State *L, const char *name);

#endif /* CLUA_SHIM_H */
