#!/bin/bash -ex

# Standalone script to build clang/LLVM for frostdb
# Based on monorepo build scripts but with all dependencies removed

# Which clang version to build
CLANG_VERSION=17.0.3
# SHA256 of the llvm-project tarball for the above version
# This needs to be obtained from the official LLVM release
CLANG_PROJECT_SHA=be5a1e44d64f306bb44fce7d36e3b3993694e8e6122b2348608906283c176db8

# Build directories
BUILD_DIR=/home/ryli/fdb/tmp/clang-build-frostdb
INSTALL_DIR=/home/ryli/fdb/plans/compiler_upgrade/installed

# Use all processors by default for the build
CPUS=${CPUS:-$(getconf _NPROCESSORS_ONLN)}

# Folder of this script
SCRIPTPATH="$(cd "$(dirname "$0")" && pwd -P)"

# Which compiler to use for bootstrap
# Use devtoolset-11 if available (provides GCC 11.2.1), otherwise system compiler
if [ -f /opt/rh/devtoolset-11/enable ]; then
  echo "Using devtoolset-11 for bootstrap compiler"
  source /opt/rh/devtoolset-11/enable
  export CC=gcc
  export CXX=g++
else
  echo "Warning: devtoolset-11 not found, using system compiler"
  export CC=${CC:-gcc}
  export CXX=${CXX:-g++}
fi

echo "Building LLVM/Clang ${CLANG_VERSION}"
echo "Using bootstrap compiler: CC=$CC, CXX=$CXX"
echo "CPUs: $CPUS"
echo "Build directory: $BUILD_DIR"
echo "Install directory: $INSTALL_DIR"

# Helper function to download the required source files
prepare_build() {
  # Prepare the build folder
  rm -rf $BUILD_DIR
  mkdir -p $BUILD_DIR
  cd $BUILD_DIR

  # Download the source tarball from Artifactory
  mkdir -p dl
  cd dl
  TAR_NAME=llvm-project-${CLANG_VERSION}.src.tar.xz

  echo "Downloading LLVM source tarball..."
  curl -L https://artifactory.int.snowflakecomputing.com/artifactory/development-github-virtual/llvm/llvm-project/releases/download/llvmorg-${CLANG_VERSION}/${TAR_NAME} -o ${TAR_NAME}

  # Validate the signature of this tarball
  if [ "${CLANG_PROJECT_SHA}" != "PLACEHOLDER_WILL_UPDATE_AFTER_DOWNLOAD" ]; then
    echo "Validating SHA256 checksum..."
    SIG_CMP=$(sha256sum ${TAR_NAME} | cut -d ' ' -f1)
    if [ "$SIG_CMP" != "${CLANG_PROJECT_SHA}" ]; then
      echo "ERROR: Could not validate downloaded file ${TAR_NAME}"
      echo "Expected: ${CLANG_PROJECT_SHA}"
      echo "Got:      ${SIG_CMP}"
      exit 1
    fi
    echo "Checksum validated successfully"
  else
    echo "WARNING: Skipping SHA256 validation (placeholder value)"
    echo "Computed SHA256: $(sha256sum ${TAR_NAME} | cut -d ' ' -f1)"
  fi

  cd ..

  # Unpack the llvm source directory
  echo "Unpacking source tarball..."
  tar xf dl/${TAR_NAME}
  mv llvm-project-${CLANG_VERSION}.src src

  # Apply local patches that we require but are not yet in the upstream version
  if compgen -G "${SCRIPTPATH}/patches/*.patch" >/dev/null; then
    echo "Applying patches..."
    for PATCH in ${SCRIPTPATH}/patches/*.patch; do
      echo "Trying to apply patch ${PATCH}"
      if ! patch -p1 -d src <${PATCH}; then
        echo "ERROR: Applying patch ${PATCH} failed"
        exit 1
      fi
    done
  else
    echo "No patches to apply"
  fi

  # Remove the downloads
  rm -rf dl
}

build() {
  # Make sure that the source directory is correctly set up
  prepare_build

  # Prepare the cmake build directory
  cd $BUILD_DIR
  mkdir -p build
  cd build

  # Clean the installed directory
  rm -rf $INSTALL_DIR
  mkdir -p $INSTALL_DIR

  # Detect target architecture
  target=X86
  if [ $(uname -m) == aarch64 ]; then
    target=AArch64
  fi
  echo "Target architecture: $target"

  # Configure and build
  # Single-stage build with GCC 11+ (devtoolset-11)
  # Can build all runtimes including libcxx/libcxxabi/libunwind in one pass
  echo "Configuring cmake..."
  cmake \
    -DCMAKE_C_COMPILER=${CC} \
    -DCMAKE_CXX_COMPILER=${CXX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb" \
    -DLLVM_ENABLE_RUNTIMES="compiler-rt;libcxx;libcxxabi;libunwind" \
    -DCLANG_INCLUDE_DOCS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DCLANG_DEFAULT_PIE_ON_LINUX=OFF \
    -DLLVM_STATIC_LINK_CXX_STDLIB=ON \
    -DLLVM_TARGETS_TO_BUILD="$target" \
    ../src/llvm \
    -GNinja

  echo "Building and installing LLVM/Clang..."
  time ninja -j ${CPUS} install/strip FileCheck

  # Copy FileCheck to bin directory
  cp bin/FileCheck $INSTALL_DIR/bin/

  # Create patch signature file
  echo "Creating patch signature file..."
  $SCRIPTPATH/create_patch_signature.sh > $INSTALL_DIR/sf_patch.signature

  # Clean up build directory
  cd $SCRIPTPATH
  rm -rf $BUILD_DIR

  echo "Build completed successfully!"
  echo "Compiler installed to: $INSTALL_DIR"
}

# Run the build
build
