import Testing
@testable import OpenCodeTheme

@Suite("OpenCode Icons Parity Tests")
struct OpenCodeIconsTests {
    @Test func coreIconsAndNewIconsCountsAndLookups() {
        #expect(OpenCodeIcons.allData.count == 170)
        #expect(OpenCodeIcons.all.count == 170)
        #expect(OpenCodeIcons.data(named: "chevron-down") != nil)
        #expect(OpenCodeIcons.byName("chevron-down") != nil)
        #expect(OpenCodeIcons.byName("does-not-exist") == nil)

        // Existing compatibility aliases still resolve
        #expect(!OpenCodeIcons.chevronDown.paths.isEmpty)
        #expect(!OpenCodeIcons.close.paths.isEmpty)

        #expect(OpenCodeNewIcons.all.count == 71)
        #expect(OpenCodeNewIcons.byName("folder") != nil)
        #expect(OpenCodeNewIcons.byName("missing-icon") == nil)
    }

    @Test func appAndProviderIconsResolve() {
        #expect(OpenCodeAppIcons.all.count == 12)
        #expect(OpenCodeAppIcons.named("vscode") != nil)
        let zedLight = OpenCodeAppIcons.data(named: "zed", dark: false)
        let zedDark = OpenCodeAppIcons.data(named: "zed", dark: true)
        #expect(zedLight != nil && zedDark != nil)
        #expect(zedLight?.name != zedDark?.name)

        #expect(OpenCodeProviderIcons.all.count == 102)
        #expect(OpenCodeProviderIcons.ids.count == 102)
        #expect(!OpenCodeProviderIcons.fallback.paths.isEmpty)
        #expect(OpenCodeProviderIcons.named("openai") != nil)
        #expect(OpenCodeProviderIcons.providerData(for: "anthropic") != nil)
    }

    @Test func fileAndTreeIconsCatalogsAndLookups() {
        #expect(OpenCodeFileIcons.all.count == 314)
        #expect(OpenCodeFileIcons.byFileName("package.json") != nil)
        #expect(OpenCodeFileIcons.byExtension("rs") != nil)
        #expect(OpenCodeFileIcons.byFolderName("src") != nil)

        #expect(!OpenCodeFileIcons.file("Package.swift").paths.isEmpty)
        #expect(!OpenCodeFileIcons.file("main.rs").paths.isEmpty)
        #expect(!OpenCodeFileIcons.file("Dockerfile").paths.isEmpty)
        #expect(!OpenCodeFileIcons.folder("src", expanded: false).paths.isEmpty)
        #expect(!OpenCodeFileIcons.folder("src", expanded: true).paths.isEmpty)

        #expect(OpenCodeTreeIcons.all.count == 52)
        #expect(!OpenCodeTreeIcons.chevron.paths.isEmpty)
        let swiftTreeIcon = OpenCodeTreeIcons.file("Sources/main.swift")
        #expect(!swiftTreeIcon.data.body.isEmpty)
        #expect(swiftTreeIcon.color(dark: true).a > 0)
    }
}
