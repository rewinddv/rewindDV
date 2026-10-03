# Static regression checks for IIG-owned paths that cannot run in host stubs.
# Dynamic DMA/context behavior is exercised by FoundationReceiveLifecycleTests.
root = File.expand_path('../../..', __dir__)
driver = File.read(File.join(root, 'ASFWDriver/ASFWDriver.cpp'))
context = File.read(File.join(root, 'ASFWDriver/Service/DriverContext.cpp'))
checks = {
  'quiescence gates owner teardown' => driver.index('ctx.dvCapture.StopAll') < driver.index('ctx.DisarmProviderNotifications()'),
  'quarantine retains service owner' => driver.include?('service.retain();'),
  'free preserves the entire unproved graph' => driver.match?(/void ASFWDriver::free\(\).*?receiveQuarantined.*?return;.*?context->Reset\(\)/m),
  'quarantine suppresses superclass Stop' => driver.match?(/IMPL\(ASFWDriver, Stop\).*?receiveQuarantined.*?return ivars->context->receiveQuiesceFailure.*?return Stop\(provider, SUPERDISPATCH\)/m),
  'no client allocation can reuse retained address owner' => driver.match?(/IMPL\(ASFWDriver, NewUserClient\).*?receiveQuarantined.*?return kIOReturnNotReady;.*?auto ret = Create/m),
  'reset releases stopped receive contexts before hardware owner' => context.index('ReleaseQuiescedReceiveContexts()') < context.index('deps.hardware.reset()'),
  'failed teardown cannot publish completion' => driver.scan(/if \(ExecuteRuntimeTeardown\(\*this, ctx, \*plan\)\) \{\s*ReleaseQuiescedRuntime/).length == 2
}
checks.each { |name, result| abort("FAILED: #{name}") unless result }
puts "Foundation receive outer source gates passed (#{checks.length}); static checks, not hardware proof"
