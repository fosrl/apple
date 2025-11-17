package main

/*
#include <stdint.h>
*/
import (
	"C"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
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
	httpServer     *http.Server
	socketPath     = "/tmp/pangolin-tunnel.sock"
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

	// Remove existing socket if it exists
	if _, err := os.Stat(socketPath); err == nil {
		appLogger.Info("Removing existing socket at %s", socketPath)
		if err := os.Remove(socketPath); err != nil {
			appLogger.Warn("Failed to remove existing socket: %v", err)
		}
	}

	// Create Unix socket listener
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		appLogger.Error("Failed to create Unix socket: %v", err)
		return C.CString(fmt.Sprintf("Error: Failed to create socket: %v", err))
	}

	// Set up HTTP server
	mux := http.NewServeMux()
	mux.HandleFunc("/test", handleTestEndpoint)

	httpServer = &http.Server{
		Handler: mux,
	}

	// Start HTTP server in background
	wg.Add(1)
	go func() {
		defer wg.Done()
		appLogger.Info("Unix socket server started on %s", socketPath)

		// Set socket permissions to allow connections
		if err := os.Chmod(socketPath, 0666); err != nil {
			appLogger.Warn("Failed to set socket permissions: %v", err)
		}

		// Run server in a goroutine so we can handle shutdown
		serverDone := make(chan error, 1)
		go func() {
			serverDone <- httpServer.Serve(listener)
		}()

		select {
		case err := <-serverDone:
			if err != nil && err != http.ErrServerClosed {
				appLogger.Error("HTTP server error: %v", err)
			}
		case <-stopChan:
			appLogger.Info("Shutting down Unix socket server")
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := httpServer.Shutdown(ctx); err != nil {
				appLogger.Error("Error shutting down server: %v", err)
			}
			listener.Close()
			os.Remove(socketPath)
			appLogger.Info("Unix socket server stopped")
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

// handleTestEndpoint handles requests to the /test endpoint
func handleTestEndpoint(w http.ResponseWriter, r *http.Request) {
	appLogger.Info("Test endpoint called from %s", r.RemoteAddr)

	// Safely read shared variables
	tunnelMutex.Lock()
	fd := tunnelFileDesc
	running := tunnelRunning
	tunnelMutex.Unlock()

	response := map[string]interface{}{
		"status":         "ok",
		"message":        "Pangolin tunnel is running",
		"tunnel_fd":      fd,
		"timestamp":      time.Now().Unix(),
		"tunnel_running": running,
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		appLogger.Error("Failed to encode response: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}
}

// We need an entry point; it's ok for this to be empty
func main() {}
