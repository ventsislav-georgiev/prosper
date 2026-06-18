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
/* Install / clear an instruction-count hook (uses LUA_MASKCOUNT). */
void         clua_set_count_hook(lua_State *L, lua_Hook hook, int count);
void         clua_clear_hook(lua_State *L);
/* Push msg and longjmp out of the current protected call (never returns). */
void         clua_raise(lua_State *L, const char *msg);

#endif /* CLUA_SHIM_H */
