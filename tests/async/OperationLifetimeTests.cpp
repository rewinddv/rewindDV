// Modified by Rewind Digital for rewindDV; software-only ownership regressions.
#include <gtest/gtest.h>
#include "ASFWDriver/Async/Track/Tracking.hpp"
#include <array>
#include <thread>
using namespace ASFW::Async;
namespace {
struct Queue {};
struct Lifetime : testing::Test {
    LabelAllocator labels;
    TransactionManager manager;
    Queue queue;
    Track_Tracking<Queue> tracking{&labels, &manager, queue};
    unsigned callbacks{0};
    void SetUp() override { ASSERT_TRUE(manager.Initialize()); }
    TxMetadata Metadata() {
        TxMetadata meta{}; meta.generation=7; meta.destinationNodeID=0xffc1;
        meta.tCode=1; meta.completionStrategy=CompletionStrategy::CompleteOnAT;
        meta.callback=[this](auto,auto,auto,auto){++callbacks;}; return meta;
    }
    AsyncHandle Post() {
        auto h=tracking.RegisterTx(Metadata());
        if(h) tracking.OnTxPosted(h,100,500000);
        return h;
    }
    uint8_t Label(AsyncHandle h) { return static_cast<uint8_t>((h.value-1)&63); }
    TxCompletion Completion(AsyncHandle h) {
        TxCompletion c{}; c.operationIdentity=h.value; c.tLabel=Label(h);
        c.eventCode=OHCIEventCode::kAckComplete; return c;
    }
    void Response(AsyncHandle h, uint16_t generation=7, uint16_t node=0xffc1) {
        RxResponse r{}; r.generation=generation; r.sourceNodeID=node;
        r.tLabel=Label(h); r.tCode=2; tracking.OnRxResponse(r);
    }
};
TEST_F(Lifetime, ExhaustSpaceARBeforeATThenReuseAndDeliverOldCompletion) {
    std::array<AsyncHandle,64> old{};
    for(auto& h:old) { h=Post(); ASSERT_TRUE(h); }
    EXPECT_FALSE(Post());
    Response(old[0]); EXPECT_EQ(callbacks,1u);
    EXPECT_FALSE(Post()); // AR does not retire local AT ownership.
    auto late=Completion(old[0]); tracking.OnTxCompletion(late);
    auto next=Post(); ASSERT_TRUE(next);
    EXPECT_EQ(Label(next),Label(old[0])); EXPECT_NE(next.value,old[0].value);
    tracking.OnTxCompletion(late); // exact copied old program token after reuse
    EXPECT_EQ(callbacks,1u); EXPECT_TRUE(tracking.GetLabelFromHandle(next));
    EXPECT_FALSE(tracking.GetLabelFromHandle(old[0]));
    tracking.OnTxCompletion(Completion(next)); EXPECT_EQ(callbacks,2u);
    for(size_t i=1;i<64;++i) tracking.OnTxCompletion(Completion(old[i]));
    EXPECT_EQ(callbacks,65u); EXPECT_FALSE(labels.HasAnyLabelsInUse());
}
TEST_F(Lifetime, PayloadSurvivesARAndExpiresOnlyAtProgramRetirement) {
    auto h=Post(); auto payload=std::shared_ptr<PayloadContext>(nullptr,[](PayloadContext*){});
    std::weak_ptr<PayloadContext> weak=payload;
    ASSERT_TRUE(tracking.Payloads()->Attach(h.value,std::move(payload),7));
    Response(h); EXPECT_FALSE(weak.expired());
    tracking.OnTxCompletion(Completion(h)); EXPECT_TRUE(weak.expired());
}
TEST_F(Lifetime, CancelAndResetNeverClearUncertainWireFence) {
    auto h=Post(); tracking.CancelAllAndFreeLabels();
    EXPECT_EQ(callbacks,1u); EXPECT_TRUE(labels.HasUncertainWire());
    EXPECT_FALSE(Post());
    tracking.OnTxCompletion(Completion(h));
    tracking.RetireStoppedAT(); labels.ClearBitmap(); labels.Reset();
    EXPECT_TRUE(labels.IsLabelInUse(Label(h))); EXPECT_FALSE(Post());
    Response(h); EXPECT_EQ(callbacks,1u);
}
TEST_F(Lifetime, StopCancellationAfterLocalDMARetirementPreservesRemoteUncertainty) {
    auto meta=Metadata();
    bool callbackSawFence=false;
    meta.callback=[&](auto,auto,auto,auto){
        ++callbacks;
        callbackSawFence=labels.HasUncertainWire();
        EXPECT_EQ(manager.Count(),0u);
        EXPECT_FALSE(Post());
    };
    auto h=tracking.RegisterTx(meta); ASSERT_TRUE(h);
    tracking.OnTxPosted(h,100,500000);
    tracking.RetireStoppedAT(); // Root Stop first establishes local DMA retirement.
    EXPECT_FALSE(labels.HasUncertainWire());
    tracking.CancelAllAndFreeLabels();
    EXPECT_EQ(callbacks,1u); EXPECT_TRUE(callbackSawFence);
    labels.Reset(); labels.ClearBitmap();
    EXPECT_TRUE(labels.HasUncertainWire()); EXPECT_FALSE(Post());
    Response(h); tracking.OnTxCompletion(Completion(h));
    EXPECT_EQ(callbacks,1u); EXPECT_TRUE(labels.HasUncertainWire());
}
TEST_F(Lifetime, TimeoutThenLateATCannotReopenAdmission) {
    auto h=Post();
    for(unsigned n=0;n<8;++n) tracking.OnTimeoutTick(UINT64_MAX);
    EXPECT_EQ(callbacks,1u); EXPECT_TRUE(labels.HasUncertainWire());
    tracking.OnTxCompletion(Completion(h)); Response(h);
    EXPECT_EQ(callbacks,1u); EXPECT_FALSE(Post());
}
TEST_F(Lifetime, WrongGenerationRouteMalformedAndDuplicateCannotComplete) {
    auto h=Post(); Response(h,8); Response(h,7,0xffc2); EXPECT_EQ(callbacks,0u);
    auto malformed=Completion(h); malformed.operationIdentity+=64;
    tracking.OnTxCompletion(malformed); EXPECT_EQ(callbacks,0u);
    malformed=Completion(h); malformed.tLabel=255;
    tracking.OnTxCompletion(malformed); EXPECT_EQ(callbacks,0u);
    tracking.OnTxCompletion(Completion(h)); tracking.OnTxCompletion(Completion(h));
    EXPECT_EQ(callbacks,1u);
}
TEST_F(Lifetime, ReentrantCompletionKeepsNewOwner) {
    auto meta=Metadata(); AsyncHandle next{};
    meta.callback=[&](auto,auto,auto,auto){ ++callbacks; next=Post(); };
    auto h=tracking.RegisterTx(meta); tracking.OnTxPosted(h,100,500000);
    tracking.OnTxCompletion(Completion(h)); ASSERT_TRUE(next);
    EXPECT_TRUE(tracking.GetLabelFromHandle(next));
    tracking.OnTxCompletion(Completion(next)); EXPECT_EQ(callbacks,2u);
}
TEST_F(Lifetime, UnpostedRollbackReleasesPayloadWithoutCallback) {
    auto h=tracking.RegisterTx(Metadata());
    auto payload=std::shared_ptr<PayloadContext>(nullptr,[](PayloadContext*){});
    std::weak_ptr<PayloadContext> weak=payload;
    ASSERT_TRUE(tracking.Payloads()->Attach(h.value,std::move(payload),7));
    ASSERT_TRUE(tracking.PreparePosted(h)); tracking.AbandonUnposted(h);
    EXPECT_TRUE(weak.expired()); EXPECT_FALSE(labels.HasAnyLabelsInUse());
    EXPECT_EQ(callbacks,0u); EXPECT_FALSE(labels.HasUncertainWire());
}
TEST_F(Lifetime, DuplicatePayloadAttachCannotReplaceOwner) {
    auto h=Post(); auto p=std::shared_ptr<PayloadContext>(nullptr,[](PayloadContext*){});
    std::weak_ptr<PayloadContext> weak=p;
    ASSERT_TRUE(tracking.Payloads()->Attach(h.value,std::move(p),7));
    EXPECT_FALSE(tracking.Payloads()->Attach(h.value,{},7)); EXPECT_FALSE(weak.expired());
    tracking.OnTxCompletion(Completion(h)); EXPECT_TRUE(weak.expired());
}
TEST_F(Lifetime, ProgramRetirementIsMonotonicBeforePostedNotification) {
    auto h=tracking.RegisterTx(Metadata()); ASSERT_TRUE(tracking.PreparePosted(h));
    EXPECT_TRUE(labels.RetireAT(h.value)); tracking.OnTxPosted(h,100,500000);
    EXPECT_FALSE(labels.RetireAT(h.value)); // second posted notification cannot resurrect DMA
    Response(h); EXPECT_FALSE(labels.HasAnyLabelsInUse());
}
TEST_F(Lifetime, CancelBeforePublicationRefusesAndRollbackReleasesOnlyOldOwner) {
    auto h=tracking.RegisterTx(Metadata()); ASSERT_TRUE(h);
    tracking.CancelAllAndFreeLabels();
    EXPECT_FALSE(tracking.PreparePosted(h));
    auto next=Post(); ASSERT_TRUE(next);
    tracking.RollbackUnpublished(h);
    EXPECT_TRUE(tracking.GetLabelFromHandle(next));
    tracking.OnTxCompletion(Completion(next));
}
TEST_F(Lifetime, CancelAfterPrepareThenRefusedSubmitReclaimsUnpublishedProgram) {
    auto h=tracking.RegisterTx(Metadata()); ASSERT_TRUE(tracking.PreparePosted(h));
    tracking.OnTxPosted(h,100,500000);
    tracking.CancelAllAndFreeLabels(); EXPECT_TRUE(labels.HasUncertainWire());
    tracking.RollbackUnpublished(h); // proven synchronous submit refusal, no DMA existed
    EXPECT_FALSE(labels.HasUncertainWire()); EXPECT_FALSE(labels.HasAnyLabelsInUse());
    EXPECT_TRUE(Post());
}
TEST_F(Lifetime, UnsolicitedResponseCannotCompleteUnpublishedRegistration) {
    auto h=tracking.RegisterTx(Metadata()); Response(h); EXPECT_EQ(callbacks,0u);
    EXPECT_TRUE(tracking.GetLabelFromHandle(h)); tracking.AbandonUnposted(h);
}
TEST_F(Lifetime, UncertainLateWirePreservesBoundedEvidenceWithoutSuccess) {
    auto h=Post(); tracking.CancelAllAndFreeLabels();
    std::array<uint8_t,600> bytes{}; bytes.fill(0x5a);
    RxResponse r{}; r.generation=7; r.sourceNodeID=0xffc1; r.tLabel=Label(h); r.payload=bytes;
    tracking.OnRxResponse(r); tracking.OnRxResponse(r);
    const auto e=tracking.CopyUnattributedResponseEvidence();
    EXPECT_EQ(e.count,2u); EXPECT_TRUE(e.uncertainWire);
    EXPECT_EQ(e.wirePayloadLength,600u); EXPECT_EQ(e.preservedPrefixLength,512u);
    EXPECT_EQ(e.latestPrefix.front(),0x5a); EXPECT_EQ(e.latestPrefix.back(),0x5a);
    EXPECT_EQ(callbacks,1u); EXPECT_FALSE(Post());
}
TEST_F(Lifetime, ExternalProtocolUncertaintyFencesFreshOperations) {
    labels.FenceWireResponses(); EXPECT_FALSE(Post());
    labels.ClearBitmap(); labels.Reset(); EXPECT_FALSE(Post());
}
TEST(OperationIdentity, TokensDoNotRepeatAcrossTrackingReconstruction) {
    uint32_t first=0;
    for(unsigned i=0;i<2;++i) {
        LabelAllocator labels; TransactionManager manager; ASSERT_TRUE(manager.Initialize());
        Queue queue; Track_Tracking<Queue> tracking(&labels,&manager,queue);
        auto h=tracking.RegisterTx({}); ASSERT_TRUE(h);
        if(i) EXPECT_NE(h.value,first); else first=h.value;
        tracking.AbandonUnposted(h);
    }
}
TEST(OperationIdentity, ConcurrentAllocatorCyclesRemainBoundedAndExclusive) {
    LabelAllocator labels; std::array<std::atomic<unsigned>,64> owners{};
    std::atomic<bool> duplicate=false;
    std::array<std::thread,8> workers;
    for(auto& worker:workers) worker=std::thread([&]{
        for(unsigned n=0;n<10000;++n) {
            auto label=labels.Allocate(); if(label==255) continue;
            if(owners[label].fetch_add(1)!=0) duplicate=true;
            owners[label].fetch_sub(1); labels.Free(label);
        }
    });
    for(auto& worker:workers) worker.join();
    EXPECT_FALSE(duplicate); EXPECT_FALSE(labels.HasAnyLabelsInUse());
}
}
