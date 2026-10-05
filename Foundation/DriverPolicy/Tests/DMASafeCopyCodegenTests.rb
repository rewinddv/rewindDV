#!/usr/bin/env ruby
# Normal host RAM accepts the unaligned SIMD reads that trap on uncached DMA.
# Check the optimized, isolated production-copy wrapper as a separate obligation.
assembly = File.read(ARGV.fetch(0))
body = assembly[/^_rewindDVCopyFromDMA:.*?^\s*\.cfi_endproc/m]
abort 'FAIL: DMA copy wrapper missing from ARM64 assembly' unless body
loads = body.lines.select { |line| line.match?(/^\s+ld\w*\s/) }
abort 'FAIL: DMA copy has no inspectable loads' if loads.empty?
bad = loads.reject { |line| line.match?(/^\s+(?:ldr|ldur|ldrb|ldurb)\s+w\d+,/) }
abort "FAIL: DMA copy widened a device read:\n#{bad.join}" unless bad.empty?
abort 'FAIL: DMA copy delegates to an unverified routine' if body.match?(/^\s+(?:bl\w*\s|b\s+_)/)
puts 'PASS: optimized ARM64 DMA copy uses only scalar byte/32-bit reads and no library calls'
