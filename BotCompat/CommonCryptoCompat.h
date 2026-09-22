#import <Foundation/Foundation.h>

#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonKeyDerivation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL ExternalCCSHA256(const void *data,
                      CC_LONG length,
                      unsigned char * _Nonnull digest);
BOOL ExternalCCSHA256Init(CC_SHA256_CTX *context);
BOOL ExternalCCSHA256Update(CC_SHA256_CTX *context,
                            const void *data,
                            CC_LONG length);
BOOL ExternalCCSHA256Final(unsigned char * _Nonnull digest,
                           CC_SHA256_CTX *context);

int ExternalCCKeyDerivationPBKDF(CCPBKDFAlgorithm algorithm,
                                 const char *password,
                                 size_t passwordLength,
                                 const uint8_t *salt,
                                 size_t saltLength,
                                 CCPseudoRandomAlgorithm prf,
                                 uint32_t rounds,
                                 uint8_t *derivedKey,
                                 size_t derivedKeyLength);

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
                                                    size_t tagLength);

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
                                                    size_t tagLength);

NS_ASSUME_NONNULL_END