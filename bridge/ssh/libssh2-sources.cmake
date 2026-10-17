# libssh2's portable sources for the OpenSSL backend. Kept in step with scripts/build-ssh-xcframework.sh.
set(MR_LIBSSH2_SOURCES)
foreach(_source
        agent bcrypt_pbkdf chacha channel cipher-chachapoly comp crypt global
        hostkey keepalive kex knownhost mac misc openssl packet pem poly1305
        publickey scp session sftp transport userauth userauth_kbd_packet version)
    list(APPEND MR_LIBSSH2_SOURCES "${MR_LIBSSH2_SOURCE_DIR}/src/${_source}.c")
endforeach()

# Weak algorithms are not compiled out (the OpenSSL backend keys that off
# OPENSSL_NO_*); the bridge's method preferences keep them from being
# negotiated instead.
set(MR_LIBSSH2_DEFINITIONS
    __STDC_WANT_LIB_EXT1__=1
    HAVE_CONFIG_H
    LIBSSH2_OPENSSL
)
