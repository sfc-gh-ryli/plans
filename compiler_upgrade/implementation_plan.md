# Compiler Upgrade Implementation Plan

## Overview
This plan covers setting up infrastructure to build and deploy clang/LLVM compiler toolchains for frostdb, initially validating with current version 17.0.3 before any upgrades.

## Prerequisites
- Cloud Workspace environment
- AWS CLI configured with access to `s3://sfc-eng-jenkins`
- Access to `https://artifactory.int.snowflakecomputing.com`
- Build dependencies: cmake, ninja-build, gold linker, existing compiler for bootstrap

---

## Phase 1: Local Testing Infrastructure

### Goal
Set up fast iteration cycle by using local compiler builds instead of S3 downloads.

### Steps

#### 1.1 Download Current Compiler Archive
```bash
# For x86_64
aws s3 cp s3://sfc-eng-jenkins/foundationdb/bazel/toolchain/clang-17.0.3-x86_64-kkopec-1716656853.tgz /home/ryli/fdb/tmp/

# For aarch64 (if on ARM)
aws s3 cp s3://sfc-eng-jenkins/foundationdb/bazel/toolchain/clang-17.0.3-aarch64-20250405110201.tgz /home/ryli/fdb/tmp/
```

#### 1.2 Unpack Archive to Local Directory
```bash
mkdir -p /home/ryli/fdb/local_clang_test
cd /home/ryli/fdb/local_clang_test
tar xzf /home/ryli/fdb/tmp/clang-17.0.3-*.tgz
```

#### 1.3 Modify MODULE.bazel for Local Testing
**File**: `/home/ryli/fdb/frostdb/MODULE.bazel`

Comment out existing `s3_archive` rules (lines 272-290) and add:
```python
# Temporary local testing - replace with s3_archive for production
new_local_repository(
    name = "clang-17.0.3-x86_64",  # or clang-17.0.3-aarch64
    path = "/home/ryli/fdb/local_clang_test",
    build_file = "//:dependencies/toolchain/clang-toolchain.BUILD",
)
```

**Note**: Only need one architecture at a time. Comment out the unused arch in the symlink rule.

#### 1.4 Verify Build Works
```bash
cd /home/ryli/fdb/frostdb
bazel build //contrib/crc32/...
bazel build //contrib/...
bazel build //flow/...
```

**Success Criteria**: All builds succeed without errors.

---

## Phase 2: Recreate Current Compiler from Source

### Goal
Validate we can build clang 17.0.3 from source with identical configuration to current S3 archive.

### Steps

#### 2.1 Create Standalone Build Script
**File**: `/home/ryli/fdb/plans/compiler_upgrade/build_clang_frostdb.sh`

Based on `build_clang_new.sh`, remove:
- References to `../compilers.py` (use system gcc/g++)
- Megacache integration (lines 92-123)
- All paths to `../../../Varia/`
- References to `create-clang-patch-signature-file.sh` (create simple replacement)

Key parameters to configure:
```bash
CLANG_VERSION=17.0.3
CLANG_PROJECT_SHA=<lookup from LLVM releases>
BUILD_DIR=/home/ryli/fdb/tmp/clang-build-frostdb
INSTALL_DIR=/home/ryli/fdb/local_clang_build/installed
```

Build configuration (keep these from reference script):
```cmake
-DCMAKE_BUILD_TYPE=Release
-DLLVM_USE_LINKER=gold
-DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld"
-DLLVM_ENABLE_RUNTIMES="compiler-rt"
-DCLANG_INCLUDE_DOCS=OFF
-DCLANG_INCLUDE_TESTS=OFF
-DLLVM_INCLUDE_DOCS=OFF
-DLLVM_INCLUDE_EXAMPLES=OFF
-DLLVM_INCLUDE_TESTS=OFF
-DCLANG_DEFAULT_PIE_ON_LINUX=OFF
-DLLVM_TARGETS_TO_BUILD="X86"  # or AArch64
```

#### 2.2 Obtain LLVM 17.0.3 SHA256
```bash
# Download and compute hash
curl -L https://artifactory.int.snowflakecomputing.com/artifactory/development-github-virtual/llvm/llvm-project/releases/download/llvmorg-17.0.3/llvm-project-17.0.3.src.tar.xz -o /home/ryli/fdb/tmp/llvm-project-17.0.3.src.tar.xz
sha256sum /home/ryli/fdb/tmp/llvm-project-17.0.3.src.tar.xz
```

#### 2.3 Handle Patches Directory
Create `patches/` directory in same location as build script:
```bash
mkdir -p /home/ryli/fdb/plans/compiler_upgrade/patches
# Initially empty, may need patches for frostdb-specific requirements
```

#### 2.4 Create Patch Signature Script
**File**: `/home/ryli/fdb/plans/compiler_upgrade/create_patch_signature.sh`
```bash
#!/bin/bash
SCRIPTPATH="$(cd "$(dirname "$0")" && pwd -P)"
if compgen -G "${SCRIPTPATH}/patches/*.patch" > /dev/null; then
    sha256sum ${SCRIPTPATH}/patches/*.patch
fi
```

#### 2.5 Run Build
```bash
cd /home/ryli/fdb/plans/compiler_upgrade
chmod +x build_clang_frostdb.sh create_patch_signature.sh
./build_clang_frostdb.sh
```

**Expected Duration**: 1-2 hours (use CPUS=16 or more to speed up)

#### 2.6 Compare Build Output Structure
```bash
# Compare structure of locally built vs S3 archive
tree -L 2 /home/ryli/fdb/local_clang_build/installed
tree -L 2 /home/ryli/fdb/local_clang_test

# Check for required binaries
ls /home/ryli/fdb/local_clang_build/installed/bin/ | grep -E "(clang|lld|FileCheck)"
```

**Expected Structure**:
```
installed/
├── bin/
│   ├── clang
│   ├── clang++
│   ├── clang-17
│   ├── lld
│   ├── ld.lld
│   ├── FileCheck
│   └── ...
├── lib/
│   ├── clang/
│   └── ...
├── include/
└── sf_patch.signature
```

#### 2.7 Test Locally-Built Compiler
Update MODULE.bazel to point to new build:
```python
new_local_repository(
    name = "clang-17.0.3-x86_64",
    path = "/home/ryli/fdb/local_clang_build/installed",
    build_file = "//:dependencies/toolchain/clang-toolchain.BUILD",
)
```

Run incremental build tests:
```bash
bazel clean
bazel build //contrib/crc32/...
bazel build //flow/...
bazel build //fdbclient/...
# If all succeed, try full build
bazel build //...
```

#### 2.8 Validate clang-toolchain.BUILD Compatibility
**File**: `/home/ryli/fdb/frostdb/dependencies/toolchain/clang-toolchain.BUILD`

Verify this BUILD file correctly references paths in the compiler archive:
- Check `bin/` references
- Check `lib/clang/*/` version-specific paths
- May need updates if directory structure differs

---

## Phase 4: Automation Pipeline

### Goal
Create reproducible Jenkins job to build, package, and upload compiler archives.

### Steps

#### 4.1 Create Packaging Script
**File**: `/home/ryli/fdb/plans/compiler_upgrade/package_clang.sh`

```bash
#!/bin/bash -ex

if [ $# -ne 2 ]; then
    echo "Usage: $0 <clang_version> <architecture>"
    echo "Example: $0 17.0.3 x86_64"
    exit 1
fi

CLANG_VERSION=$1
ARCH=$2
TIMESTAMP=$(date +%Y%m%d%H%M%S)
USERNAME=${USER}
ARCHIVE_NAME="clang-${CLANG_VERSION}-${ARCH}-${USERNAME}-${TIMESTAMP}.tgz"

SCRIPTPATH="$(cd "$(dirname "$0")" && pwd -P)"
INSTALL_DIR="${SCRIPTPATH}/installed"

if [ ! -d "$INSTALL_DIR" ]; then
    echo "Error: $INSTALL_DIR does not exist. Run build script first."
    exit 1
fi

# Create tarball
cd "$INSTALL_DIR"
tar czf "/home/ryli/fdb/tmp/${ARCHIVE_NAME}" .

# Compute SHA256
SHA256=$(sha256sum "/home/ryli/fdb/tmp/${ARCHIVE_NAME}" | cut -d' ' -f1)

echo "======================================"
echo "Package created: /home/ryli/fdb/tmp/${ARCHIVE_NAME}"
echo "SHA256: ${SHA256}"
echo "======================================"
echo ""
echo "To upload to S3:"
echo "aws s3 cp /home/ryli/fdb/tmp/${ARCHIVE_NAME} s3://sfc-eng-jenkins/foundationdb/bazel/toolchain/"
echo ""
echo "Update MODULE.bazel with:"
echo "  file_path = \"${ARCHIVE_NAME}\""
echo "  sha256 = \"${SHA256}\""
```

#### 4.2 Create Upload Script
**File**: `/home/ryli/fdb/plans/compiler_upgrade/upload_clang.sh`

```bash
#!/bin/bash -ex

if [ $# -ne 1 ]; then
    echo "Usage: $0 <archive_path>"
    exit 1
fi

ARCHIVE_PATH=$1
BUCKET="s3://sfc-eng-jenkins/foundationdb/bazel/toolchain"

aws s3 cp "$ARCHIVE_PATH" "$BUCKET/"
echo "Uploaded $(basename $ARCHIVE_PATH) to $BUCKET"
```

#### 4.3 Test Local Pipeline End-to-End
```bash
cd /home/ryli/fdb/plans/compiler_upgrade

# Build
./build_clang_frostdb.sh

# Package
./package_clang.sh 17.0.3 x86_64

# Test upload (dry-run first)
aws s3 cp /home/ryli/fdb/tmp/clang-17.0.3-*.tgz s3://sfc-eng-jenkins/foundationdb/bazel/toolchain/ --dryrun

# Actual upload (if dry-run succeeds)
./upload_clang.sh /home/ryli/fdb/tmp/clang-17.0.3-*.tgz
```

#### 4.4 Design Jenkins Job Structure
**File**: `/home/ryli/fdb/plans/compiler_upgrade/Jenkinsfile` (conceptual)

```groovy
pipeline {
    agent {
        label 'linux && bazel'
    }

    parameters {
        string(name: 'CLANG_VERSION', defaultValue: '17.0.3', description: 'LLVM/Clang version to build')
        choice(name: 'ARCHITECTURE', choices: ['x86_64', 'aarch64'], description: 'Target architecture')
    }

    stages {
        stage('Build Compiler') {
            steps {
                sh '''
                    cd plans/compiler_upgrade
                    ./build_clang_frostdb.sh
                '''
            }
        }

        stage('Package') {
            steps {
                sh '''
                    cd plans/compiler_upgrade
                    ./package_clang.sh ${CLANG_VERSION} ${ARCHITECTURE}
                '''
            }
        }

        stage('Upload to S3') {
            steps {
                sh '''
                    ARCHIVE=$(ls /home/ryli/fdb/tmp/clang-${CLANG_VERSION}-*.tgz)
                    cd plans/compiler_upgrade
                    ./upload_clang.sh $ARCHIVE
                '''
            }
        }

        stage('Output Instructions') {
            steps {
                sh '''
                    ARCHIVE=$(basename /home/ryli/fdb/tmp/clang-${CLANG_VERSION}-*.tgz)
                    SHA256=$(sha256sum /home/ryli/fdb/tmp/clang-${CLANG_VERSION}-*.tgz | cut -d' ' -f1)

                    echo "=========================================="
                    echo "Update frostdb/MODULE.bazel:"
                    echo "  file_path = \"${ARCHIVE}\""
                    echo "  sha256 = \"${SHA256}\""
                    echo "=========================================="
                '''
            }
        }
    }

    post {
        always {
            cleanWs()
        }
    }
}
```

**Job Requirements**:
- Must run on both x86_64 and aarch64 agents (separate jobs or matrix)
- Build time: ~1-2 hours per architecture
- Workspace cleanup to avoid disk space issues
- Artifacts: `.tgz` file + SHA256 checksum

#### 4.5 Multi-Architecture Strategy

**Option A: Separate Jenkins Jobs**
- `build-clang-x86_64` and `build-clang-aarch64`
- Run in parallel, triggered manually
- Each outputs its own archive and SHA256

**Option B: Matrix Build**
- Single Jenkinsfile with matrix strategy
- Automatically builds both architectures
- Aggregates results in single job run

Recommended: **Option A** for clarity and debugging.

---

## Validation Checklist

### Phase 1 Complete When:
- [ ] Can build frostdb using local_repository reference
- [ ] Build times are reasonable (no S3 download overhead)
- [ ] Can switch between S3 and local builds easily

### Phase 2 Complete When:
- [ ] Build script runs without monorepo dependencies
- [ ] Locally-built 17.0.3 has identical structure to S3 archive
- [ ] frostdb builds successfully with locally-built compiler
- [ ] Can reproduce build on fresh workspace

### Phase 4 Complete When:
- [ ] Packaging script generates valid .tgz archives
- [ ] Upload script works with S3 bucket permissions
- [ ] Jenkins job can build, package, and upload without manual intervention
- [ ] Documentation exists for updating MODULE.bazel with new archives

---

## Troubleshooting Guide

### Build Failures

**"Could not validate downloaded file"**
- SHA256 mismatch: Update CLANG_PROJECT_SHA in build script
- Use: `sha256sum llvm-project-*.src.tar.xz`

**"patch ... failed"**
- Patches may not apply to different LLVM versions
- Review patch files in `patches/` directory
- May need to rebase patches or remove if fixed upstream

**"ninja: command not found"**
- Install: `sudo yum install ninja-build` or `apt-get install ninja-build`

**CMake errors about missing compiler**
- Set CC/CXX explicitly: `export CC=gcc CXX=g++`
- Ensure bootstrap compiler is recent enough (gcc 7+)

### Bazel Build Failures

**"error: no such package '@clang-17.0.3'"**
- Check MODULE.bazel syntax for new_local_repository
- Verify path exists: `ls /path/to/clang`

**Linker errors with locally-built clang**
- Compare lib/ directory structure with S3 archive
- Check clang-toolchain.BUILD for hardcoded version paths
- Look for `/lib/clang/17.0.3/` vs `/lib/clang/17/` differences

**"error: unable to execute command: Killed"**
- Out of memory during compilation
- Reduce parallelism: `bazel build --jobs=4`
- Increase swap space

---

## Next Steps After Validation

Once Phases 1, 2, and 4 are complete:

1. **Phase 3: Version Upgrade**
   - Confirm target version with team (21.1.0?)
   - Update build script for new version
   - Handle new compiler warnings/errors
   - Iterate until full build succeeds

2. **Integration with Monorepo**
   - Investigate monorepo's compiler build system
   - Align build configurations where possible
   - Consider using their packages directly if compatible

3. **Documentation**
   - Update team wiki with compiler upgrade process
   - Document Jenkins job usage
   - Create runbook for emergency rollbacks

---

## File Locations Summary

| File | Purpose |
|------|---------|
| `/home/ryli/fdb/frostdb/MODULE.bazel` | Compiler version references (lines 272-290) |
| `/home/ryli/fdb/plans/compiler_upgrade/build_clang_frostdb.sh` | Main build script (to be created) |
| `/home/ryli/fdb/plans/compiler_upgrade/package_clang.sh` | Archive packaging (to be created) |
| `/home/ryli/fdb/plans/compiler_upgrade/upload_clang.sh` | S3 upload helper (to be created) |
| `/home/ryli/fdb/plans/compiler_upgrade/patches/` | Custom patches directory |
| `/home/ryli/fdb/plans/compiler_upgrade/Jenkinsfile` | CI/CD pipeline definition (to be created) |
| `/home/ryli/fdb/frostdb/dependencies/toolchain/clang-toolchain.BUILD` | Bazel build rules for compiler |

---

## Time Estimates

- **Phase 1**: 30 minutes - 1 hour
- **Phase 2**: 3-4 hours (including 1-2 hour build time)
- **Phase 4**: 2-3 hours (scripting and Jenkins setup)
- **Total**: 1 work day for initial validation

Build times scale with available CPUs. Recommended minimum: 16 cores.
