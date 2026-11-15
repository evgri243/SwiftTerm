//
//  MetalRowCacheTests.swift
//  SwiftTermTests
//
//  The Metal renderer caches each row's draw data by the buffer line it shows,
//  not by screen row, so a scroll moves rows instead of rebuilding them. These
//  tests pin both halves of that: a row that only moved is placed again, not
//  rebuilt, and what it then draws is bit for bit what a row built from
//  scratch at that position draws, in vertex data and in pixels; and each
//  thing that changes a row's pixels still rebuilds it.
//
//  Parity is checked inside one renderer, against a frame built after
//  `discardRowCache()`, so both frames share one glyph atlas and agree on
//  texture coordinates. Debug builds only: the row counts come from the
//  renderer's debug counters.
//

#if (os(macOS) || os(iOS)) && canImport(MetalKit) && DEBUG
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Metal
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct MetalRowCacheTests {
    nonisolated static var metalIsUsable: Bool {
        MetalTerminalRenderer.shaderLibraryIsAvailable
    }

    /// Lines covering what a row can draw: palette, 256-colour and truecolor
    /// cells, every font face, each underline style, strikethrough, wide and
    /// combining text, color emoji, the custom box/block/Powerline glyphs and
    /// tabs. No BiDi text, so every line is one the cache may move.
    static let corpus: [String] = [
        "plain ascii 0123456789 !@#$%^&*()_+-=[]{};':\",./<>?",
        "\u{1b}[31mred \u{1b}[32mgreen \u{1b}[1;34mbold blue\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[1;3mbold italic\u{1b}[0m \u{1b}[2mdim\u{1b}[0m",
        "\u{1b}[38;5;208mindexed \u{1b}[48;5;22mon green\u{1b}[0m \u{1b}[38;2;250;128;114;48;2;10;20;30mtruecolor\u{1b}[0m \u{1b}[7minverse\u{1b}[0m",
        "\u{1b}[4msingle\u{1b}[0m \u{1b}[4:2mdouble\u{1b}[0m \u{1b}[4:3mcurly\u{1b}[0m \u{1b}[4:4mdotted\u{1b}[0m \u{1b}[4:5mdashed\u{1b}[0m \u{1b}[4;58;2;255;0;0mred\u{1b}[0m \u{1b}[9mstrike\u{1b}[0m",
        "wide 漢字かな 한국어 emoji 😀🎉 combining e\u{301}a\u{308}o\u{302} ✓ ☃",
        "box ┌─┬─┐│├┼┤└┴┘═║╔╗ blocks ▀▄█▌▐░▒▓ powerline \u{e0b0}\u{e0b2}\u{e0b4}\u{e0b6}",
        "\u{1b}[44;37m status \u{1b}[34;42m\u{e0b0}\u{1b}[30m git \u{1b}[0;32m\u{e0b0}\u{1b}[0m tabs\there\tand",
        "\u{1b}[48;2;40;40;40m\u{1b}[K\u{1b}[38;2;200;200;0mfull-width background row\u{1b}[0m",
        "\u{1b}[5mblink\u{1b}[0m \u{1b}[8mhidden\u{1b}[0m \u{1b}[1;4;9;38;5;45mall at once\u{1b}[0m end",
    ]

    /// A line in each DEC line size, which places with a clip and a pivot.
    static let decLines: [String] = [
        "\u{1b}#6double width line",
        "\u{1b}#3double height",
        "\u{1b}#4double height",
    ]

    static let bidiLine = "Hebrew שלום עולם and Arabic مرحبا بالعالم 123"

    /// What one frame drew.
    struct DrawnFrame {
        /// Each row's vertex buffers, as the GPU read them, in screen order.
        var rows: [[UInt8]]
        var pixels: [UInt8]
        var rebuilt: Int
        var cached: Int
        var moved: Int
    }

    /// A view drawn by one renderer into an off-screen layer, never a window.
    @MainActor
    final class Harness {
        let view: TerminalView
        let target: TerminalMetalLayerView
        let renderer: MetalTerminalRenderer

        init?(cols: Int = 64, rows: Int = 12, scrollback: Int = 200, scale: CGFloat = 2) {
            guard MetalRowCacheTests.metalIsUsable,
                  let device = MTLCreateSystemDefaultDevice() else { return nil }
            let frame = CGRect(x: 0, y: 0, width: 640, height: 260)
            view = TerminalView(frame: frame, font: nil,
                                options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
            view.frameDriver.invalidate()
            view.metalScaleFactorOverride = scale
            target = TerminalMetalLayerView(frame: frame)
            target.renderDevice = device
            target.metalLayer.framebufferOnly = false
            target.renderContentsScale = scale
            target.renderDrawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
            guard let renderer = try? MetalTerminalRenderer(target: target) else { return nil }
            renderer.waitForCompletionAfterCommit = true
            renderer.capturesRenderedTexture = true
            renderer.capturesDrawData = true
            self.renderer = renderer
        }

        func setScale(_ scale: CGFloat) {
            view.metalScaleFactorOverride = scale
            target.renderContentsScale = scale
            target.renderDrawableSize = CGSize(width: view.bounds.width * scale,
                                               height: view.bounds.height * scale)
        }

        /// Renders one frame. Sleeps first, so the main run loop turns between
        /// frames: a test drawing many synchronous frames would otherwise hold
        /// the main actor long enough to starve other suites' timers.
        func frame() async -> DrawnFrame? {
            try? await Task.sleep(for: .milliseconds(1))
            guard view.renderSnapshotForMetal(renderer: renderer, target: target),
                  let drawData = renderer.lastDrawData,
                  let texture = renderer.lastRenderedTexture else { return nil }
            let bytesPerRow = texture.width * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
            pixels.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                                 mipmapLevel: 0)
            }
            let rows: [[UInt8]]
            if let frame = drawData.frame {
                rows = [Self.bytes(frame)]
            } else {
                rows = drawData.rows.map(Self.bytes)
            }
            let counts = renderer.debugRowCacheCounts
            return DrawnFrame(rows: rows, pixels: pixels,
                              rebuilt: counts.rebuilt, cached: counts.cached, moved: counts.moved)
        }

        /// Renders the same terminal state again with every row built from
        /// scratch.
        func freshFrame() async -> DrawnFrame? {
            renderer.discardRowCache()
            return await frame()
        }

        private static func append(_ buffer: MTLBuffer?, count: Int, stride: Int, to out: inout [UInt8]) {
            withUnsafeBytes(of: UInt32(count)) { out.append(contentsOf: $0) }
            guard let buffer, count > 0 else { return }
            out.append(contentsOf: UnsafeRawBufferPointer(start: buffer.contents(), count: count * stride))
        }

        private static func append(_ images: [ImageDrawBuffer], to out: inout [UInt8]) {
            withUnsafeBytes(of: UInt32(images.count)) { out.append(contentsOf: $0) }
            for image in images {
                withUnsafeBytes(of: ObjectIdentifier(image.texture).hashValue) { out.append(contentsOf: $0) }
                append(image.buffer, count: image.vertexCount, stride: MemoryLayout<GlyphVertex>.stride, to: &out)
            }
        }

        private static func append<T>(_ values: [T], to out: inout [UInt8]) {
            withUnsafeBytes(of: UInt32(values.count)) { out.append(contentsOf: $0) }
            values.withUnsafeBytes { out.append(contentsOf: $0) }
        }

        private static func append(_ draws: [ImageDraw], to out: inout [UInt8]) {
            withUnsafeBytes(of: UInt32(draws.count)) { out.append(contentsOf: $0) }
            for draw in draws {
                withUnsafeBytes(of: ObjectIdentifier(draw.texture).hashValue) { out.append(contentsOf: $0) }
                append(draw.vertices, to: &out)
            }
        }

        static func bytes(_ row: RowDrawBuffers) -> [UInt8] {
            var out: [UInt8] = []
            append(row.backgroundBuffer, count: row.backgroundCount, stride: MemoryLayout<ColorCell>.stride, to: &out)
            append(row.powerlineJoinBuffer, count: row.powerlineJoinCount, stride: MemoryLayout<ColorCell>.stride, to: &out)
            append(row.glyphGrayBuffer, count: row.glyphGrayCount, stride: MemoryLayout<TextCell>.stride, to: &out)
            append(row.glyphColorBuffer, count: row.glyphColorCount, stride: MemoryLayout<TextCell>.stride, to: &out)
            append(row.decorationBuffer, count: row.decorationCount, stride: MemoryLayout<ColorCell>.stride, to: &out)
            append(row.belowBackgroundImageBuffers, to: &out)
            append(row.underImageBuffers, to: &out)
            append(row.placeholderImageBuffers, to: &out)
            append(row.overImageBuffers, to: &out)
            append(row.otherImageBuffers, to: &out)
            return out
        }

        static func bytes(_ frame: FrameDrawData) -> [UInt8] {
            var out: [UInt8] = []
            append(frame.backgroundCells, to: &out)
            append(frame.powerlineJoinCells, to: &out)
            append(frame.glyphCellsGray, to: &out)
            append(frame.glyphCellsColor, to: &out)
            append(frame.decorationCells, to: &out)
            append(frame.belowBackgroundImageDraws, to: &out)
            append(frame.underImageDraws, to: &out)
            append(frame.placeholderImageDraws, to: &out)
            append(frame.overImageDraws, to: &out)
            append(frame.otherImageDraws, to: &out)
            return out
        }

        var screenRows: Int { view.withTerminal { $0.rows } }
    }

    /// Fills the screen and the scrollback above it, leaving the cursor at
    /// the end of the last line.
    private func fill(_ harness: Harness, lines: [String], count: Int) {
        var text = ""
        for index in 0..<count {
            if index > 0 { text += "\r\n" }
            text += "\(index % 10) " + lines[index % lines.count]
        }
        harness.view.feed(text: text)
    }

    /// Expects `cached` to draw exactly what a fresh build of the same state
    /// draws: the same vertex bytes for every row and the same pixels.
    private func expectParity(_ harness: Harness, with cached: DrawnFrame,
                              sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let fresh = await harness.freshFrame() else {
            Issue.record("no fresh frame", sourceLocation: sourceLocation)
            return
        }
        #expect(fresh.cached == 0, "the fresh frame rebuilt every row", sourceLocation: sourceLocation)
        #expect(cached.rows.count == fresh.rows.count, sourceLocation: sourceLocation)
        let differingRows = zip(cached.rows, fresh.rows).enumerated()
            .filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(differingRows.isEmpty, "rows whose vertex data differs: \(differingRows)",
                sourceLocation: sourceLocation)
        let samePixels = Self.sameBytes(cached.pixels, fresh.pixels)
        let differingBytes = samePixels ? 0
            : zip(cached.pixels, fresh.pixels).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
        #expect(samePixels, "\(differingBytes) pixel bytes differ", sourceLocation: sourceLocation)
    }

    /// A `memcmp`: element-wise comparison of a few megabytes is slow in a
    /// debug build.
    static func sameBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && a.withUnsafeBytes { a in
            b.withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 }
        }
    }

    // MARK: Reuse

    /// Output that scrolls the screen by a line rebuilds only the new line;
    /// every other row moves, and draws what a full rebuild would.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func scrollingOutputMovesRowsInsteadOfRebuildingThem() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus, count: rows + 5)
        let before = try #require(await harness.frame())
        #expect(before.rebuilt == rows)

        harness.view.feed(text: "\r\n" + Self.corpus[3])
        let scrolled = try #require(await harness.frame())
        #expect(scrolled.rebuilt == 1)
        #expect(scrolled.moved == rows - 1)
        #expect(!Self.sameBytes(scrolled.pixels, before.pixels))
        await expectParity(harness, with: scrolled)

        // Several lines in one frame.
        harness.view.feed(text: "\r\n" + Self.corpus[1] + "\r\n" + Self.corpus[4] + "\r\n" + Self.corpus[5])
        let three = try #require(await harness.frame())
        #expect(three.rebuilt == 3)
        #expect(three.moved == rows - 3)
        await expectParity(harness, with: three)
    }

    /// The same once the scrollback is full, when the line leaving the top is
    /// recycled as the new bottom line: the same object, with new contents.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func scrollingAFullScrollbackRebuildsTheRecycledLine() async throws {
        let harness = try #require(Harness(scrollback: 4))
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus, count: rows + 20)
        _ = try #require(await harness.frame())

        harness.view.feed(text: "\r\n" + Self.corpus[2])
        let scrolled = try #require(await harness.frame())
        #expect(scrolled.rebuilt == 1)
        #expect(scrolled.moved == rows - 1)
        await expectParity(harness, with: scrolled)
    }

    /// Scrolling the view through the scrollback moves rows too: only the
    /// lines that come into view are built.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func scrollingTheViewMovesRows() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus, count: rows * 3)
        _ = try #require(await harness.frame())

        harness.view.scrollUp(lines: 3)
        let up = try #require(await harness.frame())
        #expect(up.rebuilt == 3)
        #expect(up.moved == rows - 3)
        await expectParity(harness, with: up)

        harness.view.scrollDown(lines: 3)
        let down = try #require(await harness.frame())
        #expect(down.rebuilt == 3)
        #expect(down.moved == rows - 3)
        await expectParity(harness, with: down)

        harness.view.scrollUp(lines: rows + 2)
        let page = try #require(await harness.frame())
        #expect(page.rebuilt == rows)
        await expectParity(harness, with: page)
    }

    /// A frame with nothing changed reuses every row as it is.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func anUnchangedFrameReusesEveryRow() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus, count: rows)
        let first = try #require(await harness.frame())
        let second = try #require(await harness.frame())
        #expect(second.rebuilt == 0)
        #expect(second.moved == 0)
        #expect(second.cached == rows)
        #expect(second.rows == first.rows)
        #expect(Self.sameBytes(second.pixels, first.pixels))
    }

    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func synchronizedIdenticalRepaintReusesPreparedRows() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        let repaint = (0..<rows).map {
            "\u{1b}[\($0 + 1);1H\u{1b}[2K" + Self.corpus[$0 % Self.corpus.count]
        }.joined()
        harness.view.feed(text: "\u{1b}[?25l" + repaint)
        let first = try #require(await harness.frame())
        for _ in 0..<4 {
            harness.view.feed(text: "\u{1b}[?2026h" + repaint + "\u{1b}[?2026l")
            let repeated = try #require(await harness.frame())
            #expect(repeated.rebuilt == 0)
            #expect(repeated.moved == 0)
            #expect(repeated.cached == rows)
            #expect(repeated.rows == first.rows)
            #expect(Self.sameBytes(repeated.pixels, first.pixels))
            await expectParity(harness, with: repeated)
        }
    }

    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func synchronizedRepaintPreparesOnlyTheChangedSpinnerRow() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        func repaint(_ spinner: String) -> String {
            (0..<rows).map {
                "\u{1b}[\($0 + 1);1H\u{1b}[2K" +
                    ($0 == 0 ? spinner : Self.corpus[$0 % Self.corpus.count])
            }.joined()
        }
        harness.view.feed(text: "\u{1b}[?25l" + repaint("|"))
        _ = try #require(await harness.frame())
        for spinner in ["/", "-", "\\", "|"] {
            harness.view.feed(text: "\u{1b}[?2026h" + repaint(spinner) + "\u{1b}[?2026l")
            let changed = try #require(await harness.frame())
            #expect(changed.rebuilt == 1)
            #expect(changed.cached == rows - 1)
            await expectParity(harness, with: changed)
        }
    }

    /// JLine's inline Compose runner updates live TUI regions via synchronized
    /// `flushStatic` scroll (`\r\n`) plus `CSI M` (delete lines) and `CSI L`
    /// (insert lines), allocating fresh `BufferLine` objects with new
    /// `RenderIdentity` tokens while most rows (including repeated `│...│`
    /// box-drawing borders) keep identical cell contents.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func jlineLineReallocationsReuseContentCachedRowsAndPlainBorders() async throws {
        for mode in [MetalBufferingMode.perRowPersistent, .perFrameAggregated] {
            let harness = try #require(Harness())
            harness.view.metalBufferingMode = mode
            #if os(iOS)
            harness.view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            #else
            harness.view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            #endif
            let rows = harness.screenRows
            func tuiRows(spinner: String, step: Int) -> [String] {
                var result: [String] = []
                result.append("\u{1b}[38;2;95;105;125m┌──────────────────────────────────────────────────┐\u{1b}[0m")
                result.append("\u{1b}[38;2;95;105;125m│\u{1b}[0m \u{1b}[1;36m\(spinner) Thinking\u{1b}[0m step \(step)                           \u{1b}[38;2;95;105;125m│\u{1b}[0m")
                for body in 2..<(rows - 1) {
                    if body % 3 == 0 {
                        result.append("\u{1b}[38;2;95;105;125m│\u{1b}[0m                                                  \u{1b}[38;2;95;105;125m│\u{1b}[0m")
                    } else {
                        result.append("\u{1b}[38;2;95;105;125m│\u{1b}[0m \u{1b}[32m•\u{1b}[0m item \(body) \u{1b}[38;5;214mstatus=ok\u{1b}[0m                        \u{1b}[38;2;95;105;125m│\u{1b}[0m")
                    }
                }
                result.append("\u{1b}[38;2;95;105;125m└──────────────────────────────────────────────────┘\u{1b}[0m")
                return result
            }

            let initial = tuiRows(spinner: "|", step: 1)
            harness.view.feed(text: "\u{1b}[?25l" + initial.enumerated().map {
                "\u{1b}[\($0.offset + 1);1H\u{1b}[2K\($0.element)"
            }.joined())
            let first = try #require(await harness.frame())
            #expect(first.rebuilt == rows)
            // Top border, spinner row, empty bordered rows, and bottom border are pure ASCII + box drawing.
            #expect(harness.renderer.debugPlainRowCount >= 5)

            let beforeIdentities: [ObjectIdentifier] = harness.view.withTerminal { terminal in
                let buffer = terminal.displayBuffer
                return (0..<rows).map { ObjectIdentifier(buffer.lines[buffer.yDisp + $0].renderIdentity) }
            }

            // Simulate JLine deleting & re-inserting all TUI lines (`CSI M` + `CSI L`)
            // and flushing one static history line (`\r\n`) while updating only the spinner row.
            let updated = tuiRows(spinner: "/", step: 2)
            var burst = "\u{1b}[?2026h"
            burst += "\u{1b}[\(rows);1H\r\n"
            burst += "\u{1b}[1;1H\u{1b}[\(rows)M\u{1b}[\(rows)L"
            for (index, line) in updated.enumerated() {
                burst += "\u{1b}[\(index + 1);1H\u{1b}[2K\(line)"
            }
            burst += "\u{1b}[?2026l"
            harness.view.feed(text: burst)

            let afterIdentities: [ObjectIdentifier] = harness.view.withTerminal { terminal in
                let buffer = terminal.displayBuffer
                return (0..<rows).map { ObjectIdentifier(buffer.lines[buffer.yDisp + $0].renderIdentity) }
            }
            #expect(Set(beforeIdentities).isDisjoint(with: Set(afterIdentities)))

            let redrawn = try #require(await harness.frame())
            #expect(redrawn.rebuilt == 1)
            #expect(redrawn.cached == rows - 1)
            await expectParity(harness, with: redrawn)
        }
    }

    /// Content-keyed row caching never serves stale rows across combining-mark,
    /// wide-glyph, SGR, or OSC 8 payload changes, and stays bounded by its LRU cap.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func contentCacheInvalidationHazardsAndLRUCap() async throws {
        let harness = try #require(Harness(scrollback: 500))
        let rows = harness.screenRows

        harness.view.linkHighlightMode = .always
        let baseLines = [
            "combining cafe\u{301} vs cafe\u{300}",
            "wide 東京タワー and 한글",
            "\u{1b}]8;;https://one.example\u{7}linked row\u{1b}]8;;\u{7}",
            "\u{1b}[4:3;58;2;255;80;0munderlined\u{1b}[0m",
        ]
        fill(harness, lines: baseLines, count: rows)
        _ = try #require(await harness.frame())

        // Reallocate row 1..4 via CSI M / CSI L while mutating combining mark, CJK, and link URL.
        let mutated = [
            "0 combining cafe\u{300} vs cafe\u{301}",
            "1 wide 大阪タワー and 한글",
            "2 \u{1b}]8;;https://two.example\u{7}linked row\u{1b}]8;;\u{7}",
            "3 \u{1b}[4:3;58;2;0;180;255munderlined\u{1b}[0m",
        ]
        var update = "\u{1b}[?2026h\u{1b}[1;1H\u{1b}[4M\u{1b}[4L"
        for (i, row) in mutated.enumerated() {
            update += "\u{1b}[\(i + 1);1H\u{1b}[2K\(row)"
        }
        update += "\u{1b}[?2026l"
        harness.view.feed(text: update)
        let afterHazards = try #require(await harness.frame())
        #expect(afterHazards.rebuilt == 4)
        await expectParity(harness, with: afterHazards)

        // Feed > 300 distinct batches of visible frames to exceed the 256-entry cap.
        for batch in 0..<28 {
            var chunk = ""
            for line in 0..<rows {
                chunk += "\r\nunique-lru-row-\(batch)-\(line)-\(batch * 31 + line)"
            }
            harness.view.feed(text: chunk)
            _ = try #require(await harness.frame())
            #expect(harness.renderer.debugContentRowCacheCount <= 256)
        }
        let finalFrame = try #require(await harness.frame())
        #expect(finalFrame.rebuilt == 0)
        await expectParity(harness, with: finalFrame)
    }

    /// A combining mark is the only difference between two rows of the same
    /// width. Rewriting the row with its twin's mark rebuilds it, and rewriting
    /// it back draws the first row again, exactly.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func combiningMarkOnlyDifferenceRebuildsTheRow() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        let accent = "row a e\u{301}x"
        let twin = "row a e\u{302}x"
        fill(harness, lines: [accent], count: rows)
        let before = try #require(await harness.frame())

        func rewriteRow(_ text: String) async throws -> DrawnFrame {
            harness.view.feed(text: "\u{1b}[3;1H\u{1b}[2K2 " + text)
            return try #require(await harness.frame())
        }

        let mark = try await rewriteRow(twin)
        #expect(mark.rebuilt == 1)
        #expect(mark.moved == 0)
        #expect(mark.rows[2] != before.rows[2])
        #expect(mark.rows[1] == before.rows[1])
        await expectParity(harness, with: mark)

        let restored = try await rewriteRow(accent)
        #expect(restored.rebuilt <= 1)
        #expect(restored.rows[2] == before.rows[2])
        await expectParity(harness, with: restored)
    }

    /// One SGR attribute is the only difference between rows of the same text.
    /// Each variant rebuilds its row and draws differently from the one before;
    /// plain text again draws the first row exactly.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func oneAttributeDifferenceRebuildsTheRow() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        let plain = "row b shared"
        let variants = [
            "\u{1b}[38;2;10;200;30m" + plain + "\u{1b}[0m",
            "\u{1b}[38;2;10;200;31m" + plain + "\u{1b}[0m",
            "\u{1b}[1m" + plain + "\u{1b}[0m",
        ]
        fill(harness, lines: [plain], count: rows)
        let before = try #require(await harness.frame())

        func rewriteRow(_ text: String) async throws -> DrawnFrame {
            harness.view.feed(text: "\u{1b}[3;1H\u{1b}[2K2 " + text)
            return try #require(await harness.frame())
        }

        var previous = before
        for variant in variants {
            let frame = try await rewriteRow(variant)
            #expect(frame.rebuilt == 1)
            #expect(frame.rows[2] != previous.rows[2])
            await expectParity(harness, with: frame)
            previous = frame
        }

        let back = try await rewriteRow(plain)
        #expect(back.rebuilt <= 1)
        #expect(back.rows[2] == before.rows[2])
        await expectParity(harness, with: back)
    }

    /// DEC double-width and double-height lines place with a clip rectangle
    /// and a pivot that move with the row.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func decLineSizesMoveExactly() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus + Self.decLines, count: rows + 2)
        _ = try #require(await harness.frame())
        harness.view.feed(text: "\r\n" + Self.decLines[0] + "\r\n" + Self.corpus[0])
        let scrolled = try #require(await harness.frame())
        #expect(scrolled.rebuilt == 2)
        await expectParity(harness, with: scrolled)
    }

    /// A BiDi row's layout depends on its whole paragraph, so it is rebuilt
    /// whenever it moves; the rows around it still move.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func bidiRowsAreRebuiltWhenTheyMove() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus + [Self.bidiLine], count: rows + 4)
        let before = try #require(await harness.frame())
        let bidiRows = harness.view.withTerminal { terminal in
            let buffer = terminal.displayBuffer
            return (0..<rows).filter { screenRow in
                let line = buffer.lines[buffer.yDisp + screenRow]
                return line.translateToString(trimRight: true).contains("שלום")
            }.count
        }
        #expect(bidiRows > 0)
        #expect(before.rebuilt == rows)

        let unchanged = try #require(await harness.frame())
        #expect(unchanged.rebuilt == 0)

        harness.view.feed(text: "\r\n" + Self.corpus[0])
        let scrolled = try #require(await harness.frame())
        #expect(scrolled.rebuilt == 1 + bidiRows)
        #expect(scrolled.moved == rows - 1 - bidiRows)
        await expectParity(harness, with: scrolled)
    }

    /// The per-frame aggregated mode places moved rows the same way, and a
    /// switch between modes keeps drawing the same thing.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func aggregatedModeMovesRowsAndSwitchesCleanly() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        harness.view.metalBufferingMode = .perFrameAggregated
        fill(harness, lines: Self.corpus, count: rows + 5)
        let before = try #require(await harness.frame())

        harness.view.feed(text: "\r\n" + Self.corpus[3])
        let scrolled = try #require(await harness.frame())
        #expect(scrolled.rebuilt == 1)
        #expect(scrolled.moved == rows - 1)
        await expectParity(harness, with: scrolled)

        harness.view.metalBufferingMode = .perRowPersistent
        let persistent = try #require(await harness.frame())
        #expect(persistent.rebuilt == 0)
        #expect(Self.sameBytes(persistent.pixels, scrolled.pixels))
        harness.view.metalBufferingMode = .perFrameAggregated
        let aggregated = try #require(await harness.frame())
        #expect(aggregated.rebuilt == 0)
        #expect(aggregated.rows == scrolled.rows)
        #expect(!Self.sameBytes(aggregated.pixels, before.pixels))
    }

#if os(macOS)
    /// Translucent rows keep their colors after a scroll or an option change.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func translucentBackgroundsKeepCacheParity() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        harness.view.backgroundOpacity = 0.4
        fill(harness, lines: Self.corpus, count: rows * 2)
        _ = try #require(await harness.frame())

        harness.view.translucentCellBackgrounds = true
        let enabled = try #require(await harness.frame())
        #expect(enabled.rebuilt == rows)
        await expectParity(harness, with: enabled)

        harness.view.scrollUp(lines: 2)
        let scrolled = try #require(await harness.frame())
        #expect(scrolled.moved == rows - 2)
        await expectParity(harness, with: scrolled)

        harness.view.backgroundOpacity = 0.6
        let opacity = try #require(await harness.frame())
        #expect(opacity.rebuilt == rows)
        await expectParity(harness, with: opacity)

        harness.view.translucentCellBackgrounds = false
        let disabled = try #require(await harness.frame())
        #expect(disabled.rebuilt == rows)
        await expectParity(harness, with: disabled)
    }
#endif

    // MARK: Invalidation

    /// A cell rewritten in place rebuilds that row only, whether its text or
    /// only its attributes changed.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func contentAndAttributeChangesRebuildOnlyTheirRow() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus, count: rows)
        let before = try #require(await harness.frame())

        harness.view.feed(text: "\u{1b}[5;3HX")
        let text = try #require(await harness.frame())
        #expect(text.rebuilt == 1)
        #expect(text.moved == 0)
        #expect(text.rows[4] != before.rows[4])
        #expect(text.rows[3] == before.rows[3])
        await expectParity(harness, with: text)

        harness.view.feed(text: "\u{1b}[5;3H\u{1b}[38;2;0;200;255;48;5;52mX\u{1b}[0m")
        let attribute = try #require(await harness.frame())
        #expect(attribute.rebuilt == 1)
        #expect(attribute.rows[4] != text.rows[4])
        await expectParity(harness, with: attribute)
    }

    /// The cursor is drawn over the rows, not into them: moving it rebuilds
    /// nothing, and it still draws where it now is.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func movingTheCursorRebuildsNoRow() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus, count: rows)
        let before = try #require(await harness.frame())

        harness.view.feed(text: "\u{1b}[3;10H")
        let moved = try #require(await harness.frame())
        #expect(moved.rebuilt == 0)
        #expect(moved.moved == 0)
        #expect(moved.rows == before.rows)
        #expect(!Self.sameBytes(moved.pixels, before.pixels))
        await expectParity(harness, with: moved)
    }

    /// A selection rebuilds the rows it covers and no others, and a selected
    /// row keeps its highlight as it scrolls.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func selectionRebuildsTheRowsItCovers() async throws {
        let harness = try #require(Harness())
        let rows = harness.screenRows
        fill(harness, lines: Self.corpus, count: rows + 3)
        let before = try #require(await harness.frame())
        let top = harness.view.withTerminal { $0.displayBuffer.yDisp }

        harness.view.selection.setSelection(start: Position(col: 4, row: top + 2),
                                            end: Position(col: 12, row: top + 3))
        let selected = try #require(await harness.frame())
        #expect(selected.rebuilt == 2)
        #expect(selected.rows[2] != before.rows[2])
        #expect(selected.rows[1] == before.rows[1])
        await expectParity(harness, with: selected)

        harness.view.feed(text: "\r\n" + Self.corpus[0])
        let scrolled = try #require(await harness.frame())
        #expect(scrolled.rebuilt == 1)
        await expectParity(harness, with: scrolled)

        harness.view.selection.selectNone()
        let cleared = try #require(await harness.frame())
        #expect(cleared.rebuilt == 2)
        await expectParity(harness, with: cleared)
    }

    /// A new font, scale, palette, contrast ratio or terminal size changes
    /// every row.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func frameWideChangesRebuildEveryRow() async throws {
        let harness = try #require(Harness())
        fill(harness, lines: Self.corpus, count: harness.screenRows + 2)
        _ = try #require(await harness.frame())

        harness.view.font = TTFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let font = try #require(await harness.frame())
        #expect(font.rebuilt == font.rows.count)
        await expectParity(harness, with: font)

        harness.setScale(1)
        let scale = try #require(await harness.frame())
        #expect(scale.rebuilt == scale.rows.count)
        await expectParity(harness, with: scale)

        harness.view.nativeForegroundColor = .systemOrange
        let color = try #require(await harness.frame())
        #expect(color.rebuilt == color.rows.count)
        await expectParity(harness, with: color)

        harness.view.minimumContrastRatio = 4.5
        let contrast = try #require(await harness.frame())
        #expect(contrast.rebuilt == contrast.rows.count)
        await expectParity(harness, with: contrast)

        harness.view.withTerminal { $0.resize(cols: 50, rows: 10) }
        let size = try #require(await harness.frame())
        #expect(size.rebuilt == size.rows.count)
        #expect(size.rows.count == 10)
        await expectParity(harness, with: size)
    }

    /// Custom box, block and Powerline glyphs are drawn by the renderer, so
    /// turning them off or on must reach rows that did not otherwise change.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func customGlyphSettingsRebuildEveryRow() async throws {
        let harness = try #require(Harness())
        fill(harness, lines: Self.corpus, count: harness.screenRows)
        let before = try #require(await harness.frame())

        harness.view.customBlockGlyphs = false
        let fontGlyphs = try #require(await harness.frame())
        #expect(fontGlyphs.rebuilt == fontGlyphs.rows.count)
        #expect(!Self.sameBytes(fontGlyphs.pixels, before.pixels))
        await expectParity(harness, with: fontGlyphs)

        harness.view.customBlockGlyphs = true
        harness.view.antiAliasCustomBlockGlyphs = true
        let antiAliased = try #require(await harness.frame())
        #expect(antiAliased.rebuilt == antiAliased.rows.count)
        await expectParity(harness, with: antiAliased)
    }
}
#endif
