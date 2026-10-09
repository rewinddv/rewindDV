#!/usr/bin/env python3
"""Extract production Stop/finalizer methods; run deterministic host schedules.

Native queue delivery, RequestRuntimeQuiesce's subordinate runtime preparation,
and actual DMA containment are modeled boundaries. HardwareInterface, lifecycle
coordinator, NativeCallbackDrain, Stop, CompleteServiceStop and CompleteNativeRuntimeDrain are real
production source. Native request return and completion are fed explicitly to the production ledger,
never inferred from revocation. This is not a live DriverKit or physical removal qualification.
"""
import argparse, hashlib, json, os, pathlib, subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('repo', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--source-ref', help='Read service entry/finalizer from this Git ref for mutation/baseline comparison')
a=p.parse_args(); root=a.repo.resolve(); out=a.output.resolve(); out.mkdir(parents=True,exist_ok=True)
source_path='ASFWDriver/ASFWDriver.cpp'
src=subprocess.check_output(['git','-C',str(root),'show',f'{a.source_ref}:{source_path}'],text=True) if a.source_ref else (root/source_path).read_text()
def method(signature):
    start=src.find(signature)
    if start<0:return None
    begin=src.index('{',start); depth=1; end=begin+1
    # These methods contain no quoted/comment braces, so balanced source braces
    # preserve their exact original bodies without an implementation rewrite.
    while depth:
        depth+=(src[end]=='{')-(src[end]=='}');end+=1
    return src[start:end]
stop=method('kern_return_t IMPL(ASFWDriver, Stop)')
complete=method('kern_return_t ASFWDriver::CompleteServiceStop(IOService* provider)')
finalize=method('void ASFWDriver::CompleteNativeRuntimeDrain()')
assert stop and finalize
for name,body in [('Stop',stop),('CompleteServiceStop',complete),('CompleteNativeRuntimeDrain',finalize)]:
    if body:(out/f'{name}.extracted.cpp').write_text(body+'\n')
methods=stop.replace('kern_return_t IMPL(ASFWDriver, Stop)','kern_return_t Stop(IOService* provider)')+'\n'
if complete:methods+=complete.replace('ASFWDriver::','')+'\n'
methods+=finalize.replace('ASFWDriver::','')+'\n'
cpp=r'''
#include "Hardware/HardwareInterface.hpp"
#include "Service/Lifecycle/RuntimeLifecycleCoordinator.hpp"
#include "Shared/Completion/NativeCallbackDrain.hpp"
#include <atomic>
#include <cassert>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
using namespace ASFW::Driver;
constexpr int SUPERDISPATCH=1;
constexpr uint32_t kIOServicePowerCapabilityOn=1;
#define ASFW_LOG(...) ((void)0)
#define ASFW_LOG_ERROR(...) ((void)0)
unsigned failures=0, checks=0;
std::string scenario;
#define CHECK(x) do {++checks;if(!(x)){++failures;std::cerr<<"FAIL "<<scenario<<":"<<__LINE__<<" "<<#x<<"\n";}}while(0)
struct PCIDevice:IOPCIDevice {
 unsigned reads=0,writes=0;
 kern_return_t Open(IOService*) override{return kIOReturnSuccess;}
 kern_return_t GetBARInfo(uint8_t,uint8_t* index,uint64_t* size,uint8_t* type) override{*index=0;*size=4096;*type=1;return kIOReturnSuccess;}
 void MemoryRead32(uint8_t,uint64_t,uint32_t* value) override{++reads;*value=0;}
 void MemoryWrite32(uint8_t,uint64_t,uint32_t) override{++writes;}
};
using Drain=ASFW::Shared::NativeCallbackDrain;
struct Context {
 struct Deps {HardwareInterface* hardware=nullptr;} deps;
 std::atomic<bool> receiveQuarantined{false};
 std::atomic<int> receiveQuiesceFailure{kIOReturnNotReady};
 std::atomic<bool> quarantineServiceRetained{false};
 bool nativeDrainServiceRetained=false;
 OSSharedPtr<IOService> nativeDrainProvider;
 std::shared_ptr<Drain> nativeDrain;
 std::optional<QuiescePlan> nativeDrainPlan;
 std::shared_ptr<ControllerStateMachine> state=std::make_shared<ControllerStateMachine>();
 std::unique_ptr<RuntimeLifecycleCoordinator> lifecycle=std::make_unique<RuntimeLifecycleCoordinator>(state);
 bool dmaContained=false;
 unsigned teardowns=0, releases=0, nativeOwnersReleased=0;
 Drain::Ticket ticket=0;
 Context(){assert(lifecycle->BeginStart("fixture",1));assert(lifecycle->CompleteStart("fixture",2));}
};
struct IVars {
 Context* context=nullptr;
 IOService* powerProvider=nullptr;
 IOService* stopProvider=nullptr;
 bool stopPending=false,stopCompleted=false;
 kern_return_t stopResult=0;
 bool powerAcknowledgementPending=false;
 uint32_t pendingPowerFlags=0;
 bool wakeRebuildPending=false;
 uint64_t wakeVerifyAttempt=0;
};
struct Driver:OSObject {
 IVars storage; IVars* ivars=&storage;
 bool missingQueue=false,resources=true,reentrantSuper=false;
 bool requireServiceHold=true;
 int minimumProviderRefs=3;
 unsigned supers=0,requests=0,nativeWaves=0;
 kern_return_t superResult=kIOReturnSuccess,reentryResult=0;
 void QuarantineRuntime(Driver& service,Context& ctx,kern_return_t status){
  ctx.receiveQuiesceFailure=status;ctx.receiveQuarantined=true;
  if(!ctx.quarantineServiceRetained.exchange(true)){
   if(ctx.nativeDrainServiceRetained)ctx.nativeDrainServiceRetained=false;
   else service.retain();
  }
 }
 // The scheduler is modeled as serialized Default. No thread-race claim about
 // plain ivars is made; receipt assertions cover sequential and same-stack reentry.
 void RequestRuntimeQuiesce(uint32_t reason){
  ++requests;
  if(!ivars||!ivars->context)return;
  auto& c=*ivars->context;
  if(missingQueue){QuarantineRuntime(*this,c,kIOReturnNotReady);return;}
  if(!c.lifecycle)return;
  const auto plan=c.lifecycle->BeginQuiesce(static_cast<QuiesceReason>(reason),"fixture",3);
  if(!plan)return;
  if(plan->revokeImmediately&&c.deps.hardware)c.deps.hardware->LatchProviderRevokedAndDrain();
  if(!plan->runTeardown)return;
  // A representative reachable RX Stop cleanup operation using actual
  // production scope, write and final flush. It must be barred at terminal entry.
  if(c.deps.hardware)c.deps.hardware->SetInterruptMask(1,false);
  if(resources){c.nativeDrainPlan=*plan;BeginNativeRuntimeDrain();}
 }
 void BeginNativeRuntimeDrain(){
  auto& c=*ivars->context;++nativeWaves;
  if(!c.nativeDrainServiceRetained){retain();c.nativeDrainServiceRetained=true;}
  c.nativeDrain=std::make_shared<Drain>();
  c.ticket=*c.nativeDrain->BeginSource([&c]{++c.nativeOwnersReleased;},2);
  c.nativeDrain->RequestReturned(c.ticket,true);
  c.nativeDrain->Seal();
 }
 bool ExecuteRuntimeTeardown(Driver&,Context& c,const QuiescePlan&){
  ++c.teardowns;
  // Independent DMA proof injected by each fixture, never hardwareGone/enum.
  return c.dmaContained;
 }
 void ReleaseQuiescedRuntime(Context& c,const QuiescePlan& plan){
  ++c.releases;c.lifecycle->CompleteQuiesce(plan,"fixture release",4);
 }
 void Notify(){
  if(!ivars||!ivars->context)return;
  auto& c=*ivars->context;
  if(c.deps.hardware)c.deps.hardware->LatchProviderRevokedAndDrain();
  RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kProviderRevoked));
 }
 kern_return_t Stop(IOService* provider,int){
  ++supers;
  if(requireServiceHold)CHECK(GetRetainCount()>=2);
  if(provider)CHECK(provider->GetRetainCount()>=minimumProviderRefs);
  if(reentrantSuper){reentrantSuper=false;reentryResult=Stop(provider);}
  return superResult;
 }
 kern_return_t StartRuntime(IOService*){return kIOReturnNotReady;}
 void ScheduleWakeVerify(uint64_t){}
 kern_return_t SetPowerState(uint32_t,int){return kIOReturnSuccess;}
''' + methods + r'''
};
struct Fixture {
 PCIDevice* pci=new PCIDevice;
 HardwareInterface hardware;
 Context context;
 Driver* driver=new Driver;
 Fixture(){assert(hardware.Attach(nullptr,pci)==kIOReturnSuccess);context.deps.hardware=&hardware;driver->storage.context=&context;}
 ~Fixture(){
  // Explicit fixture cleanup of retained/quarantined objects after all fake
  // work is stopped. Production quarantine is intentionally permanent.
  if(driver->storage.stopProvider){driver->storage.stopProvider->release();driver->storage.stopProvider=nullptr;}
  if(context.nativeDrainServiceRetained){context.nativeDrainServiceRetained=false;driver->release();}
  if(context.quarantineServiceRetained.exchange(false))driver->release();
  driver->release();hardware.Detach();pci->release();
 }
 void Ack(){assert(context.nativeDrain);context.nativeDrain->CompletionObserved(context.ticket);driver->CompleteNativeRuntimeDrain();}
 void NoMMIO(){CHECK(pci->reads==0);CHECK(pci->writes==0);CHECK(!hardware.TryBeginAccess());}
};
int main(){
 for(bool notificationFirst:{false,true}){
  scenario=notificationFirst?"notification-before-stop":"stop-before-notification";
  Fixture f;if(notificationFirst)f.driver->Notify();
  CHECK(f.driver->Stop(f.pci)==kIOReturnSuccess);f.NoMMIO();
  CHECK(f.driver->supers==0);CHECK(f.context.releases==0);CHECK(f.pci->GetRetainCount()==3);
  CHECK(f.driver->Stop(f.pci)==kIOReturnSuccess);CHECK(f.pci->GetRetainCount()==3);
  f.driver->Notify();f.driver->Notify();CHECK(f.driver->nativeWaves==1);
  f.context.dmaContained=true;f.Ack();
  CHECK(f.driver->supers==1);CHECK(f.context.releases==1);CHECK(f.pci->GetRetainCount()==2);
  CHECK(f.driver->Stop(f.pci)==kIOReturnSuccess);CHECK(f.driver->supers==1);
  f.driver->Notify();CHECK(f.driver->nativeWaves==1);CHECK(f.context.releases==1);
  f.driver->CompleteNativeRuntimeDrain();CHECK(f.driver->supers==1);
 }
 {
  scenario="queue-unavailable";Fixture f;f.driver->missingQueue=true;
  CHECK(f.driver->Stop(f.pci)==kIOReturnNotReady);f.NoMMIO();
  CHECK(f.context.receiveQuarantined);CHECK(f.driver->supers==0);CHECK(f.context.releases==0);
  const auto held=f.driver->GetRetainCount();CHECK(f.driver->Stop(f.pci)==kIOReturnNotReady);
  CHECK(f.driver->GetRetainCount()==held);CHECK(f.pci->GetRetainCount()==3);
 }
 {
  scenario="no-context-reentrant-super";Fixture f;f.driver->storage.context=nullptr;
  f.driver->reentrantSuper=true;CHECK(f.driver->Stop(f.pci)==kIOReturnSuccess);
  CHECK(f.driver->supers==1);CHECK(f.driver->reentryResult==kIOReturnBusy);
  CHECK(f.pci->GetRetainCount()==2);CHECK(f.driver->GetRetainCount()==1);
  CHECK(f.driver->Stop(f.pci)==kIOReturnSuccess);CHECK(f.driver->supers==1);
 }
 {
  scenario="no-hardware-no-resources";Fixture f;f.context.deps.hardware=nullptr;f.driver->resources=false;
  CHECK(f.driver->Stop(f.pci)==kIOReturnSuccess);CHECK(f.driver->supers==1);
  CHECK(f.driver->Stop(f.pci)==kIOReturnSuccess);CHECK(f.driver->supers==1);
  CHECK(f.context.releases==0);CHECK(f.pci->GetRetainCount()==2);
 }
 {
  scenario="null-provider-empty-stop";Fixture f;f.driver->resources=false;f.context.deps.hardware=nullptr;
  CHECK(f.driver->Stop(nullptr)==kIOReturnSuccess);CHECK(f.driver->supers==1);
  CHECK(f.driver->Stop(nullptr)==kIOReturnSuccess);CHECK(f.driver->supers==1);
 }
 {
  scenario="failed-super-receipt";Fixture f;f.driver->resources=false;f.driver->superResult=kIOReturnError;
  CHECK(f.driver->Stop(f.pci)==kIOReturnError);f.NoMMIO();
  CHECK(f.driver->Stop(f.pci)==kIOReturnError);CHECK(f.driver->supers==1);CHECK(f.pci->GetRetainCount()==2);
 }
 {
  scenario="native-terminal-without-dma-proof";Fixture f;f.driver->Stop(f.pci);f.Ack();
  CHECK(f.context.receiveQuarantined);CHECK(f.context.releases==0);CHECK(f.driver->supers==0);
  CHECK(f.driver->Stop(f.pci)==kIOReturnNotReady);CHECK(f.pci->GetRetainCount()==3);
 }
 {
  scenario="native-cancel-not-acknowledged";Fixture f;f.driver->Stop(f.pci);f.context.dmaContained=true;
  f.driver->CompleteNativeRuntimeDrain();CHECK(f.context.receiveQuarantined);
  CHECK(f.context.releases==0);CHECK(f.driver->supers==0);CHECK(f.context.teardowns==0);
 }
 {
  scenario="late-native-completion-after-ledger-quarantine";Fixture f;f.driver->Stop(f.pci);
  f.context.dmaContained=true;f.context.nativeDrain->Quarantine();f.Ack();
  CHECK(f.context.receiveQuarantined);CHECK(f.context.nativeOwnersReleased==1);
  CHECK(f.context.releases==0);CHECK(f.driver->supers==0);CHECK(f.context.teardowns==0);
  f.driver->CompleteNativeRuntimeDrain();CHECK(f.driver->supers==0);CHECK(f.context.releases==0);
 }
 {
  scenario="suspend-then-terminal-second-cancel-wave";Fixture f;
  f.driver->RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kSystemSuspend));
  CHECK(f.driver->nativeWaves==1);f.pci->reads=0;f.pci->writes=0;
  CHECK(f.driver->Stop(f.pci)==kIOReturnSuccess);f.NoMMIO();
  f.context.dmaContained=true;f.Ack();CHECK(f.driver->nativeWaves==2);
  CHECK(f.driver->supers==0);CHECK(f.context.releases==0);CHECK(f.pci->GetRetainCount()==3);
  f.Ack();CHECK(f.driver->supers==1);CHECK(f.context.releases==1);CHECK(f.pci->GetRetainCount()==2);
 }
 std::cout<<"terminal Stop fixture checks="<<checks<<" failures="<<failures<<"; extracted production Stop/completion/finalizer + real HardwareInterface/lifecycle/native ledger; modeled native delivery/DMA boundaries\n";
 return failures?1:0;
}
'''
(out/'terminal-stop-tests.cpp').write_text(cpp)
flags=['-std=c++23','-DASFW_HOST_TEST','-g','-fsanitize=address,undefined','-fno-sanitize-recover=all','-Wno-character-conversion','-Wno-deprecated-copy']
flags += ['-I'+str(root/x) for x in ['tests/mocks','tests/support','.','ASFWDriver','ASFWDriver/Async','ASFWDriver/Core','ASFWDriver/Bus','ASFWDriver/Logging','ASFWDriver/Hardware','ASFWDriver/Testing','ASFWDriver/Discovery','docs','AppleHeaders']]
prod=['ASFWDriver/Hardware/HardwareInterface.cpp','ASFWDriver/Common/BarrierUtils.cpp','ASFWDriver/Controller/ControllerStateMachine.cpp','ASFWDriver/Service/Lifecycle/RuntimeLifecycleCoordinator.cpp','tests/support/LoggingStubs.cpp','ASFWDriver/Logging/LogRing.cpp']
cmd=['xcrun','clang++',*flags,str(out/'terminal-stop-tests.cpp'),*[str(root/x) for x in prod],'-pthread','-o',str(out/'terminal-stop-tests')]
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
receipt={'source_ref':a.source_ref,'service_source_sha256':hashlib.sha256(src.encode()).hexdigest(),'production_files':{x:hashlib.sha256((root/x).read_bytes()).hexdigest() for x in prod},'compile_command':cmd,'environment':{'DEVELOPER_DIR':env['DEVELOPER_DIR']},'boundaries':'Native scheduler/delivery and DMA containment are modeled; service methods, MMIO, coordinator and NativeCallbackDrain are production source.'}
build=subprocess.run(cmd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(out/'compile.log').write_text(build.stdout);receipt['compile_exit']=build.returncode
if build.returncode==0:
 run=subprocess.run([str(out/'terminal-stop-tests')],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(out/'run.log').write_text(run.stdout);receipt['run_exit']=run.returncode;print(run.stdout,end='')
else: print(build.stdout)
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
raise SystemExit(receipt.get('run_exit',build.returncode))
