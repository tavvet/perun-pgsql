#!/usr/bin/env bash
#
# Build the DocC documentation archive for PerunPGSQL.
#
# swift-docc-plugin drives `swift-symbolgraph-extract`, which does NOT inherit the target's
# OpenSSL header search path (the `-Xcc -I<prefix>/include` in Package.swift is a target
# `unsafeFlag`, and neither the target settings nor a global `-Xcc` reach the extract step).
# So we inject the include path via CPATH, which clang honours for every compilation — the
# same prefix Package.swift probes for.
#
# Usage: ./Scripts/build-docs.sh [extra generate-documentation args]
#   OPENSSL_PREFIX=/path overrides the probe.
set -euo pipefail

prefix="${OPENSSL_PREFIX:-}"
if [[ -z "$prefix" ]]; then
    for candidate in \
        /opt/homebrew/opt/openssl@3 \
        /usr/local/opt/openssl@3 \
        /opt/homebrew/opt/openssl \
        /usr/local/opt/openssl \
        /usr; do
        if [[ -f "$candidate/include/openssl/ssl.h" ]]; then
            prefix="$candidate"
            break
        fi
    done
fi
[[ -n "$prefix" ]] || { echo "error: OpenSSL headers not found; set OPENSSL_PREFIX" >&2; exit 1; }

CPATH="$prefix/include${CPATH:+:$CPATH}" PERUN_BUILD_DOCS=1 \
    swift package generate-documentation --target PerunPGSQL "$@"
