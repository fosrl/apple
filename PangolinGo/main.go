package main

/*
#include <stdint.h>
*/
import (
	"C"
	"fmt"
	"sync"
	"time"
)

var (
	tunnelRunning  bool
	tunnelMutex    sync.Mutex
	tunnelFileDesc int32
	stopChan       chan struct{}
	wg             sync.WaitGroup
)

//export startTunnel
func startTunnel(fd C.int) *C.char {
	appLogger.Info("Starting tunnel with FD: %d", int(fd))

	tunnelMutex.Lock()
	defer tunnelMutex.Unlock()

	// Check if tunnel is already running
	if tunnelRunning {
		appLogger.Warn("Tunnel is already running")
		return C.CString("Error: Tunnel already running")
	}

	tunnelFileDesc = int32(fd)
	appLogger.Info("Starting tunnel from go side with FD: %d", tunnelFileDesc)

	// Create stop channel
	stopChan = make(chan struct{})
	tunnelRunning = true

	// Schedule network settings update after 5 seconds
	wg.Go(func() {
		appLogger.Info("Scheduling network settings update in 5 seconds")

		select {
		case <-time.After(5 * time.Second):
			// Check if tunnel is still running before updating settings
			tunnelMutex.Lock()
			running := tunnelRunning
			tunnelMutex.Unlock()

			if running {
				SetDNSServers([]string{"1.1.1.1"})
				SetMTU(1280)
			} else {
				appLogger.Warn("Tunnel stopped before settings update, skipping")
			}
		case <-stopChan:
			appLogger.Info("Tunnel stopped before settings update, cancelling")
		}
	})

	appLogger.Info("Start tunnel completed successfully")
	return C.CString(fmt.Sprintf("Tunnel started with FD: %d", tunnelFileDesc))
}

//export stopTunnel
func stopTunnel() *C.char {
	appLogger.Info("Stopping tunnel")

	tunnelMutex.Lock()
	defer tunnelMutex.Unlock()

	// Check if tunnel is not running
	if !tunnelRunning {
		appLogger.Warn("Tunnel is not running")
		return C.CString("Error: Tunnel not running")
	}

	// Stop the background process
	if stopChan != nil {
		close(stopChan)
		stopChan = nil
	}

	tunnelRunning = false
	tunnelMutex.Unlock()

	// Wait for goroutine to finish (with timeout)
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		appLogger.Info("Background process stopped successfully")
	case <-time.After(5 * time.Second):
		appLogger.Warn("Timeout waiting for background process to stop")
	}

	tunnelMutex.Lock()
	appLogger.Info("Tunnel stopped successfully")
	return C.CString("Tunnel stopped")
}

// We need an entry point; it's ok for this to be empty
func main() {}
