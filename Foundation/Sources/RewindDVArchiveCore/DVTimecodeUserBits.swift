// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Read-only companion interpretation. A usage flag never establishes missing
/// user bytes, a century, a device clock or an LTC/VITC modulation profile.
public enum DVTimecodeUserBits {
  public static func usage(_ timecode: [UInt8], isPAL: Bool) -> UInt8? {
    guard timecode.count == 5 else { return nil }
    let b0 = (timecode[isPAL ? 2 : 3] >> 7) & 1
    let b1 = (timecode[4] >> 6) & 1
    let b2 = (timecode[isPAL ? 3 : 4] >> 7) & 1
    return b0 | b1 << 1 | b2 << 2
  }
  public static func usageFields(_ code: UInt8) -> [DVPackSemanticReport.Field] {
    let labels = ["User data; character set unspecified", "ISO eight-bit character codes",
      "User data; character set unspecified", "Reserved usage and clock reference",
      "Recorded date and time zone", "Page and line multiplex", "Recorded date and time zone", "Page and line multiplex"]
    guard code < 8 else { return [] }
    let ref = "PRIMARY_STANDARD: SMPTE ST 12-1:2014 §8.4, Table 1"
    return [field("BGF_USAGE", "Binary user-data format", code, labels[Int(code)], ref, status: code == 3 ? "reserved" : "interpreted"),
      field("CLOCK_REFERENCE", "Timecode clock reference", code,
        code == 3 ? "Reserved" : [2,6,7].contains(code) ? "Referenced to an external time-of-day clock" : "Clock reference unspecified",
        ref, status: code == 3 ? "reserved" : "interpreted", note: "Recorded flag only; does not establish clock accuracy or the playback deck's clock.")]
  }
  public static func binaryFields(_ bytes: [UInt8], usage: UInt8?) -> [DVPackSemanticReport.Field] {
    guard bytes.count == 5 else { return [] }
    let hex = bytes.dropFirst().reversed().map { String(format:"%02X",$0) }.joined()
    var fields = [field("USER_BITS_HEX", "Recorded user bits", UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24,
      hex, "PRIMARY_STANDARD: SMPTE ST 314M-2005 Table 11; IEC 61834-4:1998 binary-group packs")]
    guard let usage else {
      fields.append(field("USER_BITS_USAGE", "User-bit interpretation", fields[0].rawValue, "Matching timecode usage is absent or conflicting", "Same-frame, same-recording-area association", status:"uninterpreted", note:"No usage selected; original nibbles remain authoritative."))
      return fields
    }
    if usage == 1 {
      let payload = Array(bytes.dropFirst().reversed())
      // ISO 646 invariant characters only. National replacement positions,
      // control shifts, escape sequences and high-byte sets stay unresolved.
      let invariant: (UInt8) -> Bool = { b in
        (0x30...0x39).contains(b) || (0x41...0x5a).contains(b) || (0x61...0x7a).contains(b)
          || b == 0x5f || b == 0x20 || (0x21...0x22).contains(b) || (0x25...0x3f).contains(b)
      }
      let supported = payload.allSatisfy(invariant)
      fields.append(field("USER_BITS_TEXT", "Recorded user text", fields[0].rawValue,
        supported ? "ISO 646 candidate: " + String(bytes:payload,encoding:.ascii)! : "Character-set or control-sequence context required",
        "PRIMARY_STANDARD: SMPTE ST 12-1:2014 §8.4.2; ISO character order BG8/BG7 to BG2/BG1",
        status:"uninterpreted", note:"Candidate uses invariant ISO 646 characters. The recorded usage also permits ISO 2022; its active designation is unknown, so this is not confirmed text."))
    }
    guard usage == 4 || usage == 6 else { return fields }
    let ref = "PRIMARY_STANDARD: SMPTE ST 309:2012 §5, Tables 1–5"
    let zone = bytes[4] & 0x3f, mjd = bytes[4] & 0x80 != 0
    let z = timeZone(zone)
    fields += [field("USER_DATE_FORMAT", "Recorded date format", mjd ? 1:0, mjd ? "Modified Julian date; timecode is UTC" : "Year/month/day; timecode is local time",ref),
      field("USER_TIME_ZONE", "Recorded UTC offset", zone, z.meaning, ref, status:z.status, note:"The recorded offset already includes the applicable effective offset; daylight saving does not add another hour."),
      field("USER_DAYLIGHT_SAVING", "Recorded daylight-saving status", (bytes[4] >> 6)&1, bytes[4]&0x40 == 0 ? "Not in effect":"In effect",ref)]
    func bcd(_ b: UInt8) -> Int? { b&15 < 10 && b>>4 < 10 ? Int(b&15)+10*Int(b>>4):nil }
    guard let a=bcd(bytes[1]),let b=bcd(bytes[2]),let c=bcd(bytes[3]) else {
      fields.append(field("USER_RECORDED_DATE", "Recorded user-bit date", fields[0].rawValue,"Invalid decimal date digits",ref,status:"invalid")); return fields
    }
    if mjd {
      let day = a + b*100 + c*10_000
      var calendar = Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(secondsFromGMT:0)!
      let base=calendar.date(from:DateComponents(year:1858,month:11,day:17))!
      let date=calendar.date(byAdding:.day,value:day,to:base)!
      let parts=calendar.dateComponents([.year,.month,.day],from:date)
      let meaning=String(format:"MJD %d; Gregorian candidate %04d-%02d-%02d",day,parts.year!,parts.month!,parts.day!)
      fields.append(.init(id:"USER_RECORDED_DATE",name:"Recorded user-bit date",rawValue:day,meaning:meaning,status:"interpreted",reference:ref,
        confidence:.conflictingEvidence,qualifier:"ST 309 §5.3 six-digit prose and Annex C example disagree with Table 5 digit constraints. Candidate conversion follows normative prose; the source disagreement remains explicit."))
    } else {
      let maxDays=[31,c%4 == 0 ? 29:28,31,30,31,30,31,31,30,31,30,31]
      let valid=(1...12).contains(b) && a >= 1 && a <= maxDays[max(0,min(11,b-1))]
      fields.append(field("USER_RECORDED_DATE","Recorded user-bit date",fields[0].rawValue,
        valid ? String(format:"Year %02d · month %02d · day %02d",c,b,a):"Invalid recorded month/day",ref,
        status:valid ? "interpreted":"invalid",note:"Two-digit recorded year; no century is inferred. February 29 in year 00 additionally depends on the unknown century."))
    }
    return fields
  }
  public static func timeZone(_ code: UInt8) -> (meaning:String,status:String) {
    let units=Int(code&15),tens=Int(code>>4)
    var minutes: Int?
    if units < 10 && tens <= 2 && tens*10+units <= 25 {
      let n=tens*10+units;minutes=(n <= 12 ? -n:26-n)*60
    } else if (0x0a...0x0f).contains(code) { minutes = -(Int(code-0x0a)*60+30) }
    else if (0x1a...0x1f).contains(code) { minutes = -(Int(code-0x1a)*60+390) }
    else if (0x2a...0x2f).contains(code) { minutes = 690-Int(code-0x2a)*60 }
    else if (0x3a...0x3f).contains(code) { minutes = 330-Int(code-0x3a)*60 }
    else if code == 0x32 { minutes=765 }
    if let minutes { return (String(format:"UTC%@%02d:%02d",minutes < 0 ? "−":"+",abs(minutes)/60,abs(minutes)%60),"interpreted") }
    if code == 0x39 { return ("No time-zone information","unavailable") }
    if code == 0x38 { return ("User-defined offset; profile required","uninterpreted") }
    if (0x28...0x31).contains(code) { return ("Deprecated time-zone code","reserved") }
    return ("Reserved time-zone code","reserved")
  }
  static func field<T: BinaryInteger>(_ id:String,_ name:String,_ raw:T,_ meaning:String,_ reference:String,
    status:String="interpreted",note:String?=nil) -> DVPackSemanticReport.Field {
    .init(id:id,name:name,rawValue:raw,meaning:meaning,status:status,reference:reference,confidence:.normativeConfirmed,qualifier:note)
  }
}
