//
//  PacketTunnel-Bridging-Header.h
//  PacketTunnel
//
//  Bridging header for C interop with tunnel file descriptor discovery
//

#ifndef PacketTunnel_Bridging_Header_h
#define PacketTunnel_Bridging_Header_h

#include "TunnelFileDescriptor.h"
#include "GoLoggerBridge.h"
#include <sys/socket.h>  // For getpeername, sockaddr, AF_SYSTEM
#include <sys/ioctl.h>   // For ioctl
#include <string.h>      // For strcpy

#endif /* PacketTunnel_Bridging_Header_h */

