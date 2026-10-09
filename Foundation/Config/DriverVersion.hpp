// RewindDV Foundation candidate metadata. Upstream baseline is identified below;
// this is a modified downstream article, not an unmodified ASFW binary.
#pragma once
#include <cstdint>
#include "ProductIdentity.hpp"
// Xcode supplies the canonical driver build through DriverBuild.xcconfig.
// Host-only contract fixtures have no deliverable driver identity.
#ifndef REWINDDV_DRIVER_BUILD
#ifdef ASFW_HOST_TEST
#define REWINDDV_DRIVER_BUILD 0
#else
#error "Build Foundation driver with DriverBuild.xcconfig"
#endif
#endif
#ifndef ASFW_HOST_TEST
static_assert(REWINDDV_DRIVER_BUILD == REWINDDV_EXPECTED_DRIVER_BUILD, "Driver identity drift");
#endif
#define REWINDDV_STRINGIFY_IMPL(value) #value
#define REWINDDV_STRINGIFY(value) REWINDDV_STRINGIFY_IMPL(value)
namespace ASFW::Version {
// Legacy source-lineage base, not the final candidate commit. The clean build
// receipt binds executable hashes to the final commit and tree; see checkpoint docs.
inline constexpr const char* kGitCommitFull = "see public source manifest";
inline constexpr const char* kGitCommitShort = "public";
inline constexpr const char* kGitBranch = "public-source";
inline constexpr bool kGitDirty = false;
inline constexpr const char* kBuildTimestamp = "2026-10-04";
inline constexpr const char* kBuildHost = "Xcode 27.0 (27A266a)";
inline constexpr const char* kCompilerVersion = "Apple Clang";
inline constexpr const char* kSemanticVersion = REWINDDV_PRODUCT_VERSION_STRING;
inline constexpr const char* kFullVersionString = "rewindDV " REWINDDV_PRODUCT_VERSION_STRING " (Alpha) Driver Build" REWINDDV_STRINGIFY(REWINDDV_DRIVER_BUILD) " (ASFW ac8a124 derived)";
inline constexpr const char* kBuildInfoString = "Foundation Build" REWINDDV_STRINGIFY(REWINDDV_DRIVER_BUILD) "; ownership and initial-reset hardening; no command replay; macOS 26 minimum; consult candidate source manifest";
}

#undef REWINDDV_STRINGIFY
#undef REWINDDV_STRINGIFY_IMPL
