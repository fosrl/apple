#!/bin/bash

# Tail logs for Pangolin PacketTunnel system extension
# Usage: ./tail-logs.sh [level]
# Level can be: debug, info, default, error, fault (default: debug)

# Show help if requested
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    echo "Usage: $0 [level]"
    echo ""
    echo "Tail logs for Pangolin PacketTunnel system extension"
    echo ""
    echo "Levels:"
    echo "  debug   - Show all logs (default)"
    echo "  info    - Show info, default, error, and fault logs"
    echo "  default - Show default, error, and fault logs"
    echo "  error   - Show error and fault logs only"
    echo "  fault   - Show fault logs only"
    echo ""
    echo "Examples:"
    echo "  $0           # Use debug level (default)"
    echo "  $0 info      # Use info level"
    echo "  $0 error     # Use error level"
    exit 0
fi

LEVEL=${1:-debug}

# Validate level
VALID_LEVELS=("debug" "info" "default" "error" "fault")
if [[ ! " ${VALID_LEVELS[@]} " =~ " ${LEVEL} " ]]; then
    echo "Error: Invalid level '$LEVEL'"
    echo "Valid levels: ${VALID_LEVELS[*]}"
    echo "Run '$0 --help' for usage information"
    exit 1
fi

echo "Tailing logs for subsystem: net.pangolin.Pangolin.PacketTunnel (level: $LEVEL)"
echo "Press Ctrl+C to stop"
echo ""

log stream --predicate 'subsystem == "net.pangolin.Pangolin.PacketTunnel"' --level="$LEVEL" --style compact

