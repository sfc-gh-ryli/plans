#!/bin/bash -e

# Package clang compiler into a .tgz archive for upload to S3
# Usage: ./package_clang.sh <source_dir> <output_dir> <version> <architecture> <username>

# Arguments
SOURCE_DIR=${1:?Error: SOURCE_DIR required}
OUTPUT_DIR=${2:?Error: OUTPUT_DIR required}
VERSION=${3:?Error: VERSION required (e.g., 17.0.3)}
ARCH=${4:?Error: ARCH required (e.g., x86_64 or aarch64)}
USERNAME=${5:-$(whoami)}

# Generate timestamp
TIMESTAMP=$(date +%s)

# Output filename
ARCHIVE_NAME="clang-${VERSION}-${ARCH}-${USERNAME}-${TIMESTAMP}.tgz"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"

echo "Packaging clang compiler..."
echo "  Source: ${SOURCE_DIR}"
echo "  Output: ${ARCHIVE_PATH}"
echo "  Version: ${VERSION}"
echo "  Architecture: ${ARCH}"
echo "  Username: ${USERNAME}"
echo "  Timestamp: ${TIMESTAMP}"

# Validate source directory exists and has expected structure
if [ ! -d "${SOURCE_DIR}" ]; then
    echo "ERROR: Source directory does not exist: ${SOURCE_DIR}"
    exit 1
fi

# Check for required directories
for dir in bin lib include; do
    if [ ! -d "${SOURCE_DIR}/${dir}" ]; then
        echo "ERROR: Required directory missing: ${SOURCE_DIR}/${dir}"
        exit 1
    fi
done

# Check for clang binary
if [ ! -f "${SOURCE_DIR}/bin/clang" ]; then
    echo "ERROR: clang binary not found: ${SOURCE_DIR}/bin/clang"
    exit 1
fi

# Verify clang version matches
CLANG_VERSION=$(${SOURCE_DIR}/bin/clang --version | head -1 | awk '{print $3}')
if [ "${CLANG_VERSION}" != "${VERSION}" ]; then
    echo "WARNING: Clang version mismatch!"
    echo "  Expected: ${VERSION}"
    echo "  Found: ${CLANG_VERSION}"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create output directory if it doesn't exist
mkdir -p "${OUTPUT_DIR}"

# Create the archive
echo "Creating archive..."
cd "${SOURCE_DIR}/.."
tar czf "${ARCHIVE_PATH}" "$(basename ${SOURCE_DIR})"

# Verify archive was created
if [ ! -f "${ARCHIVE_PATH}" ]; then
    echo "ERROR: Failed to create archive"
    exit 1
fi

# Calculate SHA256 checksum
echo "Calculating SHA256 checksum..."
SHA256=$(sha256sum "${ARCHIVE_PATH}" | cut -d' ' -f1)

# Get archive size
SIZE=$(du -h "${ARCHIVE_PATH}" | cut -f1)

echo ""
echo "Packaging complete!"
echo "  Archive: ${ARCHIVE_PATH}"
echo "  Size: ${SIZE}"
echo "  SHA256: ${SHA256}"
echo ""
echo "To upload to S3:"
echo "  aws s3 cp ${ARCHIVE_PATH} s3://sfc-eng-jenkins/foundationdb/bazel/toolchain/"
echo ""
echo "To use in MODULE.bazel:"
echo "  s3_archive("
echo "      name = \"clang-${VERSION}-${ARCH}\","
echo "      bucket = \"sfc-eng-jenkins/foundationdb/bazel/toolchain\","
echo "      build_file = \"//:dependencies/toolchain/clang-toolchain.BUILD\","
echo "      file_path = \"${ARCHIVE_NAME}\","
echo "      sha256 = \"${SHA256}\","
echo "  )"
