import Testing
import Rune
import RuneKit
@testable import OpenCodeTheme

@Suite("OpenCode Icons Parity Tests")
struct OpenCodeIconsTests {
    @Test func orderedCatalogMatchesUpstreamArtwork() {
        let catalog = OpenCodeIcons.allData
        #expect(catalog.count == 166)
        #expect(Set(catalog.map(\.name)).count == catalog.count)
        #expect(OpenCodeIcons.all == catalog.map(\.svgIcon))

        // FNV-1a over Rust ALL at 935b2ff9, including both NUL terminators and little-endian f32.
        var hash: UInt64 = 0xcbf29ce484222325
        func consume(_ byte: UInt8) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        for icon in catalog {
            #expect(OpenCodeIcons.data(named: icon.name) == icon)
            #expect(OpenCodeIcons.byName(icon.name) == icon.svgIcon)
            #expect(icon.svgIcon.viewBox == icon.viewBox && icon.svgIcon.body == icon.body)
            icon.name.utf8.forEach(consume)
            consume(0)
            for shift in stride(from: 0, to: 32, by: 8) {
                consume(UInt8(truncatingIfNeeded: icon.viewBox.bitPattern >> shift))
            }
            icon.body.utf8.forEach(consume)
            consume(0)
        }
        #expect(hash == 0x2d90912952d75258)
        #expect(OpenCodeIcons.byName("outline-maximize") == OpenCodeIcons.outlineMaximize)
        #expect(OpenCodeIcons.byName("does-not-exist") == nil)
        #expect(!OpenCodeIcons.chevronDown.paths.isEmpty && !OpenCodeIcons.close.paths.isEmpty)
    }

    @Test func aliasesPreserveTheirNamesAndRenderTheirTargets() throws {
        let pairs = [
            ("circle-xmark", OpenCodeIcons.closeData),
            ("outline-browser-annotate", OpenCodeIcons.selectElementData),
            ("arrow-undo-down", OpenCodeIcons.enterData),
            ("file-tree", OpenCodeIcons.folderData),
            ("dash", OpenCodeIcons.minusData),
        ]
        for (name, target) in pairs {
            let alias = try #require(OpenCodeIcons.data(named: name))
            #expect(alias.name == name && alias != target)
            #expect(alias.viewBox == target.viewBox && alias.body == target.body)
            #expect(OpenCodeIcons.byName(name) == target.svgIcon)
            let pixels = GlyphAtlas.rasterizeIconBitmap(alias.svgIcon, pixelSize: 24)
            #expect(pixels.contains { $0 > 0 })
            #expect(pixels == GlyphAtlas.rasterizeIconBitmap(target.svgIcon, pixelSize: 24))
        }
        #expect(OpenCodeIcons.circleXmarkData.name == "circle-xmark")
        #expect(OpenCodeIcons.circleXmark != OpenCodeIcons.circleX)
        #expect(OpenCodeNewIcons.plus == OpenCodeIcons.plus)
        #expect(OpenCodeNewIcons.newIcon(OpenCodeIcons.checkSmall)?.name == "check")
        #expect(OpenCodeNewIcons.newIcon(SVGIcon(paths: [])) == nil)
    }

    @Test func boldCardVariantsRemainAvailableOutsideTheGallery() {
        let variants = [OpenCodeIcons.circleBanSignBoldData, OpenCodeIcons.circleCheckBoldData,
                        OpenCodeIcons.helpBoldData, OpenCodeIcons.warningBoldData, OpenCodeIcons.dashBoldData]
        for variant in variants {
            #expect(variant.body.contains(#"stroke-width="1.5""#))
            #expect(!OpenCodeIcons.allData.contains(variant))
        }
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

        for dark in [true, false] {
            let k = OpenCodeTheme.kit(dark: dark)
            let t = OpenCodeTheme.theme(dark: dark)
            let s = OpenCodeTreeIcons.style(k)
            #expect(s.rowHeight == 28.0)
            #expect(s.indent == 21.5)
            #expect(s.padding == 8.0)
            #expect(s.gap == 6.0)
            #expect(s.radius == 6.0)
            #expect(s.labelFont == TextStyle(size: 12.0, weight: 500.0).lh(28.0))
            #expect(s.labelRest == t["v2-text-text-muted"])
            #expect(s.labelSelected == t["v2-text-text-base"])
            #expect(s.labelFade == 16.0)
            #expect(s.chevronOnly == true)
            #expect(s.chevron == OpenCodeIcons.chevronDown)
            #expect(s.chevronNudge == 1.0)
            #expect(s.chevronRest == t["v2-icon-icon-muted"])
            #expect(s.chevronSelected == t["v2-text-text-base"])
            #expect(s.guidesHover == 0.75)
            #expect(s.hover == t["v2-overlay-simple-overlay-hover"])
            #expect(s.selected == t["v2-overlay-simple-overlay-pressed"])
            let borderMuted = t["v2-border-border-muted"] ?? .transparent
            #expect(abs(s.guide.a - borderMuted.a * 0.5) < 0.0001)
            #expect(s.guide.r == borderMuted.r && s.guide.g == borderMuted.g && s.guide.b == borderMuted.b)

            let folderRow: TreeRowItem<Void> = OpenCodeTreeIcons.item("src", path: "src", folder: true, selected: false, dark: dark)
            #expect(folderRow.labelText == "src")
            #expect(folderRow.iconSVG == nil)
            #expect(folderRow.iconColorValue == nil)

            let unselectedFile: TreeRowItem<Void> = OpenCodeTreeIcons.item("main.rs", path: "src/main.rs", folder: false, selected: false, dark: dark)
            #expect(unselectedFile.labelText == "main.rs")
            #expect(unselectedFile.iconSVG == OpenCodeTreeIcons.file("src/main.rs").icon)
            #expect(unselectedFile.iconColorValue == t["v2-icon-icon-muted"])

            let selectedFile: TreeRowItem<Void> = OpenCodeTreeIcons.item("main.rs", path: "src/main.rs", folder: false, selected: true, dark: dark)
            #expect(selectedFile.iconSVG == OpenCodeTreeIcons.file("src/main.rs").icon)
            #expect(selectedFile.iconColorValue == OpenCodeTreeIcons.file("src/main.rs").color(dark: dark))
        }
    }

    @Test func multiColorIconsCarryBodyAndRasterize() {
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

        #expect(OpenCodeIcons.copy.body != nil)
        #expect(OpenCodeTreeIcons.file("Sources/main.swift").icon.body != nil)
    }
}
