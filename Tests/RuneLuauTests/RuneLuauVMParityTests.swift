import Foundation
import Testing
import Rune
@testable import RuneLuau

@Suite("RuneLuau VM & Stdlib Parity", .serialized)
struct RuneLuauVMParityTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune_luau_vm_parity_\(name)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runVM(_ source: String, sandboxed: Bool = false) throws -> [LuauValue] {
        let vm = LuauVM()
        if sandboxed { vm.sandbox() }
        let closure = try vm.load(source: source, name: "test.luau")
        return try vm.call(closure: closure)
    }

    // MARK: - 1. LuauData & ScriptError

    @Test("LuauData toJSONObject and sorted-key BTreeMap parity")
    func dataJSONObjectAndSortedKeys() throws {
        let data: LuauData = [
            "zebra": 1,
            "alpha": true,
            "middle": [1.5, "hi", .nil],
        ]
        let obj = data.toJSONObject()
        let dict = try #require(obj as? [String: Any])
        #expect(dict["zebra"] as? Int64 == 1)
        #expect(dict["alpha"] as? Bool == true)
        let arr = try #require(dict["middle"] as? [Any])
        #expect(arr.count == 3)
        #expect(arr[0] as? Double == 1.5)
        #expect(arr[1] as? String == "hi")
        #expect(arr[2] is NSNull)

        let roundTripped = LuauData.fromJSONObject(obj)
        #expect(roundTripped == data)

        // Ensure `toLuau` inserts keys in sorted order matching Rust BTreeMap
        guard case .table(let tbl) = data.toLuau() else {
            Issue.record("expected table")
            return
        }
        let orderedKeys = tbl.hashOrder.compactMap { key -> String? in
            if case .string(let s) = key { return s }
            return nil
        }
        #expect(orderedKeys == ["alpha", "middle", "zebra"])

        // Ensure Codable decode produces deterministic sorted keys
        struct S: Codable, Equatable { let zebra: Int; let alpha: Bool }
        let decoded = try LuauData.map(["zebra": 7, "alpha": false]).decode(S.self)
        #expect(decoded == S(zebra: 7, alpha: false))
    }

    @Test("ScriptError summary splits on first newline or CRLF and ErrorKind.missing")
    func scriptErrorSummaryAndMissing() throws {
        let multi = ScriptError(kind: .runtime, message: "line1\r\nstack traceback:\n\tinit.luau:1")
        #expect(multi.summary == "line1")

        let single = ScriptError(kind: .syntax, message: "unexpected EOF")
        #expect(single.summary == "unexpected EOF")

        do {
            _ = try Sources().compile()
            Issue.record("expected missing error")
        } catch let err as ScriptError {
            #expect(err.kind == .missing)
            #expect(err.message.contains("init.luau"))
        }
    }

    // MARK: - 2. Sources

    @Test("Sources CRUD, paths, compileFrom reuse, fromDir, and precompiled")
    func sourcesMethodsAndPrecompiled() throws {
        #expect(Sources.entry == "init.luau")

        var s = Sources.single("return { x = 1 }")
            .with("b.luau", "return 2")
            .with("a/c.luau", "return 3")
            .parentConfig("{\"aliases\": {}}")
            .folder("demo")
            .entry("./main.luau")
        s.insert("./main.luau", "local b = require('./b')\nreturn { v = b }")

        #expect(s.entryPath == "main.luau")
        #expect(s.folder == "demo")
        #expect(s.parentConfig == "{\"aliases\": {}}")
        #expect(s.get("b.luau") == "return 2")
        #expect(s.get("./a/c.luau") == "return 3")
        #expect(s.paths == ["a/c.luau", "b.luau", "init.luau", "main.luau"])

        let c1 = try s.compile()
        var s2 = s
        s2.insert("b.luau", "return 20")
        let c2 = try s2.compileFrom(c1)
        #expect(c2.module("a/c.luau") === c1.module("a/c.luau"))
        #expect(c2.module("b.luau") !== c1.module("b.luau"))

        // fromDir reads nested files + hidden configs + parent .luaurc, skips directories ending in .luau
        let parentDir = try makeTempDir("sources_parent")
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try "{\"aliases\": {\"root\": \"./shared\"}}".write(
            to: parentDir.appendingPathComponent(".luaurc"),
            atomically: true,
            encoding: .utf8
        )
        let appDir = parentDir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appDir.appendingPathComponent("sub.luau"), withIntermediateDirectories: true)
        try "return 42".write(to: appDir.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        try "return { aliases = {} }".write(to: appDir.appendingPathComponent(".config.luau"), atomically: true, encoding: .utf8)

        let diskSources = try Sources.fromDir(appDir)
        #expect(diskSources.folder == "app")
        #expect(diskSources.parentConfig != nil)
        #expect(diskSources.paths == [".config.luau", "init.luau"])

        // Precompiled OnceLock + version check + bypass syntax error in source
        Sources._resetPrecompiledForTests()
        defer { Sources._resetPrecompiledForTests() }

        let goodBC = try Sources.compileBytecode("return { ok = 99 }", name: "init.luau")
        var badVersionBC = goodBC
        badVersionBC[4] = 0xFF // corrupt version uint32

        Sources.precompiled([
            ("init.luau", goodBC),
            ("fallback.luau", badVersionBC),
        ])
        // Second call must be ignored (write-once OnceLock)
        let secondBC = try Sources.compileBytecode("return { ok = 123 }", name: "init.luau")
        Sources.precompiled(["init.luau": secondBC])

        let preSrc = Sources()
            .with("init.luau", "this is invalid syntax %%% !!!")
            .with("fallback.luau", "return 77")
        let compiledPre = try preSrc.compile()
        let vm = LuauVM()
        let entryMod = try #require(compiledPre.module("init.luau"))
        let res = try vm.call(closure: LuauClosure(proto: entryMod.proto, upvalues: [], env: vm.globals))
        guard case .table(let t) = res.first else {
            Issue.record("expected table from precompiled init.luau")
            return
        }
        #expect(t.rawGet("ok") == .number(99))
        #expect(compiledPre.module("fallback.luau") != nil)
    }

    // MARK: - 3. Workers

    @Test("Workers spawnBlocking runs off-main-thread and dropped Completer delivers nil")
    func workersSpawnBlockingAndCompleterDrop() throws {
        let onBgExpectation = DispatchSemaphore(value: 0)
        final class Flag: @unchecked Sendable { var isMain = true }
        let flag = Flag()
        spawnBlocking {
            flag.isMain = Thread.isMainThread
            onBgExpectation.signal()
        }
        #expect(onBgExpectation.wait(timeout: .now() + 2) == .success)
        #expect(flag.isMain == false)

        let src = Sources.single("""
        local M = {}
        M.done = false
        M.gotNil = false
        function M.start()
            task.spawn(function()
                local res = drop_job()
                M.gotNil = (res == nil)
                M.done = true
            end)
        end
        function M.state()
            return { done = M.done, gotNil = M.gotNil }
        end
        return M
        """)
        let opts = ScriptOptions().setup { host in
            let fn = try host.asyncFunction("drop_job") { _, completer in
                spawnBlocking {
                    // Intentionally drop completer without calling complete(...)
                    _ = completer
                }
            }
            host.global("drop_job", value: fn)
        }
        let script = Script(name: "worker-drop", sources: src, options: opts)
        let wakerFlag = Flag()
        script.setWaker(Waker { wakerFlag.isMain = false })
        script.prewarm()
        #expect(script.error == nil)
        try script.call("start")

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            var tx = Tx()
            _ = script.poll(now: 0, tx: &tx)
            let state = try script.query("state")
            if case .bool(true) = state.get("done") {
                #expect(state.get("gotNil") == .bool(true))
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Issue.record("timed out waiting for dropped Completer to resolve nil")
    }

    // MARK: - 4. TaskScheduler & Sandbox

    @Test("Sandbox freezes @rune/signal, enforces 100k defer cap, task.cancel, and Signal APIs")
    func taskSchedulerSandboxSignals() throws {
        // Frozen @rune/signal in sandbox
        let frozenSrc = Sources.single("""
        local Sig = require("@rune/signal")
        local ok = pcall(function()
            Sig.new = function() end
        end)
        local M = {}
        M.frozen = not ok
        function M.check()
            return M.frozen
        end
        return M
        """)
        let s1 = Script(name: "frozen-sig", sources: frozenSrc)
        s1.prewarm()
        #expect(s1.error == nil)
        #expect(try s1.query("check") == .bool(true))

        // Signal:Once, Wait, Version, Disconnect + task.cancel
        let sigSrc = Sources.single("""
        local SigMod = require("@rune/signal")
        local sig = SigMod.new()
        local M = { log = {}, canceledRan = false }

        local onceCount = 0
        local waitRes = nil
        local c1 = sig:Once(function(a)
            onceCount += 1
            table.insert(M.log, "once:" .. tostring(a))
        end)
        local c2 = sig:Connect(function(a)
            table.insert(M.log, "conn:" .. tostring(a))
        end)

        function M.run()
            local v0 = sig:Version()
            local waiter = task.spawn(function()
                waitRes = sig:Wait()
            end)
            local canceled = task.delay(0.01, function()
                M.canceledRan = true
            end)
            task.cancel(canceled)

            sig:Fire("hello")
            local v1 = sig:Version()
            c2:Disconnect()
            sig:Fire("world")
            local v2 = sig:Version()
            return {
                v0 = v0,
                v1 = v1,
                v2 = v2,
                onceCount = onceCount,
                waitRes = waitRes,
                logLen = #M.log,
                canceledRan = M.canceledRan,
            }
        end
        return M
        """)
        let s2 = Script(name: "signal-apis", sources: sigSrc)
        s2.prewarm()
        #expect(s2.error == nil)
        let res = try s2.query("run")
        #expect(res.get("v0") == .integer(0))
        #expect(res.get("v1") == .integer(1))
        #expect(res.get("v2") == .integer(2))
        #expect(res.get("onceCount") == .integer(1))
        #expect(res.get("waitRes") == .string("hello"))
        #expect(res.get("logLen") == .integer(2))
        var tx = Tx()
        Thread.sleep(forTimeInterval: 0.03)
        _ = s2.poll(now: 0.05, tx: &tx)
        #expect(try s2.query("run").get("canceledRan") == .bool(false))

        // 100k defer cap
        let deferSrc = Sources.single("""
        local function bomb()
            task.defer(bomb)
        end
        task.defer(bomb)
        return {}
        """)
        let s3 = Script(name: "defer-cap", sources: deferSrc, options: ScriptOptions().timeLimit(.seconds(5)))
        var deferTx = Tx()
        _ = s3.poll(now: 0, tx: &deferTx)
        #expect(s3.error == nil)
        #expect(s3.log.contains(where: { $0.level == .error && $0.message.contains("100,000") }))
    }

    // MARK: - 5. Require & Watch

    @Test("Require relative aliases, ambiguous error, and Watch subdirectory/error preservation")
    func requireAndWatchParity() throws {
        // Non-./ relative aliases & ../ & ambiguous require
        let reqSrc = Sources()
            .with(".config.luau", """
            return {
                luau = {
                    aliases = {
                        lib = "views",
                        sub = "./views/nested",
                    }
                }
            }
            """)
            .with("views/item.luau", "return 12")
            .with("views/nested/helper.luau", "local up = require('../item')\nreturn up + 5")
            .with("init.luau", """
            local h = require("@sub/helper")
            local i = require("@lib/item")
            return { sum = h + i }
            """)
        let compiled = try reqSrc.compile()
        let s = Script(name: "req-alias", sources: reqSrc)
        s.prewarm()
        #expect(s.error == nil)
        #expect(compiled.module("views/nested/helper.luau") != nil)

        // Ambiguous require: dup.luau and dup/init.luau both exist
        let ambigSrc = Sources()
            .with("dup.luau", "return 1")
            .with("dup/init.luau", "return 2")
            .with("init.luau", "return require('@self/dup')")
        let sAmbig = Script(name: "ambig", sources: ambigSrc)
        sAmbig.prewarm()
        let ambigErr = try #require(sAmbig.error)
        #expect(ambigErr.message.lowercased().contains("ambiguous"))

        // Watch: subdirectory + hidden .luaurc + error preservation on invalid reload + recovery
        let dir = try makeTempDir("watch")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "local M = {}\nfunction M.val() return 1 end\nreturn M".write(
            to: dir.appendingPathComponent("init.luau"),
            atomically: true,
            encoding: .utf8
        )
        let subDir = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "return 10".write(to: subDir.appendingPathComponent("a.luau"), atomically: true, encoding: .utf8)

        let diskSrc = try Sources.fromDir(dir)
        let watched = Script(name: "watched", sources: diskSrc)
        watched.prewarm()
        try watched.watch(dir)
        #expect(try watched.query("val") == .integer(1))

        // Write invalid syntax -> reload error is logged, prior working module is preserved
        try "return ((( broken".write(to: dir.appendingPathComponent("init.luau"), atomically: true, encoding: .utf8)
        let deadline1 = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline1 {
            var tx = Tx()
            _ = watched.poll(now: 0, tx: &tx)
            if watched.log.contains(where: { $0.level == .error }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        #expect(watched.error == nil)
        #expect(watched.log.contains(where: { $0.level == .error }))
        #expect(try watched.query("val") == .integer(1))

        // Fix syntax in init.luau requiring sub/a + hidden .luaurc
        try "{\"aliases\": {\"s\": \"./sub\"}}".write(to: dir.appendingPathComponent(".luaurc"), atomically: true, encoding: .utf8)
        try "local a = require('@s/a')\nlocal M = {}\nfunction M.val() return a end\nreturn M".write(
            to: dir.appendingPathComponent("init.luau"),
            atomically: true,
            encoding: .utf8
        )
        let deadline2 = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline2 {
            var tx = Tx()
            _ = watched.poll(now: 0, tx: &tx)
            if watched.error == nil, (try? watched.query("val")) == .integer(10) {
                return
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        Issue.record("watched script did not recover after valid edit; error=\(String(describing: watched.error))")
    }

    // MARK: - 6. Watchdog

    @Test("Default 250ms watchdog aborts infinite loop under 260ms and resists pcall")
    func watchdogDefault250msAndPcallImmunity() throws {
        let spinSrc = Sources.single("""
        local M = {}
        function M.spin()
            while true do end
        end
        function M.spinPcall()
            pcall(function()
                while true do end
            end)
            return "escaped"
        end
        return M
        """)
        let opts = ScriptOptions()
        #expect(opts.timeLimit == .milliseconds(250))

        let script = Script(name: "watchdog", sources: spinSrc, options: opts)
        script.prewarm()
        #expect(script.error == nil)

        let t0 = ContinuousClock.now
        do {
            _ = try script.query("spin")
            Issue.record("expected timeout error")
        } catch let err as ScriptError {
            #expect(err.kind == .timeout)
        }
        let elapsed = t0.duration(to: .now)
        #expect(elapsed >= .milliseconds(240))
        #expect(elapsed < .milliseconds(260))

        do {
            _ = try script.query("spinPcall")
            Issue.record("expected pcall to be unable to catch timeout")
        } catch let err as ScriptError {
            #expect(err.kind == .timeout)
        }
    }

    // MARK: - 7. VM / Parser / Stdlib Additions

    @Test("buffer library round-trips types, bits, copy, fill, and bounds checking")
    func bufferLibrary() throws {
        let out = try runVM("""
        local b = buffer.create(32)
        assert(typeof(b) == "buffer" and type(b) == "buffer")
        assert(buffer.len(b) == 32)
        buffer.writei8(b, 0, -42)
        buffer.writeu8(b, 1, 250)
        buffer.writei16(b, 2, -12345)
        buffer.writeu16(b, 4, 60000)
        buffer.writei32(b, 6, -1000000)
        buffer.writeu32(b, 10, 3000000000)
        buffer.writef32(b, 14, 1.5)
        buffer.writef64(b, 18, 3.141592653589793)

        assert(buffer.readi8(b, 0) == -42)
        assert(buffer.readu8(b, 1) == 250)
        assert(buffer.readi16(b, 2) == -12345)
        assert(buffer.readu16(b, 4) == 60000)
        assert(buffer.readi32(b, 6) == -1000000)
        assert(buffer.readu32(b, 10) == 3000000000)
        assert(buffer.readf32(b, 14) == 1.5)
        assert(buffer.readf64(b, 18) == 3.141592653589793)

        buffer.writestring(b, 26, "hello!")
        assert(buffer.readstring(b, 26, 5) == "hello")

        local b2 = buffer.fromstring("abcdef")
        buffer.copy(b2, 1, b2, 0, 4)
        assert(buffer.tostring(b2) == "aabcdf")
        buffer.fill(b2, 2, string.byte("X"), 3)
        assert(buffer.tostring(b2) == "aaXXXf")

        local bits = buffer.create(4)
        buffer.writebits(bits, 3, 5, 29)
        buffer.writebits(bits, 8, 12, 0xABC)
        assert(buffer.readbits(bits, 3, 5) == 29)
        assert(buffer.readbits(bits, 8, 12) == 0xABC)

        local okOob = pcall(function() buffer.readu32(b, 30) end)
        assert(not okOob)
        return true
        """)
        #expect(out == [.bool(true)])
    }

    @Test("string.pack, unpack, and packsize round-trip formats cleanly")
    func stringPackUnpackPacksize() throws {
        let out = try runVM("""
        local fmt = "<bBhHi4I4fd c4 z s2"
        local packed = string.pack(fmt, -5, 200, -1000, 50000, -90000, 90000, 2.5, 6.25, "ab", "hi", "len!")
        local a, b, c, d, e, f, g, h, s1, s2, s3, nextPos = string.unpack(fmt, packed)
        assert(a == -5 and b == 200 and c == -1000 and d == 50000)
        assert(e == -90000 and f == 90000 and g == 2.5 and h == 6.25)
        assert(string.byte(s1, 1, 4) == 97 and select(2, string.byte(s1, 1, 4)) == 98 and select(3, string.byte(s1, 1, 4)) == 0)
        assert(s2 == "hi" and s3 == "len!" and nextPos == #packed + 1)

        local be = string.pack(">I2I4", 0x0102, 0x11223344)
        assert(string.byte(be, 1) == 0x01 and string.byte(be, 2) == 0x02)
        assert(string.byte(be, 3) == 0x11 and string.byte(be, 6) == 0x44)
        local u1, u2 = string.unpack(">I2I4", be)
        assert(u1 == 0x0102 and u2 == 0x11223344)

        assert(string.packsize("!4bXi4f") == 8)
        assert(string.packsize("!4bi4f") == 12)
        local varErr = pcall(function() return string.packsize("z") end)
        assert(not varErr)
        return true
        """)
        #expect(out == [.bool(true)])
    }

    @Test("os.date and os.time date table parity")
    func osDateAndTime() throws {
        let out = try runVM("""
        local utc = os.date("!*t", 0)
        assert(utc.year == 1970 and utc.month == 1 and utc.day == 1)
        assert(utc.hour == 0 and utc.min == 0 and utc.sec == 0)
        assert(utc.wday == 5 and utc.yday == 1 and utc.isdst == false)

        local formatted = os.date("!%Y-%m-%d %H:%M:%S", 1700000000)
        assert(formatted == "2023-11-14 22:13:20")

        local bad = pcall(function() return os.date("%Q") end)
        assert(not bad)

        local ts = os.time({ year = 2024, month = 6, day = 15, hour = 10, min = 30, sec = 0 })
        assert(type(ts) == "number" and ts > 0)
        return true
        """)
        #expect(out == [.bool(true)])
    }

    @Test("debug.info reports source, line, name, arity, and function reference")
    func debugInfoParity() throws {
        let out = try runVM("""
        local function add(a, b, ...)
            return a + b
        end
        local function caller()
            local src, line, name, nparams, isvar, fn = debug.info(1, "slnaf")
            return src, line, name, nparams, isvar, fn
        end
        local src, line, name, nparams, isvar, fn = caller()
        assert(src == "test.luau" and line > 0 and name == "caller")
        assert(nparams == 0 and isvar == false and fn == caller)

        local fnSrc, _, fnName, np, iv, ref = debug.info(add, "slnaf")
        assert(fnSrc == "test.luau" and fnName == "add" and np == 2 and iv == true and ref == add)

        local co = coroutine.create(function(x)
            return debug.info(1, "na")
        end)
        local ok, cn, cnp, civ = coroutine.resume(co, 1)
        assert(ok and cnp == 1 and civ == false)

        local badOpt = pcall(function() return debug.info(add, "z") end)
        assert(not badOpt)
        return true
        """)
        #expect(out == [.bool(true)])
    }

    @Test("vector library, component indexing, and scalar arithmetic")
    func vectorLibraryAndOperators() throws {
        let out = try runVM("""
        local a = vector.create(3, 4, 0)
        local b = vector.create(0, 1, 0)
        assert(a.x == 3 and a.Y == 4 and a.z == 0)
        assert(vector.magnitude(a) == 5)
        local n = vector.normalize(a)
        assert(math.abs(n.x - 0.6) < 1e-6 and math.abs(n.y - 0.8) < 1e-6)
        assert(vector.dot(a, b) == 4)
        local c = vector.cross(vector.create(1, 0, 0), vector.create(0, 1, 0))
        assert(c == vector.create(0, 0, 1))
        assert(math.abs(vector.angle(vector.create(1, 0, 0), vector.create(0, 1, 0)) - math.pi / 2) < 1e-6)
        assert(vector.angle(vector.create(1, 0, 0), vector.create(0, 1, 0), vector.create(0, 0, -1)) < 0)
        assert(vector.floor(vector.create(1.9, -1.2, 0)) == vector.create(1, -2, 0))
        assert(vector.ceil(vector.create(1.1, -1.8, 0)) == vector.create(2, -1, 0))
        assert(vector.abs(vector.create(-1, 2, -3)) == vector.create(1, 2, 3))
        assert(vector.sign(vector.create(-5, 0, 9)) == vector.create(-1, 0, 1))
        assert(vector.clamp(vector.create(-1, 5, 10), vector.zero, vector.create(3, 4, 5)) == vector.create(0, 4, 5))
        assert(vector.min(vector.create(3, 1, 4), vector.create(2, 5, 1)) == vector.create(2, 1, 1))
        assert(vector.max(vector.create(3, 1, 4), vector.create(2, 5, 1)) == vector.create(3, 5, 4))
        assert(vector.lerp(vector.zero, vector.one, 0.25) == vector.create(0.25, 0.25, 0.25))

        assert(a * 2 == vector.create(6, 8, 0))
        assert(2 * a == vector.create(6, 8, 0))
        assert(vector.create(6, 8, 0) / 2 == a)
        assert(vector.create(7, 9, 5) // 2 == vector.create(3, 4, 2))
        assert(vector.create(7, 9, 5) // vector.create(2, 4, 2) == vector.create(3, 2, 2))
        return true
        """)
        #expect(out == [.bool(true)])
    }

    @Test("collectgarbage, gcinfo, function attributes, and typeof annotation parsing")
    func gcAndAttributesAndTypeof() throws {
        let out = try runVM("""
        local kb = collectgarbage("count")
        local g = gcinfo()
        assert(type(kb) == "number" and kb > 0 and g > 0)
        assert(collectgarbage("isrunning") == true)
        assert(collectgarbage("collect") == 0)

        @native
        function addOne(x: typeof(1 + 2)): number
            return x + 1
        end

        @[native, checked]
        local function mulTwo(x: number): number
            return x * 2
        end

        local subOne = @native function(x)
            return x - 1
        end

        assert(addOne(4) == 5 and mulTwo(3) == 6 and subOne(9) == 8)
        return true
        """)
        #expect(out == [.bool(true)])
    }

    @Test("Raw byte-strings preserve arbitrary non-UTF8 bytes across escapes, string.*, patterns, table.*, and utf8.*")
    func byteStringSemantics() throws {
        let out = try runVM(#"""
        local raw = "\xff\x00\xfe\x80A"
        assert(#raw == 5 and string.len(raw) == 5)
        local b1, b2, b3, b4, b5 = string.byte(raw, 1, 5)
        assert(b1 == 255 and b2 == 0 and b3 == 254 and b4 == 128 and b5 == 65)
        assert(string.byte("\255") == 255)

        local rev = string.reverse(raw)
        local r1, r5 = string.byte(rev, 1), string.byte(rev, 5)
        assert(r1 == 65 and r5 == 255)

        local ch = string.char(0xFF, 0x00, 0x80)
        assert(#ch == 3 and string.byte(ch, 1) == 0xFF and string.byte(ch, 2) == 0 and string.byte(ch, 3) == 0x80)

        local fmtc = string.format("%c", 255)
        assert(#fmtc == 1 and string.byte(fmtc, 1) == 255)

        local lower = string.lower("\xffABC\xfe")
        assert(string.byte(lower, 1) == 255 and string.sub(lower, 2, 4) == "abc" and string.byte(lower, 5) == 254)

        local cat = "\xff" .. "\xfe"
        assert(#cat == 2 and string.byte(cat, 1) == 255 and string.byte(cat, 2) == 254)
        assert("\xfe" < "\xff" and "\xfe" <= "\xfe")

        local f1, f2 = string.find(raw, "\xfe\x80", 1, true)
        assert(f1 == 3 and f2 == 4)
        local m = string.match("\x01\xff\x02", "(\xff)")
        assert(#m == 1 and string.byte(m, 1) == 255)
        local gs = string.gsub("\xffa\xfe", "\xff", "\x81")
        assert(string.byte(gs, 1) == 0x81 and string.byte(gs, 2) == 97 and string.byte(gs, 3) == 0xFE)

        local tc = table.concat({ "\xff", "\x00" }, "\xfe")
        assert(#tc == 3 and string.byte(tc, 1) == 255 and string.byte(tc, 2) == 254 and string.byte(tc, 3) == 0)

        local arr = { "\xff", "\x01", "\x80" }
        table.sort(arr)
        assert(string.byte(arr[1], 1) == 1 and string.byte(arr[2], 1) == 128 and string.byte(arr[3], 1) == 255)

        local ulen, failPos = utf8.len("a\xffb")
        assert(ulen == nil and failPos == 2)

        local c1, c2 = utf8.codepoint("ab", 1, 2)
        assert(c1 == 97 and c2 == 98)
        return true
        """#)
        #expect(out == [.bool(true)])
    }

    @Test("Script.collectGarbage runs Luau GC cleanly without disrupting live module (#905)")
    func scriptCollectGarbageRunsCleanly() throws {
        let src = Sources.single("""
        local M = {}
        function M.churn(n)
            local sum = 0
            for i = 1, n do
                local tmp = { i, tostring(i) }
                sum = sum + tmp[1]
            end
            return sum == 20100
        end
        return M
        """)
        let script = Script(name: "gc-rest", sources: src)
        script.prewarm()
        #expect(script.error == nil)
        let r1 = try script.query("churn", args: [LuauData.number(200)])
        #expect(r1 == .bool(true))
        script.collectGarbage()
        let r2 = try script.query("churn", args: [LuauData.number(200)])
        #expect(r2 == .bool(true))
    }
}
