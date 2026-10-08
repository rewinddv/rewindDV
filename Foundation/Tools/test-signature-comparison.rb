#!/usr/bin/ruby
require_relative 'compare-signature-stripped'

def fixture(reservation = 16384)
  header = [0xfeedfacf, 0x100000c, 0, 2, 1, 72, 0, 0].pack('V8')
  segment = [0x19, 72].pack('V2') + '__LINKEDIT'.ljust(16, "\0") +
    [0x1000, reservation, 104, 16].pack('Q<4') + [1, 1, 0, 0].pack('V4')
  header + segment + '0123456789abcdef'
end

def rejects(label)
  begin
    yield
  rescue RuntimeError
    return
  end
  abort "Unexpected acceptance: #{label}"
end

original = fixture
raise 'Identical rejected' unless StrippedMachO.compare(original, original)
raise 'Valid signing reservation rejected' unless StrippedMachO.compare(original, fixture(32768))
changed = original.dup; changed.setbyte(110, changed.getbyte(110) ^ 1)
rejects('payload change') { StrippedMachO.compare(original, changed) }
changed = original.dup; changed.setbyte(28, 1)
rejects('header change') { StrippedMachO.compare(original, changed) }
rejects('truncated file') { StrippedMachO.compare(original, original[0...-1]) }
rejects('undersized mapping') { StrippedMachO.compare(original, fixture(0)) }
rejects('excessive mapping') { StrippedMachO.compare(original, fixture(2 * 1024 * 1024)) }
rejects('unaligned mapping') { StrippedMachO.compare(original, fixture(16385)) }
changed = original.dup; changed[32 + 56, 4] = [5].pack('V')
rejects('executable LINKEDIT') { StrippedMachO.compare(original, changed) }
changed = original.dup; changed[32 + 4, 4] = [0].pack('V')
rejects('malformed command') { StrippedMachO.compare(original, changed) }
changed = original.dup; changed[32, 4] = [0x1d].pack('V')
rejects('retained signature') { StrippedMachO.compare(original, changed) }
puts '11 signature-comparison cases passed; only bounded LINKEDIT reservation variation accepted.'
