// OFFLINE READ-ONLY. No app/driver/hardware linkage. User-provided saved DV only.
import CryptoKit
import Foundation

@main struct RecordedClockRegression {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      fatalError("Usage: RecordedClockRegression /saved/capture.dv 'expected date and time'")
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let before = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
    let report = try DVTechnicalSpecifications.read(url: url)
    precondition(report.validRecordedDate?.value == CommandLine.arguments[2])
    let after = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
    precondition(before == after)
    print("RECORDED_CLOCK_READ_ONLY_PASS \(report.validRecordedDate!.value)")
    print(report.validRecordedDate!.evidence)
  }
}
