// Offline ordinary transaction-order regression. No hardware, DMA or network.
#include "ASFWDriver/Async/Track/Tracking.hpp"
#include <cstdio>
using namespace ASFW::Async;
struct Queue {};
int main() {
  unsigned oldCompletions=0, newerCompletions=0;
  LabelAllocator allocator;
  TransactionManager manager;
  if (!manager.Initialize()) return 2;
  Queue queue;
  Track_Tracking<Queue> tracking(&allocator,&manager,queue);
  TxMetadata oldMeta{};
  oldMeta.generation=7; oldMeta.destinationNodeID=0xffc1;
  oldMeta.tCode=1; oldMeta.completionStrategy=CompletionStrategy::CompleteOnAT;
  oldMeta.callback=[&](auto, auto status, auto, auto) {
    if (status==AsyncStatus::kSuccess) ++oldCompletions;
  };
  auto old=tracking.RegisterTx(oldMeta);
  tracking.OnTxPosted(old,100,500000);
  // Occupy all other labels using admitted transactions; cursor wraps to old.
  for (unsigned n=0;n<63;++n) {
    TxMetadata filler=oldMeta; filler.callback={};
    auto h=tracking.RegisterTx(filler);
    if (!h) return 3;
    tracking.OnTxPosted(h,100,500000);
  }
  RxResponse response{};
  response.generation=7; response.sourceNodeID=0xffc1;
  response.tLabel=static_cast<uint8_t>(old.value-1);
  response.tCode=2; response.rCode=0;
  // Production permits AR before AT (covered by existing completion test).
  tracking.OnRxResponse(response);
  TxMetadata newer=oldMeta;
  newer.callback=[&](auto,auto status,auto,auto) {
    if (status==AsyncStatus::kSuccess) ++newerCompletions;
  };
  auto next=tracking.RegisterTx(newer);
  tracking.OnTxPosted(next,200,500000);
  TxCompletion late{};
  late.tLabel=static_cast<uint8_t>(old.value-1);
  late.eventCode=OHCIEventCode::kAckComplete;
  tracking.OnTxCompletion(late);
  std::printf("old_handle=%u newer_handle=%u old_success=%u newer_success_before_own_completion=%u\n",
      old.value,next.value,oldCompletions,newerCompletions);
  const bool valid = next.value==old.value && oldCompletions==1;
  const bool regression = newerCompletions!=0;
  tracking.CancelAllAndFreeLabels();
  if (!valid) return 4;
  return regression ? 1 : 0;
}
