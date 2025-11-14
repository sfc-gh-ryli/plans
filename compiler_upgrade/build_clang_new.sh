#!/bin/bash -ex

# Which clang version should be installed
CLANG_VERSION=18.1.4
# SHA256 of the llvm-project tarball for the above version
CLANG_PROJECT_SHA=2c01b2fbb06819a12a92056a7fd4edcdc385837942b5e5260b9c2c0baff5116b

# Build in temp
BUILD_DIR=/tmp/clang-build-$USER

# Use all processors by default for the build
CPUS=${CPUS:-$(getconf _NPROCESSORS_ONLN)}

# Folder of this script
SCRIPTPATH="$(
  cd "$(dirname "$0")"
  pwd -P
)"
# Name of this script
SCRIPTNAME="$(basename "$0")"

# Which compiler to use
export CC=`$SCRIPTPATH/../compilers.py --default --cc`
export CXX=`$SCRIPTPATH/../compilers.py --default --cxx`

# Helper funtion to download the required source files.
prepare_build() {
  # Prepare the build folder
  rm -rf $BUILD_DIR
  mkdir -p $BUILD_DIR
  cd $BUILD_DIR

  # Download the source tarball 
  mkdir -p dl
  cd dl
  TAR_NAME=llvm-project-${CLANG_VERSION}.src.tar.xz
  curl https://artifactory.int.snowflakecomputing.com/artifactory/development-github-virtual/llvm/llvm-project/releases/download/llvmorg-${CLANG_VERSION}/${TAR_NAME} -o ${TAR_NAME}
  # validate the signature of this tarball
  SIG_CMP=$(sha256sum llvm-project-${CLANG_VERSION}.src.tar.xz | cut -d ' ' -f1)
  if [ $SIG_CMP != ${CLANG_PROJECT_SHA} ]; then
    echo "Could not validate downloaded file clang-project-${CLANG_VERSION}.src.tar.xz".
    exit -1
  fi
  cd ..

  # Unpack the llvm source directory
  tar xf dl/llvm-project-${CLANG_VERSION}.src.tar.xz
  mv llvm-project-${CLANG_VERSION}.src src

  # Apply local patches that we require but are not yet in the upstream version.
  if compgen -G "${SCRIPTPATH}/patches/*.patch" >/dev/null; then
    for PATCH in ${SCRIPTPATH}/patches/*.patch; do
      echo "Trying to apply patch ${PATCH}"
      if ! patch -p1 -dsrc <${PATCH}; then
        echo "Applying patch ${PATCH} failed"
        exit 1
      fi
    done
  fi

  # And remove the downloads.
  rm -rf dl
}

build() {
  # Make sure that the source directory is correctly set up.
  prepare_build
  # Prepare the cmake build directory
  cd $BUILD_DIR
  mkdir -p build
  cd build
  # Clean the installed directory
  rm -rf $SCRIPTPATH/installed
  # Note we may not be in the context of the build environment so ARCH may not be set.
  target=X86
  if [ $(uname -p) == aarch64 ]; then
    target=AArch64
  fi

  # And start the build
  cmake -DCMAKE_CXX_COMPILER=${CXX} -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$SCRIPTPATH/installed \
    -DLLVM_USE_LINKER=gold -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld" -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
    -DCLANG_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_TESTS=OFF \
    -DCLANG_DEFAULT_PIE_ON_LINUX=OFF -DLLVM_TARGETS_TO_BUILD="$target" ../src/llvm -GNinja &&
    time ninja-build -j ${CPUS} install/strip FileCheck && cp bin/FileCheck $SCRIPTPATH/installed/bin/ && cd $SCRIPTPATH && rm -rf $BUILD_DIR

  # We add a small sf_patch.signature file to the top-level clang install directory that contains the signatures of all custom
  # patch files applied to the llvm/clang source. This can be used to quickly validate the installed version when we add patches.
  $SCRIPTPATH/create-clang-patch-signature-file.sh >$SCRIPTPATH/installed/sf_patch.signature
}

check_cache() {
  # Try to fetch a built package from megacache.
  cd $SCRIPTPATH
  COMMON_MEGACACHE_ARGS="-kclang -d${SCRIPTNAME} -a installed --subkey $(../gen_toolchain_signature.py)"
  for PATCH in patches/*.patch; do
    COMMON_MEGACACHE_ARGS+=" -d${PATCH}"
  done
  if [ "${CLANG_DISABLE_MEGACACHE_GET}" != "1" ]; then
    set +e
    ../../../Varia/megacache.py ${COMMON_MEGACACHE_ARGS} -g
    MEGACACHE_RC=$?
    set -e
  else
    # Pretend a cache miss if megacache get is disabled
    MEGACACHE_RC=1
  fi
  if [ $((MEGACACHE_RC)) -eq 1 ]; then
    # We could not find a pre-built package. Build from source and upload.
    build
    cd $SCRIPTPATH
    if [ "${CLANG_DISABLE_MEGACACHE_PUT}" != "1" ]; then
      ../../../Varia/megacache.py ${COMMON_MEGACACHE_ARGS} -p
    fi
  elif [ $((MEGACACHE_RC)) -ne 0 ]; then
    echo "Megacache query failed with an error, exiting"
    exit 1
  fi
}

check_cache