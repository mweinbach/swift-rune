import Foundation
import Rune

#if os(WASI)
func logImage(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

// The WASI reactor delivers all three completion callbacks on its single thread.
final class ImageFixtures: @unchecked Sendable {
    var images: [CachedImage] = []
    var wakes = 0

    func completed() {
        wakes += 1
        logImage("image-wake \(wakes)")
        for (index, image) in images.enumerated() where image.isReady {
            switch image.wait(timeout: 0) {
            case .success(let size): logImage("image-ready \(index) \(size.0)x\(size.1)")
            case .failure(let error): logImage("image-failed \(index) \(error)")
            }
        }
    }
}

let fixtures = ImageFixtures()
let cache = ImageCache(wake: { fixtures.completed() })
// A solid 8×4 JPEG and a 5×3 GIF with partial frames and three additional plays.
let jpegData = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAAEAAgDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAABv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAHCP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AAgPXA//2Q==")!
let jpeg = cache.load(jpegData)
let gif = cache.load(Data(base64Encoded: "R0lGODlhBQADAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwEDAAAh+QQFBgAAACwAAAAABQADAAAICwABCBQYYKBBgQEBACH5BA0NAAAALAMAAQABAAEAgQAAAP8AAAD/AAAAAAgEAAUEBAAh+QQFFQAAACwDAAEAAgABAIEAAAD/AAAAAP8AAAAIBQABCAgIADs=")!)
let remote = cache.url("/Tests/Browser/ImageApp/remote.webp", sizePt: 5, scale: 1)
fixtures.images = [jpeg, gif, remote]
logImage("image-initial \(jpeg.isReady) \(gif.isReady) \(remote.isReady) shared=\(jpeg === cache.load(jpegData))")
if case .failure(let pending) = gif.wait(timeout: 0) { logImage("image-pending \(pending)") }

Task {
    let pool = ImageDecodePool()
    do {
        let thumbnail = try await pool.decode(data: jpegData, key: "jpeg-thumbnail", maxDimension: 4)
        logImage("image-async-encoded \(thumbnail.width)x\(thumbnail.height)")
        let url = URL(string: "/Tests/Browser/ImageApp/remote.webp")!
        let remoteThumb = try await pool.loadURL(url, maxDimension: 2)
        logImage("image-async-url \(remoteThumb.width)x\(remoteThumb.height)")
        let reused = try await pool.loadURL(url, maxDimension: 2)
        logImage("image-async-cache \(reused.width)x\(reused.height) entries=\(pool.cachedCount) hits=\(pool.hitCount)")

        let animation = try await pool.loadURL(URL(string: "/Tests/Browser/ImageApp/remote.apng")!, maxDimension: 3)
        // The four APNG canvases have also been verified with FFmpeg.
        let red: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 255]
        let purple: [UInt8] = [127, 0, 128, 255], clear: [UInt8] = [0, 0, 0, 0]
        let yellow: [UInt8] = [255, 255, 0, 128]
        let expected = [red + red + red, red + purple + red, red + red + green, yellow + red + clear]
        let rgba = animation.frames.map { Array($0.rgba) }
        let delays = animation.frames.map { Int(($0.durationSeconds * 1000).rounded()) }
        logImage("image-async-apng \(animation.width)x\(animation.height) frames=\(rgba.count) plays=\(animation.loopCount) rgba=\(rgba == expected) timing=\(delays == [80, 120, 170, 250])")
    } catch { logImage("image-async-error \(error)") }
}

let spec = AppSpec<ImageFixtures>(title: "Browser images", size: Vec2(24, 8), state: fixtures) { state, _ in
    let jpegTile: El<ImageFixtures> = el().size(8, 4).absolute(x: 0, y: 0).pixels(state.images[0].pixels)
    let gifTile: El<ImageFixtures> = el().size(5, 3).absolute(x: 8, y: 0).pixels(state.images[1].pixels)
    let urlTile: El<ImageFixtures> = el().size(5, 3).absolute(x: 16, y: 0).pixels(state.images[2].pixels)
    return el().sizeFull().bg(.black).child(jpegTile).child(gifTile).child(urlTile)
}
try RuneApp.run(spec)

#else
print("Build rune-image-probe for WASI and open the image-wasi browser fixture.")
#endif
