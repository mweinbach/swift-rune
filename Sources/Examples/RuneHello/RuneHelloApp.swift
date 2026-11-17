import Rune
@_exported import RuneHelloScene

@main
enum RuneHelloApp {
    static func makeSpec() -> AppSpec<HelloState> { RuneHelloScene.makeSpec() }

    static func main() {
        RuneApp.runOrExit(makeSpec())
    }
}
