#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <sodium.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void cfree(void **data) {
    if (*data) {
        free(*data);
        *data = NULL;
    }
}

bool pem_to_der(const char *pem_key_str,
                unsigned char **der_out,
                size_t         *der_len) {
    BIO           *bio      = NULL;
    EVP_PKEY      *pkey     = NULL;
    unsigned char *tmp      = NULL;
    bool           result   = false;

    if (!pem_key_str || !der_out || !der_len) {
        goto cleanup;
    }
    bio = BIO_new_mem_buf(pem_key_str, -1);
    if (!bio) {
        goto cleanup;
    }
    pkey = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    if (!pkey) {
        goto cleanup;
    }
    *der_len = i2d_PUBKEY(pkey, NULL);
    if (*der_len <= 0) {
        goto cleanup;
    }
    *der_out = malloc(*der_len);
    tmp = *der_out;
    if (!der_out) {
        goto cleanup;
    }
    if (i2d_PUBKEY(pkey, &tmp) != *der_len) {
        goto cleanup;
    }

    result = true;

cleanup:
    if (!result) {
        if (*der_out) {
            OPENSSL_cleanse(*der_out, *der_len);
            free(*der_out);
            *der_out = NULL;
        }
        *der_len = 0;
    }
    if (bio) {
        BIO_free(bio);
    }
    if (pkey) {
        EVP_PKEY_free(pkey);
    }
    return result;
}

bool decrypt_secretbox(
    const uint8_t *password,
    size_t         password_len,
    const uint8_t *salt,
    size_t         salt_len,
    const char    *kdf_name,
    uint64_t       N,
    uint32_t       r,
    uint32_t       p,

    const char    *cipher_name,
    const uint8_t *nonce,
    size_t         nonce_len,
    const uint8_t *ciphertext,
    size_t         ciphertext_len,

    uint8_t      **plaintext,
    size_t        *plaintext_len
) {
    bool    result = false;
    uint8_t key[crypto_secretbox_KEYBYTES];

    if (!plaintext || !plaintext_len || !password || !salt || !nonce || !ciphertext) {
        goto cleanup;
    }
    if (!kdf_name || strcmp(kdf_name, "scrypt") != 0) {
        goto cleanup;
    }
    if (!cipher_name || strcmp(cipher_name, "nacl/secretbox") != 0) {
        goto cleanup;
    }
    if (nonce_len != crypto_secretbox_NONCEBYTES) {
        goto cleanup;
    }
    if (ciphertext_len <= crypto_secretbox_MACBYTES) {
        goto cleanup;
    }
    if (password_len < crypto_pwhash_scryptsalsa208sha256_PASSWD_MIN ||
        password_len > crypto_pwhash_scryptsalsa208sha256_PASSWD_MAX) {
        goto cleanup;
    }
    if (salt_len != crypto_pwhash_scryptsalsa208sha256_SALTBYTES) {
        goto cleanup;
    }
    if (sodium_init() < 0) {
        goto cleanup;
    }

    if (crypto_pwhash_scryptsalsa208sha256_ll(
        password,
        password_len,
        salt,
        salt_len,
        N,   // cost
        r,   // block size
        p,   // parallelization
        key,
        sizeof key
    ) != 0) {
        goto cleanup;
    }

    *plaintext_len = ciphertext_len - crypto_secretbox_MACBYTES;
    *plaintext = malloc(*plaintext_len);
    if (!*plaintext) {
        goto cleanup;
    }

    if (crypto_secretbox_open_easy(
        *plaintext,
        ciphertext,
        ciphertext_len,
        nonce,
        key
    ) != 0) {
        goto cleanup;
    }

    result = true;

cleanup:
    sodium_memzero(key, sizeof key);
    if (!result) {
        if (*plaintext) {
            sodium_memzero(*plaintext, *plaintext_len);
            free(*plaintext);
            *plaintext = NULL;
        }
        *plaintext_len = 0;
    }
    return result;
}

bool encrypt_secretbox(
    const uint8_t *password,
    size_t         password_len,
    const char    *kdf_name,
    uint64_t       N,
    uint32_t       r,
    uint32_t       p,

    const char    *cipher_name,
    const uint8_t *plaintext,
    size_t         plaintext_len,

    uint8_t      **salt,
    size_t        *salt_len,
    uint8_t      **nonce,
    size_t        *nonce_len,
    uint8_t      **ciphertext,
    size_t        *ciphertext_len
) {
    bool    result = false;
    uint8_t key[crypto_secretbox_KEYBYTES];

    if (!salt || !salt_len || !nonce || !nonce_len || !ciphertext || !ciphertext_len || !password || !plaintext) {
        goto cleanup;
    }
    if (!kdf_name || strcmp(kdf_name, "scrypt") != 0) {
        goto cleanup;
    }
    if (!cipher_name || strcmp(cipher_name, "nacl/secretbox") != 0) {
        goto cleanup;
    }
    if (password_len < crypto_pwhash_scryptsalsa208sha256_PASSWD_MIN ||
        password_len > crypto_pwhash_scryptsalsa208sha256_PASSWD_MAX) {
        goto cleanup;
    }
    if (sodium_init() < 0) {
        goto cleanup;
    }

    *salt_len = crypto_pwhash_scryptsalsa208sha256_SALTBYTES;
    *salt = malloc(*salt_len);
    if (!*salt) {
        goto cleanup;
    }
    randombytes_buf(*salt, *salt_len);

    *nonce_len = crypto_secretbox_NONCEBYTES;
    *nonce = malloc(*nonce_len);
    if (!*nonce) {
        goto cleanup;
    }
    randombytes_buf(*nonce, *nonce_len);

    if (crypto_pwhash_scryptsalsa208sha256_ll(
        password,
        password_len,
        *salt,
        *salt_len,
        N,   // cost
        r,   // block size
        p,   // parallelization
        key,
        sizeof key
    ) != 0) {
        goto cleanup;
    }

    *ciphertext_len = plaintext_len + crypto_secretbox_MACBYTES;
    *ciphertext = malloc(*ciphertext_len);
    if (!*ciphertext) {
        goto cleanup;
    }

    if (crypto_secretbox_easy(
        *ciphertext,
        plaintext,
        plaintext_len,
        *nonce,
        key
    ) != 0) {
        goto cleanup;
    }

    result = true;

cleanup:
    sodium_memzero(key, sizeof key);
    if (!result) {
        if (*salt) {
            sodium_memzero(*salt, *salt_len);
            free(*salt);
            *salt = NULL;
        }
        if (*nonce) {
            sodium_memzero(*nonce, *nonce_len);
            free(*nonce);
            *nonce = NULL;
        }
        if (*ciphertext) {
            sodium_memzero(*ciphertext, *ciphertext_len);
            free(*ciphertext);
            *ciphertext = NULL;
        }
        *salt_len       = 0;
        *nonce_len      = 0;
        *ciphertext_len = 0;
    }
    return result;
}

bool verify_signature(
    const char          *pem_key_buffer,
    const unsigned char *message,
    size_t               message_len,
    const unsigned char *signature,
    size_t               signature_len
) {
    BIO        *bio    = NULL;
    EVP_PKEY   *pkey   = NULL;
    EVP_MD_CTX *ctx    = NULL;
    bool        result = false;

    bio = BIO_new_mem_buf(pem_key_buffer, -1);
    if (!bio) {
        goto cleanup;
    }
    pkey = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    if (!pkey) {
        goto cleanup;
    }
    ctx = EVP_MD_CTX_new();
    if (!ctx) {
        goto cleanup;
    }
    if (EVP_DigestVerifyInit(ctx, NULL, EVP_sha256(), NULL, pkey) != 1) {
        goto cleanup;
    }
    if (EVP_DigestVerifyUpdate(ctx, message, message_len) != 1) {
        goto cleanup;
    }
    if (EVP_DigestVerifyFinal(ctx, signature, signature_len) == 1) {
        result = true;
    }

cleanup:
    if (ctx) {
        EVP_MD_CTX_free(ctx);
    }
    if (pkey) {
        EVP_PKEY_free(pkey);
    }
    if (bio) {
        BIO_free(bio);
    }
    return result;
}

bool sign_message(
    const unsigned char *private_key,
    size_t               private_key_len,
    const unsigned char *message,
    size_t               message_len,
    unsigned char      **signature,
    size_t              *signature_len
) {
    BIO        *bio    = NULL;
    EVP_PKEY   *pkey   = NULL;
    EVP_MD_CTX *ctx    = NULL;
    bool        result = false;

    pkey = d2i_AutoPrivateKey(NULL, &private_key, private_key_len);
    if (!pkey) {
        goto cleanup;
    }

    ctx = EVP_MD_CTX_new();
    if (!ctx) {
        goto cleanup;
    }
    if (EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, pkey) != 1) {
        goto cleanup;
    }
    if (EVP_DigestSignUpdate(ctx, message, message_len) != 1) {
        goto cleanup;
    }
    if (EVP_DigestSignFinal(ctx, NULL, signature_len) != 1) {
        goto cleanup;
    }
    *signature = malloc(*signature_len);
    if (!*signature) {
        goto cleanup;
    }

    if (EVP_DigestSignFinal(ctx, *signature, signature_len) != 1) {
        goto cleanup;
    }

    result = true;

cleanup:
    if (!result) {
        if (*signature) {
            OPENSSL_cleanse(*signature, *signature_len);
            free(*signature);
            *signature = NULL;
        }
        *signature_len = 0;
    }
    if (ctx) {
        EVP_MD_CTX_free(ctx);
    }
    if (pkey) {
        EVP_PKEY_free(pkey);
    }
    if (bio) {
        BIO_free(bio);
    }
    return result;
}

bool generate_p256_keypair(
    uint8_t   **public_key_out,
    size_t     *public_key_len,
    uint8_t   **private_key_out,
    size_t     *private_key_len
) {
    EVP_PKEY     *pkey      = NULL;
    EVP_PKEY_CTX *pctx      = NULL;
    BIO          *pub_bio   = NULL;
    BIO          *priv_bio  = NULL;
    char         *pub_data  = NULL;
    char         *priv_data = NULL;
    bool          result    = false;

    pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
    if (!pctx) {
        goto cleanup;
    }
    if (EVP_PKEY_keygen_init(pctx) != 1) {
        goto cleanup;
    }
    if (EVP_PKEY_CTX_set_ec_paramgen_curve_nid(pctx, NID_X9_62_prime256v1) != 1) {
        goto cleanup;
    }
    if (EVP_PKEY_keygen(pctx, &pkey) != 1) {
        goto cleanup;
    }

    pub_bio = BIO_new(BIO_s_mem());
    if (!pub_bio) {
        goto cleanup;
    }
    if (PEM_write_bio_PUBKEY(pub_bio, pkey) != 1) {
        goto cleanup;
    }
    *public_key_len = BIO_get_mem_data(pub_bio, &pub_data);
    if (*public_key_len <= 0) {
        goto cleanup;
    }

    priv_bio = BIO_new(BIO_s_mem());
    if (!priv_bio) {
        goto cleanup;
    }
    if (i2d_PKCS8PrivateKey_bio(priv_bio, pkey, NULL, NULL, 0, NULL, NULL) != 1) {
        goto cleanup;
    }
    *private_key_len = BIO_get_mem_data(priv_bio, &priv_data);
    if (*private_key_len <= 0) {
        goto cleanup;
    }

    *public_key_out = malloc(*public_key_len);
    if (!*public_key_out) {
        goto cleanup;
    }

    *private_key_out = malloc(*private_key_len);
    if (!*private_key_out) {
        goto cleanup;
    }

    memcpy(*public_key_out,  pub_data,  *public_key_len);
    memcpy(*private_key_out, priv_data, *private_key_len);

    result = true;

cleanup:
    if (!result) {
        if (*public_key_out) {
            OPENSSL_cleanse(*public_key_out, *public_key_len);
            free(*public_key_out);
            *public_key_out = NULL;
        }
        if (*private_key_out) {
            OPENSSL_cleanse(*private_key_out, *private_key_len);
            free(*private_key_out);
            *private_key_out = NULL;
        }
        *public_key_len  = 0;
        *private_key_len = 0;
    }
    pub_data  = NULL;
    priv_data = NULL;
    if (pub_bio) {
        BIO_free(pub_bio);
    }
    if (priv_bio) {
        BIO_free(priv_bio);
    }
    if (pkey) {
        EVP_PKEY_free(pkey);
    }
    if (pctx) {
        EVP_PKEY_CTX_free(pctx);
    }
    return result;
}

bool generate_and_encrypt_keypair(
    const uint8_t *password,
    size_t         password_len,
    const char    *kdf_name,
    uint64_t       N,
    uint32_t       r,
    uint32_t       p,
    const char    *cipher_name,

    uint8_t      **public_key_out,
    size_t        *public_key_len,
    uint8_t      **salt,
    size_t        *salt_len,
    uint8_t      **nonce,
    size_t        *nonce_len,
    uint8_t      **ciphertext,
    size_t        *ciphertext_len
) {
    uint8_t       *private_key     = NULL;
    size_t         private_key_len = 0;
    bool           result          = false;

    if (!generate_p256_keypair(
        public_key_out,
        public_key_len,
        &private_key,
        &private_key_len
    )) {
        goto cleanup;
    }

    if (!encrypt_secretbox(
        password,
        password_len,
        kdf_name,
        N,
        r,
        p,
        cipher_name,
        private_key,
        private_key_len,
        salt,
        salt_len,
        nonce,
        nonce_len,
        ciphertext,
        ciphertext_len
    )) {
        goto cleanup;
    }

    result = true;

cleanup:
    if (private_key) {
        OPENSSL_cleanse(private_key, private_key_len);
        free(private_key);
        private_key = NULL;
    }
    private_key_len = 0;
    return result;
}
