import Foundation

/// Resolve a target once, then run either backend to completion. Cancellation is never a fallback.
public enum AutomaticCapture {
    public static func capture(
        sdk: @Sendable () async throws -> CapturedSnapshot,
        inspector: @Sendable () async throws -> CapturedSnapshot,
        progress: @Sendable (String) async -> Void = { _ in }
    ) async throws -> CapturedSnapshot {
        try Task.checkCancellation()
        let sdkFailure: String
        do {
            let result = try await sdk()
            try Task.checkCancellation()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            sdkFailure = "SDK 不可用，已降级到 ui-inspector：\(error.localizedDescription)"
        }
        await progress("SDK 不可用，使用 ui-inspector 获取界面…")
        try Task.checkCancellation()
        do {
            let result = try await inspector()
            try Task.checkCancellation()
            guard let original = result.snapshot.captureMetadata else { return result }
            let metadata = CaptureMetadata(serial: original.serial, packageName: original.packageName,
                                           startedAt: original.startedAt, finishedAt: original.finishedAt,
                                           includeFacets: original.includeFacets, stableLayout: original.stableLayout,
                                           stableImage: original.stableImage,
                                           diagnostics: [sdkFailure] + original.diagnostics,
                                           baselineJSON: original.baselineJSON, backend: .uiInspector)
            return CapturedSnapshot(snapshot: result.snapshot.withCaptureContext(deviceName: result.snapshot.deviceName, metadata: metadata),
                                    imageData: result.imageData, aligned: result.aligned)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw CommandFailure.failed("\(sdkFailure)\nui-inspector 获取失败：\(error.localizedDescription)")
        }
    }
}
