import Testing
import Rune
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
        #expect(OpenCodeProviderIcons.ids.contains("anthropic") && OpenCodeProviderIcons.ids.contains("openai"))
        for id in OpenCodeProviderIcons.ids {
            let data = OpenCodeProviderIcons.providerData(for: id)
            let icon = OpenCodeProviderIcons.named(id)
            #expect(data != nil && icon != nil, "no mark for \(id)")
            if let data, let icon {
                #expect(data.name == id)
                let paints = data.body.contains("currentColor") || data.body.contains("fill=\"#")
                #expect(data.viewBox > 0.0 && icon.viewBox > 0.0 && paints, "\(id) takes the text colour or its own")
                #expect(!data.body.contains("transform") && !data.body.contains("<g"), "\(id) is flat")
            }
        }
        #expect(OpenCodeProviderIcons.named("not-a-provider") == nil)
        #expect(OpenCodeProviderIcons.fallback == OpenCodeProviderIcons.synthetic)
        #expect(OpenCodeProviderIcons.data(named: "synthetic")?.name == "synthetic")
        #expect(!OpenCodeProviderIcons.fallback.paths.isEmpty || OpenCodeProviderIcons.fallback.body != nil)
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

    @Test func multiColorIconsCarryBodyAndRasterizeAndNewIconResolvesByValue() {
        let rustIcon = OpenCodeFileIcons.file("main.rs")
        let vscodeIcon = OpenCodeAppIcons.named("vscode")
        let ai302Icon = OpenCodeProviderIcons.named("302ai")

        #expect(rustIcon.body != nil)
        #expect(vscodeIcon?.body != nil)
        #expect(ai302Icon?.body != nil)
        #expect(vscodeIcon?.isColorIcon == true || ai302Icon?.isColorIcon == true)

        let rasterizer = ColorIconRasterizer()
        if let ai = ai302Icon, ai.isColorIcon {
            let img = rasterizer.rasterize(ai, pixelSize: 32)
            #expect(img != nil)
            #expect(img?.width == 32 && img?.height == 32)
            #expect((img?.mips.first?.rgba.contains(where: { $0 != 0 }) ?? false))
        }
        if let vs = vscodeIcon, vs.isColorIcon {
            let img = rasterizer.rasterize(vs, pixelSize: 32)
            #expect(img != nil)
            #expect((img?.mips.first?.rgba.contains(where: { $0 != 0 }) ?? false))
        }

        #expect(OpenCodeNewIcons.newIcon(OpenCodeIcons.check)?.svgIcon == OpenCodeNewIcons.check)
        #expect(OpenCodeNewIcons.newIcon(OpenCodeNewIcons.check)?.name == "check")
        #expect(OpenCodeNewIcons.newIcon(OpenCodeIcons.flask) == nil)
        #expect(OpenCodeIcons.copy.body != nil)
        #expect(OpenCodeTreeIcons.file("Sources/main.swift").icon.body != nil)
    }
}
