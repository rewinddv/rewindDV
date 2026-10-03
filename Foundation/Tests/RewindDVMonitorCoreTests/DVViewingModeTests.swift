import Testing
@testable import RewindDVMonitorCore

@Test func displayAspectOnlyOffersStandardAndWidescreen() {
  #expect(DVDisplayAspect.allCases.map(\.rawValue) == ["4:3", "16:9"])
  #expect(DVDisplayAspect.standard.ratio == 4.0 / 3.0)
  #expect(DVDisplayAspect.widescreen.ratio == 16.0 / 9.0)
  for reported in [4.0 / 3.0, 1.36] {
    #expect(DVDisplayAspect.initial(reportedRatio: reported) == .standard)
  }
  for reported in [16.0 / 9.0, 1.82] {
    #expect(DVDisplayAspect.initial(reportedRatio: reported) == .widescreen)
  }
  for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
    #expect(DVDisplayAspect.initial(reportedRatio: invalid) == .standard)
  }
}

@Test func fieldInspectionRowsAreBoundedAndParitySpecific() {
  for height in [480, 576] {
    for row in 0..<height {
      #expect(DVViewingMode.weave.sourceRow(for: row, height: height) == row)
      #expect(DVViewingMode.top.sourceRow(for: row, height: height) % 2 == 0)
      #expect(DVViewingMode.bottom.sourceRow(for: row, height: height) % 2 == 1)
      #expect(DVViewingMode.bottom.sourceRow(for: row, height: height) < height)
    }
  }
  #expect(DVViewingMode.allCases.count == 5)
  #expect(DVViewingMode.blend.explanation.contains("No cadence removal"))
  #expect(DVViewingMode.top.explanation.contains("Not a claim about temporal field order"))
}
