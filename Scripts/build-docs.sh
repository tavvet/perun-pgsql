#!/usr/bin/env bash
#
# Build the DocC documentation archive for PerunPGSQL.
#
# OpenSSL is found through pkg-config, so we point PKG_CONFIG_PATH at Homebrew's keg-only
# openssl@3. swift-docc-plugin also drives `swift-symbolgraph-extract`, which does not always
# inherit those flags, so we additionally set CPATH (clang honours it for every compilation) as
# a belt-and-suspenders fallback for the header search path.
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

PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
CPATH="$prefix/include${CPATH:+:$CPATH}" \
PERUN_BUILD_DOCS=1 \
    swift package generate-documentation --target PerunPGSQL "$@"
