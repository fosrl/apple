//
//  PacketTunnel-Bridging-Header.h
//  PacketTunnel
//
//  Bridging header for C interop with tunnel file descriptor discovery
//

#ifndef PacketTunnel_Bridging_Header_h
#define PacketTunnel_Bridging_Header_h

#include "GoLoggerBridge.h"

#if TARGET_OS_OSX || TARGET_OS_MAC
// macOS-specific includes for file descriptor discovery
#include "TunnelFileDescriptor.h"
#include <sys/socket.h>  // For getpeername, sockaddr, AF_SYSTEM
#include <sys/ioctl.h>   // For ioctl
#include <string.h>      // For strcpy
#endif

#endif /* PacketTunnel_Bridging_Header_h */

