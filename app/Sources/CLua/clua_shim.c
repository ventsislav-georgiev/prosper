#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "clua_shim.h"
#include "lstate.h"  /* #1126: L->allowhook */

/* R1154-1: every top-level call passes no message handler (msgh 0). A handler would run on every error with the memory
** cap and the budget still on. Lua 5.4.9 allocates nothing after the unwind (luaD_seterrorobj copies the error value;
** luaD_errerr makes "error in error handling" before its throw); a handler must not be added here without re-checking
** that, or without switching the cap off before the error object is set. */
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

/* #1154: one budget per outermost call. A call made from inside a host call finds the hook set and leaves it, so it
** runs on the outer count, and a spent budget stays spent; only the call that armed the budget removes it. */
int clua_budget_arm(lua_State *L, int count) {
    if (lua_gethook(L) != NULL)
        return 0;
    lua_sethook(L, budget_hook, LUA_MASKCOUNT, count < 1 ? 1 : count); /* 0 or less would never fire */
    return 1;
}

int clua_budget_disarm(lua_State *L, int armed) {
    int spent = lua_gethook(L) == budget_spent;
    if (armed)
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

/* #1127: the per-runtime memory cap. One clua_mem per state, reached through lua_getallocf. The allocator runs on the
** thread that makes the Lua API call (the runtime's own queue) and on the thread that closes the state; nothing else
** reads or writes these fields. 'enforce' is set by the host only around protected calls (clua_pcall, lua_load), so a
** refusal always becomes a Lua error there and never reaches the panic function. */
static clua_mem *mem_of(lua_State *L) {
    void *ud;
    lua_getallocf(L, &ud);
    return (clua_mem *)ud;
}

static void mem_lower(clua_mem *m, size_t by) {
    m->used = by < m->used ? m->used - by : 0; /* sizes come from Lua: never wrap below zero */
}

void *clua_mem_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    clua_mem *m = (clua_mem *)ud;
    size_t old = ptr != NULL ? osize : 0; /* with ptr NULL, osize is a type tag, not a size (lua_Alloc, lmem.c) */
    void *p;
    if (nsize == 0) {
        free(ptr);
        mem_lower(m, old);
        return NULL;
    }
    if (nsize > old) {
        size_t grow = nsize - old;
        size_t room = m->cap > m->used ? m->cap - m->used : 0;
        if (grow > SIZE_MAX - m->used || (m->enforce && grow > room)) {
            m->refused = 1;
            return NULL; /* Lua: "not enough memory" for this call */
        }
    }
    p = realloc(ptr, nsize); /* a shrink is never refused */
    if (p == NULL)
        return NULL;
    if (nsize > old) {
        m->used += nsize - old; /* checked above: cannot wrap */
        if (m->used > m->peak)
            m->peak = m->used;
    } else {
        mem_lower(m, old - nsize);
    }
    return p;
}

/* What luaL_newstate's panic does (print, then Lua aborts); only a real out-of-memory outside a call reaches it. */
static int clua_panic(lua_State *L) {
    const char *msg = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "error object is not a string";
    lua_writestringerror("PANIC: unprotected error in call to Lua API (%s)\n", msg);
    return 0;
}

lua_State *clua_newstate(size_t cap) {
    clua_mem *m = (clua_mem *)calloc(1, sizeof *m);
    lua_State *L;
    if (m == NULL)
        return NULL;
    m->cap = cap;
    L = lua_newstate(clua_mem_alloc, m);
    if (L == NULL) {
        free(m);
        return NULL;
    }
    lua_atpanic(L, clua_panic); /* warnings stay off: no warnf, so warn() does nothing */
    return L;
}

void clua_close(lua_State *L) {
    clua_mem *m = mem_of(L);
    m->enforce = 0;
    lua_close(L);
    free(m);
}

clua_mem *clua_mem_of(lua_State *L) {
    return mem_of(L);
}

int clua_mem_enforce(lua_State *L, int on) {
    clua_mem *m = mem_of(L);
    int was = m->enforce;
    m->enforce = on;
    return was;
}

void clua_mem_settle(lua_State *L) {
    clua_mem *m = mem_of(L);
    if (m->refused) {
        m->refused = 0;
        lua_gc(L, LUA_GCCOLLECT); /* the refused call's garbage goes now, not at some later step */
    }
}

/* Host functions run with the cap off: a refusal inside one would unwind through Swift frames. Their pushes are
** counted, and a host call that leaves the runtime over its cap fails here, in C, once the host code has returned.
** This relies on f never raising a Lua error: a raise would skip the restore below and leave the cap off for the rest
** of that call (LuaRuntime.pcall still restores it when the call ends). True today: f is LuaRuntime's trampoline, the
** Swift host functions return a count and never call lua_error or luaL_error, a call back into the runtime goes
** through LuaRuntime.pcall (protected), and their pushes run uncapped, so only a real malloc failure could raise. */
static int host_call(lua_State *L) {
    clua_mem *m = mem_of(L);
    lua_CFunction f = lua_tocfunction(L, lua_upvalueindex(3));
    int was = m->enforce;
    int n;
    m->enforce = 0;
    n = f(L);
    m->enforce = was;
    if (was && m->used > m->cap) {
        m->refused = 1;
        lua_pushliteral(L, "not enough memory");
        return lua_error(L);
    }
    return n;
}

void clua_pushhostfunction(lua_State *L, lua_CFunction f) {
    lua_pushcfunction(L, f);
    lua_pushcclosure(L, host_call, 3);
}

/* R1127-3: the host reads and writes globals raw, so no metamethod of the globals table runs outside a call. */
int clua_rawgetglobal(lua_State *L, const char *name) {
    int t;
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_pushstring(L, name);
    t = lua_rawget(L, -2);
    lua_remove(L, -2);
    return t;
}

void clua_rawsetglobal(lua_State *L, const char *name) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_pushstring(L, name);
    lua_rotate(L, -3, -1); /* value, G, name -> G, name, value */
    lua_rawset(L, -3);
    lua_pop(L, 1);
}
