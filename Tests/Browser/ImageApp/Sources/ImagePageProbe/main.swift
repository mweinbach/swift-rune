import Rune
import RuneRef

struct PageTiles {
    let large: RGBA8Atlas
    let live = Pixels()
}

let width = 1_025
var rgba = [UInt8]()
for _ in 0..<width { rgba.append(contentsOf: [255, 0, 0, 255]) }
let tiles = PageTiles(large: RGBA8Atlas(width: width, height: 1, texels: rgba))
tiles.live.set(width: 2, height: 2, rgba: Array(repeating: [0, 255, 0, 255], count: 4).flatMap { $0 })
var spec = AppSpec<PageTiles>(title: "Independent image pages", size: Vec2(24, 8), state: tiles) { state, _ in
    el().sizeFull().bg(.black)
        .child(image(state.large).absolute(x: 0, y: 0).size(8, 8))
        .child(pixels(state.live).absolute(x: 8, y: 0).size(8, 8))
        .child(image(state.large).absolute(x: 16, y: 0).size(8, 8))
}
spec.onKey = { state, _, _ in
    state.live.set(width: 2, height: 2, rgba: Array(repeating: [0, 0, 255, 255], count: 4).flatMap { $0 })
    return true
}
try RuneApp.run(spec)
