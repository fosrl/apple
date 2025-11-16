//
//  GoLoggerBridge.h
//  PacketTunnel
//
//  Bridge for Go to log via os.log
//

#ifndef GoLoggerBridge_h
#define GoLoggerBridge_h

#include <os/log.h>

// Function that Go can call to log via os.log
// subsystem: the subsystem identifier (e.g., "net.pangolin.Pangolin.PacketTunnel")
// category: the category (e.g., "PangolinGo")
// level: log level (0=debug, 1=info, 2=default, 3=error, 4=fault)
// message: the log message
void goLogToOSLog(const char* subsystem, const char* category, int level, const char* message);

#endif /* GoLoggerBridge_h */

