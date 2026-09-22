#import "CommonCryptoCompat.h"

#import <dlfcn.h>
#import <pthread.h>

typedef unsigned char *(*ExternalCCSHA256Function)(const void *, CC_LONG, unsigned char *);
typedef int (*ExternalCCSHA256InitFunction)(CC_SHA256_CTX *);
typedef int (*ExternalCCSHA256UpdateFunction)(CC_SHA256_CTX *, const void *, CC_LONG);
typedef int (*ExternalCCSHA256FinalFunction)(unsigned char *, CC_SHA256_CTX *);
typedef int (*ExternalCCKeyDerivationPBKDFFunction)(CCPBKDFAlgorithm,
                                                    const char *,
                                                    size_t,
                                                    const uint8_t *,
                                                    size_t,
                                                    CCPseudoRandomAlgorithm,
                                                    uint32_t,
                                                    uint8_t *,
                                                    size_t);
typedef CCCryptorStatus (*ExternalCCCryptorGCMOneshotEncryptFunction)(CCAlgorithm,
                                                                       const void *,
                                                                       size_t,
                                                                       const void *,
                                                                       size_t,
                                                                       const void *,
                                                                       size_t,
                                                                       const void *,
                                                                       size_t,
                                                                       void *,
                                                                       void *,
                                                                       size_t);
typedef CCCryptorStatus (*ExternalCCCryptorGCMOneshotDecryptFunction)(CCAlgorithm,
                                                                       const void *,
                                                                       size_t,
                                                                       const void *,
                                                                       size_t,
                                                                       const void *,
                                                                       size_t,
                                                                       const void *,
                                                                       size_t,
                                                                       void *,
                                                                       const void *,
                                                                       size_t);

static pthread_once_t gCommonCryptoOnce = PTHREAD_ONCE_INIT;
static void *gCommonCryptoHandle = NULL;
static ExternalCCSHA256Function gCCSHA256 = NULL;
static ExternalCCSHA256InitFunction gCCSHA256Init = NULL;
static ExternalCCSHA256UpdateFunction gCCSHA256Update = NULL;
static ExternalCCSHA256FinalFunction gCCSHA256Final = NULL;
static ExternalCCKeyDerivationPBKDFFunction gCCKeyDerivationPBKDF = NULL;
static ExternalCCCryptorGCMOneshotEncryptFunction gCCCryptorGCMOneshotEncrypt = NULL;
static ExternalCCCryptorGCMOneshotDecryptFunction gCCCryptorGCMOneshotDecrypt = NULL;

static void LoadCommonCrypto(void) {
    gCommonCryptoHandle = dlopen("/usr/lib/system/libcommonCrypto.dylib", RTLD_LAZY);
    if (!gCommonCryptoHandle) {
        gCommonCryptoHandle = dlopen("/usr/lib/libcommonCrypto.dylib", RTLD_LAZY);
    }

    void *lookupHandle = gCommonCryptoHandle ?: RTLD_DEFAULT;
    gCCSHA256 = (ExternalCCSHA256Function)dlsym(lookupHandle, "CC_SHA256");
    gCCSHA256Init = (ExternalCCSHA256InitFunction)dlsym(lookupHandle, "CC_SHA256_Init");
    gCCSHA256Update = (ExternalCCSHA256UpdateFunction)dlsym(lookupHandle, "CC_SHA256_Update");
    gCCSHA256Final = (ExternalCCSHA256FinalFunction)dlsym(lookupHandle, "CC_SHA256_Final");
    gCCKeyDerivationPBKDF = (ExternalCCKeyDerivationPBKDFFunction)dlsym(lookupHandle, "CCKeyDerivationPBKDF");
    gCCCryptorGCMOneshotEncrypt = (ExternalCCCryptorGCMOneshotEncryptFunction)dlsym(lookupHandle, "CCCryptorGCMOneshotEncrypt");
    gCCCryptorGCMOneshotDecrypt = (ExternalCCCryptorGCMOneshotDecryptFunction)dlsym(lookupHandle, "CCCryptorGCMOneshotDecrypt");
}

static void EnsureCommonCryptoLoaded(void) {
    pthread_once(&gCommonCryptoOnce, LoadCommonCrypto);
}

BOOL ExternalCCSHA256(const void *data,
                      CC_LONG length,
                      unsigned char * _Nonnull digest) {
    EnsureCommonCryptoLoaded();
    return gCCSHA256 && gCCSHA256(data, length, digest) != NULL;
}

BOOL ExternalCCSHA256Init(CC_SHA256_CTX *context) {
    EnsureCommonCryptoLoaded();
    return gCCSHA256Init && gCCSHA256Init(context) == 1;
}

BOOL ExternalCCSHA256Update(CC_SHA256_CTX *context,
                            const void *data,
                            CC_LONG length) {
    EnsureCommonCryptoLoaded();
    return gCCSHA256Update && gCCSHA256Update(context, data, length) == 1;
}

BOOL ExternalCCSHA256Final(unsigned char * _Nonnull digest,
                           CC_SHA256_CTX *context) {
    EnsureCommonCryptoLoaded();
    return gCCSHA256Final && gCCSHA256Final(digest, context) == 1;
}

int ExternalCCKeyDerivationPBKDF(CCPBKDFAlgorithm algorithm,
                                 const char *password,
                                 size_t passwordLength,
                                 const uint8_t *salt,
                                 size_t saltLength,
                                 CCPseudoRandomAlgorithm prf,
                                 uint32_t rounds,
                                 uint8_t *derivedKey,
                                 size_t derivedKeyLength) {
    EnsureCommonCryptoLoaded();
    return gCCKeyDerivationPBKDF
        ? gCCKeyDerivationPBKDF(algorithm, password, passwordLength, salt, saltLength,
                                prf, rounds, derivedKey, derivedKeyLength)
        : -1;
}

CCCryptorStatus ExternalCCCryptorGCMOneshotEncrypt(CCAlgorithm algorithm,
                                                    const void *key,
                                                    size_t keyLength,
                                                    const void *iv,
                                                    size_t ivLength,
                                                    const void *aad,
                                                    size_t aadLength,
                                                    const void *dataIn,
                                                    size_t dataInLength,
                                                    void *dataOut,
                                                    void *tag,
                                                    size_t tagLength) {
    EnsureCommonCryptoLoaded();
    return gCCCryptorGCMOneshotEncrypt
        ? gCCCryptorGCMOneshotEncrypt(algorithm, key, keyLength, iv, ivLength,
                                      aad, aadLength, dataIn, dataInLength,
                                      dataOut, tag, tagLength)
        : (CCCryptorStatus)-1;
}

CCCryptorStatus ExternalCCCryptorGCMOneshotDecrypt(CCAlgorithm algorithm,
                                                    const void *key,
                                                    size_t keyLength,
                                                    const void *iv,
                                                    size_t ivLength,
                                                    const void *aad,
                                                    size_t aadLength,
                                                    const void *dataIn,
                                                    size_t dataInLength,
                                                    void *dataOut,
                                                    const void *tag,
                                                    size_t tagLength) {
    EnsureCommonCryptoLoaded();
    return gCCCryptorGCMOneshotDecrypt
        ? gCCCryptorGCMOneshotDecrypt(algorithm, key, keyLength, iv, ivLength,
                                      aad, aadLength, dataIn, dataInLength,
                                      dataOut, tag, tagLength)
        : (CCCryptorStatus)-1;
}