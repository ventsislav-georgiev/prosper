#include <string.h>
#include "clua_shim.h"
#include "lstate.h"  /* #1126: L->allowhook */

int clua_pcall(lua_State *L, int nargs, int nresults, int msgh) {
    return lua_pcall(L, nargs, nresults, msgh);
}

void clua_pop(lua_State *L, int n) {
    lua_pop(L, n);
}

void clua_pushcfunction(lua_State *L, lua_CFunction f) {
    lua_pushcfunction(L, f);
}

const char *clua_tostring(lua_State *L, int idx) {
    return lua_tostring(L, idx);
}

int clua_isfunction(lua_State *L, int idx) {
    return lua_isfunction(L, idx);
}

int clua_isnil(lua_State *L, int idx) {
    return lua_isnil(L, idx);
}

int clua_upvalueindex(int i) {
    return lua_upvalueindex(i);
}

/* #1126: the per-call instruction budget. ldebug.c counts every thread against the main thread's
** count, so arming the main thread arms the whole state. Both hooks run inside a host call, on the
** thread that call runs on (the extension's lane or the main thread), and touch only L's own state. */
static void budget_spent(lua_State *L, lua_Debug *ar) {
    (void)ar;
    /* luaD_hook turned hooks off for this thread and the raise skips its restore: turn them back on, so a
       message handler run by the raise and the close handlers of a coroutine it ends are counted too. */
    L->allowhook = 1;
    lua_pushliteral(L, "execution budget exceeded");
    lua_error(L); /* longjmp, does not return */
}

/* L may be a coroutine; it inherited this hook from the thread that created it. */
static void budget_hook(lua_State *L, lua_Debug *ar) {
    lua_State *main;
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
    main = lua_tothread(L, -1);
    lua_pop(L, 1);
    /* Sticky: from now on every instruction in any thread raises again, so a pcall cannot go on. */
    lua_sethook(main, budget_spent, LUA_MASKCOUNT, 1);
    budget_spent(L, ar);
}

void clua_budget_arm(lua_State *L, int count) {
    lua_sethook(L, budget_hook, LUA_MASKCOUNT, count < 1 ? 1 : count); /* 0 or less would never fire */
}

int clua_budget_disarm(lua_State *L) {
    int spent = lua_gethook(L) == budget_spent;
    lua_sethook(L, NULL, 0, 0);
    return spent;
}

/* #1126: setmetatable without finalizers, which would run outside the per-call budget. */
int clua_sandbox_setmetatable(lua_State *L) {
    int t = lua_type(L, 2);
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_argexpected(L, t == LUA_TNIL || t == LUA_TTABLE, 2, "nil or table");
    if (t == LUA_TTABLE) {
        lua_pushliteral(L, "__gc");
        if (lua_rawget(L, 2) != LUA_TNIL) /* raw, as luaC_checkfinalizer (lgc.c) looks; false counts */
            return luaL_argerror(L, 2, "__gc is not available");
    }
    if (luaL_getmetafield(L, 1, "__metatable") != LUA_TNIL)
        return luaL_error(L, "cannot change a protected metatable");
    lua_settop(L, 2);
    lua_setmetatable(L, 1);
    return 1;
}

/* #1126: the collector stays the host's; a script may only read it. Other options do nothing. */
int clua_sandbox_collectgarbage(lua_State *L) {
    const char *opt = luaL_optstring(L, 1, "collect");
    if (strcmp(opt, "count") == 0)
        lua_pushnumber(L, (lua_Number)lua_gc(L, LUA_GCCOUNT) + (lua_Number)lua_gc(L, LUA_GCCOUNTB) / 1024);
    else if (strcmp(opt, "isrunning") == 0)
        lua_pushboolean(L, lua_gc(L, LUA_GCISRUNNING));
    else
        lua_pushinteger(L, 0);
    return 1;
}
