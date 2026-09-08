//
// Copyright (c) 2023-2025, Crash Override, Inc.
//
// This file is part of Chalk
// (see https://crashoverride.com/docs/chalk)
//

#include <crypto/x509.h>
#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/encoder.h>
#include <openssl/objects.h>
#include <openssl/pem.h>
#include <openssl/types.h>
#include <openssl/x509_vfy.h>
#include <openssl/x509v3.h>
#include <limits.h>
#include <stdint.h>

void cleanup_key_value(char **kv);

int
convert_ASN1TIME(ASN1_TIME *t, char *buf, size_t len)
{
    int  rc;
    BIO *b;

    if (buf == NULL || len == 0) {
        return -1;
    }
    buf[0] = 0;
    if (t == NULL) {
        return -1;
    }
    b = BIO_new(BIO_s_mem());
    if (b == NULL) {
        return -1;
    }
    rc = ASN1_TIME_print(b, t);
    if (rc <= 0) {
        BIO_free(b);
        return -1;
    }
    rc = BIO_gets(b, buf, len);
    if (rc <= 0) {
        BIO_free(b);
        return -1;
    }
    BIO_free(b);
    return 0;
}

char *
convert_ASN1STRING(ASN1_BIT_STRING *s)
{
    int            l      = (s == NULL) ? 0 : ASN1_STRING_length(s);
    unsigned char *data;
    char          *result;
    char          *cur;

    if (l <= 0) {
        return calloc(1, 1);
    }
    if ((size_t)l > SIZE_MAX / 3) {
        return NULL;
    }
    // each byte is 2 hex plus colon or last char NULL
    result = calloc((size_t)l * 3, 1);
    if (result == NULL) {
        return NULL;
    }
    data   = ASN1_STRING_get0_data(s);
    cur    = result;

    for (int i = 0; i < l - 1; i++) {
        sprintf(cur, "%02x:", data[i]);
        cur += 3;
    }
    sprintf(cur, "%02x", data[l - 1]);

    return result;
}

char **
convert_NAME(X509_NAME *n, int short_name)
{
    int count        = X509_NAME_entry_count(n);
    size_t capacity  = (size_t)count * 2 + 1;
    char **key_value = calloc(capacity, sizeof(*key_value));
    size_t ix         = 0;
    if (key_value == NULL) {
        return NULL;
    }
    for (int i = 0; i < count; i++) {
        X509_NAME_ENTRY *entry = X509_NAME_get_entry(n, i);
        ASN1_OBJECT     *key   = X509_NAME_ENTRY_get_object(entry);
        ASN1_STRING     *value = X509_NAME_ENTRY_get_data(entry);
        unsigned char *utf8;
        int nid = OBJ_obj2nid(key);

        if (nid == NID_undef) {
            // raw OID as the key
            char scratch[200];
            OBJ_obj2txt(scratch, 200, key, 1);
            key_value[ix] = strdup(scratch);
        } else {
            const char *nid_name = short_name ? OBJ_nid2sn(nid)
                                             : OBJ_nid2ln(nid);
            key_value[ix] = strdup(nid_name == NULL ? "" : nid_name);
        }
        if (key_value[ix] == NULL) {
            cleanup_key_value(key_value);
            return NULL;
        }
        ix++;

        int len = ASN1_STRING_to_UTF8(&utf8, value);
        if (len < 0) {
            key_value[ix] = strdup("");
        } else {
            key_value[ix] = strndup((const char *)utf8, (size_t)len);
            OPENSSL_free(utf8);
        }
        if (key_value[ix] == NULL) {
            cleanup_key_value(key_value);
            return NULL;
        }
        ix++;
    }
    return key_value;
}

// Drain a bio.
char *
BIO_all(BIO *bio)
{
    BUF_MEM *bptr = NULL;
    char    *result;
    size_t   total = 0;
    size_t   expected;

    if (bio == NULL || BIO_get_mem_ptr(bio, &bptr) <= 0 || bptr == NULL) {
        return NULL;
    }
    expected = bptr->length;
    if (expected == 0 || expected == SIZE_MAX) {
        return NULL;
    }
    result = malloc(expected + 1);
    if (result == NULL) {
        return NULL;
    }

    while (total < expected) {
        size_t remaining = expected - total;
        int chunk = remaining > INT_MAX ? INT_MAX : (int)remaining;
        int n = BIO_read(bio, result + total, chunk);
        if (n <= 0) {
            free(result);
            return NULL;
        }
        total += (size_t)n;
    }
    result[total] = 0;

    return result;
}

#define FIXED_LEN 15

typedef struct {
    char **key_value;
    char **subject;
    char **subject_short;
    char **issuer;
    char **issuer_short;
    int  version;
    int  key_size;
} Cert;

Cert *
extract_cert_data(BIO *fdb)
{
    int               cur        = BIO_tell(fdb);
    X509             *cert       = PEM_read_bio_X509(fdb, NULL, NULL, NULL);
    if (!cert) {
        // attempt to rewind to original position to reread as DER cert
        if (BIO_seek(fdb, cur) < 0) {
            return NULL;
        }
        cert                     = d2i_X509_bio(fdb, NULL);
        if (!cert) {
            return NULL;
        }
    }
    char              scratch[2000];
    int               version    = ((int)X509_get_version(cert)) + 1;
    EVP_PKEY         *pub        = X509_get_pubkey(cert);
    if (pub == NULL) {
        // Unparseable/unsupported public key. Treat the whole record as not a
        // certificate rather than dereferencing NULL below.
        X509_free(cert);
        return NULL;
    }
    int               keynid     = EVP_PKEY_base_id(pub);
    const char       *keytype_ln = OBJ_nid2ln(keynid);
    char             *keytype    = strdup(keytype_ln == NULL ? "" : keytype_ln);
    int               keysize    = EVP_PKEY_get_bits(pub);
    int               signid     = X509_get_signature_nid(cert);
    const char       *sigtype_ln = OBJ_nid2ln(signid);
    char             *sigtype    = strdup(sigtype_ln == NULL ? "" : sigtype_ln);
    ASN1_BIT_STRING  *sig;
    X509_ALGOR       *sigalg;
    X509_NAME        *subj       = X509_get_subject_name(cert);
    X509_NAME        *issuer     = X509_get_issuer_name(cert);
    ASN1_INTEGER     *sn         = X509_get_serialNumber(cert);
    BIGNUM           *bn         = ASN1_INTEGER_to_BN(sn, NULL);
    char             *bn_dec     = (bn == NULL) ? NULL : BN_bn2dec(bn);
    // Copy onto the normal heap: everything in key_value is released with
    // free(), not OPENSSL_free().
    char             *serial     = strdup(bn_dec == NULL ? "" : bn_dec);
    if (bn_dec != NULL) {
        OPENSSL_free(bn_dec);
    }
    if (bn != NULL) {
        BN_free(bn);
    }
    ASN1_TIME        *atime      = X509_get_notBefore(cert);
    convert_ASN1TIME(atime, scratch, 200);
    char             *not_before = strdup(scratch);
    atime                        = X509_get_notAfter(cert);
    convert_ASN1TIME(atime, scratch, 200);
    char             *not_after  = strdup(scratch);
    BIO              *key_bio    = BIO_new(BIO_s_mem());
    OSSL_ENCODER_CTX *encoder    = OSSL_ENCODER_CTX_new_for_pkey(
        pub,
        OSSL_KEYMGMT_SELECT_PUBLIC_KEY,
        "PEM",
        "SubjectPublicKeyInfo",
        NULL);
    if (encoder != NULL) {
        OSSL_ENCODER_to_bio(encoder, key_bio);
        OSSL_ENCODER_CTX_free(encoder);
    }

    X509_get0_signature(&sig, &sigalg, cert);

    char *key_contents = BIO_all(key_bio);
    BIO_free(key_bio);
    STACK_OF(X509_EXTENSION) *exts = cert->cert_info.extensions;

    int num_exts = sk_X509_EXTENSION_num(exts);
    if (num_exts < 0) {
        num_exts = 0;
    }

    size_t capacity   = FIXED_LEN + (size_t)num_exts * 2;
    char **key_value = calloc(capacity, sizeof(*key_value));
    if (key_value == NULL) {
        free(serial);
        free(key_contents);
        free(keytype);
        free(sigtype);
        free(not_before);
        free(not_after);
        EVP_PKEY_free(pub);
        X509_free(cert);
        return NULL;
    }

    int ix              = 0;
    key_value[ix++]     = strdup("Serial");
    key_value[ix++]     = serial;
    key_value[ix++]     = strdup("Key");
    key_value[ix++]     = (key_contents == NULL) ? strdup("") : key_contents;
    key_value[ix++]     = strdup("Key Type");
    key_value[ix++]     = keytype;
    key_value[ix++]     = strdup("Signature Type");
    key_value[ix++]     = sigtype;
    key_value[ix++]     = strdup("Not Before");
    key_value[ix++]     = not_before;
    key_value[ix++]     = strdup("Not After");
    key_value[ix++]     = not_after;
    if (sig) {
        key_value[ix++] = strdup("Signature");
        key_value[ix++] = convert_ASN1STRING(sig);
    }

    for (int i = 0; i < num_exts; i++) {
        char           *name    = NULL;
        char           *value   = NULL;
        X509_EXTENSION *ex      = sk_X509_EXTENSION_value(exts, i);
        ASN1_OBJECT    *obj     = X509_EXTENSION_get_object(ex);
        BIO            *ext_bio = BIO_new(BIO_s_mem());
        BUF_MEM        *bptr    = NULL;
        BIO_get_mem_ptr(ext_bio, &bptr);
        BIO_set_close(ext_bio, BIO_CLOSE);

        unsigned nid = OBJ_obj2nid(obj);
        if (nid == NID_undef) {
            // raw OID as extension name
            char extname[200];
            OBJ_obj2txt(extname, 200, (const ASN1_OBJECT *)obj, 1);
            name = strdup(extname);
        } else {
            const char *c_ext_name = OBJ_nid2ln(nid);
            name = strdup(c_ext_name);
        }

        X509V3_EXT_print(ext_bio, ex, 0, 0);
        value = BIO_all(ext_bio);

        if (!value) {
            value = strdup("");
        }

        key_value[ix++] = name;
        key_value[ix++] = value;

        BIO_free(ext_bio);
        ext_bio = NULL;
    }

    key_value[ix++] = 0;

    Cert *result          = malloc(sizeof(Cert));
    if (result == NULL) {
        cleanup_key_value(key_value);
        EVP_PKEY_free(pub);
        X509_free(cert);
        return NULL;
    }
    result->key_value     = key_value;
    result->subject       = convert_NAME(subj, 0);
    result->subject_short = convert_NAME(subj, 1);
    result->issuer        = convert_NAME(issuer, 0);
    result->issuer_short  = convert_NAME(issuer, 1);
    result->version       = version;
    result->key_size      = keysize;

    // subj/issuer point into cert, so this must come after convert_NAME.
    EVP_PKEY_free(pub);
    X509_free(cert);

    return result;
}

void
cleanup_key_value(char **kv)
{
    if (kv == NULL) {
        return;
    }
    char **info = kv;
    char *p     = *info++;
    while (p) {
        free(p);
        p = *info++;
    }
    free(kv);
}

void
cleanup_cert_info(Cert *cert)
{
    if (cert == NULL) {
        return;
    }
    cleanup_key_value(cert->key_value);
    cleanup_key_value(cert->subject);
    cleanup_key_value(cert->subject_short);
    cleanup_key_value(cert->issuer);
    cleanup_key_value(cert->issuer_short);
    free(cert);
}

BIO *
open_cert(int fd)
{
    BIO  *fdb    = BIO_new_fd(fd, 0);
    return fdb;
}

BIO *
read_cert(char *data, int n)
{
    BIO  *fdb    = BIO_new_mem_buf(data, n);
    return fdb;
}

void
close_cert(BIO *fdb)
{
    BIO_free(fdb);
}
