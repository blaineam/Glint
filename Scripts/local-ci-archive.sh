#!/bin/zsh
# Thin wrapper around the shared CI script.
# See ../../_shared/local-ci-archive.sh for full behavior.
# Per-project tweaks go in .local-ci.conf next to the .xcodeproj.
exec "$(cd "$(dirname "$0")/../../_shared" && pwd)/local-ci-archive.sh" "$@"
