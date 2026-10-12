// SPDX-License-Identifier: Apache-2.0
// RewindDV regression coverage for host-only DriverKit ownership.
#include <gtest/gtest.h>
#include "ASFWDriver/Testing/HostDriverKitStubs.hpp"

namespace {
struct Tracked final : OSObject {
    explicit Tracked(int& destroyed) : destroyed_(destroyed) {}
    ~Tracked() override { ++destroyed_; }
    int& destroyed_;
};
}

TEST(HostOwnership, FinalReleaseDestroysExactlyOnce) {
    int destroyed = 0;
    auto* object = new Tracked(destroyed);
    object->retain();
    EXPECT_EQ(object->GetRetainCount(), 2);
    object->release();
    EXPECT_EQ(destroyed, 0);
    object->release();
    EXPECT_EQ(destroyed, 1);
}

TEST(HostOwnership, AdoptCopyMoveAndDetachPreserveReferences) {
    int destroyed = 0;
    auto* object = new Tracked(destroyed);
    {
        OSSharedPtr<Tracked> first(object, OSNoRetain);
        EXPECT_EQ(object->GetRetainCount(), 1);
        auto second = first;
        EXPECT_EQ(object->GetRetainCount(), 2);
        OSSharedPtr<Tracked> third(std::move(second));
        EXPECT_FALSE(second);
        EXPECT_EQ(object->GetRetainCount(), 2);
        auto* detached = third.detach();
        EXPECT_FALSE(third);
        EXPECT_EQ(detached, object);
        detached->release();
        EXPECT_EQ(object->GetRetainCount(), 1);
        EXPECT_EQ(destroyed, 0);
    }
    EXPECT_EQ(destroyed, 1);
}

TEST(HostOwnership, RetainingAliasAndSelfAssignmentDoNotReleaseEarly) {
    int destroyed = 0;
    auto* object = new Tracked(destroyed);
    OSSharedPtr<Tracked> first(object, OSRetain);
    object->release();
    first.reset(first.get(), OSRetain);
    auto& alias = first;
    first = alias;
    first = std::move(alias);
    EXPECT_EQ(object->GetRetainCount(), 1);
    EXPECT_EQ(destroyed, 0);
    first.reset();
    EXPECT_EQ(destroyed, 1);
}

TEST(HostOwnership, AssignmentReleasesPreviousObject) {
    int destroyedA = 0, destroyedB = 0;
    OSSharedPtr<Tracked> first(new Tracked(destroyedA), OSNoRetain);
    OSSharedPtr<Tracked> second(new Tracked(destroyedB), OSNoRetain);
    first = second;
    EXPECT_EQ(destroyedA, 1);
    EXPECT_EQ(second->GetRetainCount(), 2);
    first.reset();
    EXPECT_EQ(destroyedB, 0);
    OSSharedPtr<Tracked> last;
    last = std::move(second);
    EXPECT_FALSE(second);
    last.reset();
    EXPECT_EQ(destroyedB, 1);
}

TEST(HostOwnership, AdoptingSamePointerTransfersAnExistingOwnedReference) {
    int destroyed = 0;
    auto* object = new Tracked(destroyed);
    OSSharedPtr<Tracked> owner(object, OSNoRetain);
    object->retain(); // separately owned +1 transferred by reset below
    owner.reset(object, OSNoRetain);
    EXPECT_EQ(object->GetRetainCount(), 1);
    EXPECT_EQ(destroyed, 0);
    owner.reset();
    EXPECT_EQ(destroyed, 1);
}
