// Read-only real-file report oracle. No driver linked or source writes.
import Foundation
@main struct DVTechnicalSpecificationsRegression {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Provide a saved DV fixture") }
    let report = try DVTechnicalSpecifications.read(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    for section in report.sections {
      print("[\(section.title)]")
      for row in section.rows { print("\(row.label): \(row.value)") }
    }
    print(report.coverage)
  }
}
