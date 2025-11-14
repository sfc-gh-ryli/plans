# Proposed implementation plan (all scripts/commands should be ran in Cloud Workspace):

1. To speed up local testing, temporarily replace clang s3_archive in @../../frostdb/MODULE.bazel#L272 with Bazel's new_local_repository at https://bazel.build/rules/lib/repo/local#new_local_repository (pointing out to a local directory with the contents of that S3 archive unpacked), check if things build. 
2. See if we are able to even recreate current version of that compiler archive
  a. Copy @./build_clang_old.sh  (or its slightly newer version? @./build_clang_new.sh) that was originally used for this 
  b. Remove monorepo specific things, change clang version and build settings to match ours
  c. Point your local repository to the one created by this script instead of downloaded from S3, check if things still build
  d. To debug any failures, I usually try building some easy targets first: my favorite order is contrib/crc32/…, contrib/…, flow/…, fdbclient/…, …
3. Upgrade the script to build version that developers want (ask Jason / Markus), repeat
4. If any errors look like legitimate ones expected due to version upgrade you can try to fix them yourself, but you can also pack and upload (under different name!) new S3 archive and send developers a branch with new compiler enabled to play with

Once we have it working using Cloud Workspaces, to avoid having to reinvent this wheel every other year, this time we should formalize this process into checked in scripts and a Jenkins job that will do the entire process up to uploading to S3. We should only check in new S3 links generated from that job.

Alternatively: skip the custom script and Jenkins job, and try to integrate with what monorepo is now using to build their packages. Probably still good to make it work locally with a script and show it to them as “we want to do this, but with your system”.

Super alternatively: if the version that developers want is close enough to what monorepo uses, maybe we can directly use theirs (possibly after some adjustments to align them)? 
