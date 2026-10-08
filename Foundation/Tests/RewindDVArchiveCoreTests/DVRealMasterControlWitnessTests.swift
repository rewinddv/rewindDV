// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import RewindDVArchiveCore

/// Original byte-level regression witnesses. These preserve the unresolved
/// difference between real recordings and the inherited fixed-bit interpretation;
/// they do not establish either producer nonconformance or new normative facts.
@Suite struct DVRealMasterControlWitnessTests {
  @Test func recordedVAUXDiscrepancyRemainsIndependentOfOtherFields() throws {
    for pal in [false, true] {
      for mic in [false, true] {
        for professional in [false, true] {
          var context = DVIEC61834.Context()
          context.isPAL = pal; context.mic = mic; context.professionalCamera = professional
          for bytes: [UInt8] in [[0x61,0x03,0x82,0xfc,0xff], [0x61,0x3f,0x01,0xfc,0xff]] {
            let snapshot = bytes
            let decoded = try #require(DVIEC61834.decode(bytes, context: context))
            for (id, bit) in [("PC2_FIXED6",6),("PC2_FIXED3",3)] {
              let field = try #require(decoded.fields.first { $0.id == id })
              let layout = try #require(decoded.layout.first { $0.id == id })
              #expect(layout.slices == [.init(2,bit,1)])
              #expect(layout.fixed == 1)
              #expect(field.rawValue == 0)
              #expect(field.status == "invalid") // inherited conditional check, not media damage
            }
            #expect(decoded.fields.first { $0.id == "REC_M" }?.rawValue == 0)
            #expect(decoded.fields.first { $0.id == "REC_M" }?.status == "interpreted")
            #expect(decoded.fields.first { $0.id == "DISP" }?.rawValue == UInt32(bytes[2] & 7))
            #expect(decoded.fields.first { $0.id == "BCS" }?.rawValue == 0)
            #expect(bytes == snapshot)
          }
        }
      }
    }
  }

  @Test func everyPC2ValueKeepsFixedBitsSeparateFromRecordingModeAndDisplay() throws {
    for pc2 in UInt8.min...UInt8.max {
      let decoded = try #require(DVIEC61834.decode([0x61,0x03,pc2,0xfc,0xff]))
      for (id,bit) in [("PC2_FIXED6",6),("PC2_FIXED3",3)] {
        let f = try #require(decoded.fields.first { $0.id == id })
        let independent = UInt32((Int(pc2) / (1 << bit)) % 2)
        #expect(f.rawValue == independent)
        #expect(f.status == (independent == 1 ? "interpreted":"invalid"))
      }
      let mode = try #require(decoded.fields.first { $0.id == "REC_M" })
      #expect(mode.rawValue == UInt32((Int(pc2) / 16) % 4))
      #expect(mode.status == (["interpreted","reserved","interpreted","invalid"][Int(mode.rawValue)]))
      #expect(decoded.fields.first { $0.id == "DISP" }?.rawValue == UInt32(Int(pc2) % 8))
    }
  }

  @Test func recordingInvalidAAUXWitnessIsARecordedIndicator() throws {
    let bytes: [UInt8] = [0x51,0x03,0xff,0xa0,0xff]
    for pal in [false,true] {
      var context = DVIEC61834.Context(); context.isPAL = pal
      let decoded = try #require(DVIEC61834.decode(bytes,context:context))
      let mode = try #require(decoded.fields.first { $0.id == "REC_M" })
      #expect(mode.rawValue == 7)
      #expect(mode.status == "invalid")
      #expect(mode.meaning == "Recording marked invalid")
      #expect(decoded.fields.first { $0.id == "SPD" }?.rawValue == 32)
      #expect(decoded.fields.first { $0.id == "DRF" }?.rawValue == 1)
      #expect(bytes == [0x51,0x03,0xff,0xa0,0xff])
    }
  }
}
