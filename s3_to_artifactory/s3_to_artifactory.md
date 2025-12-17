# Move FDB build dependencies from S3 to artifactory

The goal of this task is to move codebase dependencies that currently live in S3 to Artifactory. You can find such codebase dependencies by searching for the term s3_archive in the `frostdb/` directory. Specifically, you should look in `frostdb/MODULE.bazel`, and `frostdb/dependencies/sysroot/MODULE.bazel`.

There are a small number of known S3 archives:
1. sysroot_aarch64
2. sysroot_x86_64
3. awssdk
4. gcc

Each migration to Artifactory will look roughly similar, but have some different logic involved. I have already performed a migration for clang, which I will highlight as the primary example to work off of.

The migration will work in the following steps:
1. Determine how each dependency was created. They are typically built from some build script, whether adhoc (in which case I will provide it to you) or in a codebase. I will detail how each one is built below.
2. Navigate to `third-party-repack/`. This repository contains build+publish scripts that are responsible for building certain artifacts and publishing them to Artifactory, with some of the details abstracted out for our ease of use. Please take some time to understand how the build script should look. clang, for example, is built in a single script. gcc has a build script to set up a docker environment, which runs a second build script. There is always an upload step to Artifactory, which should not change significantly.
3. Set up folders for each of these archives in `third-party-repack/` and create build scripts for them based on how they are built as you learned in step 1.
4. Let me merge the build scripts and run the pipelines myself, which will run the scripts and perform the upload. In exchange, I will provide you with Artifactory URLs for the new archives and their SHAs.
5. In the same MODULE.bazel file where the `s3_archive` definitions currently exist, replace them with `http_archive` definitions, using the examples in the file.

## Example
Clang has already been updated to use this flow. Look at the following code to familiarize yourself:
- `frostdb/MODULE.bazel` for the http_archive definitions
- `third-party-repack/fdb/clang/build.sh` for how it's built

I'm pasting the MODULE.bazel changes below for reference:
```
# Migrated from S3 to Artifactory
# s3_archive(
#     name = "clang-17.0.3-aarch64",
#     bucket = "sfc-eng-jenkins/foundationdb/bazel/toolchain",
#     build_file = "//:dependencies/toolchain/clang-toolchain.BUILD",
#     file_path = "clang-17.0.3-aarch64-20250405110201.tgz",
#     sha256 = "670be4cdcd81451265a77bace2e7fd1341980bd82cfa206d01612b5c58b108cb",
# )

# s3_archive(
#     name = "clang-17.0.3-x86_64",
#     bucket = "sfc-eng-jenkins/foundationdb/bazel/toolchain",
#     build_file = "//:dependencies/toolchain/clang-toolchain.BUILD",
#     file_path = "clang-17.0.3-x86_64-kkopec-1716656853.tgz",
#     sha256 = "ef2667e3f82ff5c95bea73e433985501fc10855649e8f65b9c28123fcbda293b",
# )

cloud_http_archive(
    name = "clang-18.1.8-aarch64",
    build_file = "//:dependencies/toolchain/clang-toolchain.BUILD",
    sha256 = "505df988a9d671f5c1214370f85e969a3ddb92c5378991bdbe93eb725d07ef5c",
    url = "https://artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/artifactory/internal-production-generic-third_party_repack-local/fdb/clang/clang-18.1.8-aarch64-20251201-214455.tgz",
)

cloud_http_archive(
    name = "clang-18.1.8-x86_64",
    build_file = "//:dependencies/toolchain/clang-toolchain.BUILD",
    sha256 = "8bf0219b03dc794cd7f0cda565681b1dea315f2f2c4e9a75e1fc621a54350c30",
    url = "https://artifactory.ci1.us-west-2.aws-dev.app.snowflake.com/artifactory/internal-production-generic-third_party_repack-local/fdb/clang/clang-18.1.8-x86_64-20251201-215035.tgz",
)
```

Notably, you will have to use a cloud_http_archive, which is custom-written by me, and not an http_archive, because we have certain checks which set NO_CLOUD_ARCHIVE where we don't want these cloud archives to be downloaded (because they will produce errors). We want to preserve the behavior here when we move away from s3_archive.

## How to Build Each Archive
### sysroot (both aarch64 and x86_64)
In the past, we used an adhoc build script which you can find at `plans/s3_to_artifactory/pack_sysroot.sh`. This was required to be run within our FDB build docker image, as it would copy various files from there to pack for bazel and frostdb. It is worth noting that there are x86_64 and aarch64 versions of the docker image, and we would run the build scripts in their respective docker images. The set of files to package in sysroot is slightly different for the two architectures.

We want to do exactly the same thing now to build the archive for Artifactory, using `third-party-repack/gcc/build.sh` as an example for how to set up the docker image and run a build script in it. 

However, before that, I want to understand what files the sysroot build script is actually packaging and what is needed for the project to build. I think it would be a great exercise to try and remove some of the files which we package to sysroot until there's a build failure, and slowly add back files until there isn't. That way we can have a more explicit set of files. I would imagine the iteration flow involves using docker commands (pull, run) to locally run the build script on the docker image and save tarballs locally to test with. Then I would temporarily change the `s3_archive` for sysroots to `local_respository` and point them to the tarballs. Then we can run bazel build. But you can think about it and confirm whether there are better strategies. You may be able to identify through inspection of `frostdb/` what files are definitely used from the sysroot, so you can skip removing those.

### gcc
This one has already been made for you, I think it should work as is so you don't have to do anything.

### awssdk
The archive is built with the script at `frostdb/dependencies/awssdk/build_archive.sh`. It should be as simple as using this script to repack to Artifactory, though I would appreciate if you could parameterize the version.
