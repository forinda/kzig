Test-only keys and certificates for `src/db` (never used outside tests):
an unrelated CA, and private keys in each format the TLS client reads
(SEC1 and PKCS#8 EC, PKCS#1 and PKCS#8 RSA). Generated with openssl.

Encrypted copies (password `kzig-test`): PBES2 (PBKDF2-HMAC-SHA256 + AES-256-CBC, and
PBKDF2-HMAC-SHA1 + AES-128-CBC) and OpenSSL's traditional `DEK-Info` PEM (AES-256, AES-128).
