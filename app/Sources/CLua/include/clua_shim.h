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

#endif /* CLUA_SHIM_H */
