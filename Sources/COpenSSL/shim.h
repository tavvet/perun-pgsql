#ifndef PERUN_COPENSSL_SHIM_H
#define PERUN_COPENSSL_SHIM_H

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

/*
 * Several handy OpenSSL "functions" are actually preprocessor macros, so
 * Swift's Clang importer never sees them. Wrap the ones we need as real
 * (static inline) functions.
 */

static inline long perun_SSL_set_tlsext_host_name(SSL *ssl, const char *name) {
    return SSL_set_tlsext_host_name(ssl, name);
}

static inline long perun_SSL_CTX_set_min_proto_version(SSL_CTX *ctx, int version) {
    return SSL_CTX_set_min_proto_version(ctx, version);
}

#endif /* PERUN_COPENSSL_SHIM_H */
