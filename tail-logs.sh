#!/bin/bash

LEVEL=${1:-debug}

echo "Tailing logs for subsystem: com.cndf.vpn (level: $LEVEL)"
echo "Press Ctrl+C to stop"
echo ""

log stream --predicate 'subsystem == "com.cndf.vpn" OR subsystem == "com.cndf.vpn.PacketTunnel"' --level $LEVEL --style compact
