// RewindDV Foundation candidate metadata. Upstream baseline is identified below;
// this is a modified downstream article, not an unmodified ASFW binary.
#pragma once
#include <cstdint>
namespace ASFW::Version {
// Legacy source-lineage base, not the final candidate commit. The clean build
// receipt binds executable hashes to the final commit and tree; see checkpoint docs.
inline constexpr const char* kGitCommitFull = "56ce9a5f590f63ab6b089b3e7ddf06b0a6a75adf";
inline constexpr const char* kGitCommitShort = "56ce9a5f";
inline constexpr const char* kGitBranch = "codex/clean-source-remediation";
inline constexpr bool kGitDirty = false;
inline constexpr const char* kBuildTimestamp = "2026-10-04";
inline constexpr const char* kBuildHost = "Xcode 27.0 (27A266a)";
inline constexpr const char* kCompilerVersion = "Apple Clang";
inline constexpr const char* kSemanticVersion = "0.1.0";
inline constexpr const char* kFullVersionString = "RewindDV Foundation 0.1.0 Build188 (ASFW ac8a124 derived)";
inline constexpr const char* kBuildInfoString = "Foundation Build188; prepare shared timer before controller dependency copy; nonblocking reset recovery; no command replay; macOS 26 minimum; consult candidate source manifest";
}
