# Copyright 2026 Rewind Digital, LLC
# SPDX-License-Identifier: Apache-2.0
# Static production-wiring checks, not an executable hardware/reset proof.
# Optional commit SHA checks the same contracts against a retained baseline.
require 'open3'

root = File.expand_path('../../..', __dir__)
revision = ARGV.first
abort 'Expected an optional hexadecimal commit SHA' if revision && !revision.match?(/\A[0-9a-f]{7,40}\z/)
read_source = lambda do |path|
  if revision
    text, status = Open3.capture2('git', '-C', root, 'show', "#{revision}:#{path}")
    abort "Unable to read baseline #{path}" unless status.success?
    text
  else
    File.read(File.join(root, path))
  end
end

handler = read_source.call('ASFWDriver/UserClient/Handlers/ConfigROMHandler.cpp')
export = handler.split('kern_return_t ConfigROMHandler::ExportConfigROM', 2).last
                .split('kern_return_t ConfigROMHandler::TriggerROMRead', 2).first
interrupts = read_source.call('ASFWDriver/Controller/ControllerCoreInterrupts.cpp')
reset = interrupts.split('if ((events & IntEventBits::kBusReset) != 0U)', 2).last
discovery = read_source.call('ASFWDriver/Controller/ControllerCoreDiscovery.cpp')
completion = discovery.split('void ControllerCore::OnDiscoveryScanComplete', 2).last
scanner = read_source.call('ASFWDriver/ConfigROM/Remote/ROMScanner.cpp')
start = scanner.split('bool ROMScanner::Start', 2).last
               .split('void ROMScanner::Abort', 2).first

checks = {
  'selector 14 uses an owned eligibility-filtered snapshot' =>
    export.include?('CopyExportableByNode(requestedGen, nodeId)') &&
    !export.include?('->FindByNode('),
  'reset revokes ROM export eligibility before protocol reset notification' =>
    (interrupts.index('deps_.romStore->SuspendAll(') || Float::INFINITY) <
      (interrupts.index('deps_.avcDiscovery->OnBusReset(') || -1),
  'reset revokes exports even if subsequent MMIO access is denied' =>
    (reset.index('deps_.romStore->SuspendAll(') || Float::INFINITY) <
      (reset.index('hw.TryBeginAccess()') || -1),
  'busy rejection precedes admission, which precedes possible synchronous completion' =>
    start.include?('admission && !admission()') &&
    start.index('IsBusyFor(request.gen)') < start.index('admission && !admission()') &&
    start.index('admission && !admission()') < start.index('session->Start('),
  'controller obtains export authority in the accepted scan callback' =>
    discovery.include?('BeginExportScan(request.gen, request.targetNodes)') &&
    discovery.include?('OnDiscoveryScanComplete(gen, roms, hadBusyNodes, *admission)'),
  'failed export publication returns before live route publication' =>
    completion.match?(/if \(!deps_\.romStore->PublishExportScan\(admission, gen, acceptedRoms\)\)\s*\{[^}]*return;/m) &&
    completion.index('PublishExportScan(') < completion.index('deviceRegistry->UpsertFromROM(')
}

checks.each { |description, passed| puts "#{passed ? 'PASS' : 'FAIL'}: #{description}" }
abort 'Config-ROM export source gates failed' unless checks.values.all?
puts "Config-ROM export source gates passed (#{checks.size}); static checks only"
