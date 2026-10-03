// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "RewindDVFoundation",
  platforms: [.macOS(.v26)],
  products: [.library(name: "RewindDVArchiveCore", targets: ["RewindDVArchiveCore"])],
  targets: [
    .target(name: "RewindDVArchiveCore"),
    .testTarget(name: "RewindDVArchiveCoreTests", dependencies: ["RewindDVArchiveCore"], exclude: ["Fixtures"]),
    .target(name: "RewindDVMonitorCore", dependencies: ["RewindDVArchiveCore"]),
    .testTarget(name: "RewindDVMonitorCoreTests", dependencies: ["RewindDVMonitorCore"]),
    .target(
      name: "RewindDVControlCore", path: "App",
      exclude: ["DVMetadataInspector.swift", "ForensicPrefixView.swift", "MultiPassView.swift", "GentleRecoveryView.swift", "RewindDVSection.swift", "DVFrameForensicsView.swift", "SupportDiagnostics.swift", "DVMetalFieldProcessor.swift", "AcknowledgmentsView.swift", "AutomationStatusSnapshot.swift", "MeterBank.swift", "TapeEvidenceMapView.swift", "WholeTapeCaptureModel.swift", "DVFilmExporter.swift", "DVFilmView.swift", "DVPackMetadataView.swift", "DriverBridge.swift", "DeviceInspectorView.swift", "RewindDVApp.swift", "UnifiedMonitorWorkspace.swift", "ReviewedRangeModel.swift", "ReviewedRangeView.swift", "MonitorVideoSurface.swift", "OfflineDVPlayback.swift", "LiveDVFrameDecoder.swift", "LiveDVPreview.swift", "LiveAudioMonitor.swift", "LiveMonitorModel.swift", "LiveReceiveRing.swift", "LiveReceivePump.swift", "LiveReceiveFlight.swift", "LiveReceiveAtomics.c", "LiveReceiveAtomics.h", "Resources"],
      sources: ["ControlWire.swift", "InspectorWire.swift", "InspectorFlight.swift", "DurableSerialExecutor.swift", "DriverReadiness.swift", "CapabilityWire.swift", "WindStopObserver.swift", "AVCSpecificationCatalog.swift"]),
    .testTarget(name: "RewindDVControlCoreTests", dependencies: ["RewindDVControlCore"]),
    .executableTarget(
      name: "RewindDVInspect", dependencies: ["RewindDVArchiveCore"], path: "Tools/RewindDVInspect"),
  ]
)
