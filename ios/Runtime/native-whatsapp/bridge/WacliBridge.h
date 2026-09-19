#ifndef OPERATOR_WACLI_BRIDGE_H
#define OPERATOR_WACLI_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

char *WacliStartLink(char *store, char *phone);
char *WacliLinkStatus(char *operationID);
char *WacliCancelLink(char *operationID);
void WacliFreeString(char *value);
char *WacliListChats(char *store, int limit);
char *WacliListMessages(char *store, char *chat, int limit);
char *WacliStartSync(char *store, int timeoutSeconds);
char *WacliSyncStatus(char *operationID);
char *WacliCancelSync(char *operationID);
char *WacliSendText(char *store, char *recipientJID, char *body, int timeoutMilliseconds);
char *WacliSendText(char *store, char *recipientJID, char *body, int timeoutSeconds);

#ifdef __cplusplus
}
#endif

#endif
