#ifndef WACORE_H
#define WACORE_H

// C surface of the core (zen/core/src/ffi.rs; the Go core in core/ has the first three).

typedef void (*wa_event_cb)(const char *json);

// Boots the client. Events arrive on arbitrary threads as JSON; the string is
// only valid during the callback.
void WAStart(const char *dataDir, wa_event_cb cb);

// Runs one JSON command and returns a JSON reply to release with WAFree.
char *WACall(const char *request);

void WAFree(char *p);
// Video of a call, as complete H.264 access units (Annex B). The sink gets
// the other side's frames on arbitrary threads; the data is only valid
// during the callback. WAVideoSend takes one encoded camera frame.
#include <stddef.h>
#include <stdint.h>
typedef void (*wa_video_cb)(const uint8_t *data, size_t len, int keyframe);
void WAVideoSetSink(wa_video_cb cb);
void WAVideoSend(const uint8_t *data, size_t len);

#endif
