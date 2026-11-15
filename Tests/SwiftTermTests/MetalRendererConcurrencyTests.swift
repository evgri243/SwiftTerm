//
//  MetalRendererConcurrencyTests.swift
//  SwiftTermTests
//
//  Covers the checked state captured by Metal completion and timer callbacks.
//

#if (os(macOS) || os(iOS)) && canImport(MetalKit)
import Foundation
import Metal
import MetalKit
import QuartzCore
import Testing
#if os(iOS)
import UIKit
#endif
@testable import SwiftTerm

@Suite("Metal renderer concurrency", .serialized)
struct MetalRendererConcurrencyTests {
    private func requireSendable<T: Sendable>(_: T.Type) {}

    @Test func redrawStateIsCheckedSendableAndConsumesPendingOnce() {
        requireSendable(MetalRedrawState.self)
        let redraws = Locked(0)
        let state = MetalRedrawState()
        state.configure {
            redraws.withLock { $0 += 1 }
        }

        state.markPendingRedraw()
        #expect(state.consumePendingRedraw())
        #expect(!state.consumePendingRedraw())
        state.requestRedraw()
        #expect(redraws.withLock { $0 } == 1)
    }

    @Test @MainActor func cursorBlinkControllerOwnsTimerOnMainActor() {
        let redraws = Locked(0)
        let state = MetalRedrawState()
        state.configure {
            redraws.withLock { $0 += 1 }
        }
        let controller = MetalCursorBlinkController(redrawState: state,
                                                    interval: 0.01)

        #expect(state.setCursorBlinkWanted(true))
        controller.apply(shouldBlink: true)
        #expect(controller.isRunning)
        // Wait for the first timer fire; a fixed short wait races the scheduler under load.
        let deadline = Date().addingTimeInterval(10)
        while redraws.withLock({ $0 }) == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(redraws.withLock { $0 } > 0)

        let redrawCount = redraws.withLock { $0 }
        controller.resetAfterInput()
        #expect(state.cursorBlinkOn)
        #expect(controller.isRunning)
        #expect(redraws.withLock { $0 } == redrawCount + 1)

        #expect(state.setCursorBlinkWanted(false))
        controller.apply(shouldBlink: false)
        #expect(!controller.isRunning)
        #expect(state.cursorBlinkOn)
    }

    @Test func bufferRecyclerRetainsAndReturnsCompletedBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let buffer = device.makeBuffer(length: 4_096,
                                              options: .storageModeShared) else {
            return
        }
        let recycler = MetalTerminalRenderer.MetalBufferRecycler()
        requireSendable(MetalTerminalRenderer.MetalBufferRecycler.self)

        let batchID = try #require(recycler.retainUntilCompletion([buffer]))
        #expect(recycler.pendingBatchCount == 1)
        #expect(recycler.take(length: buffer.length) == nil)

        recycler.complete(batchID: batchID)
        #expect(recycler.pendingBatchCount == 0)
        let returned = try #require(recycler.take(length: buffer.length))
        #expect(returned === buffer)
    }

    @Test @MainActor func borrowedBufferAndDataFeedsParseSynchronouslyWithoutRetainingStorage() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 120),
                                font: nil,
                                options: TerminalOptions(cols: 40, rows: 6, scrollback: 20))
        defer { _ = view.updateUiClosed() }
        view.resetDiagnostics()

        var scratch = Array("borrowed-\u{1b}[32mok\u{1b}[0m\r\n".utf8)
        let firstCount = scratch.count
        scratch.withUnsafeMutableBytes { raw in
            view.feed(buffer: UnsafeRawBufferPointer(raw))
            // Overwrite immediately to prove `feed(buffer:)` kept no reference.
            for index in raw.indices {
                raw[index] = UInt8(ascii: "X")
            }
        }

        let secondData = Data("second-line-漢字\r\n".utf8)
        let sender = view.feedSender
        let backgroundDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            sender.feed(data: secondData)
            backgroundDone.signal()
        }
        #expect(backgroundDone.wait(timeout: .now() + 5) == .success)

        // Also exercise the nonisolated view wrapper and ignore empty buffers.
        view.feed(data: Data("third-line\r\n".utf8))
        view.feed(data: Data())

        let snapshot = view.terminalStateSnapshot()
        #expect(snapshot.visibleRows[0].text.hasPrefix("borrowed-ok"))
        #expect(snapshot.visibleRows[1].text.hasPrefix("second-line-漢字"))
        #expect(snapshot.visibleRows[2].text.hasPrefix("third-line"))
        let current = view.diagnosticsState.withLock { $0 }
        #expect(current.bytesFed == firstCount + secondData.count + "third-line\r\n".utf8.count)
        #expect(current.batches == 3)
    }

#if os(iOS)
    @MainActor
    private func pumpMainRunLoop(until timeout: TimeInterval = 2.0,
                                 displayTick: (() -> Void)? = nil,
                                 condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            // The hostless test process has no running display link. A frame
            // refused because the previous command buffer is still in flight
            // is retried by the next display tick, so stand in for it here.
            displayTick?()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    @Test @MainActor func iosWindowAttachStartsRenderLoopAndSurvivesDetachReattachAndClose() throws {
        guard MetalTerminalRenderer.shaderLibraryIsAvailable else { return }
        let frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        let window1 = UIWindow(frame: frame)
        let window2 = UIWindow(frame: frame)
        window1.isHidden = false
        window2.isHidden = false

        let view = TerminalView(frame: frame,
                                font: nil,
                                options: TerminalOptions(cols: 48, rows: 10, scrollback: 100))
        #expect(view.usesMetalLayerSurface)
        #expect(!view.isUsingRenderLoop)

        window1.addSubview(view)
        view.layoutIfNeeded()
        try view.setUseMetal(true)
        #expect(view.isUsingMetalRenderer)
        #expect(view.isUsingRenderLoop)
        #expect(view.metalView is TerminalMetalLayerView)

        view.resetDiagnostics()
        view.feed(data: Data("frame-one\r\n".utf8))
        view.frameTick()
        #expect(pumpMainRunLoop(displayTick: { view.frameTick() }) {
            view.renderOwner.completedMetalRenders > 0 &&
                (view.renderLoop?.currentCounters.frames ?? 0) > 0
        })

        // Simulate switching tabs (detaching and reattaching to the same and another window).
        for cycle in 0..<3 {
            view.removeFromSuperview()
            #expect(!view.isUsingRenderLoop)
            view.feed(data: Data("while-detached-\(cycle)\r\n".utf8))

            let targetWindow = cycle.isMultiple(of: 2) ? window1 : window2
            targetWindow.addSubview(view)
            view.layoutIfNeeded()
            #expect(view.isUsingRenderLoop)
            let beforeRenders = view.renderOwner.completedMetalRenders
            view.feed(data: Data("while-attached-\(cycle)\r\n".utf8))
            view.frameTick()
            #expect(pumpMainRunLoop(displayTick: { view.frameTick() }) {
                view.renderOwner.completedMetalRenders > beforeRenders
            })
        }

        #expect(view.updateUiClosed())
        #expect(!view.isUsingRenderLoop)
        #expect(!view.isUsingMetalRenderer)
    }

    @Test @MainActor func iosMetalSurfaceFallbackAndScaleOverrideWork() throws {
        guard MetalTerminalRenderer.shaderLibraryIsAvailable else { return }
        let frame = CGRect(x: 0, y: 0, width: 300, height: 160)
        let window = UIWindow(frame: frame)
        window.isHidden = false
        let view = TerminalView(frame: frame,
                                font: nil,
                                options: TerminalOptions(cols: 40, rows: 8, scrollback: 50))
        defer { _ = view.updateUiClosed() }
        window.addSubview(view)
        view.layoutIfNeeded()

        try view.setUseMetal(true)
        #expect(view.isUsingRenderLoop)

        view.metalScaleFactorOverride = 3
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.metalView?.renderContentsScale == 3)
        #expect(view.metalView?.renderDrawableSize == CGSize(width: 900, height: 480))

        // Toggle to MTKView fallback (`SWIFTTERM_METAL_LAYER=0` equivalent) and back.
        try view.setUsesMetalLayerSurface(false)
        #expect(view.isUsingMetalRenderer)
        #expect(!view.isUsingRenderLoop)
        #expect(view.metalView is MTKView)

        try view.setUsesMetalLayerSurface(true)
        #expect(view.isUsingMetalRenderer)
        #expect(view.isUsingRenderLoop)
        #expect(view.metalView is TerminalMetalLayerView)
        #expect(view.metalView?.renderContentsScale == 3)
    }

    @Test @MainActor func iosDisplayLinkUsesProMotionAndSuppressesProgrammaticScrollDirtying() async throws {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        let window = UIWindow(frame: frame)
        window.isHidden = false
        let view = TerminalView(frame: frame,
                                font: nil,
                                options: TerminalOptions(cols: 40, rows: 6, scrollback: 100))
        defer { _ = view.updateUiClosed() }
        window.addSubview(view)
        view.layoutIfNeeded()

        if #available(iOS 15.0, *) {
            let range = try #require(view.frameDriver.preferredFrameRateRange)
            #expect(range.minimum == 60)
            #expect(range.maximum == 120)
            #expect(range.preferred == 120)
        }

        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        driver.nowUptimeNs = { 1 }
        driver.onTick = { [weak view] in view?.frameTick() }
        driver.setWindowAttachedOnMain(true)
        view.frameDriver.shutdown()
        view.frameDriver = driver

        for line in 0..<25 {
            view.feed(text: "line-\(line)\r\n")
        }
        driver.markDirty()
        await Task.yield()
        source.tick()
        let framesAfterOutput = driver.currentCounters.frames
        #expect(framesAfterOutput >= 1)

        // Programmatic scroller sync must not re-dirty the frame driver.
        view.updateScroller()
        await Task.yield()
        source.tick()
        #expect(driver.currentCounters.frames == framesAfterOutput)
        #expect(view.contentOffset.y > 0)

        // Direct contentOffset scroll still marks the frame driver dirty itself.
        view.contentOffset = .zero
        await Task.yield()
        source.tick()
        #expect(driver.currentCounters.frames == framesAfterOutput + 1)
    }

    @Test @MainActor func iosAccessibilityLayoutChangedPostsOnlyWhenVoiceOverRuns() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 300, height: 120),
                                font: nil,
                                options: TerminalOptions(cols: 40, rows: 6, scrollback: 20))
        defer {
            voiceOverRunningForTesting = nil
            accessibilityLayoutChangedObserverForTesting = nil
            _ = view.updateUiClosed()
        }

        var posted = 0
        accessibilityLayoutChangedObserverForTesting = { posted += 1 }

        voiceOverRunningForTesting = { false }
        view.applyFrameSideEffects(MainFrameEffects(
            rangeChanged: nil,
            notifyAccessibility: true,
            scrollPosition: 0))
        #expect(posted == 0)

        voiceOverRunningForTesting = { true }
        view.applyFrameSideEffects(MainFrameEffects(
            rangeChanged: nil,
            notifyAccessibility: true,
            scrollPosition: 0))
        #expect(posted == 1)
    }
#endif
}
#endif
