# Static regression checks for IIG-owned paths that cannot run in host stubs.
# Dynamic DMA/context behavior is exercised by FoundationReceiveLifecycleTests.
root = File.expand_path('../../..', __dir__)
driver = File.read(File.join(root, 'ASFWDriver/ASFWDriver.cpp'))
context = File.read(File.join(root, 'ASFWDriver/Service/DriverContext.cpp'))
async = File.read(File.join(root, 'ASFWDriver/Async/AsyncSubsystemLifecycle.cpp'))
checks = {
  'terminal Stop revokes MMIO before entering coordinator teardown' => driver.match?(/IMPL\(ASFWDriver, Stop\).*?LatchProviderRevokedAndDrain\(\);.*?RequestRuntimeQuiesce\(static_cast<uint32_t>\(QuiesceReason::kProviderRevoked\)\)/m),
  'terminal finalizer uses the shared exactly-once superclass receipt' => driver.match?(/void ASFWDriver::CompleteNativeRuntimeDrain.*?if \(ivars->stopPending\) \{\s*\(void\)CompleteServiceStop\(ivars->stopProvider\);/m),
  'terminal completion permanently refuses runtime restart' => driver.include?('if (ivars->stopCompleted) return kIOReturnNotReady;'),
  'async retirement failure gates other DMA releases and provider detach' => driver.match?(/if \(ctx.deps.asyncSubsystem && !ctx.deps.asyncSubsystem->Stop\(\)\).*?QuarantineRuntime\(service, ctx, kIOReturnNotReady\).*?return false;.*?selfId->ReleaseBuffers\(\).*?hardware->Detach\(\)/m),
  'reset retains graph without async retirement proof' => context.index('!deps.asyncSubsystem->DMAContextsRetired()') < context.index('deps.hardware.reset()'),
  'failed async retirement returns before destroying payload owners' => async.match?(/!contextManager_->teardown\(disableHardware\).*?dmaQuarantined_ = true;.*?return false;.*?tracking_->CancelAllAndFreeLabels\(\)/m),
  'async stop records cancellation uncertainty before dropping transaction owners' => async.match?(/bool AsyncSubsystem::Teardown.*?if \(tracking_\) tracking_->CancelAllAndFreeLabels\(\);.*?else txnMgr_->CancelAll\(\);.*?txnMgr_\.reset\(\);.*?completionQueue_\.reset\(\)/m),
  'wire retirement is checked after async stop and before any root release' => driver.match?(/bool ExecuteRuntimeTeardown.*?!ctx.deps.asyncSubsystem->Stop\(\).*?ctx.deps.asyncSubsystem->HasUncertainWire\(\).*?QuarantineRuntime\(service, ctx, kIOReturnNotReady\).*?return false;.*?selfId->ReleaseBuffers\(\).*?hardware->Detach\(\)/m),
  'reset cannot discard fence introduced by its own final AVC shutdown' => context.match?(/void ServiceContext::Reset.*?deps.avcDiscovery->Shutdown\(\);.*?deps.asyncSubsystem->HasUncertainWire\(\).*?receiveQuarantined.store\(true.*?return;.*?audioCoordinator.reset\(\).*?deps.asyncSubsystem.reset\(\)/m),
  'quarantined async start cannot report running success' => async.index('if (dmaQuarantined_) return kIOReturnNotReady;') < async.index('if (isRunning_)'),
  'quiescence gates owner teardown' => driver.index('ctx.dvCapture.StopAll') < driver.index('ctx.BeginProviderNativeRetirement(drain)'),
  'quarantine retains service owner exactly once or transfers native retain' => driver.match?(/void QuarantineRuntime.*?receiveQuarantined.store\(true.*?!ctx.quarantineServiceRetained.exchange\(true.*?ctx.nativeDrainServiceRetained = false;.*?else service.retain\(\);/m),
  'free preserves the entire unproved graph' => driver.match?(/void ASFWDriver::free\(\).*?receiveQuarantined.*?return;.*?context->Reset\(\)/m),
  'quarantine suppresses superclass Stop' => driver.match?(/IMPL\(ASFWDriver, Stop\).*?receiveQuarantined.*?return ivars->context->receiveQuiesceFailure.*?return CompleteServiceStop\(provider\)/m),
  'no client allocation can reuse retained address owner' => driver.match?(/IMPL\(ASFWDriver, NewUserClient\).*?receiveQuarantined.*?return kIOReturnNotReady;.*?auto ret = Create/m),
  'reset releases stopped receive contexts before hardware owner' => context.index('ReleaseQuiescedReceiveContexts()') < context.index('deps.hardware.reset()'),
  'failed teardown cannot publish completion' => driver.match?(/if \(!ExecuteRuntimeTeardown\(\*this, ctx, plan\)\) \{.*?return;\s*\}\s*ReleaseQuiescedRuntime\(ctx, plan\);/m),
  'native retirement gates complete borrowed runtime release' => driver.match?(/bool ExecuteRuntimeTeardown.*?!ctx.nativeDrain->AllTerminal\(\).*?return false;.*?!ctx.deps.asyncSubsystem->Stop\(\)/m),
  'restart cannot overlap native drain' => driver.include?('if (ctx.nativeDrain || ivars->stopPending) return kIOReturnBusy;'),
  'native timeout permanently contains complete service' => driver.match?(/drain->Quarantined\(\) \|\| !drain->AllTerminal\(\).*?QuarantineRuntime\(\*this, ctx, kIOReturnTimeout\).*?return;/m),
  'lifecycle queue failure contains before borrowed graph mutation' => driver.match?(/void ASFWDriver::RequestRuntimeQuiesce.*?CopyDispatchQueue\("Default", &rawQueue\) != kIOReturnSuccess.*?failedContext.quarantineServiceRetained.exchange\(true.*?failedContext.receiveQuarantined.store\(true.*?return;.*?ctx.lifecycle->BeginQuiesce/m),
  'failed wake rebuild defers power acknowledgement through new drain' => driver.match?(/if \(powerPending\) \{\s*if \(ctx.nativeDrain\).*?powerAcknowledgementPending = true;.*?else if.*?SetPowerState\(powerFlags, SUPERDISPATCH\)/m),
  'provider callback aliases remain through original terminal wave' => context.match?(/void ServiceContext::BeginProviderNativeRetirement.*?if \(!providerNotifications \|\| providerNotificationDrain\) return;.*?providerNotificationDrain = drain;.*?auto source = providerNotifications;.*?auto action = providerNotificationAction;.*?RetireNativeSource\(source, action, drain\)/m),
  'provider proof gates graph reset before any borrowed owner release' => context.match?(/void ServiceContext::Reset.*?providerNotifications &&.*?!providerNotificationDrain->AllTerminal\(\).*?return;.*?audioCoordinator.reset\(\)/m)
}
checks.each { |name, result| abort("FAILED: #{name}") unless result }
puts "Foundation receive outer source gates passed (#{checks.length}); static checks, not hardware proof"
