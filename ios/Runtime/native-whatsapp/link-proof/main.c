#include "WacliBridge.h"

int main(void) {
    char unknown[] = "unknown";
    char *result = WacliLinkStatus(unknown);
    if (result == 0) return 1;
    WacliFreeString(result);
    char store[] = "/private/unlinked";
    result = WacliListChats(store, 10);
    if (result == 0) return 2;
    WacliFreeString(result);
    return 0;
}
