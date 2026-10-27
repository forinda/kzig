Test-only keys and certificates for `src/db` (never used outside tests):
an unrelated CA, and private keys in each format the TLS client reads
(SEC1 and PKCS#8 EC, PKCS#1 and PKCS#8 RSA). Generated with openssl.

Encrypted copies (password `kzig-test`): PBES2 (PBKDF2-HMAC-SHA256 + AES-256-CBC, and
PBKDF2-HMAC-SHA1 + AES-128-CBC) and OpenSSL's traditional `DEK-Info` PEM (AES-256, AES-128).

Also: an Ed25519 key (PKCS#8), self-signed certificates for the EC, RSA and Ed25519 keys (to
check a key matches its certificate), and keys encrypted with scrypt (PBES2) and with 3DES
(PBES2 and DEK-Info).

`crl/`: an EC and an RSA test CA, certificates they issued (one revoked each), their CRLs, and an
already-lapsed CRL.

Also in `crl/`: a CRL with a critical extension (IssuingDistributionPoint), and a second CA with
the EC CA's name but another key (a rollover).
