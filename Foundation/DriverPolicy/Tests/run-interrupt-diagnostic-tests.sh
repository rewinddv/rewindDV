#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
interrupt_test_dir=$(mktemp -d /tmp/rewinddv-interrupt-tests.XXXXXX)
xcrun --sdk macosx clang++ -std=c++20 -Wall -Wextra -Werror -I. \
  Foundation/DriverPolicy/Tests/InterruptDiagnosticTests.cpp \
  ASFWDriver/Diagnostics/DiagnosticLogger.cpp -o "$interrupt_test_dir/interrupt-tests"
"$interrupt_test_dir/interrupt-tests"
# The only production use remains presentation of the enabled-event snapshot.
# This source contract complements executable formatter and native compile checks.
ruby -e '
  path = "ASFWDriver/Controller/ControllerCoreInterrupts.cpp"
  source = File.read(path)
  abort "caller contract changed" unless source.include?("const std::string eventDecode = DiagnosticLogger::DecodeInterruptEvents(events);") && source.include?(%q{ASFW_LOG_V3(Controller, "%{public}s", eventDecode.c_str());})
  uses = Dir["ASFWDriver/**/*.{cpp,hpp}"].flat_map { |p| File.readlines(p).select { |l| l.include?("DiagnosticLogger::") }.map { |l| [p,l] } }
  abort "unexpected diagnostic API use" unless uses.size == 2
  puts "Interrupt diagnostic production caller contract PASS"
'
