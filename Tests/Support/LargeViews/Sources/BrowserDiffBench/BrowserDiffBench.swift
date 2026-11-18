import LargeViewFixtures
import Rune

@main
enum BrowserDiffBench {
    static func main() throws {
        try App(title: "Diff", size: LargeViewFixtures.diffViewport,
                state: LargeViewFixtures.diffState(), view: LargeViewFixtures.diffView).run()
    }
}
