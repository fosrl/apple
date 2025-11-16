//
//  OSLogBridge.h
//  PacketTunnel
//
//  Bridge for Go logging to os_log
//

#ifndef OSLogBridge_h
#define OSLogBridge_h

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize the OS log bridge with subsystem and category
void initOSLogBridge(const char* subsystem, const char* category);

// Log a message to os_log with the specified level
// level: 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR
void logToOSLog(int level, const char* message);

#ifdef __cplusplus
}
#endif

#endif /* OSLogBridge_h */

