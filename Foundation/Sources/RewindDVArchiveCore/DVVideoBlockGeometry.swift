// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// DV25 shuffle geometry adapted from DVRescue tools/dvloupe, commit
// 5cead7a5dae4ec7ffdf24115c8e3bc6d9c05c033. BSD-3-Clause attribution and
// full license retained in Foundation/NOTICE.md and ThirdPartyNotices.txt.
import Foundation

/// Location of the nominal macroblock for a video DIF block, not the complete
/// impact footprint: compressed coefficients can borrow space within a segment,
/// and a decoder may conceal errors. No pixel is certified damaged or pristine.
public enum DVVideoBlockGeometry {
  public enum Layout: String, Codable, Sendable {
    case ntsc411, pal420, pal411
    public var isPAL: Bool { self != .ntsc411 }
  }
  public struct Region: Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
  }
  /// Qualified layouts: consumer DV 525/60 4:1:1 and 625/50 4:2:0 only.
  public static func region(sequence: Int, block: Int, pal: Bool) -> Region? {
    region(sequence: sequence, block: block, layout: pal ? .pal420 : .ntsc411)
  }
  public static func region(sequence: Int, block: Int, layout: Layout) -> Region? {
    let pal = layout.isPAL
    let is411 = layout != .pal420
    guard (0..<(pal ? 12 : 10)).contains(sequence), (0..<135).contains(block) else { return nil }
    let slot = block % 5
    let band = ([2,6,8,0,4][slot] + sequence) % (pal ? 12 : 10)
    let column = [2,1,3,0,4][slot]
    let segment = block / 5
    let wide = is411 && (column < 4 || segment < 24)
    let width = wide ? 32 : 16, height = wide ? 8 : 16
    let rows = is411 ? 6 : 3
    let index = segment + (is411 ? (column % 2) * 3 : 0)
    let macroX = index / rows
    let macroY = (macroX % 2 == 0 ? index : index + rows - 1 - (index % rows) * 2) % rows
    return Region(x: column * 144 - (is411 && column % 2 == 1 ? 16 : 0) + (is411 ? 32 : 16) * macroX,
      y: band * 48 + macroY * height, width: width, height: height)
  }
}
