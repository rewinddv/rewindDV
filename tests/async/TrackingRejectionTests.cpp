#include <gtest/gtest.h>
#include "ASFWDriver/Async/Track/Tracking.hpp"
using namespace ASFW::Async;
struct UnusedQueue {};
TEST(TrackingRejectionTests, RejectedRegistrationsReleaseLabelsWithoutPhantomCallbacks) {
    int called=0; LabelAllocator labels; TransactionManager manager;
    ASSERT_TRUE(manager.Initialize().has_value());
    UnusedQueue queue; Track_Tracking<UnusedQueue> tracking(&labels,&manager,queue);
    TxMetadata meta{}; meta.generation=4;
    meta.callback=[&](auto,auto,auto,auto){++called;};
    for (unsigned n=0;n<128;++n) {
        auto handle=tracking.RegisterTx(meta); ASSERT_NE(handle.value,0u);
        tracking.AbandonUnposted(handle);
        EXPECT_EQ(manager.Count(),0u); EXPECT_FALSE(labels.HasAnyLabelsInUse());
    }
    EXPECT_EQ(called,0);
    auto posted=tracking.RegisterTx(meta); ASSERT_NE(posted.value,0u);
    auto* txn=manager.Find(TLabel{*tracking.GetLabelFromHandle(posted)});
    txn->TransitionTo(TransactionState::ATPosted,"test");
    tracking.AbandonUnposted(posted);
    EXPECT_EQ(manager.Count(),1u);
    tracking.CancelAllAndFreeLabels();
    EXPECT_EQ(called,1); EXPECT_EQ(manager.Count(),0u);
}

TEST(TrackingRejectionTests, QuarantineRetainsPayloadOwnerAfterTrackingIsDestroyed) {
    LabelAllocator labels; TransactionManager manager;
    ASSERT_TRUE(manager.Initialize().has_value());
    UnusedQueue queue;
    PayloadRegistry* retained = nullptr;
    // A deleter-only sentinel proves shared ownership without a device mapping.
    auto payload = std::shared_ptr<PayloadContext>(nullptr, [](PayloadContext*) {});
    std::weak_ptr<PayloadContext> lifetime = payload;
    {
        Track_Tracking<UnusedQueue> tracking(&labels,&manager,queue);
        retained = tracking.Payloads();
        ASSERT_TRUE(retained->Attach(1,std::move(payload),4));
        tracking.QuarantinePayloads();
        EXPECT_EQ(tracking.Payloads(),nullptr);
    }
    EXPECT_FALSE(lifetime.expired());
    // Test-only reclamation: no DMA ever existed in this fixture. Production
    // intentionally does not reclaim an uncertain mapping on a timeout.
    delete retained;
    EXPECT_TRUE(lifetime.expired());
}
