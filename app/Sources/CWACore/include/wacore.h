#ifndef WACORE_H
#define WACORE_H

// C surface of the Go core (core/main.go).

typedef void (*wa_event_cb)(const char *json);

// Boots the client. Events arrive on arbitrary threads as JSON; the string is
// only valid during the callback.
void WAStart(const char *dataDir, wa_event_cb cb);

// Runs one JSON command and returns a JSON reply to release with WAFree.
char *WACall(const char *request);

void WAFree(char *p);

#endif
