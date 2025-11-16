package main

/*
#include <stdint.h>
*/
import (
	"C"
	"sync"
	"time"
)
import "fmt"

var (
	tunnelRunning  bool
	tunnelMutex    sync.Mutex
	tunnelFileDesc int32
	stopChan       chan struct{}
	wg             sync.WaitGroup
)

//export startTunnel
func startTunnel(fd C.int) *C.char {
	appLogger.Info("startTunnel() called - starting tunnel with FD: %d", int(fd))

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

	// Start background process that runs forever
	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()

		appLogger.Info("Background process started")

		for {
			select {
			case <-ticker.C:
				appLogger.Info("Background process running...")
			case <-stopChan:
				appLogger.Info("Background process stopped")
				return
			}
		}
	}()

	appLogger.Info("startTunnel() completed successfully")
	return C.CString(fmt.Sprintf("Tunnel started with FD: %d", tunnelFileDesc))
}

//export stopTunnel
func stopTunnel() *C.char {
	appLogger.Info("stopTunnel() called - stopping tunnel")

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
	appLogger.Info("stopTunnel() completed successfully")
	return C.CString("Tunnel stopped")
}

// We need an entry point; it's ok for this to be empty
func main() {}
