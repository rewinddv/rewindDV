import Foundation

/// Viewing geometry only; never changes source packs, raster bytes or exports.
public enum DVDisplayAspect: String, CaseIterable, Sendable, Identifiable {
  case standard = "4:3"
  case widescreen = "16:9"
  public var id: String { rawValue }
  public var ratio: Double { self == .standard ? 4.0 / 3.0 : 16.0 / 9.0 }
  public static func initial(reportedRatio: Double) -> Self {
    guard reportedRatio.isFinite, reportedRatio > 0 else { return .standard }
    return abs(reportedRatio - widescreen.ratio) < abs(reportedRatio - standard.ratio)
      ? .widescreen : .standard
  }
}

/// Presentation only. Never used by ingest, reconstruction or recovery.
public enum DVViewingMode: String, CaseIterable, Sendable, Identifiable {
  case standard = "Standard (Apple)"
  case weave = "Weave (both fields)"
  case top = "Top field"
  case bottom = "Bottom field"
  case blend = "Deinterlaced (vertical blend)"

  public var id: String { rawValue }
  public var shaderMode: UInt32 {
    switch self { case .standard, .weave: 0; case .top: 1; case .bottom: 2; case .blend: 3 }
  }
  public var explanation: String {
    switch self {
    case .standard: "Apple presentation. No field-preservation claim. Original DV is unchanged."
    case .weave: "Both decoded fields woven without a vertical filter. Motion may show combing. Original DV is unchanged."
    case .top: "Even raster rows, line-doubled for inspection. Not a claim about temporal field order. Original DV is unchanged."
    case .bottom: "Odd raster rows, line-doubled for inspection. Not a claim about temporal field order. Original DV is unchanged."
    case .blend: "Display-only ¼–½–¼ vertical filter at frame rate. Softer detail; motion can ghost. No cadence removal or motion-adaptive processing."
    }
  }
  public func sourceRow(for row: Int, height: Int) -> Int {
    guard height > 0 else { return 0 }
    let row = min(max(0, row), height - 1)
    switch self {
    case .top: return row / 2 * 2
    case .bottom: return min(height - 1, row / 2 * 2 + 1)
    default: return row
    }
  }
}
