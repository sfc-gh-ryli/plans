# Clang/LLVM Compiler Build Guide

## Purpose

This document explains the process of building custom Clang/LLVM compilers for FoundationDB (FrostDB), why it's necessary, and how to reproduce the build process.

## Background: Why Build Custom Compilers?

### The Problem

FoundationDB requires specific compiler versions that:
1. **Support C++20/23 features** - The codebase uses modern C++ (coroutines, concepts, ranges)
2. **Match production environments** - Compiler must match what ships in production
3. **Have specific patches** - May need custom patches for compatibility or bug fixes
4. **Are not available in standard repos** - Amazon Linux 2 only provides older GCC/Clang

### Current Compiler Upgrade Context (Clang 21.1.0)

As documented in `UPGRADE_21.1.0_FINDINGS.md`:
- **Goal**: Upgrade from older Clang to Clang 21.1.0 for C++20 compliance
- **Key change**: Clang 21 removed non-standard `char_traits<uint8_t>`, breaking `std::basic_string<uint8_t>`
- **Solution**: Migrated to `std::vector<uint8_t>` + `std::span<uint8_t const>` (see Issue 5 in FINDINGS.md)

## The Build Script: `build_clang_21.1.0.sh`

### What It Does

The script performs a **single-stage LLVM/Clang build** from source:

1. **Downloads** LLVM source tarball (21.1.0) from Artifactory
2. **Validates** SHA256 checksum to ensure integrity
3. **Applies patches** (if any exist in `patches/*.patch`)
4. **Configures** CMake with specific options
5. **Builds** using Ninja (parallel build tool)
6. **Installs** to `plans/compiler_upgrade/installed-21.1.0/`

### Key Configuration Decisions

#### Bootstrap Compiler
```bash
# Uses devtoolset-11 (GCC 11.2.1) if available, fallback to devtoolset-10
source /opt/rh/devtoolset-11/enable
export CC=gcc
export CXX=g++
```
**Why**: Building Clang requires a C++17-capable compiler. System GCC on AL2 is too old.

#### Build Type
```cmake
-DCMAKE_BUILD_TYPE=Release
```
**Why**: Production needs optimized binaries (not Debug builds).

#### Enabled Components
```cmake
-DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb"
-DLLVM_ENABLE_RUNTIMES="compiler-rt;libcxx;libcxxabi;libunwind"
```
**Why**:
- `clang` - The C++ compiler itself
- `lld` - Fast linker (required by FDB build system)
- `libcxx/libcxxabi` - C++ standard library (must match compiler version!)
- `compiler-rt` - Runtime library for sanitizers
- `libunwind` - Stack unwinding for exceptions/debugging

#### Target Architecture
```cmake
-DLLVM_TARGETS_TO_BUILD="$target"  # X86 or AArch64
```
**Why**: Only build for the current architecture to save time (~30-40% faster).

#### Static Linking
```cmake
-DLLVM_STATIC_LINK_CXX_STDLIB=ON
```
**Why**: Embeds libstdc++ into Clang binary, avoiding runtime library conflicts.

### Build Outputs

**Installation directory**: `plans/compiler_upgrade/installed-21.1.0/`

**Key files created**:
```
installed-21.1.0/
├── bin/
│   ├── clang             # C compiler
│   ├── clang++           # C++ compiler
│   ├── lld               # Linker
│   └── FileCheck         # Test utility
├── lib/
│   └── libc++.a          # C++ standard library
├── include/
│   └── c++/v1/           # C++ headers
└── sf_patch.signature    # Patch tracking file
```

## How To Build a New Compiler Version

### Prerequisites

1. **Disk space**: ~50GB free (source + build artifacts)
2. **RAM**: 16GB minimum, 32GB recommended
3. **Time**: 45-90 minutes (varies by CPU count)
4. **Bootstrap compiler**: GCC 11+ or Clang 13+

### Step-by-Step Process

#### 1. Update Version Numbers
```bash
cd plans/compiler_upgrade/
cp build_clang_21.1.0.sh build_clang_21.2.0.sh  # Example for 21.2.0
```

Edit the script:
```bash
CLANG_VERSION=21.2.0
CLANG_PROJECT_SHA=PLACEHOLDER_WILL_UPDATE_AFTER_DOWNLOAD
INSTALL_DIR=/home/ryli/fdb/plans/compiler_upgrade/installed-21.2.0
```

#### 2. Get the Correct SHA256

Run once to download and see the SHA:
```bash
./build_clang_21.2.0.sh 2>&1 | grep "Computed SHA256"
```

Update script with the real SHA256, then run again.

#### 3. Run the Build
```bash
./build_clang_21.2.0.sh
```

**Build time**: Expect 45-90 minutes depending on CPU count.

#### 4. Verify Installation
```bash
installed-21.2.0/bin/clang++ --version
# Should show: clang version 21.2.0
```

### Troubleshooting Build Failures

**Error: "devtoolset not found"**
- Install devtoolset-11: `sudo yum install devtoolset-11-gcc devtoolset-11-gcc-c++`
- Or use newer system compiler: `export CC=gcc CXX=g++`

**Error: "ninja: command not found"**
- Install ninja: `pip install ninja` or `sudo yum install ninja-build`

**Error: "out of memory"**
- Reduce parallel jobs: `export CPUS=4` before running script

**Error: "checksum mismatch"**
- Download may be corrupted, delete and retry
- Or verify you have the correct SHA256 for the version

## Integrating New Compiler with Bazel

### 1. Register Compiler in `.bazelrc`

Add toolchain configuration:
```python
# .bazelrc
build:clang21 --repo_env=CLANG_VERSION=21.2.0
build:clang21 --repo_env=CLANG_DIR=/home/ryli/fdb/plans/compiler_upgrade/installed-21.2.0
```

### 2. Update Toolchain Repository

Edit `toolchain/BUILD.bazel` or repository rules to reference new compiler:
```python
cc_toolchain(
    name = "clang_21_2_0",
    toolchain_identifier = "clang-21.2.0",
    compiler_files = ":compiler_clang_21_2_0",
    # ... other settings
)
```

### 3. Test the Build

```bash
bazel build --config=clang21 //bindings/c/test/unit:fdb_c_unit_tests
```

## Common Compiler Upgrade Issues

### Issue 1: Standard Library Changes

**Example**: Clang 21 removed `char_traits<uint8_t>` (see Issue 5 in FINDINGS.md)

**Solution**: Migrate to standard-compliant types:
- `std::basic_string<uint8_t>` → `std::vector<uint8_t>`
- `std::basic_string_view<uint8_t>` → `std::span<uint8_t const>`

### Issue 2: Library Version Mismatches

**Example**: fmt library API changes between versions

**Solution**:
- `fmt::localtime()` removed → use `*std::localtime(&time_t)`
- `fmt::join()` moved to `<fmt/ranges.h>`

### Issue 3: Stricter Warnings/Errors

**Example**: VLA (Variable Length Arrays) now error with `-Werror`

**Solution**: Replace VLAs with `std::vector`:
```cpp
// Before:
char buf[size];  // ERROR: VLA not allowed in C++

// After:
std::vector<char> buf(size);
```

## Patch Management

### When to Add Patches

Patches should be added to `patches/*.patch` when:
1. Upstream LLVM has a bug affecting FDB
2. Need to backport a fix from a newer version
3. Require FDB-specific modifications

### Creating a Patch

```bash
cd /path/to/llvm/source
# Make your changes
git diff > ~/fdb/plans/compiler_upgrade/patches/001-fix-something.patch
```

The build script automatically applies all `*.patch` files in order.

### Patch Signature File

The build creates `sf_patch.signature` containing:
- List of applied patches
- Their checksums
- Build timestamp

This helps track which patches are in production builds.

## Build Performance Tips

### Faster Builds

1. **Reduce targets**: Only build what you need
   ```cmake
   -DLLVM_TARGETS_TO_BUILD="X86"  # vs "all"
   ```
   Saves ~30-40% build time

2. **Use ccache**: Cache compiler outputs
   ```bash
   export CC="ccache gcc"
   export CXX="ccache g++"
   ```

3. **More parallelism**: If you have RAM
   ```bash
   export CPUS=32
   ```

4. **Skip tests**: Already disabled in script
   ```cmake
   -DLLVM_INCLUDE_TESTS=OFF
   ```

### Disk Space Management

**During build**:
- Source: ~2GB
- Build artifacts: ~15-25GB
- Total: ~30GB

**After install**:
- Installed: ~3-5GB
- Build artifacts deleted by script

## History and Evolution

### Previous Compilers

- **GCC 4.8** - Original FDB compiler (too old for C++20)
- **GCC 7.x** - Intermediate upgrade
- **Clang 13-16** - Previous Clang versions
- **Clang 21.1.0** - Current target (this upgrade)

### Why Clang Over GCC?

1. **Better C++20 support** - Earlier adoption of new standards
2. **Better error messages** - More helpful diagnostics
3. **Faster compilation** - In many cases
4. **Sanitizer support** - ASAN/UBSAN work better
5. **Industry standard** - Used by Apple, Google, etc.

## Related Files

- **This guide**: `COMPILER_BUILD_GUIDE.md`
- **Build script**: `build_clang_21.1.0.sh`
- **Findings doc**: `UPGRADE_21.1.0_FINDINGS.md` - Tracks migration issues
- **Patches dir**: `patches/` - Custom patches (if any)
- **Installed compiler**: `installed-21.1.0/` - Build output

## Quick Reference

### Build New Compiler
```bash
cd plans/compiler_upgrade/
./build_clang_21.1.0.sh
# Wait 45-90 minutes
```

### Verify Compiler
```bash
installed-21.1.0/bin/clang++ --version
installed-21.1.0/bin/clang++ -v
```

### Test with Simple Program
```bash
echo 'int main() {}' > test.cpp
installed-21.1.0/bin/clang++ -std=c++20 test.cpp -o test
./test && echo "Success!"
```

### Use in Bazel Build
```bash
bazel build --config=clang21 //your/target
```

## Future Compiler Upgrades

When upgrading to a new compiler version in the future:

1. **Read release notes** - Check LLVM release notes for breaking changes
2. **Update build script** - Copy and modify version numbers
3. **Create findings doc** - Track issues as you encounter them
4. **Fix issues systematically** - Use build-driven approach (compile, fix, repeat)
5. **Test incrementally** - Start with unit tests, then expand
6. **Document patterns** - Record common fix patterns for future reference

## Lessons Learned from Clang 21 Upgrade

### What Worked Well

1. **Build-driven fixes** - Let compiler find all issues, fix systematically
2. **Incremental testing** - Build small targets first (unit tests), then expand
3. **Helper functions** - Created `toByteString()`, `bytesEqual()`, `concat()` for common patterns
4. **Clear documentation** - FINDINGS.md tracked all issues

### What To Watch For

1. **Type alias issues** - Operators don't work via ADL with type aliases
2. **Library compatibility** - Standard library changes (fmt, ranges, etc.)
3. **Formatter conflicts** - Be careful with custom formatters + range formatters
4. **Stricter checking** - New compilers enable more warnings/errors

### Time Estimates

- Building compiler: 45-90 minutes
- Fixing compilation errors: 20-40 hours (depends on breaking changes)
- Testing and validation: 4-8 hours
- **Total**: Plan 1-2 weeks for a major compiler upgrade

## Questions for Future Agents

If you're working on a compiler upgrade, ask:

1. **What breaking changes?** - Check LLVM release notes
2. **Which targets fail first?** - Start with unit tests
3. **What patterns emerge?** - Look for common error types
4. **Can it be automated?** - regex replacements for simple patterns
5. **Need patches?** - Check if upstream bugs need workarounds

## Success Criteria

A compiler upgrade is complete when:

✅ All test targets build successfully
✅ Unit tests pass
✅ Integration tests pass
✅ No compiler warnings in CI
✅ Documentation updated
✅ FINDINGS document complete

---

**Last Updated**: 2025-11-17
**Compiler Version**: Clang 21.1.0
**Status**: Build script working, migration complete for ByteString issue
