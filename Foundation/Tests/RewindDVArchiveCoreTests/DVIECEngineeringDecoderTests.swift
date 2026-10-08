import Foundation
import Testing
@testable import RewindDVArchiveCore

/// Original engineering expectations, recorded before running the decoder.
/// Layout provenance is the existing implementation at 0490edaa; arithmetic,
/// Gregorian date constraints, and evidence-status invariants are independently
/// calculated. These tests are not independent normative certification.
@Suite struct DVIECEngineeringDecoderTests {
  private func field(_ bytes: [UInt8], _ id: String,
                     context: DVIEC61834.Context = .init()) throws -> DVPackSemanticReport.Field {
    let decoded = try #require(DVIEC61834.decode(bytes, context: context))
    return try #require(decoded.fields.first { $0.id == id })
  }

  @Test func shutterConversionHasConsistentUnitsAndFiniteResult() throws {
    // Two periods of 64 microseconds are 128 microseconds, independently of
    // the recording format; this is a supplied-profile arithmetic fixture.
    let bytes: [UInt8] = [0x7f, 0xff, 0xff, 0x02, 0x80]
    var context = DVIEC61834.Context()
    context.horizontalPeriodSeconds = 0.000064
    let seconds = try field(bytes, "CONSUMER_SHUTTER", context: context)
    #expect(seconds.rawValue == 2)
    #expect(seconds.meaning == "0.000128 s")
    #expect(seconds.numeric?.unit == "s")
    #expect(seconds.numeric?.rule.contains("SPD * TH") == true)
    context.horizontalPeriodSeconds = .greatestFiniteMagnitude
    let overflow = try field(bytes, "CONSUMER_SHUTTER", context: context)
    #expect(overflow.rawValue == 2)
    #expect(overflow.status == "uninterpreted")
    #expect(!overflow.meaning.contains("inf s"))
    let raw = try field(bytes, "CONSUMER_SHUTTER")
    #expect(raw.numeric?.unit == "horizontal periods")
    #expect(raw.meaning == "2 horizontal periods")
  }

  @Test func missingGenreContextDoesNotEraseUnavailableSentinel() throws {
    for code in UInt8(0)...127 {
      let result = try field([0x06, 0x00, code, 0xff, 0xff], "SUBCATEGORY")
      #expect(result.rawValue == UInt32(code))
      #expect(result.status == (code == 127 ? "unavailable" : "uninterpreted"))
    }
  }

  @Test func programmeCalendarRejectsImpossibleDaysWithoutInventingCentury() throws {
    // Hand-composed binary examples: 20/04/31 and 19/02/29 are impossible;
    // 20/02/29 is possible. Year 00 cannot determine century leap status.
    for bytes: [UInt8] in [[0x42, 0, 0, 0x3f, 0x44], [0x42, 0, 0, 0x3d, 0x32]] {
      #expect(try field(bytes, "PROGRAMME_DAY").status == "invalid")
    }
    for bytes: [UInt8] in [[0x42, 0, 0, 0x3d, 0x42], [0x42, 0, 0, 0x1d, 0x02]] {
      #expect(try field(bytes, "PROGRAMME_DAY").status == "interpreted")
    }
    // Whole calendar boundary classes, including invalid and unavailable years.
    let monthLengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    for year in [0, 19, 20, 99, 100, 127] {
      for month in 1...12 {
        let februaryMayHave29 = year == 0 || year == 20 || year >= 100
        let lastDay = month == 2 && februaryMayHave29 ? 29 : monthLengths[month - 1]
        for day in 0...31 {
          let bytes: [UInt8] = [0x42, 0, 0,
            UInt8(year / 16 * 32 + day), UInt8(year % 16 * 16 + month)]
          let result = try field(bytes, "PROGRAMME_DAY")
          #expect(result.rawValue == UInt32(day))
          #expect(result.status == (day >= 1 && day <= lastDay ? "interpreted" : "invalid"))
        }
      }
    }
  }

  @Test func ambiguousFFPreservesConditionalPaddingValidation() throws {
    // Allocation ambiguity is not resolved by this test. The base-layout
    // condition itself is unambiguous: each padding octet must equal 255.
    for byte in 1...4 {
      for code in UInt8(0)...255 {
        var bytes: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff]
        bytes[byte] = code
        let result = try field(bytes, "NO_INFO_PC\(byte)")
        #expect(result.rawValue == UInt32(code))
        #expect(result.status == "uninterpreted")
        #expect(result.confidence == .conflictingEvidence)
        #expect(result.qualifier?.contains(code == 255
          ? "Base NO INFO padding check: met" : "Base NO INFO padding check: violated") == true)
      }
    }
  }

  @Test func professionalPrecisionDomainsMatchIndependentLinearAnchors() throws {
    // Engineering anchors from the implemented technical definition:
    // pedestal: code zero = -320 mV, midpoint = 0 mV;
    // gamma: code zero = 0.30, midpoint = 0.45;
    // flare: code zero = -64%, midpoint = 0%.
    // Expectations use slope/intercept from those anchors, not decoder output.
    for bits in [8, 10] {
      let midpoint = bits == 8 ? 128 : 512
      let sentinel = midpoint * 2 - 1
      for code in 0...sentinel {
        let octet = UInt8(bits == 8 ? code : code / 4)
        let extensionBits = bits == 8 ? 0x3f : (code % 4) * 21
        let pc4 = UInt8((bits == 8 ? 0xc0 : 0x40) | extensionBits)
        for (header, suffix, intercept, span): (UInt8, String, Double, Double) in [
          (0x75, "PEDESTAL", -320, 320), (0x76, "GAMMA", 0.30, 0.15),
          (0x7c, "FLARE", -64, 64)] {
          let decoded = try #require(DVIEC61834.decode([header, octet, octet, octet, pc4]))
          for channel in ["G", "R", "B"] {
            let result = try #require(decoded.fields.first { $0.id == channel + "_" + suffix })
            #expect(result.rawValue == UInt32(code))
            #expect(result.numeric?.bitWidth == bits)
            #expect(result.status == (code == sentinel ? "unavailable" : "interpreted"))
            if code != sentinel {
              let number = try #require(Double(result.meaning.split(separator: " ")[0]))
              let expected = intercept + Double(code) * span / Double(midpoint)
              #expect(abs(number - expected) < 0.000000001)
            }
          }
        }
      }
    }
  }

  @Test func consumerZoomEntireCodeDomain() throws {
    // Decimal digits define 0.0–7.9, 0x7e is >=8, 0x7f unavailable.
    // Corroboration: JohnstonJ/video-scanner b6a12951 camera_consumer.py,
    // original independent Python implementation, already in source lineage.
    for code in UInt8(0)...127 {
      for enabledBit: UInt8 in [0, 128] {
        let result = try field([0x71, 0xff, 0xff, 0xff, code | enabledBit], "ZOOM_MAGNITUDE")
        #expect(result.rawValue == UInt32(code))
        if code == 127 { #expect(result.status == "unavailable") }
        else if code == 126 {
          #expect(result.numeric?.relation == "atLeast")
          #expect(result.meaning == "≥ 8×")
        } else if code % 16 >= 10 { #expect(result.status == "invalid") }
        else {
          let number = try #require(Double(result.meaning.replacingOccurrences(of: "×", with: "")))
          let tenths = Int(code / 16) * 10 + Int(code % 16)
          #expect(abs(number * 10 - Double(tenths)) < 0.000000001)
        }
      }
    }
  }
}
