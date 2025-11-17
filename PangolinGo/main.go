package main

/*
#include <stdint.h>
*/
import (
	"C"
	"fmt"
	"sync"
)

var (
	tunnelRunning  bool
	tunnelMutex    sync.Mutex
	tunnelFileDesc int32
)

//export startTunnel
func startTunnel(fd C.int) *C.char {
	appLogger.Debug("Starting tunnel with FD: %d", int(fd))

	tunnelMutex.Lock()
	defer tunnelMutex.Unlock()

	// Check if tunnel is already running
	if tunnelRunning {
		appLogger.Warn("Tunnel is already running")
		return C.CString("Error: Tunnel already running")
	}

	tunnelFileDesc = int32(fd)
	tunnelRunning = true

	appLogger.Debug("Start tunnel completed successfully")
	return C.CString(fmt.Sprintf("Tunnel started with FD: %d", tunnelFileDesc))
}

//export stopTunnel
func stopTunnel() *C.char {
	appLogger.Debug("Stopping tunnel")

	tunnelMutex.Lock()
	defer tunnelMutex.Unlock()

	// Check if tunnel is not running
	if !tunnelRunning {
		appLogger.Warn("Tunnel is not running")
		return C.CString("Error: Tunnel not running")
	}

	tunnelRunning = false
	appLogger.Debug("Tunnel stopped successfully")
	return C.CString("Tunnel stopped")
}

// We need an entry point; it's ok for this to be empty
func main() {}
