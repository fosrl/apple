package main

import (
	"C"
	"sync"
	"time"
)

var (
	tunnelRunning bool
	tunnelMutex   sync.Mutex
	stopChan      chan struct{}
	wg            sync.WaitGroup
)

//export startTunnel
func startTunnel() *C.char {
	appLogger.Info("startTunnel() called - starting tunnel")

	tunnelMutex.Lock()
	defer tunnelMutex.Unlock()

	// Check if tunnel is already running
	if tunnelRunning {
		appLogger.Warn("Tunnel is already running")
		return C.CString("Error: Tunnel already running")
	}

	// Create stop channel
	stopChan = make(chan struct{})
	tunnelRunning = true

	// Start background process that runs forever
	wg.Go(func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()

		appLogger.Info("Olm process started")

		for {
			select {
			case <-ticker.C:
				appLogger.Info("Olm running...")
			case <-stopChan:
				appLogger.Info("Olm process stopped")
				return
			}
		}
	})

	appLogger.Info("startTunnel() completed successfully")
	return C.CString("Tunnel started")
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

	tunnelRunning = false
	appLogger.Info("stopTunnel() completed successfully")
	return C.CString("Tunnel stopped")
}

// We need an entry point; it's ok for this to be empty
func main() {
	appLogger.Info("main() entry point called")
}
