#include <stddef.h>

char *WacliStartLink(char *store, char *phone) { return NULL; }
char *WacliLinkStatus(char *operationID) { return NULL; }
char *WacliCancelLink(char *operationID) { return NULL; }
void WacliFreeString(char *value) {}
char *WacliListChats(char *store, int limit) { return NULL; }
char *WacliListMessages(char *store, char *chat, int limit) { return NULL; }
char *WacliStartSync(char *store, int timeoutSeconds) { return NULL; }
char *WacliSyncStatus(char *operationID) { return NULL; }
char *WacliCancelSync(char *operationID) { return NULL; }
char *WacliSendText(char *store, char *recipientJID, char *body, int timeoutSeconds) { return NULL; }
