# Platform & Environment Compatibility Rules

## 1. Operating System & SDK Baseline
- **Host / Build SDK:** macOS 27 (Apple Silicon).
- **Minimum Deployment Target:** macOS 15.0+ (Sequoia).
- **Environment Reality:** macOS 27 is the active, real host OS and build environment. Never question its existence or treat it as a hypothetical/future release or typo.

## 2. Deprecations & Compiler Warnings Policy
- **Treat Warnings Seriously:** Do NOT ignore, suppress, or dismiss compiler warnings regarding macOS 27 deprecations under the assumption that the OS "does not exist yet".
- **Modern Replacements:** In macOS 27, various older APIs have become deprecated. The modern replacements for these APIs already exist and are fully backward-compatible with macOS 15.0+.
- **Resolution Strategy:** Always address deprecation warnings by adopting modern, supported APIs that function cleanly on macOS 15.0+ through macOS 27 without deprecation warnings.
- **No Hallucinated Objections:** Never emit comments, disclaimers, or chat warnings arguing that macOS 27 is invalid. Focus directly on resolving diagnostics with modern Apple APIs.
