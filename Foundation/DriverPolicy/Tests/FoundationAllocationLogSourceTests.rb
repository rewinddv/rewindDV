#!/usr/bin/env ruby
# Read actual production format literals. No hardware, logger invocation or DV I/O.
# Conservatively allow the full printf type width, even for smaller domain values.
require "json"

root = File.expand_path("../../..", __dir__)
source = File.read(File.join(root, "Foundation/DriverPolicy/FoundationReceiveService.cpp"))
expected = %w[alloc-input alloc-plan alloc-result alloc-cas alloc-refusal observed-stream]
found = {}
prefix = "[Isoch] "
record = File.read(File.join(root, "ASFWDriver/Logging/LogRing.hpp"))
capacity_match = record.match(/char\s+message\[(\d+)\]/)
abort "unrecognized LogRecord message capacity" unless capacity_match
message_capacity = Integer(capacity_match[1]) # Including trailing NUL.

source.scan(/ASFW_LOG\(Isoch,\s*((?:"(?:[^"\\]|\\.)*"\s*)+),/m) do |match|
  format = match.first.scan(/"(?:[^"\\]|\\.)*"/).map { |part| JSON.parse(part) }.join
  event = format[/\A\[FoundationRX\] ([a-z-]+)/, 1]
  next unless expected.include?(event)
  abort "duplicate allocation event #{event}" if found.key?(event)
  # Native builds independently check printf argument types. Here %u/%x use
  # full 32-bit maxima, not optimistic enum/channel/generation limits.
  conversions = /%(?:llu|llx|08x|u|x|%)/
  if format.gsub(conversions, "").include?("%")
    abort "unbounded/unrecognized printf conversion in #{event}"
  end
  maximum = format.gsub(conversions) do |conversion|
    case conversion
    when "%llu" then "18446744073709551615"
    when "%llx" then "ffffffffffffffff"
    when "%08x", "%x" then "ffffffff"
    when "%u" then "4294967295"
    when "%%" then "%"
    end
  end
  bytes = prefix.bytesize + maximum.bytesize + 1
  abort "#{event} needs #{bytes} bytes; LogRecord has #{message_capacity}" if bytes > message_capacity
  found[event] = bytes
end
abort "missing allocation format coverage: #{expected - found.keys}" unless found.keys.sort == expected.sort
found.sort.each { |event, bytes| puts "PASS: #{event} worst-case #{bytes}/#{message_capacity} bytes including prefix/NUL" }
puts "Allocation log format source bounds passed (actual literals; full printf integer widths)."
