// Device-build stand-in for the wacli WhatsApp bridge.
//
// The real bridge is a Go static archive built for arm64 *simulator* only
// (ios/build/native-whatsapp, see build-info.txt). Its source is not retained
// in this repo, so there is no device slice to link against and a device build
// would otherwise fail with ten undefined symbols.
//
// Swift binds these entry points purely by symbol name (@_silgen_name in
// capabilities/whatsapp/{link,read,send}), never through a header, so
// supplying C definitions with the same names is enough to satisfy the linker
// with no change to any Swift file.
//
// Every entry point returns the bridge's own "not_available" envelope, which
// NativeWhatsApp{Link,Read,Send}Error already decode as .notAvailable. WhatsApp
// commands therefore fail cleanly on device instead of crashing or hanging.
//
// This file is excluded from the simulator build via
// EXCLUDED_SOURCE_FILE_NAMES[sdk=iphonesimulator*] in ios/project.yml, so the
// real archive still provides these symbols there and simulator behaviour is
// unchanged. Building a device slice of the archive would mean re-obtaining
// wacli v0.17.1 against the checksums pinned in
// ios/Runtime/native-whatsapp/archive/build.sh.
#include <stdlib.h>
#include <string.h>

static char *wacli_unavailable(void) {
    return strdup("{\"success\":false,\"error\":{\"code\":\"not_available\"}}");
}

char *WacliStartLink(char *store, char *phone) {
    (void)store; (void)phone;
    return wacli_unavailable();
}

char *WacliLinkStatus(char *operationID) {
    (void)operationID;
    return wacli_unavailable();
}

char *WacliCancelLink(char *operationID) {
    (void)operationID;
    return wacli_unavailable();
}

char *WacliListChats(char *storePath, int limit) {
    (void)storePath; (void)limit;
    return wacli_unavailable();
}

char *WacliListMessages(char *storePath, char *chat, int limit) {
    (void)storePath; (void)chat; (void)limit;
    return wacli_unavailable();
}

char *WacliStartSync(char *storePath, int timeoutSeconds) {
    (void)storePath; (void)timeoutSeconds;
    return wacli_unavailable();
}

char *WacliSyncStatus(char *operationID) {
    (void)operationID;
    return wacli_unavailable();
}

char *WacliCancelSync(char *operationID) {
    (void)operationID;
    return wacli_unavailable();
}

char *WacliSendText(char *store, char *recipient, char *body, int timeoutMilliseconds) {
    (void)store; (void)recipient; (void)body; (void)timeoutMilliseconds;
    return wacli_unavailable();
}

void WacliFreeString(char *value) {
    free(value);
}
