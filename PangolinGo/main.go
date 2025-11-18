package main

/*
#include <stdint.h>
*/
import (
	"C"
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/fosrl/newt/logger"
	olmpkg "github.com/fosrl/olm/olm"
)

var (
	tunnelRunning  bool
	tunnelMutex    sync.Mutex
	tunnelFileDesc int32
	olmContext     context.Context
	olmCancel      context.CancelFunc
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

	// Create a LogWriter adapter that wraps our appLogger
	osLogWriter := NewOSLogWriter(appLogger)

	// Create a logger instance using the newt/logger package with our custom writer
	olmLogger := logger.NewLoggerWithWriter(osLogWriter)
	olmLogger.SetLevel(logger.DEBUG)

	logger.Init(olmLogger)

	// Create OLM config with hard-coded values
	olmConfig := olmpkg.Config{
		Endpoint:             "https://p.fosrl.io",
		ID:                   "aud0iemczu1cyin",
		Secret:               "8i84dcx5nuvt8jchphaawzzqxq4qnus5sw99sm8rh4jc0fsu",
		MTU:                  1280,
		DNS:                  "8.8.8.8",
		LogLevel:             "debug",
		EnableAPI:            true,
		SocketPath:           "/var/run/olm.sock",
		Holepunch:            false,
		FileDescriptorTun:    uint32(tunnelFileDesc),
		PingIntervalDuration: 5 * time.Second,
		PingTimeoutDuration:  5 * time.Second,
		Version:              "1",
	}

	// Create context for OLM
	olmContext, olmCancel = context.WithCancel(context.Background())

	// Start OLM in a goroutine
	go func() {
		appLogger.Info("Starting OLM tunnel...")
		olmpkg.Run(olmContext, olmConfig)
		appLogger.Info("OLM tunnel stopped")

		// Update tunnel state when OLM stops
		tunnelMutex.Lock()
		tunnelRunning = false
		tunnelMutex.Unlock()
	}()

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

	// Cancel OLM context to stop the tunnel
	if olmCancel != nil {
		olmCancel()
		olmCancel = nil
	}

	tunnelRunning = false
	appLogger.Debug("Tunnel stopped successfully")
	return C.CString("Tunnel stopped")
}

// getNetworkSettingsVersion returns the current network settings version number
//
//export getNetworkSettingsVersion
func getNetworkSettingsVersion() C.long {
	tunnelMutex.Lock()
	running := tunnelRunning
	tunnelMutex.Unlock()

	if !running {
		return C.long(0)
	}

	incrementor := olmpkg.GetNetworkSettingsIncrementor()
	return C.long(incrementor)
}

// getNetworkSettings returns the current network settings as a JSON string
//
//export getNetworkSettings
func getNetworkSettings() *C.char {
	tunnelMutex.Lock()
	running := tunnelRunning
	tunnelMutex.Unlock()

	if !running {
		return C.CString("{}")
	}

	settingsJSON, err := olmpkg.GetNetworkSettingsJSON()
	if err != nil {
		appLogger.Error("Failed to get network settings JSON: %v", err)
		return C.CString("{}")
	}

	return C.CString(settingsJSON)
}

// setLogLevel sets the log level for the Go logger
// level: 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR
//
//export setLogLevel
func setLogLevel(level C.int) {
	appLogger.SetLevel(LogLevel(level))
}

// We need an entry point; it's ok for this to be empty
func main() {}
