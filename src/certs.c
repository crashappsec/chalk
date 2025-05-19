{. emit:"""
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

int
convert_ASN1TIME(ASN1_TIME *t, char *buf, size_t len)
{
    int  rc;
    BIO *b = BIO_new(BIO_s_mem());
    rc     = ASN1_TIME_print(b, t);
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
    return -1;
}

// Drain a bio.
char *
BIO_all(BIO *bio)
{
    char *result;
    char *cur;
    char  scratch[PIPE_BUF];
    int   total;

    int n = BIO_read(bio, scratch, PIPE_BUF);
    if (!n) {
        return NULL;
    }
    result = strdup(scratch);
    total  = n;

    while ((n = BIO_read(bio, scratch, PIPE_BUF)) > 0) {
        cur = calloc(total + n + 1, 1);
        memcpy(cur, result, total);
        memcpy(cur + total, scratch, n);
        free(result);
        result = cur;
        total  = total + n;
    }

    return result;
}

#define FIXED_LEN 13
char **
extract_cert_data(int fd, int *version)
{
    char scratch[2000];

    BIO          *fdb    = BIO_new_fd(fd, 0);
    X509         *cert   = PEM_read_bio_X509(fdb, NULL, NULL, NULL);
    if (!cert) {
        return NULL;
    }
    EVP_PKEY     *pub           = X509_get_pubkey(cert);
    void         *subjn         = X509_get_subject_name(cert);
    char         *subj          = X509_NAME_oneline(subjn, NULL, 0);
    void         *in            = X509_get_issuer_name(cert);
    char         *issuer        = X509_NAME_oneline(in, NULL, 0);
    ASN1_INTEGER *sn            = X509_get_serialNumber(cert);
    BIGNUM       *bn            = ASN1_INTEGER_to_BN(sn, NULL);
    char         *serial        = BN_bn2dec(bn);
    ASN1_TIME    *atime         = X509_get_notBefore(cert);
    convert_ASN1TIME(atime, scratch, 200);
    char *not_before            = strdup(scratch);
    atime                       = X509_get_notAfter(cert);
    convert_ASN1TIME(atime, scratch, 200);
    char             *not_after = strdup(scratch);
    BIO              *key_bio   = BIO_new(BIO_s_mem());
    OSSL_ENCODER_CTX *encoder   = OSSL_ENCODER_CTX_new_for_pkey(
        pub,
        OSSL_KEYMGMT_SELECT_PUBLIC_KEY,
        "PEM",
        "PKCS1",
        NULL);
    OSSL_ENCODER_to_bio(encoder, key_bio);

    *version = ((int)X509_get_version(cert)) + 1;

    char *key_contents = BIO_all(key_bio);
    BIO_free(key_bio);
    STACK_OF(X509_EXTENSION) *exts = cert->cert_info.extensions;

    int num_exts = sk_X509_EXTENSION_num(exts);
    if (num_exts < 0) {
        num_exts = 0;
    }

    char **result = calloc(sizeof(char *), FIXED_LEN + num_exts * 2);

    int ix       = 0;
    result[ix++] = strdup("Subject");
    result[ix++] = subj;
    result[ix++] = strdup("Issuer");
    result[ix++] = issuer;
    result[ix++] = strdup("Serial");
    result[ix++] = serial;
    result[ix++] = strdup("Key");
    result[ix++] = key_contents;
    result[ix++] = strdup("Not Before");
    result[ix++] = not_before;
    result[ix++] = strdup("Not After");
    result[ix++] = not_after;

    for (int i = 0; i < num_exts; i++) {
        X509_EXTENSION *ex      = sk_X509_EXTENSION_value(exts, i);
        ASN1_OBJECT    *obj     = X509_EXTENSION_get_object(ex);
        BIO            *ext_bio = BIO_new(BIO_s_mem());
        BUF_MEM        *bptr    = NULL;
        BIO_get_mem_ptr(ext_bio, &bptr);
        BIO_set_close(ext_bio, BIO_NOCLOSE);

        if (!X509V3_EXT_print(ext_bio, ex, 0, 0)) {
            char *tmp = BIO_all(ext_bio);
            if (tmp) {
                result[ix++] = tmp;
            }
        }

        // remove newlines
        int lastchar = bptr->length;
        if (lastchar > 1
            && (bptr->data[lastchar - 1] == '\n'
                || bptr->data[lastchar - 1] == '\r')) {
            bptr->data[lastchar - 1] = 0;
        }
        if (lastchar > 0
            && (bptr->data[lastchar] == '\n'
                || bptr->data[lastchar] == '\r')) {
            bptr->data[lastchar] = 0;
        }

        unsigned nid = OBJ_obj2nid(obj);
        if (nid == NID_undef) {
            char extname[200];
            OBJ_obj2txt(extname, 200, (const ASN1_OBJECT *)obj, 1);
            result[ix++] = strdup(extname);
        }
        else {
            const char *c_ext_name = OBJ_nid2ln(nid);
            result[ix++]           = strdup(c_ext_name);
        }

        if (bptr) {
            result[ix++] = strdup(bptr->data);
        }
        BIO_free(ext_bio);
        ext_bio = NULL;
    }

    result[ix++] = 0;

    BIO_free(fdb);

    return result;
}

void
cleanup_cert_info(char **info)
{
    char *p = *info++;

    while (p) {
        free(p);
        p = *info++;
    }
}

/*
void
test_x509()
{
    int    fd = open("tmp/public_certificate.pem", O_RDONLY);
    int    version;
    int    num_items;
    char **to_print = extract_cert_data(fd, &version, &num_items);

    int i  = 0;
    int ix = 0;
    while (i < num_items) {
        char *a = to_print[i++];
        char *b = to_print[i++];
        printf("%d: %s: %s\n", ++ix, a, b);
    }

    cleanup_cert_info(to_print);
}
*/

""".}
