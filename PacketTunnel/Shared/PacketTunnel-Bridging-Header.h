//
//  PacketTunnel-Bridging-Header.h
//  PacketTunnel
//
//  Bridging header for C interop with tunnel file descriptor discovery
//

#ifndef PacketTunnel_Bridging_Header_h
#define PacketTunnel_Bridging_Header_h

#include "GoLoggerBridge.h"

// Includes for file descriptor discovery (works on both macOS and iOS)
#include "TunnelFileDescriptor.h"
#include <sys/socket.h>  // For getpeername, sockaddr, AF_SYSTEM
#include <sys/ioctl.h>   // For ioctl
#include <string.h>      // For strcpy

#endif /* PacketTunnel_Bridging_Header_h */

