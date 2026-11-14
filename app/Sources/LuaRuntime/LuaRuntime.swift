import CLua
import Foundation

/// A sandboxed, budgeted embedding of the Lua 5.4 interpreter.
///
/// One `LuaRuntime` owns one `lua_State`. It is **not** thread-safe — confine it
/// to a single thread/actor (extensions run on a dedicated extension queue). See
/// docs/ADR-002-extensibility.md.
///
/// Safety model:
/// - **Sandbox** (#1125): only the base, `coroutine`, `table`, `string`, `math`
///   and `utf8` libraries are opened, so `io`, `os`, `package` and `debug` never
///   exist in the state (not even in the registry's `_LOADED`). From base,
///   `dofile` and `loadfile` are removed, and `load` too unless `allowLoad`;
///   `string.dump` is removed; `debug` is a table holding `traceback` only.
///   A script cannot touch the filesystem, spawn processes, load native modules,
///   reach the registry or clear its budget hook. Capabilities are granted back
///   explicitly through host functions (task #22).
/// - **Budget** (#1126): an instruction-count debug hook aborts any host call
///   (`run`, `callGlobal`) that runs longer than its budget, so a runaway loop
///   cannot wedge the host. One count per call covers every coroutine of the
///   state; once spent it stays spent until the call returns, so a script's
///   `pcall` cannot keep going; `__gc` metamethods are refused and
///   `collectgarbage` only reports (`count`, `isrunning`), so no finalizer runs.
/// - **Memory** (#1127): a counting allocator in the shim caps what one runtime's
///   Lua holds (`memoryLimit`). The cap is enforced only inside protected calls
///   (compiling a chunk, `run`, `callGlobal`): a growth past it fails that call
///   with "not enough memory" and the runtime stays usable. State setup, the
///   host's own pushes and host functions are counted but never refused (no
///   protected call would catch a refusal there); a host function that leaves the
///   runtime over its cap fails once it has returned. The host reads and writes
///   globals raw, so no script metamethod runs outside a call.
public final class LuaRuntime {

    /// Errors thrown by load/run/call.
    public enum LuaError: Error, Equatable {
        case stateCreationFailed
        case compile(String)
        case runtime(String)
        case notAFunction(String)
    }

    /// The default per-call instruction budget (~tens of ms of pure Lua).
    public static let defaultInstructionBudget: Int32 = 10_000_000

    /// The default per-runtime memory cap. 256 MiB: room for the largest value one host call hands a script
    /// (host.shell.run's 64 MiB) plus a full-size transform of it; ~12x the highest built-in suite peak (20 MiB).
    public static let defaultMemoryLimit = 256 << 20

    /// `lua_State *`. Recreated on `reset()`.
    private var L: OpaquePointer!
    /// #1151: the Lua thread whose host call is running (a coroutine's own thread when a coroutine made the call),
    /// nil outside host calls. Set and put back per host call by the trampoline, and put back by `pcall` whatever
    /// unwound; read and written only on the runtime's own lane, like `L`.
    private var caller: OpaquePointer?
    /// The thread the stack helpers act on: the caller's, else the main thread.
    private var thread: OpaquePointer? { caller ?? L }
    private let maxInstructions: Int32
    private let memoryLimit: Int
    /// When true, `load` survives the sandbox, text chunks only (a binary chunk is
    /// refused: Lua byte code is not verified), so a privileged
    /// runtime can compile source it fetched itself — the hammerspoon-compat shim
    /// loads the user's `~/.hammerspoon/init.lua` this way. Still no `io`/`os`/
    /// `require`/`loadfile`, so the only source it can reach is what the host hands it.
    private let allowLoad: Bool

    /// Boxed host closures, retained for the life of the runtime so the C
    /// trampoline's light-userdata upvalue stays valid.
    private final class FnBox {
        let fn: (LuaRuntime) -> Int32
        init(_ fn: @escaping (LuaRuntime) -> Int32) { self.fn = fn }
    }
    private var boxes: [FnBox] = []
    /// Replayed on every `reset()` so a hot-reloaded state keeps its host API.
    private var registrations: [(name: String, fn: (LuaRuntime) -> Int32)] = []

    public init(maxInstructions: Int32 = LuaRuntime.defaultInstructionBudget,
                allowLoad: Bool = false,
                memoryLimit: Int = LuaRuntime.defaultMemoryLimit) throws {
        self.maxInstructions = maxInstructions
        self.allowLoad = allowLoad
        self.memoryLimit = memoryLimit
        try open()
    }

    deinit {
        if let L { clua_close(L) }
    }

    /// Bytes this runtime's Lua holds now, as the allocator counts them. Read it on the runtime's own thread.
    var memoryInUse: Int { clua_mem_of(L).pointee.used }
    /// The highest `memoryInUse` so far. Same thread rule.
    var memoryPeak: Int { clua_mem_of(L).pointee.peak }
    /// The main thread's stack height in its current frame. Same thread rule.
    var mainStackHeight: Int32 { lua_gettop(L) }

    // MARK: - State lifecycle

    private func open() throws {
        guard let state = clua_newstate(max(0, memoryLimit)) else { throw LuaError.stateCreationFailed }
        L = state
        applySandbox()
        replayRegistrations()
    }

    /// Tear down and rebuild the state (hot reload). Host registrations are
    /// reapplied; the caller is responsible for re-loading script source.
    public func reset() throws {
        if let L { clua_close(L) }
        L = nil
        boxes.removeAll(keepingCapacity: true)
        try open()
    }

    /// Open only what the sandbox grants (#1125): never `luaL_openlibs`, whose
    /// `io`/`os`/`package`/`debug` stay reachable through the registry even after
    /// their globals are cleared. Capabilities come back only via explicitly
    /// registered host functions.
    private func applySandbox() {
        let libraries: [(String, lua_CFunction)] = [
            ("_G", luaopen_base), ("coroutine", luaopen_coroutine), ("table", luaopen_table),
            ("string", luaopen_string), ("math", luaopen_math), ("utf8", luaopen_utf8),
        ]
        for (name, openLibrary) in libraries {
            luaL_requiref(L, name, openLibrary, 1)
            clua_pop(L, 1)
        }
        // `debug` holds traceback only, for xpcall(f, debug.traceback); luaopen_debug
        // just builds its table (it touches neither the registry nor the globals).
        lua_createtable(L, 0, 1)
        clua_pushcfunction(L, luaopen_debug)
        lua_callk(L, 0, 1, 0, nil)
        lua_getfield(L, -1, "traceback")
        lua_setfield(L, -3, "traceback")
        clua_pop(L, 1)
        clua_rawsetglobal(L, "debug")

        // #1126: no finalizers (they would run outside the budget); the collector stays the host's.
        clua_pushcfunction(L, clua_sandbox_setmetatable)
        clua_rawsetglobal(L, "setmetatable")
        clua_pushcfunction(L, clua_sandbox_collectgarbage)
        clua_rawsetglobal(L, "collectgarbage")

        for global in ["dofile", "loadfile"] + (allowLoad ? [] : ["load"]) {
            lua_pushnil(L)
            clua_rawsetglobal(L, global)
        }
        clua_rawgetglobal(L, "string")
        lua_pushnil(L)
        lua_setfield(L, -2, "dump")
        clua_pop(L, 1)
        if allowLoad {
            // Text chunks only: Lua byte code is not verified. `...` keeps an absent
            // env absent (luaB_load tests lua_isnone on argument 4).
            let wrapper = """
                local load0 = load
                load = function(chunk, name, mode, ...) return load0(chunk, name, "t", ...) end
                """
            // Both calls are protected, so the cap applies to them as to any call.
            let enforced = clua_mem_enforce(L, 1)
            let failed = luaL_loadstring(L, wrapper) != 0 || clua_pcall(L, 0, 0, 0) != 0
            clua_mem_enforce(L, enforced)
            if failed {
                // Fail closed: only an allocation failure reaches here; no load beats the raw one.
                clua_pop(L, 1)
                lua_pushnil(L)
                clua_rawsetglobal(L, "load")
            }
        }
    }

    // MARK: - Loading & running

    /// Compile + run a chunk of Lua source. Throws on syntax or runtime error.
    public func run(_ source: String, name: String = "=chunk") throws {
        try load(source, name: name)
        try pcall(args: 0, results: 0)
    }

    /// Compile a chunk and leave the resulting function on the stack.
    private func load(_ source: String, name: String) throws {
        let enforced = clua_mem_enforce(L, 1)
        let status = luaL_loadstring(L, source)   // protected (lua_load), so it runs under the cap
        clua_mem_enforce(L, enforced)
        clua_mem_settle(L)
        if status != 0 {
            throw LuaError.compile(takeError())
        }
    }

    /// Call a global Lua function by name with string arguments, returning its
    /// first result as a string (or nil if it returned nothing / non-string).
    /// `budget` overrides the per-VM instruction ceiling for THIS call only — pass a
    /// tighter value for hot-path calls (e.g. a keystroke-time dispatch) so a heavy
    /// callback can't burn the full default budget on a latency-critical thread.
    @discardableResult
    public func callGlobal(_ name: String, _ args: [String] = [], budget: Int32? = nil) throws -> String? {
        clua_rawgetglobal(L, name)
        if clua_isfunction(L, -1) == 0 {
            clua_pop(L, 1)
            throw LuaError.notAFunction(name)
        }
        for a in args { lua_pushstring(L, a) }
        try pcall(args: Int32(args.count), results: 1, budget: budget)
        let result = clua_tostring(L, -1).map { String(cString: $0) }
        clua_pop(L, 1)
        return result
    }

    /// Protected call with a freshly-armed instruction budget, shared by every
    /// thread of the state and sticky once spent (#1126, clua_shim.c).
    private func pcall(args: Int32, results: Int32, budget: Int32? = nil) throws {
        // A host call that unwound with a Lua error never ran the trampoline's restore.
        let previousCaller = caller
        defer { caller = previousCaller }
        clua_budget_arm(L, budget ?? maxInstructions)
        let enforced = clua_mem_enforce(L, 1)
        let status = clua_pcall(L, args, results, 0)
        clua_mem_enforce(L, enforced)
        let spent = clua_budget_disarm(L) != 0
        clua_mem_settle(L)
        if status != 0 {
            let message = takeError()
            // A spent budget is reported as such whatever unwound last (coroutine.wrap adds a position).
            throw LuaError.runtime(spent ? "execution budget exceeded" : message)
        }
    }

    /// Pop and return the error message on the top of the stack.
    private func takeError() -> String {
        let msg = clua_tostring(L, -1).map { String(cString: $0) } ?? "unknown Lua error"
        clua_pop(L, 1)
        return msg
    }

    // MARK: - Host function registration

    /// Register a Swift closure as a global Lua function. The closure reads its
    /// arguments and pushes results via the `LuaRuntime` stack helpers, and
    /// returns the number of results it pushed (Lua C-function convention).
    public func register(_ name: String, _ fn: @escaping (LuaRuntime) -> Int32) {
        registrations.append((name, fn))
        install(name: name, fn: fn)
    }

    private func replayRegistrations() {
        for r in registrations { install(name: r.name, fn: r.fn) }
    }

    private func install(name: String, fn: @escaping (LuaRuntime) -> Int32) {
        let box = FnBox(fn)
        boxes.append(box)
        // upvalue 1: the boxed closure; upvalue 2: the owning runtime.
        lua_pushlightuserdata(L, Unmanaged.passUnretained(box).toOpaque())
        lua_pushlightuserdata(L, Unmanaged.passUnretained(self).toOpaque())
        clua_pushhostfunction(L, LuaRuntime.trampoline)
        clua_rawsetglobal(L, name)
    }

    /// C entry point shared by every registered host function. Recovers the box
    /// + runtime from its upvalues and dispatches to the Swift closure.
    private static let trampoline: lua_CFunction = { L in
        guard let L,
              let boxPtr = lua_touserdata(L, clua_upvalueindex(1)),
              let rtPtr = lua_touserdata(L, clua_upvalueindex(2))
        else { return 0 }
        let box = Unmanaged<FnBox>.fromOpaque(boxPtr).takeUnretainedValue()
        let runtime = Unmanaged<LuaRuntime>.fromOpaque(rtPtr).takeUnretainedValue()
        // #1151: the helpers act on the thread that made this call until it returns, then on the previous one again.
        let previousCaller = runtime.caller
        runtime.caller = L
        defer { runtime.caller = previousCaller }
        // The count is applied to the calling thread's frame: never more values than that frame holds.
        return min(max(box.fn(runtime), 0), lua_gettop(L))
    }

    // MARK: - Stack helpers (for use inside registered host functions)
    // They act on the thread that made the running host call (#1151).

    /// Number of arguments passed to the current host function.
    public var argumentCount: Int32 { lua_gettop(thread) }

    /// String argument at 1-based index `i`, or nil if not a string.
    public func stringArgument(_ i: Int32) -> String? {
        clua_tostring(thread, i).map { String(cString: $0) }
    }

    /// Number argument at 1-based index `i`, or nil if not a number.
    public func numberArgument(_ i: Int32) -> Double? {
        var isNum: Int32 = 0
        let v = lua_tonumberx(thread, i, &isNum)
        return isNum != 0 ? v : nil
    }

    /// Boolean argument at 1-based index `i` using Lua truthiness (nil/false →
    /// false, everything else → true), or nil if no value occupies the slot.
    public func boolArgument(_ i: Int32) -> Bool? {
        guard lua_type(thread, i) != LUA_TNONE else { return nil }
        return lua_toboolean(thread, i) != 0
    }

    /// The thread to push one value on, or nil when its stack cannot grow (the push is then skipped).
    private var pushTarget: OpaquePointer? { lua_checkstack(thread, 1) != 0 ? thread : nil }

    /// Push a string result.
    public func push(_ s: String) { if let T = pushTarget { lua_pushstring(T, s) } }
    /// Push a number result.
    public func push(_ d: Double) { if let T = pushTarget { lua_pushnumber(T, d) } }
    /// Push a boolean result.
    public func push(_ b: Bool) { if let T = pushTarget { lua_pushboolean(T, b ? 1 : 0) } }
    /// Push nil.
    public func pushNil() { if let T = pushTarget { lua_pushnil(T) } }

    /// Materialise a JSON value (as produced by `JSONSerialization`) on the stack
    /// as the equivalent Lua value, so heavy JSON parsing happens in native code
    /// (Foundation) instead of a char-by-char Lua loop. Mapping:
    /// - object → table with string keys
    /// - array  → 1-based sequence; JSON `null` elements are dropped so the result
    ///   stays a gap-free Lua sequence (matching the in-VM decoder)
    /// - string / number / bool → the corresponding Lua scalar (integers stay
    ///   integers; reals stay floats)
    /// - `null` / anything unsupported → nil
    ///
    /// Net stack effect: +1. Recursion is depth-bounded and grows the C stack so
    /// pathological nesting can't crash the host.
    public func pushJSON(_ value: Any, depth: Int32 = 0) {
        guard depth < 256, lua_checkstack(thread, 3) != 0 else { lua_pushnil(thread); return }
        switch value {
        case let s as String:
            lua_pushstring(thread, s)
        case let n as NSNumber:
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                lua_pushboolean(thread, n.boolValue ? 1 : 0)
            } else {
                // objCType 'd' (100) / 'f' (102) are reals; the rest are integral.
                let t = n.objCType.pointee
                if t == 100 || t == 102 {
                    lua_pushnumber(thread, n.doubleValue)
                } else {
                    lua_pushinteger(thread, lua_Integer(n.int64Value))
                }
            }
        case let dict as [String: Any]:
            lua_createtable(thread, 0, Int32(clamping: dict.count))
            for (k, v) in dict where !(v is NSNull) {
                pushJSON(v, depth: depth + 1)
                lua_setfield(thread, -2, k)
            }
        case let arr as [Any]:
            lua_createtable(thread, Int32(clamping: arr.count), 0)
            var idx: lua_Integer = 0
            for e in arr where !(e is NSNull) {
                pushJSON(e, depth: depth + 1)
                idx += 1
                lua_rawseti(thread, -2, idx)
            }
        default:
            lua_pushnil(thread)   // NSNull or an unexpected type
        }
    }

    /// Serialise the Lua value at stack `index` to a JSON string, so heavy
    /// encoding happens in native code (Foundation) rather than a char-by-char
    /// Lua loop. Mirrors the in-VM encoder's shape rules: a table with keys
    /// exactly `1..#t` becomes a JSON array, anything else (including the empty
    /// table) a JSON object; non-finite numbers and unsupported values become
    /// `null`. Returns `"null"` if the value can't be represented. Read-only:
    /// leaves the stack as it found it.
    public func encodeJSON(at index: Int32) -> String {
        let obj = toJSONValue(at: index, depth: 0)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "null"
    }

    /// Read the Lua value at `index` into a Foundation JSON value (recursively).
    private func toJSONValue(at index: Int32, depth: Int32) -> Any {
        guard depth < 256 else { return NSNull() }
        let t = lua_type(thread, index)
        if t == LUA_TBOOLEAN {
            return lua_toboolean(thread, index) != 0
        }
        if t == LUA_TNUMBER {
            if lua_isinteger(thread, index) != 0 {
                return Int(lua_tointegerx(thread, index, nil))
            }
            let d = lua_tonumberx(thread, index, nil)
            return d.isFinite ? d : NSNull()
        }
        if t == LUA_TSTRING {
            return luaString(at: index) ?? ""
        }
        if t == LUA_TTABLE {
            return tableToJSON(at: index, depth: depth)
        }
        // LUA_TNIL / function / userdata / thread → JSON null.
        return NSNull()
    }

    /// Binary-safe read of a Lua string at `index` (handles embedded NULs).
    private func luaString(at index: Int32) -> String? {
        var len = 0
        guard let cs = lua_tolstring(thread, index, &len) else { return nil }
        return cs.withMemoryRebound(to: UInt8.self, capacity: len) {
            String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
        }
    }

    private func tableToJSON(at index: Int32, depth: Int32) -> Any {
        guard lua_checkstack(thread, 4) != 0 else { return NSNull() }
        // Absolute index so the pushes below don't shift a relative one.
        let abs = index < 0 ? lua_gettop(thread) + index + 1 : index
        let seqLen = Int(lua_rawlen(thread, abs))

        // Count entries to tell a pure 1..n sequence (array) from a map.
        var count = 0
        lua_pushnil(thread)
        while lua_next(thread, abs) != 0 {
            count += 1
            clua_pop(thread, 1)   // pop value, keep key for the next step
        }

        if count > 0 && count == seqLen {
            var arr: [Any] = []
            arr.reserveCapacity(seqLen)
            for i in 1...seqLen {
                lua_rawgeti(thread, abs, lua_Integer(i))
                arr.append(toJSONValue(at: -1, depth: depth + 1))
                clua_pop(thread, 1)
            }
            return arr
        }

        var dict: [String: Any] = [:]
        lua_pushnil(thread)
        while lua_next(thread, abs) != 0 {
            // key at -2, value at -1. Duplicate the key before stringifying:
            // lua_tolstring coerces a number key in place, which would corrupt
            // the key lua_next relies on to advance.
            lua_pushvalue(thread, -2)
            let key = luaString(at: -1) ?? ""
            clua_pop(thread, 1)   // pop the duplicated key
            dict[key] = toJSONValue(at: -1, depth: depth + 1)
            clua_pop(thread, 1)   // pop value, keep original key for lua_next
        }
        return dict
    }
}
