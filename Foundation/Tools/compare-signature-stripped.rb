#!/usr/bin/ruby
# Compare ALL bytes after codesign --remove-signature. Apple's signing tools can
# leave different page-aligned __LINKEDIT virtual reservations after removing
# different-sized signatures. Only that validated non-executable field may vary.
# No delivered binary is modified; normalization happens in memory for comparison.
module StrippedMachO
  def self.normalized(bytes)
    raise 'Expected little-endian Mach-O 64' unless bytes.bytesize >= 32 && bytes.unpack1('V') == 0xfeedfacf
    count, command_bytes = bytes.byteslice(16, 8).unpack('V2')
    raise 'Invalid command extent' unless count.between?(1, 1024) && command_bytes <= bytes.bytesize - 32
    offset = 32
    limit = offset + command_bytes
    linkedit = nil
    count.times do
      raise 'Truncated command' unless offset + 8 <= limit
      command, size = bytes.byteslice(offset, 8).unpack('V2')
      raise 'Invalid command size' unless size >= 8 && size % 8 == 0 && size <= limit - offset
      raise 'Signature must already be removed' if command == 0x1d
      if command == 0x19
        raise 'Short segment command' unless size >= 72
        sections = bytes.byteslice(offset + 64, 4).unpack1('V')
        raise 'Invalid segment extent' unless size == 72 + 80 * sections
        if bytes.byteslice(offset + 8, 16).delete("\0") == '__LINKEDIT'
          raise 'Duplicate or sectioned LINKEDIT' if linkedit || sections != 0
          virtual, file_offset, file_size = bytes.byteslice(offset + 32, 24).unpack('Q<3')
          maxprot, initprot = bytes.byteslice(offset + 56, 8).unpack('V2')
          page = 16384
          minimum = ((file_size + page - 1) / page) * page
          raise 'Invalid LINKEDIT reservation' unless file_size > 0 && file_offset >= limit &&
            file_offset + file_size == bytes.bytesize && maxprot == 1 && initprot == 1 &&
            virtual % page == 0 && virtual >= minimum && virtual <= minimum + 1024 * 1024
          linkedit = offset + 32
        end
      end
      offset += size
    end
    raise 'Command extent mismatch or absent LINKEDIT' unless offset == limit && linkedit
    copy = bytes.dup
    copy[linkedit, 8] = "\0" * 8
    copy
  end

  def self.compare(before, after)
    raise 'Non-signature executable content changed' unless normalized(before) == normalized(after)
    true
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: compare-signature-stripped.rb before after' unless ARGV.length == 2
  StrippedMachO.compare(*ARGV.map { |path| File.binread(path) })
  puts 'All stripped bytes match except permitted, validated __LINKEDIT virtual-size bookkeeping.'
end
