#ifndef EJS_FAKE_HOST_H
#define EJS_FAKE_HOST_H

#include "ejs_native_api.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EJSFakeHost EJSFakeHost;

EJSFakeHost *ejs_fake_host_create(void);
void ejs_fake_host_destroy(EJSFakeHost *host);

EJSCoreHostAPI *ejs_fake_host_api(EJSFakeHost *host);
size_t ejs_fake_host_pending_count(const EJSFakeHost *host);

void ejs_fake_host_complete_next(EJSFakeHost *host);
void ejs_fake_host_complete_all(EJSFakeHost *host);

size_t ejs_fake_host_retain_count(const EJSFakeHost *host);
size_t ejs_fake_host_release_count(const EJSFakeHost *host);

#ifdef __cplusplus
}
#endif

#endif
