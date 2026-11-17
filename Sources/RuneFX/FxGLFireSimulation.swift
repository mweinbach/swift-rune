#if canImport(CRuneGL)
import CRuneGL
import Foundation

/// The six stable-fluid passes share the Metal solver's fixed-step plan and field layout.
final class FxGLFireSimulation {
    let planner = FireSim()

    private enum Pass: Int, CaseIterable {
        case curl, forces, divergence, jacobi, project, advect
    }

    private final class Grid {
        var state: [RuneGLPassTarget] = []
        var scalars: [RuneGLPassTarget] = []
        var current = 0

        init(size: SIMD2<UInt32>, renderer: FxGLRenderer) throws {
            do {
                for _ in 0..<2 { state.append(try renderer.target(size, format: RuneGLPassRGBA16F)) }
                for _ in 0..<4 { scalars.append(try renderer.target(size, format: RuneGLPassR32F, linear: false)) }
                // The first Jacobi iteration reads the previous pressure estimate.
                rune_gl_pass_clear(renderer.device, scalars[2], 0, 0, 0, 0)
            } catch {
                close(using: renderer)
                throw error
            }
        }

        func close(using renderer: FxGLRenderer) {
            for i in state.indices { rune_gl_pass_delete_target(renderer.device, &state[i]) }
            for i in scalars.indices { rune_gl_pass_delete_target(renderer.device, &scalars[i]) }
            state.removeAll()
            scalars.removeAll()
        }
    }

    private var grids: [UInt64: Grid] = [:]
    private var programs: [OpaquePointer] = []

    private func makePrograms(using renderer: FxGLRenderer) throws {
        guard programs.isEmpty else { return }
        let vertex = try renderer.shader("quad.vert")
        let source = try renderer.shader("fire-sim.frag")
        do {
            for pass in Pass.allCases {
                let shader = "#define FS_PASS \(pass.rawValue)\n" + source
                programs.append(try FxGLRenderer.checkedPointer {
                    rune_gl_pass_program(renderer.device, vertex, shader, $0, $1)
                })
            }
        } catch {
            releasePrograms(using: renderer)
            throw error
        }
    }

    func step(using renderer: FxGLRenderer) throws {
        let ids = Set((0..<planner.gridCount).map { planner.gridID(at: $0) })
        for id in Array(grids.keys) where !ids.contains(id) {
            grids.removeValue(forKey: id)?.close(using: renderer)
        }
        guard planner.pending else { return }
        try makePrograms(using: renderer)
        for index in 0..<planner.gridCount {
            guard case let .planned(plan) = planner.phase(at: index) else { continue }
            let id = planner.gridID(at: index)
            let grid = try grids[id] ?? Grid(size: plan.gridSize, renderer: renderer)
            grids[id] = grid
            do {
                try encode(plan, grid: grid, using: renderer)
                planner.complete(plan, at: index)
            } catch {
                grids.removeValue(forKey: id)?.close(using: renderer)
                planner.restart(plan, at: index)
                throw error
            }
        }
    }

    private func encode(_ plan: FireSimPlan, grid: Grid, using renderer: FxGLRenderer) throws {
        let curl = grid.scalars[0], div = grid.scalars[1]
        let p0 = grid.scalars[2], p1 = grid.scalars[3]
        var uniform = plan.uniform
        func pass(_ kind: Pass, _ target: RuneGLPassTarget, _ textures: [UInt32]) throws {
            try renderer.draw(programs[kind.rawValue], framebuffer: target.framebuffer, viewport: plan.gridSize,
                              textures: textures, uniforms: uniform, blend: RuneGLPassReplace)
        }
        for k in 0..<plan.steps {
            uniform.origin.z = plan.start.t0 + Float(k + 1) * FireSim.dt
            uniform.origin.w = plan.start.isReset && k == 0 ? 1 : 0
            let x = grid.state[grid.current], y = grid.state[grid.current ^ 1]
            try pass(.curl, curl, [x.texture])
            try pass(.forces, y, [x.texture, curl.texture])
            try pass(.divergence, div, [y.texture])
            var previous = p0, next = p1
            for _ in 0..<FireSim.jacobiIterations {
                try pass(.jacobi, next, [previous.texture, div.texture])
                swap(&previous, &next)
            }
            try pass(.project, x, [y.texture, previous.texture])
            try pass(.advect, y, [x.texture])
            grid.current ^= 1
        }
    }

    func texture(at index: Int) -> UInt32? {
        guard index >= 0, index < planner.gridCount, let grid = grids[planner.gridID(at: index)] else { return nil }
        return grid.state[grid.current].texture
    }

    private func releasePrograms(using renderer: FxGLRenderer) {
        for program in programs { rune_gl_pass_delete_program(renderer.device, program) }
        programs.removeAll()
    }

    func close(using renderer: FxGLRenderer) {
        for grid in grids.values { grid.close(using: renderer) }
        grids.removeAll()
        releasePrograms(using: renderer)
    }
}
#endif
