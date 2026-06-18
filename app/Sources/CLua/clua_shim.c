#include "clua_shim.h"

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

void clua_set_count_hook(lua_State *L, lua_Hook hook, int count) {
    lua_sethook(L, hook, LUA_MASKCOUNT, count);
}

void clua_clear_hook(lua_State *L) {
    lua_sethook(L, NULL, 0, 0);
}

void clua_raise(lua_State *L, const char *msg) {
    lua_pushstring(L, msg);
    lua_error(L); /* longjmp — does not return */
}
