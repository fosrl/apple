#!/bin/bash

LEVEL=${1:-debug}

echo "Tailing logs for subsystem: net.pangolin.Pangolin.PacketTunnel (level: $LEVEL)"
echo "Press Ctrl+C to stop"
echo ""

log stream --predicate 'subsystem == "net.pangolin.Pangolin" OR subsystem == "net.pangolin.Pangolin.PacketTunnel"' --level $LEVEL --style compact
