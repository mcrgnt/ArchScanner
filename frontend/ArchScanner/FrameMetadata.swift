import Foundation
import ARKit
import UIKit
import simd

enum FrameMetadataWriter {
    /// ARKit public API gives intrinsics (fx, fy, cx, cy) and pose.
    /// Classic radial/tangential distortion coeffs are NOT exposed on ARCamera.
    static func write(
        frame: ARFrame,
        index: Int,
        fileName: String,
        savedPixelWidth: Int,
        savedPixelHeight: Int,
        appliedOrientation: CGImagePropertyOrientation,
        to folder: URL
    ) {
        let cam = frame.camera
        let intrinsics = cam.intrinsics
        let resolution = cam.imageResolution
        let transform = cam.transform

        let fx = intrinsics[0, 0]
        let fy = intrinsics[1, 1]
        let cx = intrinsics[2, 0]
        let cy = intrinsics[2, 1]

        let adjusted = adjustIntrinsics(
            fx: fx, fy: fy, cx: cx, cy: cy,
            bufferWidth: Int(resolution.width),
            bufferHeight: Int(resolution.height),
            orientation: appliedOrientation
        )

        let exposureDuration = cam.exposureDuration

        var ambientIntensity: Double?
        var ambientColorTemperature: Double?
        if let light = frame.lightEstimate {
            ambientIntensity = light.ambientIntensity
            ambientColorTemperature = light.ambientColorTemperature
        }

        let payload: [String: Any] = [
            "file": fileName,
            "index": index,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "arkitTimestamp": frame.timestamp,
            "trackingState": trackingStateString(cam.trackingState),
            "bufferResolution": [
                "width": Int(resolution.width),
                "height": Int(resolution.height)
            ],
            "savedImage": [
                "width": savedPixelWidth,
                "height": savedPixelHeight,
                "orientationApplied": orientationName(appliedOrientation)
            ],
            "intrinsicsARKit": [
                "fx": fx, "fy": fy, "cx": cx, "cy": cy,
                "matrix3x3_columnMajor": float3x3ToArray(intrinsics)
            ],
            "intrinsicsForSavedImage": [
                "fx": adjusted.fx, "fy": adjusted.fy,
                "cx": adjusted.cx, "cy": adjusted.cy
            ],
            "cameraTransformColumnMajor": float4x4ToArray(transform),
            "exposureDurationSec": exposureDuration,
            "ambientIntensity": ambientIntensity as Any,
            "ambientColorTemperature": ambientColorTemperature as Any,
            "calibrationNotes": [
                "ARKit exposes pinhole intrinsics via ARCamera.intrinsics.",
                "Brown-Conrady / OpenCV distortion coefficients (k1,k2,p1,p2,…) are not available through public ARKit APIs.",
                "IntrinsicsForSavedImage are rotated to match the JPEG after CIImage.oriented(.right)."
            ]
        ]

        let jsonName = (fileName as NSString).deletingPathExtension + ".json"
        let jsonURL = folder.appendingPathComponent(jsonName)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    static func writeSeriesManifest(
        seriesName: String,
        folder: URL,
        frameCount: Int
    ) {
        let device = UIDevice.current
        let payload: [String: Any] = [
            "series": seriesName,
            "frameCount": frameCount,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "device": [
                "name": device.name,
                "model": device.model,
                "systemName": device.systemName,
                "systemVersion": device.systemVersion
            ],
            "distortion": [
                "availableViaARKit": false,
                "detail": "No public radial/tangential distortion coeffs on ARCamera; use intrinsics only or Meshroom self-calibration."
            ]
        ]
        let url = folder.appendingPathComponent("series.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func adjustIntrinsics(
        fx: Float, fy: Float, cx: Float, cy: Float,
        bufferWidth: Int, bufferHeight: Int,
        orientation: CGImagePropertyOrientation
    ) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
        // JPEG is saved after .oriented(.right) == 90° CW relative to buffer.
        switch orientation {
        case .right:
            // 90° CW: (x,y) -> (h-1-y, x)
            return (
                fx: fy,
                fy: fx,
                cx: Float(bufferHeight) - cy,
                cy: cx
            )
        default:
            return (fx, fy, cx, cy)
        }
    }

    private static func float3x3ToArray(_ m: simd_float3x3) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z,
            m.columns.1.x, m.columns.1.y, m.columns.1.z,
            m.columns.2.x, m.columns.2.y, m.columns.2.z
        ]
    }

    private static func float4x4ToArray(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
        ]
    }

    private static func trackingStateString(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .notAvailable: return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited.initializing"
            case .excessiveMotion: return "limited.excessiveMotion"
            case .insufficientFeatures: return "limited.insufficientFeatures"
            case .relocalizing: return "limited.relocalizing"
            @unknown default: return "limited.unknown"
            }
        case .normal: return "normal"
        @unknown default: return "unknown"
        }
    }

    private static func orientationName(_ o: CGImagePropertyOrientation) -> String {
        switch o {
        case .up: return "up"
        case .upMirrored: return "upMirrored"
        case .down: return "down"
        case .downMirrored: return "downMirrored"
        case .leftMirrored: return "leftMirrored"
        case .right: return "right"
        case .rightMirrored: return "rightMirrored"
        case .left: return "left"
        }
    }
}
