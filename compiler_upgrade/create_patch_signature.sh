#!/bin/bash
# Create signature file for patches applied to LLVM/Clang source

SCRIPTPATH="$(cd "$(dirname "$0")" && pwd -P)"

if compgen -G "${SCRIPTPATH}/patches/*.patch" > /dev/null; then
    sha256sum ${SCRIPTPATH}/patches/*.patch
else
    echo "# No patches applied"
fi
