#!/usr/bin/env ruby
# Static lifetime contract for controller-bus borrowers. Dynamic receive/DMA
# behavior remains covered by FoundationReceiveLifecycleTests.

source = File.read('ASFWDriver/Service/DriverContext.cpp')
reset = source[/void ServiceContext::Reset\(ResetMode mode\) \{(.*?)\n\}/m, 1]
abort 'ServiceContext::Reset body not found' unless reset

required = [
  'controller->AttachROMScanner(nullptr);',
  'controller->SetFCPResponseRouter(nullptr);',
  'controller->SetAVCDiscovery(nullptr);',
  'controller->SetCMPClient(nullptr);',
  'controller->SetIRMClient(nullptr);',
  'controller->SetBusManagerElectionDriver(nullptr);',
  'controller->SetCSRResponder(nullptr);',
  'deps.romScanner.reset();',
  'deps.localRequestDispatch.reset();',
  'deps.busManagerElectionDriver.reset();',
  'deps.csrResponder.reset();',
  'deps.csrCycleMasterControl.reset();',
  'deps.csrRootStatus.reset();',
  'deps.topologyMapService.reset();',
  'deps.fcpResponseRouter.reset();',
  'deps.avcDiscovery.reset();',
  'deps.cmpClient.reset();',
  'deps.irmClient.reset();',
  'controller.reset();'
]

positions = required.to_h do |needle|
  position = reset.index(needle)
  abort "missing borrowed-client teardown: #{needle}" unless position
  [needle, position]
end

controller_reset = positions.fetch('controller.reset();')
required[0...-1].each do |needle|
  abort "#{needle} must precede controller.reset()" unless positions.fetch(needle) < controller_reset
end

abort 'CMP client must not be conditionally retained across runtime rebuilds' unless
  reset.scan('deps.cmpClient.reset();').length == 1
abort 'topology-map provider must retire before hardware' unless
  positions.fetch('deps.topologyMapService.reset();') < reset.index('deps.hardware.reset();')

puts 'Foundation runtime borrowed-client source gates passed: ROM/AVC/CMP/IRM owners retire before controller bus'

driver = File.read('ASFWDriver/ASFWDriver.cpp')
teardown = driver[/bool ExecuteRuntimeTeardown\(.*?\) \{(.*?)\n\}/m, 1]
abort 'ExecuteRuntimeTeardown body not found' unless teardown
prepare = driver[/bool PrepareRuntimeTeardown\(.*?\) \{(.*?)\n\}/m, 1]
abort 'PrepareRuntimeTeardown body not found' unless prepare
begin_quiesce = prepare.index('ctx.deps.asyncSubsystem->BeginQuiesce();')
epoch_barrier = prepare.index('ctx.deps.asyncSubsystem->RetirePostedWorkAndWait()')
async_stop = teardown.index('!ctx.deps.asyncSubsystem->Stop()')
abort 'async callback epoch retirement is missing' unless begin_quiesce && epoch_barrier && async_stop
abort 'async callback epoch must retire before native drain' unless begin_quiesce < epoch_barrier &&
  driver.match?(/if \(PrepareRuntimeTeardown\(\*this, ctx, \*plan\)\) \{\s*ctx.nativeDrainPlan = \*plan;\s*BeginNativeRuntimeDrain\(\);/m)
abort 'native terminal barrier must precede async stop' unless
  teardown.index('!ctx.nativeDrain->AllTerminal()') < async_stop

session = File.read('ASFWDriver/ConfigROM/Remote/ROMScanSession.cpp')
start = session[/void ROMScanSession::Start\(.*?\) \{(.*?)\n\}/m, 1]
abort 'ROMScanSession::Start body not found' unless start
abort 'queued ROM start lacks synchronous abort gate' unless
  start.include?('session->aborted_.load(std::memory_order_acquire)')

puts 'Foundation runtime callback gates passed: retired epochs suppress late async and ROM work'
