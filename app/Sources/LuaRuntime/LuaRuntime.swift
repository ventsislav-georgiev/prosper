import CLua
import Foundation

/// A sandboxed, budgeted embedding of the Lua 5.4 interpreter.
///
/// One `LuaRuntime` owns one `lua_State`. It is **not** thread-safe — confine it
/// to a single thread/actor (extensions run on a dedicated extension queue). See
/// docs/ADR-002-extensibility.md.
///
/// Safety model:
/// - **Sandbox**: dangerous standard libraries (`io`, `os`, `package`, `require`,
///   `dofile`, `loadfile`, `load`) are removed before any user code runs, so a
///   script cannot touch the filesystem, spawn processes, or load native modules.
///   Capabilities are granted back explicitly through host functions (task #22).
/// - **Budget**: an instruction-count debug hook aborts any call that runs longer
///   than `maxInstructions`, so a runaway loop cannot wedge the host.
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

    /// `lua_State *`. Recreated on `reset()`.
    private var L: OpaquePointer!
    private let maxInstructions: Int32
    /// When true, `load` (text-mode source) survives the sandbox so a privileged
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
                allowLoad: Bool = false) throws {
        self.maxInstructions = maxInstructions
        self.allowLoad = allowLoad
        try open()
    }

    deinit {
        if let L { lua_close(L) }
    }

    // MARK: - State lifecycle

    private func open() throws {
        guard let state = luaL_newstate() else { throw LuaError.stateCreationFailed }
        L = state
        luaL_openlibs(L)
        applySandbox()
        replayRegistrations()
    }

    /// Tear down and rebuild the state (hot reload). Host registrations are
    /// reapplied; the caller is responsible for re-loading script source.
    public func reset() throws {
        if let L { lua_close(L) }
        L = nil
        boxes.removeAll(keepingCapacity: true)
        try open()
    }

    /// Remove filesystem/process/loader access. Capabilities come back only via
    /// explicitly registered host functions.
    private func applySandbox() {
        var stripped = ["io", "os", "package", "require", "dofile", "loadfile", "load"]
        if allowLoad { stripped.removeAll { $0 == "load" } }
        for global in stripped {
            lua_pushnil(L)
            lua_setglobal(L, global)
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
        let status = luaL_loadstring(L, source)
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
        lua_getglobal(L, name)
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

    /// Protected call with a freshly-armed instruction budget.
    private func pcall(args: Int32, results: Int32, budget: Int32? = nil) throws {
        clua_set_count_hook(L, LuaRuntime.budgetHook, budget ?? maxInstructions)
        let status = clua_pcall(L, args, results, 0)
        clua_clear_hook(L)
        if status != 0 {
            throw LuaError.runtime(takeError())
        }
    }

    /// Fires once the per-call instruction budget is exhausted; aborts the call.
    private static let budgetHook: lua_Hook = { L, _ in
        clua_raise(L, "execution budget exceeded")
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
        lua_pushcclosure(L, LuaRuntime.trampoline, 2)
        lua_setglobal(L, name)
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
        return box.fn(runtime)
    }

    // MARK: - Stack helpers (for use inside registered host functions)

    /// Number of arguments passed to the current host function.
    public var argumentCount: Int32 { lua_gettop(L) }

    /// String argument at 1-based index `i`, or nil if not a string.
    public func stringArgument(_ i: Int32) -> String? {
        clua_tostring(L, i).map { String(cString: $0) }
    }

    /// Number argument at 1-based index `i`, or nil if not a number.
    public func numberArgument(_ i: Int32) -> Double? {
        var isNum: Int32 = 0
        let v = lua_tonumberx(L, i, &isNum)
        return isNum != 0 ? v : nil
    }

    /// Boolean argument at 1-based index `i` using Lua truthiness (nil/false →
    /// false, everything else → true), or nil if no value occupies the slot.
    public func boolArgument(_ i: Int32) -> Bool? {
        guard lua_type(L, i) != LUA_TNONE else { return nil }
        return lua_toboolean(L, i) != 0
    }

    /// Push a string result.
    public func push(_ s: String) { lua_pushstring(L, s) }
    /// Push a number result.
    public func push(_ d: Double) { lua_pushnumber(L, d) }
    /// Push a boolean result.
    public func push(_ b: Bool) { lua_pushboolean(L, b ? 1 : 0) }
    /// Push nil.
    public func pushNil() { lua_pushnil(L) }

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
        guard depth < 256, lua_checkstack(L, 3) != 0 else { lua_pushnil(L); return }
        switch value {
        case let s as String:
            lua_pushstring(L, s)
        case let n as NSNumber:
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                lua_pushboolean(L, n.boolValue ? 1 : 0)
            } else {
                // objCType 'd' (100) / 'f' (102) are reals; the rest are integral.
                let t = n.objCType.pointee
                if t == 100 || t == 102 {
                    lua_pushnumber(L, n.doubleValue)
                } else {
                    lua_pushinteger(L, lua_Integer(n.int64Value))
                }
            }
        case let dict as [String: Any]:
            lua_createtable(L, 0, Int32(clamping: dict.count))
            for (k, v) in dict where !(v is NSNull) {
                pushJSON(v, depth: depth + 1)
                lua_setfield(L, -2, k)
            }
        case let arr as [Any]:
            lua_createtable(L, Int32(clamping: arr.count), 0)
            var idx: lua_Integer = 0
            for e in arr where !(e is NSNull) {
                pushJSON(e, depth: depth + 1)
                idx += 1
                lua_rawseti(L, -2, idx)
            }
        default:
            lua_pushnil(L)   // NSNull or an unexpected type
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
        let t = lua_type(L, index)
        if t == LUA_TBOOLEAN {
            return lua_toboolean(L, index) != 0
        }
        if t == LUA_TNUMBER {
            if lua_isinteger(L, index) != 0 {
                return Int(lua_tointegerx(L, index, nil))
            }
            let d = lua_tonumberx(L, index, nil)
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
        guard let cs = lua_tolstring(L, index, &len) else { return nil }
        return cs.withMemoryRebound(to: UInt8.self, capacity: len) {
            String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
        }
    }

    private func tableToJSON(at index: Int32, depth: Int32) -> Any {
        guard lua_checkstack(L, 4) != 0 else { return NSNull() }
        // Absolute index so the pushes below don't shift a relative one.
        let abs = index < 0 ? lua_gettop(L) + index + 1 : index
        let seqLen = Int(lua_rawlen(L, abs))

        // Count entries to tell a pure 1..n sequence (array) from a map.
        var count = 0
        lua_pushnil(L)
        while lua_next(L, abs) != 0 {
            count += 1
            clua_pop(L, 1)   // pop value, keep key for the next step
        }

        if count > 0 && count == seqLen {
            var arr: [Any] = []
            arr.reserveCapacity(seqLen)
            for i in 1...seqLen {
                lua_rawgeti(L, abs, lua_Integer(i))
                arr.append(toJSONValue(at: -1, depth: depth + 1))
                clua_pop(L, 1)
            }
            return arr
        }

        var dict: [String: Any] = [:]
        lua_pushnil(L)
        while lua_next(L, abs) != 0 {
            // key at -2, value at -1. Duplicate the key before stringifying:
            // lua_tolstring coerces a number key in place, which would corrupt
            // the key lua_next relies on to advance.
            lua_pushvalue(L, -2)
            let key = luaString(at: -1) ?? ""
            clua_pop(L, 1)   // pop the duplicated key
            dict[key] = toJSONValue(at: -1, depth: depth + 1)
            clua_pop(L, 1)   // pop value, keep original key for lua_next
        }
        return dict
    }
}
