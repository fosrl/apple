//
//  GoLoggerBridge.m
//  PacketTunnel
//
//  Bridge implementation for Go to log via os.log
//

#import "GoLoggerBridge.h"
#import <os/log.h>

void goLogToOSLog(const char* subsystem, const char* category, int level, const char* message) {
    if (!subsystem || !category || !message) {
        return;
    }
    
    os_log_t logger = os_log_create(subsystem, category);
    
    // Map level to os_log_type_t
    os_log_type_t logType;
    switch (level) {
        case 0: // DEBUG
            logType = OS_LOG_TYPE_DEBUG;
            break;
        case 1: // INFO
            logType = OS_LOG_TYPE_INFO;
            break;
        case 2: // DEFAULT
            logType = OS_LOG_TYPE_DEFAULT;
            break;
        case 3: // ERROR
            logType = OS_LOG_TYPE_ERROR;
            break;
        case 4: // FAULT
            logType = OS_LOG_TYPE_FAULT;
            break;
        default:
            logType = OS_LOG_TYPE_DEFAULT;
            break;
    }
    
    os_log_with_type(logger, logType, "%{public}s", message);
}

