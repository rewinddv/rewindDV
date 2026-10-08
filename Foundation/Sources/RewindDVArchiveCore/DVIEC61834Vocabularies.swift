// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

extension DVIEC61834 {
  // Code labels, independently phrased for presentation. These do not implement
  // the referenced character encodings or identify people depicted on tape.
  static let textCodeLabels: [Int:String] = [
    0x40:"US mosaic",0x41:"US supplementary",0x42:"US primary",0x43:"Korean two-byte",
    0x44:"Korean one-byte",0x46:"Korean roman",0x4a:"Japanese roman",0x4b:"Japanese two-byte",
    0x4c:"Hiragana",0x4d:"Katakana",0x4e:"Mosaic A",0x4f:"Mosaic B",0x50:"Mosaic C",0x51:"Mosaic D",
    0x52:"Latin primary 1",0x53:"Latin supplementary 1",0x54:"Block mosaic",0x55:"Smoothed mosaic",
    0x56:"Arabic primary",0x57:"Arabic supplementary",0x58:"Cyrillic primary",0x59:"Cyrillic supplementary",
    0x5a:"Greek primary",0x5b:"Greek supplementary",0x5c:"Hebrew primary",0x5d:"Hebrew supplementary",
    0x68:"Latin primary 2",0x69:"Latin supplementary 2",0x6a:"Latin primary 3",0x6b:"Latin supplementary 3",
    0x6c:"Cyrillic/Latin primary",0x6d:"Latin primary 4",0x6e:"Latin supplementary 4",
    0x6f:"Yugoslav Latin primary",0x70:"Yugoslav Latin supplementary"]
  /// Initial ISO-2022 designations from §3.9. These identify sets; they do not
  /// invent glyph tables from the external character standards.
  public static func characterSets(code: UInt8, option: UInt8) -> [String: UInt8]? {
    let rows: [UInt8:[UInt8]] = [
      0x40:[0x42,0x40,0x41,0x40,0x40,0x42], 0x41:[0x42,0x40,0x41,0x40,0x41,0x42],
      0x42:[0x42,0x40,0x41,0x40,0x42,0x41], 0x43:[0x43,0x46,0x41,0x40,0x43,0x41],
      0x44:[0x43,0x46,0x41,0x44,0x43,0x44], 0x46:[0x43,0x46,0x41,0x40,0x46,0x43],
      0x4a:[0x4b,0x4a,0x4c,0x4d,0x4a,0x4b], 0x4b:[0x4b,0x4a,0x4c,0x4d,0x4b,0x4c],
      0x4c:[0x4b,0x4a,0x4c,0x4d,0x4c,0x4b], 0x4d:[0x4b,0x4a,0x4c,0x4d,0x4d,0x4b],
      0x4e:[0x4b,0x4e,0x4c,0x4d,0x4e,0x4b], 0x4f:[0x4b,0x4f,0x4c,0x4d,0x4f,0x4b],
      0x50:[0x4e,0x4f,0x50,0x51,0x50,0x4f], 0x51:[0x4e,0x4f,0x50,0x51,0x51,0x4f],
      0x52:[0x52,0x54,0x53,0x55,0x52,0x53], 0x53:[0x52,0x54,0x53,0x55,0x53,0x52],
      0x54:[0x52,0x54,0x53,0x55,0x54,0x52], 0x55:[0x52,0x54,0x53,0x55,0x55,0x52]]
    var row = rows[code]
    if row == nil {
      for primary: UInt8 in [0x56,0x58,0x5a,0x5c,0x68,0x6a,0x6d,0x6f] where code == primary || code == primary+1 {
        row = [primary,0x54,primary+1,0x55,code,code == primary ? primary+1:primary]
      }
    }
    if code == 0x6c {
      guard option == 0 || option == 5 else { return nil }
      let supplement: UInt8 = option == 5 ? 0x53:0x59
      row = [0x6c,0x54,supplement,0x55,0x6c,supplement]
    }
    return row.map { Dictionary(uniqueKeysWithValues: zip(["G0","G1","G2","G3","GL","GR"],$0)) }
  }
  static let genreLabels: [Int:String] = {
    let basic = ["Movie","Music","Sports","Entertainment","News","Education/culture","Leisure/living","Other"]
    let detail = [
      ["Animation","Action/adventure","Science fiction","War","Drama/romance","Fantasy","Comedy","Mystery","Horror","Musical/dance/opera","History/biography","Western/costume","Family","Adult"],
      ["Pop","Rock","Jazz/fusion","R&B/soul/gospel","House/rap","Easy listening","Oldies","Country/enka","Latin/reggae","Samba/tango/folk","Chanson/flamenco","World music","Classical vocal/opera","Other classical"],
      ["Athletics","Water sports","Winter sports","Ball games","Martial arts","Racing","Baseball","Basketball","Football/rugby","Soccer","Tennis","Hockey","Golf","Wrestling"],
      ["Animation","Drama","Stage/concert","Variety","Soap opera","Comedy","Children","Documentary","Interview","Talk","Quiz/puzzle","Game","Karaoke","Gambling"],
      ["News","Report","Politics","Economy/industry","Stocks","Society","Regional","Entertainment","Traffic","Weather","International","Review","Crime/police","Bulletin"],
      ["Natural science","Humanities","Social science","Computing/electronics","Environment/energy/space","Politics/economics/law","Language","Art/design/music","Literature/drama","Dance","Fashion","Health/sport","History","Religion"],
      ["Hobbies","Leisure","Living","DIY","Animals","Fish","Gardening","Travel/photo/video","Outdoors","Exercise/health","Motoring/cycling","Magic/divination","Cooking/childcare","Shopping/housing"],
      ["Instruction","Communication","Advertisement","Court","Ceremony","Party","Birthday","Anniversary","User 0","User 1","User 2","User 3","User 4","User 5"]]
    var result: [Int:String] = [:]
    for b in 0...7 {
      for c in 0...13 { result[b*16+c] = basic[b]+": "+detail[b][c] }
      result[b*16+14] = basic[b]+": details in companion text"
      result[b*16+15] = basic[b]+": basic category or companion GENRE"
    }
    result.removeValue(forKey:127)
    return result
  }()
  static let sportsSubcategories: [Int:[Int:String]] = [
    0:dictionary(["Marathon","Walking","Ekiden","Triathlon","Gymnastics","Rhythmic gymnastics","Acrobatics","Trampoline"]),
    1:dictionary(["Swimming","Synchronized swimming","Diving","Scuba","Skin diving","Lifesaving","Water polo","Boating","Windsurfing","Yachting","Canoeing","Canoe polo","Surfing","Jet surfing","Water biking"]),
    2:dictionary(["Skiing","Ski jumping","Cross-country","Freestyle","Skating","Speed skating","Figure skating","Ice dance","Bobsleigh","Luge","Biathlon","Curling","Snowmobile","Snowboarding"]),
    3:dictionary(["Volleyball","Beach volleyball","Table tennis","Softball","Handball","Badminton","Cricket","Bowling","Lacrosse","Sepak takraw","Pelota","Polo","Bicycle polo","Squash","Racquetball","Croquet","Gateball","Pushball","Netball","Dodgeball","Floorball","Lawn bowls","Jai alai"]),
    4:dictionary(["Boxing","Weightlifting","Judo","Karate","Taekwondo","Sambo","Shooting","Fencing","Kendo","Archery","Kyudo","Naginata","Kabaddi"]),
    5:dictionary(["Motor car","Sprint","Rally","Dirt trial","Drag race","Motorcycle","Road race","Motocross","Trial","Bicycle","Track race","Load race (source spelling)","Keirin","Mountain bike","All-terrain vehicle","Solar car","Bed race"]),
    15:dictionary(["Skateboarding","Grass skiing","Roller skating","Land yacht","Equestrian","Skydiving","Ultralight","Glider","Hang glider","Motor glider","Paraglider","Paraplane","Parasail","Hot-air balloon","Sport kite","Mountaineering","Free climbing","Rock climbing","Bungee","Tug of war","Boomerang","Flying disc","Disc golf","Horseshoe","Petanque","Bocce","Shuffleboard","Orienteering","Indiaca"])]
  static let ornaments = dictionary(["Special","Highlight","Series","Miniseries","Fiction","Nonfiction","Elementary","Intermediate","Advanced","Junior high","High school","College","Club","Amateur","Open","Professional","Senior","Masters","All-star","Indoor","Outdoor","Home game","Away game","City","Regional","Domestic","Foreign","International","World","Universiade","Olympic","Goodwill","Davis","Federation","Wimbledon","Thomas","Uber","Royal Henley","Super","Rose","Orange","Sugar","Cotton","Rice","Rally","Sports car","Endurance","Formula 1","Formula 3000","Indianapolis 500","Le Mans","Paris-Ile","Tour de France","Marathon Laid (source spelling)","British","US","American","French","Australian","European","South American","Japanese","Nippon"])
}
