#!/bin/bash -e

# End-to-end pipeline test script
# Validates the complete compiler build and deployment workflow

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TEST_DIR="/home/ryli/fdb/tmp/pipeline_test"
SUCCESS_COUNT=0
FAIL_COUNT=0

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
    ((SUCCESS_COUNT++))
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
    ((FAIL_COUNT++))
}

log_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

echo "=================================="
echo "Pipeline End-to-End Test"
echo "=================================="
echo ""

# Test 1: Verify build script exists and is executable
log_info "Test 1: Verify build script"
if [ -x "${SCRIPT_DIR}/build_clang_frostdb.sh" ]; then
    log_success "Build script exists and is executable"
else
    log_error "Build script missing or not executable"
fi

# Test 2: Verify packaging script exists and is executable
log_info "Test 2: Verify packaging script"
if [ -x "${SCRIPT_DIR}/package_clang.sh" ]; then
    log_success "Packaging script exists and is executable"
else
    log_error "Packaging script missing or not executable"
fi

# Test 3: Verify Jenkinsfile exists
log_info "Test 3: Verify Jenkinsfile"
if [ -f "${SCRIPT_DIR}/Jenkinsfile" ]; then
    log_success "Jenkinsfile exists"
else
    log_error "Jenkinsfile missing"
fi

# Test 4: Verify patch signature script exists
log_info "Test 4: Verify patch signature script"
if [ -x "${SCRIPT_DIR}/create_patch_signature.sh" ]; then
    log_success "Patch signature script exists"
else
    log_error "Patch signature script missing"
fi

# Test 5: Verify built compiler exists (from previous build)
log_info "Test 5: Verify previously-built compiler"
INSTALL_DIR="${SCRIPT_DIR}/installed"
if [ -f "${INSTALL_DIR}/bin/clang" ]; then
    VERSION=$(${INSTALL_DIR}/bin/clang --version | head -1 | awk '{print $3}')
    log_success "Built compiler exists (version ${VERSION})"
else
    log_error "Built compiler not found at ${INSTALL_DIR}"
fi

# Test 6: Verify compiler structure
log_info "Test 6: Verify compiler directory structure"
MISSING_DIRS=""
for dir in bin lib include libexec share; do
    if [ ! -d "${INSTALL_DIR}/${dir}" ]; then
        MISSING_DIRS="${MISSING_DIRS} ${dir}"
    fi
done
if [ -z "${MISSING_DIRS}" ]; then
    log_success "All required directories present"
else
    log_error "Missing directories:${MISSING_DIRS}"
fi

# Test 7: Verify runtime libraries
log_info "Test 7: Verify runtime libraries"
RUNTIME_DIR="${INSTALL_DIR}/lib/x86_64-unknown-linux-gnu"
if [ -d "${RUNTIME_DIR}" ]; then
    MISSING_LIBS=""
    for lib in libc++.a libc++abi.a libunwind.a; do
        if [ ! -f "${RUNTIME_DIR}/${lib}" ]; then
            MISSING_LIBS="${MISSING_LIBS} ${lib}"
        fi
    done
    if [ -z "${MISSING_LIBS}" ]; then
        log_success "All runtime libraries present"
    else
        log_error "Missing libraries:${MISSING_LIBS}"
    fi
else
    log_error "Runtime library directory not found"
fi

# Test 8: Verify X86-only target
log_info "Test 8: Verify X86-only architecture"
X86_LIBS=$(ls ${INSTALL_DIR}/lib/libLLVMX86*.a 2>/dev/null | wc -l)
OTHER_ARCH=$(ls ${INSTALL_DIR}/lib/libLLVM{AArch64,ARM,Mips,PowerPC,RISCV}*.a 2>/dev/null | wc -l)
if [ ${X86_LIBS} -gt 0 ] && [ ${OTHER_ARCH} -eq 0 ]; then
    log_success "X86-only target confirmed (${X86_LIBS} X86 libraries, 0 other architectures)"
else
    log_error "Architecture mismatch (X86: ${X86_LIBS}, Other: ${OTHER_ARCH})"
fi

# Test 9: Test packaging script (dry run)
log_info "Test 9: Test packaging script"
if ${SCRIPT_DIR}/package_clang.sh ${INSTALL_DIR} /tmp/test-package-$$  17.0.3 x86_64 test 2>&1 | grep -q "Packaging complete"; then
    PACKAGE_FILE=$(ls /tmp/test-package-$$/clang-*.tgz 2>/dev/null | head -1)
    if [ -f "${PACKAGE_FILE}" ]; then
        PACKAGE_SIZE=$(du -h ${PACKAGE_FILE} | cut -f1)
        log_success "Packaging script works (created ${PACKAGE_SIZE} archive)"
        rm -rf /tmp/test-package-$$
    else
        log_error "Packaging script did not create archive"
    fi
else
    log_error "Packaging script failed"
fi

# Test 10: Verify frostdb MODULE.bazel configuration
log_info "Test 10: Verify MODULE.bazel points to local compiler"
if grep -q "path = \"${INSTALL_DIR}\"" /home/ryli/fdb/frostdb/MODULE.bazel 2>/dev/null; then
    log_success "MODULE.bazel configured for local compiler"
else
    log_error "MODULE.bazel not configured correctly"
fi

# Test 11: Test frostdb build with locally-built compiler
log_info "Test 11: Test frostdb build"
cd /home/ryli/fdb/frostdb
if bazel build //contrib/crc32/... --verbose_failures > /dev/null 2>&1; then
    log_success "Frostdb builds successfully with locally-built compiler"
else
    log_error "Frostdb build failed"
fi

# Test 12: Verify file count matches expected
log_info "Test 12: Verify file count"
FILE_COUNT=$(find ${INSTALL_DIR} -type f | wc -l)
EXPECTED_COUNT=5250
if [ ${FILE_COUNT} -eq ${EXPECTED_COUNT} ]; then
    log_success "File count matches expected (${FILE_COUNT})"
elif [ ${FILE_COUNT} -gt $((EXPECTED_COUNT - 100)) ] && [ ${FILE_COUNT} -lt $((EXPECTED_COUNT + 100)) ]; then
    log_success "File count within acceptable range (${FILE_COUNT}, expected ${EXPECTED_COUNT})"
else
    log_error "File count mismatch (${FILE_COUNT}, expected ${EXPECTED_COUNT})"
fi

# Summary
echo ""
echo "=================================="
echo "Test Results"
echo "=================================="
echo -e "${GREEN}Passed: ${SUCCESS_COUNT}${NC}"
echo -e "${RED}Failed: ${FAIL_COUNT}${NC}"
echo ""

if [ ${FAIL_COUNT} -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed! Pipeline is ready for production.${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed. Review errors above.${NC}"
    exit 1
fi
