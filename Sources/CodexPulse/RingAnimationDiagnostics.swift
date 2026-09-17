import AppKit
import QuartzCore

/// Opt-in regression check against live presentation layers, including the
/// layout jump between one-period and two-period quota cards.
@MainActor
enum RingAnimationDiagnostics {
    static func verify(roots: [NSView], select: (String) -> Void, bucketIDs: [String]) async -> [String: Any] {
        var failures = Set<String>()
        var samples = 0, animatedSamples = 0
        var sizes = Set<Int>()
        var maxCenterDelta: CGFloat = 0
        let ids = Array(bucketIDs.prefix(2))
        for id in ids + ids.reversed() + ids {
            select(id)
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                for root in roots {
                    root.layoutSubtreeIfNeeded()
                    for ring in rings(in: root) {
                        let track = ring.trackLayer.presentation() ?? ring.trackLayer
                        let progress = ring.progressLayer.presentation() ?? ring.progressLayer
                        guard let trackPath = track.path, let progressPath = progress.path else {
                            failures.insert("Missing ring path"); continue
                        }
                        samples += 1
                        sizes.insert(Int(ring.bounds.width.rounded()))
                        let trackBox = trackPath.boundingBoxOfPath
                        let progressBox = progressPath.boundingBoxOfPath
                        let trackCenter = track.convert(CGPoint(x: trackBox.midX, y: trackBox.midY), to: nil)
                        let progressCenter = progress.convert(CGPoint(x: progressBox.midX, y: progressBox.midY), to: nil)
                        let delta = hypot(trackCenter.x - progressCenter.x, trackCenter.y - progressCenter.y)
                        maxCenterDelta = max(maxCenterDelta, delta)
                        if delta > 0.25 { failures.insert("Progress and track centers differ") }
                        if trackBox != progressBox || track.lineWidth != progress.lineWidth {
                            failures.insert("Progress and track geometry differ")
                        }
                        let strokeBox = progressBox.insetBy(dx: -progress.lineWidth / 2, dy: -progress.lineWidth / 2)
                        if !ring.bounds.insetBy(dx: -0.25, dy: -0.25).contains(strokeBox) {
                            failures.insert("Ring stroke exceeds its layout bounds")
                        }
                        if abs(progress.strokeEnd - ring.progressLayer.strokeEnd) > 0.0001 { animatedSamples += 1 }
                    }
                }
            }
        }

        // Boundary behavior must not manufacture a transition for unknown data,
        // leave a dot at zero, or animate when Reduce Motion is enabled.
        let probe = RingDrawingView()
        probe.frame = CGRect(x: 0, y: 0, width: 124, height: 124)
        probe.update(remaining: 100, lineWidth: 7, muted: false, reduceMotion: false)
        if probe.progressLayer.strokeEnd != 1 || probe.progressLayer.animationKeys()?.isEmpty == false {
            failures.insert("Initial reading should render immediately")
        }
        probe.update(remaining: 0, lineWidth: 7, muted: false, reduceMotion: true)
        if probe.progressLayer.strokeEnd != 0 || probe.progressLayer.animationKeys()?.isEmpty == false {
            failures.insert("Reduce Motion should skip progress animation")
        }
        probe.update(remaining: 50, lineWidth: 7, muted: false, reduceMotion: false)
        probe.update(remaining: nil, lineWidth: 7, muted: true, reduceMotion: false)
        if probe.progressLayer.strokeEnd != 0 || probe.progressLayer.animationKeys()?.isEmpty == false {
            failures.insert("Unknown reading should clear progress and animation")
        }
        if samples == 0 { failures.insert("No live ring frames sampled") }
        if sizes != [32, 82, 124] { failures.insert("Did not sample all three ring sizes") }
        return ["passed": failures.isEmpty, "samples": samples, "animatedSamples": animatedSamples,
                "sizes": sizes.sorted(), "maxCenterDelta": maxCenterDelta, "failures": failures.sorted()]
    }

    private static func rings(in view: NSView) -> [RingDrawingView] {
        if let ring = view as? RingDrawingView { return [ring] }
        return view.subviews.flatMap { rings(in: $0) }
    }
}
