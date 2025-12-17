# Implementation Plan: S3 to Artifactory Migration

## Overview
Migrate FDB build dependencies from S3 to Artifactory by creating build scripts in `third-party-repack/`, uploading artifacts, and updating MODULE.bazel files to use `cloud_http_archive` instead of `s3_archive`.

## Dependencies to Migrate
1. **sysroot_aarch64** - System root files for ARM64 builds
2. **sysroot_x86_64** - System root files for x86_64 builds
3. **awssdk** - AWS SDK C++ library (version 1.11.252)
4. **gcc** - GCC toolchain (already completed, build script exists)

## Migration Strategy

### Phase 1: Sysroot Optimization & Build Scripts

#### 1.1 Sysroot Analysis
**Goal**: Minimize sysroot contents by identifying essential files

**Current State**:
- x86_64 sysroot: `sysroot-20250211185051.tar.gz` (SHA: 65b48c94c2ca4913e2e478258d0e5eaf5826541d1b5024cc92bdf412ba45bc08)
- aarch64 sysroot: `sysroot-aarch64-20250409220340.tar.gz` (SHA: f4767d27a104e363a5ed591fa81659a28bbcc9b4d6cdfe141ced12ca1bb6e309)

**Used Files** (confirmed by BUILD files and toolchain config):
- `lib64/libcrypto.so.3` - OpenSSL crypto library
- `lib64/libssl.so.3` - OpenSSL SSL library
- `usr/lib64/libssl.a` - Static SSL library
- `usr/lib64/libcrypto.a` - Static crypto library
- `usr/lib64/libssl.so` - SSL dynamic library symlink
- `usr/lib64/libcrypto.so` - Crypto dynamic library symlink
- Headers in `/usr/include` - System headers
- C++ headers in `/usr/local/include/c++/` - Standard library headers
- Libraries in `/usr/lib64` and `/lib64` - System libraries
- GCC runtime from `/opt/rh/devtoolset-*/` - Toolchain libraries

**Iteration Strategy**:
1. Use Docker to test minimal sysroot builds locally
2. Pull FDB build images:
   - x86_64: `frostdb/devel:centos7-PR-10588-amd64`
   - aarch64: `frostdb/devel:centos7-PR-XXXXX-arm64` (find correct tag)
3. Create test sysroot with minimal files
4. Use `local_repository` in MODULE.bazel to test locally
5. Run `bazel build //...` to identify missing files
6. Iteratively add files until build succeeds
7. Document final minimal file list

**Commands for local testing**:
```bash
# Pull and run docker image
docker pull artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/internal-development-docker-fdb_images-local/frostdb/devel:centos7-PR-10588-amd64
docker run -v $(pwd):/workspace -w /workspace <image> bash /workspace/pack_sysroot.sh

# Test with local_repository in MODULE.bazel
local_repository(
    name = "sysroot_x86_64",
    path = "/path/to/local/sysroot-test.tar.gz",
)

# Build to find missing dependencies
bazel build //...
```

#### 1.2 Create Sysroot Build Scripts

**Location**: `third-party-repack/fdb/sysroot/`

**Files to create**:
1. `build.sh` - Main orchestration script (runs docker containers)
2. `sysroot_build_x86_64.sh` - Build script for x86_64 (runs inside docker)
3. `sysroot_build_aarch64.sh` - Build script for aarch64 (runs inside docker)

**build.sh structure** (follows gcc pattern):
```bash
#!/bin/bash
set -euxo pipefail

# Authenticate to Artifactory
sf artifact oci auth

# Build x86_64 sysroot
X86_IMAGE="artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/internal-development-docker-fdb_images-local/frostdb/devel:centos7-PR-10588-amd64"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

DOCKER_CONTAINER_X86="$(docker create -v "${SCRIPT_DIR}":/sysroot -w /sysroot "$X86_IMAGE" bash /sysroot/sysroot_build_x86_64.sh)"
docker start -a "$DOCKER_CONTAINER_X86"
docker cp "$DOCKER_CONTAINER_X86":/sysroot/sysroot-x86_64.tar.gz .
docker rm -f "$DOCKER_CONTAINER_X86"

# Build aarch64 sysroot (on aarch64 Jenkins node)
AARCH64_IMAGE="<find-correct-image>"
DOCKER_CONTAINER_AARCH64="$(docker create -v "${SCRIPT_DIR}":/sysroot -w /sysroot "$AARCH64_IMAGE" bash /sysroot/sysroot_build_aarch64.sh)"
docker start -a "$DOCKER_CONTAINER_AARCH64"
docker cp "$DOCKER_CONTAINER_AARCH64":/sysroot/sysroot-aarch64.tar.gz .
docker rm -f "$DOCKER_CONTAINER_AARCH64"

# Upload to Artifactory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
X86_VERSIONED="sysroot-x86_64-${TIMESTAMP}.tar.gz"
AARCH64_VERSIONED="sysroot-aarch64-${TIMESTAMP}.tar.gz"

mv sysroot-x86_64.tar.gz "$X86_VERSIONED"
mv sysroot-aarch64.tar.gz "$AARCH64_VERSIONED"

sf artifact raw push --file "$X86_VERSIONED" --repository internal-AUTOSELECT-generic-third_party_repack-local --path /fdb/sysroot/$X86_VERSIONED --transfer-timeout 15m
sf artifact raw push --file "$AARCH64_VERSIONED" --repository internal-AUTOSELECT-generic-third_party_repack-local --path /fdb/sysroot/$AARCH64_VERSIONED --transfer-timeout 15m
```

**sysroot_build_x86_64.sh** (based on pack_sysroot.sh):
```bash
#!/bin/bash
set -ex

# Clean up
rm -rf sysroot

# Directories to package (optimized list from Phase 1.1)
dirs=(
    "/usr/include"
    "/usr/local/include/c++"
    "/usr/local/include/x86_64-unknown-linux-gnu/c++"
    "/usr/lib64"
    "/lib64"
    "/opt/rh/devtoolset-11/root/usr/lib/gcc/x86_64-redhat-linux/11"
)

# Copy files
for from in "${dirs[@]}"; do
    to="$(dirname $from)"
    mkdir -p "sysroot$to"
    cp -r "$from" "sysroot$to"
done

# Create tarball
tar -czf sysroot-x86_64.tar.gz sysroot

echo "x86_64 sysroot build complete"
```

**sysroot_build_aarch64.sh** (similar structure):
```bash
#!/bin/bash
set -ex

# Clean up
rm -rf sysroot

# Directories for aarch64
dirs=(
    "/usr/include"
    "/usr/local/include/c++/11"
    "/usr/local/include/x86_64-unknown-linux-gnu/c++"
    "/usr/lib64"
    "/lib64"
    "/opt/rh/devtoolset-10/root/usr/lib/gcc/aarch64-redhat-linux/10"
)

# Copy files
for from in "${dirs[@]}"; do
    to="$(dirname $from)"
    mkdir -p "sysroot$to"
    cp -r "$from" "sysroot$to"
done

# Create tarball
tar -czf sysroot-aarch64.tar.gz sysroot

echo "aarch64 sysroot build complete"
```

### Phase 2: AWS SDK Build Scripts

#### 2.1 Create AWS SDK Build Script

**Location**: `third-party-repack/fdb/awssdk/`

**Files to create**:
1. `build.sh` - Parameterized build and upload script

**build.sh structure**:
```bash
#!/bin/bash
set -exo pipefail

# Parse arguments
AWSSDK_VERSION="${1:-1.11.252}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}/workspace"
PACKAGE_DIR="${WORKSPACE}/packages"

echo "====== AWS SDK Build Configuration ======"
echo "AWS SDK Version: ${AWSSDK_VERSION}"
echo "=========================================="

# Clean workspace
rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}" "${PACKAGE_DIR}"

# Clone and checkout specific version
cd "${WORKSPACE}"
git clone --depth 1 https://github.com/aws/aws-sdk-cpp aws-sdk-cpp
cd aws-sdk-cpp
git fetch origin tag "${AWSSDK_VERSION}" --depth 1
git checkout "${AWSSDK_VERSION}"
git submodule init
git submodule update --init --recursive --depth 1

# Create tarball (exclude .git directories)
cd "${WORKSPACE}"
ARCHIVE_NAME="aws-sdk-cpp-${AWSSDK_VERSION}.tar.gz"
tar czf "${PACKAGE_DIR}/${ARCHIVE_NAME}" --exclude .git --exclude '*/.git' -C aws-sdk-cpp .

# Calculate SHA256
cd "${PACKAGE_DIR}"
SHA256=$(sha256sum "${ARCHIVE_NAME}" | cut -d' ' -f1)

# Create build info
cat > "${PACKAGE_DIR}/build_info.txt" << EOF
Archive: ${ARCHIVE_NAME}
SHA256: ${SHA256}
Version: ${AWSSDK_VERSION}
Built: $(date +%Y%m%d-%H%M%S)
EOF

echo ""
echo "====== Build Information ======"
cat "${PACKAGE_DIR}/build_info.txt"
echo "==============================="
echo ""

# Upload to Artifactory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
VERSIONED_NAME="aws-sdk-cpp-${AWSSDK_VERSION}-${TIMESTAMP}.tar.gz"

echo "Uploading ${VERSIONED_NAME} to Artifactory..."
mv "${ARCHIVE_NAME}" "${VERSIONED_NAME}"

sf artifact raw push \
    --file "${PACKAGE_DIR}/${VERSIONED_NAME}" \
    --repository internal-AUTOSELECT-generic-third_party_repack-local \
    --path "/fdb/awssdk/${VERSIONED_NAME}" \
    --transfer-timeout 15m

echo "Upload complete!"
echo "Artifactory path: internal-AUTOSELECT-generic-third_party_repack-local/fdb/awssdk/${VERSIONED_NAME}"
echo ""

# Cleanup
cd "${SCRIPT_DIR}"
rm -rf "${WORKSPACE}"
echo "Build complete and workspace cleaned"
```

**Usage**:
```bash
# Build default version (1.11.252)
./build.sh

# Build specific version
./build.sh 1.11.252
```

### Phase 3: GCC Verification

**Status**: Build script already exists at `third-party-repack/fdb/gcc/`

**Action**: Verify the script works correctly
- Review `build.sh` and `gcc_build_script.sh`
- Confirm docker image is accessible
- Test build process if needed
- No changes required unless issues found

### Phase 4: Run Build Pipelines

**Prerequisites**:
- All build scripts merged into `third-party-repack/` repository
- Jenkins nodes available (x86_64 and aarch64)
- Artifactory credentials configured

**Execution** (performed by user):
1. User merges PR with build scripts
2. User runs Jenkins pipelines for each dependency:
   - `sysroot` (both architectures)
   - `awssdk`
   - `gcc` (if needed)
3. User provides Artifactory URLs and SHA256 hashes

**Expected outputs**:
```
# Sysroot x86_64
URL: https://artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/artifactory/internal-production-generic-third_party_repack-local/fdb/sysroot/sysroot-x86_64-YYYYMMDD-HHMMSS.tar.gz
SHA256: <hash>

# Sysroot aarch64
URL: https://artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/artifactory/internal-production-generic-third_party_repack-local/fdb/sysroot/sysroot-aarch64-YYYYMMDD-HHMMSS.tar.gz
SHA256: <hash>

# AWS SDK
URL: https://artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/artifactory/internal-production-generic-third_party_repack-local/fdb/awssdk/aws-sdk-cpp-1.11.252-YYYYMMDD-HHMMSS.tar.gz
SHA256: <hash>

# GCC (if rebuilt)
URL: https://artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/artifactory/internal-production-generic-third_party_repack-local/fdb/gcc/gcc-15-x86_64-YYYYMMDD-HHMMSS.tar.gz
SHA256: <hash>
```

### Phase 5: Update MODULE.bazel Files

#### 5.1 Update frostdb/dependencies/sysroot/MODULE.bazel

**Current**:
```python
s3_archive(
    name = "sysroot_aarch64",
    bucket = "sfc-eng-jenkins/foundationdb/bazel/temp",
    build_file = "//:sysroot.BUILD",
    file_path = "sysroot-aarch64-20250409220340.tar.gz",
    sha256 = "f4767d27a104e363a5ed591fa81659a28bbcc9b4d6cdfe141ced12ca1bb6e309",
    strip_prefix = "sysroot",
    patches = ["//:fix-linker-scripts-aarch64.patch"],
    patch_args = ["-p0", "--fuzz=1"],
)

s3_archive(
    name = "sysroot_x86_64",
    bucket = "sfc-eng-jenkins/foundationdb/bazel/temp",
    build_file = "//:sysroot.BUILD",
    file_path = "sysroot-20250211185051.tar.gz",
    sha256 = "65b48c94c2ca4913e2e478258d0e5eaf5826541d1b5024cc92bdf412ba45bc08",
    strip_prefix = "sysroot",
    patches = ["//:fix-linker-scripts-x86_64.patch"],
    patch_args = ["-p0", "--fuzz=1"],
)
```

**Updated** (following the clang pattern in frostdb/MODULE.bazel):
```python
# Migrated from S3 to Artifactory - using artifactory_deps extension pattern
# s3_archive(
#     name = "sysroot_aarch64",
#     bucket = "sfc-eng-jenkins/foundationdb/bazel/temp",
#     build_file = "//:sysroot.BUILD",
#     file_path = "sysroot-aarch64-20250409220340.tar.gz",
#     sha256 = "f4767d27a104e363a5ed591fa81659a28bbcc9b4d6cdfe141ced12ca1bb6e309",
#     strip_prefix = "sysroot",
#     patches = ["//:fix-linker-scripts-aarch64.patch"],
#     patch_args = ["-p0", "--fuzz=1"],
# )
#
# s3_archive(
#     name = "sysroot_x86_64",
#     bucket = "sfc-eng-jenkins/foundationdb/bazel/temp",
#     build_file = "//:sysroot.BUILD",
#     file_path = "sysroot-20250211185051.tar.gz",
#     sha256 = "65b48c94c2ca4913e2e478258d0e5eaf5826541d1b5024cc92bdf412ba45bc08",
#     strip_prefix = "sysroot",
#     patches = ["//:fix-linker-scripts-x86_64.patch"],
#     patch_args = ["-p0", "--fuzz=1"],
# )

# Note: artifactory_deps extension should be defined at the top of the file
# artifactory_deps = use_extension("//tools:cloud_archive.bzl", "artifactory_deps")

artifactory_deps.archive(
    name = "sysroot_aarch64",
    build_file = "//:sysroot.BUILD",
    url = "<ARTIFACTORY_URL_FROM_PHASE_4>",
    sha256 = "<SHA256_FROM_PHASE_4>",
    strip_prefix = "sysroot",
    patches = ["//:fix-linker-scripts-aarch64.patch"],
    patch_args = ["-p0", "--fuzz=1"],
)

artifactory_deps.archive(
    name = "sysroot_x86_64",
    build_file = "//:sysroot.BUILD",
    url = "<ARTIFACTORY_URL_FROM_PHASE_4>",
    sha256 = "<SHA256_FROM_PHASE_4>",
    strip_prefix = "sysroot",
    patches = ["//:fix-linker-scripts-x86_64.patch"],
    patch_args = ["-p0", "--fuzz=1"],
)

use_repo(
    artifactory_deps,
    "sysroot_aarch64",
    "sysroot_x86_64",
)
```

#### 5.2 Update frostdb/MODULE.bazel

**AWS SDK - Current**:
```python
s3_archive(
    name = "awssdk",
    bucket = "sfc-eng-jenkins/foundationdb/bazel/temp",
    build_file = "//:dependencies/awssdk/BUILD.bazel",
    file_path = "aws-sdk-cpp-1.11.252.tar.gz",
    patch_args = ["-p1"],
    patches = ["//:dependencies/awssdk/linux-sandbox.patch"],
    sha256 = "3507df5856336f0b6ea8f3c4b11342fb273008955f065221d899a5423caa9162",
)
```

**AWS SDK - Updated** (using artifactory_deps extension pattern):
```python
# Migrated from S3 to Artifactory
# s3_archive(
#     name = "awssdk",
#     bucket = "sfc-eng-jenkins/foundationdb/bazel/temp",
#     build_file = "//:dependencies/awssdk/BUILD.bazel",
#     file_path = "aws-sdk-cpp-1.11.252.tar.gz",
#     patch_args = ["-p1"],
#     patches = ["//:dependencies/awssdk/linux-sandbox.patch"],
#     sha256 = "3507df5856336f0b6ea8f3c4b11342fb273008955f065221d899a5423caa9162",
# )

# Add to existing artifactory_deps extension section (after clang archives)
artifactory_deps.archive(
    name = "awssdk",
    build_file = "//:dependencies/awssdk/BUILD.bazel",
    url = "<ARTIFACTORY_URL_FROM_PHASE_4>",
    sha256 = "<SHA256_FROM_PHASE_4>",
    patch_args = ["-p1"],
    patches = ["//:dependencies/awssdk/linux-sandbox.patch"],
)

# Add "awssdk" to the existing use_repo call
use_repo(
    artifactory_deps,
    "clang-18.1.8-aarch64",
    "clang-18.1.8-x86_64",
    "awssdk",  # Add this line
)
```

**GCC - Current**:
```python
s3_archive(
    name = "gcc-15",
    bucket = "sfc-eng-jenkins/foundationdb/bazel/toolchain",
    build_file = "//:dependencies/toolchain/gcc-toolchain.BUILD",
    file_path = "gcc-15-x86_64-20250921002906.tar.gz",
    sha256 = "fb9768b602c301d6006694e8d87d10e7398f979b5a8f17cf6cdf69656b459ff6",
    strip_prefix = "gcc-15",
)
```

**GCC - Updated** (using artifactory_deps extension pattern, if rebuilt):
```python
# Migrated from S3 to Artifactory
# s3_archive(
#     name = "gcc-15",
#     bucket = "sfc-eng-jenkins/foundationdb/bazel/toolchain",
#     build_file = "//:dependencies/toolchain/gcc-toolchain.BUILD",
#     file_path = "gcc-15-x86_64-20250921002906.tar.gz",
#     sha256 = "fb9768b602c301d6006694e8d87d10e7398f979b5a8f17cf6cdf69656b459ff6",
#     strip_prefix = "gcc-15",
# )

# Add to existing artifactory_deps extension section
artifactory_deps.archive(
    name = "gcc-15",
    build_file = "//:dependencies/toolchain/gcc-toolchain.BUILD",
    url = "<ARTIFACTORY_URL_FROM_PHASE_4>",
    sha256 = "<SHA256_FROM_PHASE_4>",
    strip_prefix = "gcc-15",
)

# Add "gcc-15" to the existing use_repo call
use_repo(
    artifactory_deps,
    "clang-18.1.8-aarch64",
    "clang-18.1.8-x86_64",
    "awssdk",
    "gcc-15",  # Add this line
)
```

### Phase 6: Testing & Validation

#### 6.1 Local Testing
```bash
# Clean bazel cache
bazel clean --expunge

# Test builds on both architectures
bazel build //... --config=x86_64
bazel build //... --config=aarch64

# Test specific targets that use sysroot
bazel build //fdbserver:fdbserver
bazel build //fdbcli:fdbcli

# Run tests
bazel test //...
```

#### 6.2 CI/CD Validation
- Run full CI pipeline on PR
- Verify all build configurations pass
- Check binary sizes (should be similar to previous builds)
- Validate runtime behavior

#### 6.3 Rollback Plan
If issues arise:
1. Revert MODULE.bazel changes
2. Restore `s3_archive` rules with original URLs
3. Keep build scripts in third-party-repack for future use

## Key Considerations

### MODULE.bazel Pattern
**IMPORTANT**: All s3_archives should be migrated to use the `artifactory_deps` extension pattern, following the clang example in frostdb/MODULE.bazel (lines 272-293):
1. Use `artifactory_deps = use_extension("//tools:cloud_archive.bzl", "artifactory_deps")` at the top
2. Add archives with `artifactory_deps.archive(name=..., url=..., sha256=..., ...)`
3. Register repos with `use_repo(artifactory_deps, "repo1", "repo2", ...)`

This pattern is preferred over direct `cloud_http_archive` calls because it integrates with the Bzlmod extension system and properly handles the NO_CLOUD_ARCHIVE environment variable.

### Docker Images
- x86_64: `artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/internal-development-docker-fdb_images-local/frostdb/devel:centos7-PR-10588-amd64`
- aarch64: **Need to find correct image tag** - check CI configuration or ask team

### Artifactory Repository
- Repository: `internal-production-generic-third_party_repack-local` (or `internal-AUTOSELECT-generic-third_party_repack-local`)
- Path structure: `/fdb/<dependency>/<versioned-filename>`

### Patches
- Sysroot has architecture-specific linker script patches
- AWS SDK has linux-sandbox.patch
- GCC may have patches (check BUILD file)
- All patches must be preserved in migration

### Versioning Strategy
- Include timestamp in artifact names for traceability
- Use semantic versioning where applicable (e.g., clang-18.1.8)
- Document version in build_info.txt files

### Build Time Estimates
- Clang: ~2-3 hours (reference from existing build)
- GCC: ~30 minutes (smaller subset)
- Sysroot: ~5 minutes (file copy operation)
- AWS SDK: ~10 minutes (git clone + tar)

## Success Criteria

1. All four dependencies successfully uploaded to Artifactory
2. MODULE.bazel files updated with `artifactory_deps.archive()` pattern (following clang example)
3. All migrated archives properly registered with `use_repo(artifactory_deps, ...)`
4. Full bazel build passes on x86_64 and aarch64
5. CI/CD pipeline passes
6. No regressions in build time or binary size
7. Old `s3_archive` rules commented out with migration notes

## Timeline

1. **Phase 1 (Sysroot Analysis)**: 2-3 days
   - Iterative testing to minimize contents
   - Document essential files

2. **Phase 2 (Build Scripts)**: 1 day
   - Create all build scripts
   - Local testing

3. **Phase 3 (GCC Review)**: 1 hour
   - Quick verification

4. **Phase 4 (Pipeline Execution)**: 1 day
   - User runs pipelines
   - Collect URLs and hashes

5. **Phase 5 (MODULE Updates)**: 2 hours
   - Update all MODULE.bazel files

6. **Phase 6 (Testing)**: 1 day
   - Full validation
   - CI/CD verification

**Total Estimated Time**: 5-6 days

## Next Steps

1. Confirm aarch64 docker image tag
2. Begin Phase 1: Sysroot analysis and optimization
3. Create build scripts in third-party-repack/fdb/
4. Submit PR for review
5. User runs pipelines and provides URLs
6. Update MODULE.bazel files
7. Validate and merge
