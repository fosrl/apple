package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import (
	"C"
	"context"
	"encoding/json"
	"fmt"
	"sync"

	olmpkg "github.com/fosrl/olm/olm"
)
import "time"

// InitOlmConfig represents the JSON configuration for initOlm
type InitOlmConfig struct {
	EnableAPI  bool   `json:"enableAPI"`
	SocketPath string `json:"socketPath"`
	LogLevel   string `json:"logLevel"`
	Version    string `json:"version"`
	Agent      string `json:"agent"`
}

// StartTunnelConfig represents the JSON configuration for startTunnel
type StartTunnelConfig struct {
	Endpoint            string         `json:"endpoint"`
	ID                  string         `json:"id"`
	Secret              string         `json:"secret"`
	MTU                 int            `json:"mtu"`
	DNS                 string         `json:"dns"`
	Holepunch           bool           `json:"holepunch"`
	PingIntervalSeconds int            `json:"pingIntervalSeconds"`
	PingTimeoutSeconds  int            `json:"pingTimeoutSeconds"`
	UserToken           string         `json:"userToken"`
	OrgID               string         `json:"orgId"`
	UpstreamDNS         []string       `json:"upstreamDNS"`
	OverrideDNS         bool           `json:"overrideDNS"`
	TunnelDNS           bool           `json:"tunnelDNS"`
	Fingerprint         map[string]any `json:"fingerprint"`
	Postures            map[string]any `json:"postures"`
}

var (
	tunnelRunning bool
	tunnelMutex   sync.Mutex
	olm           *olmpkg.Olm
	olmContext    context.Context
)

//export initOlm
func initOlm(configJSON *C.char) *C.char {
	appLogger.Debug("Initializing with config")

	// Parse JSON configuration
	configStr := C.GoString(configJSON)
	var config InitOlmConfig
	if err := json.Unmarshal([]byte(configStr), &config); err != nil {
		appLogger.Error("Failed to parse init config JSON: %v", err)
		return C.CString(fmt.Sprintf("Error: Failed to parse config JSON: %v", err))
	}

	// Initialize OLM logger with current log level
	InitOLMLogger()

	// Create context for OLM
	olmContext = context.Background()

	// Create OLM GlobalConfig with values from Swift
	olmConfig := olmpkg.OlmConfig{
		LogLevel:   GetLogLevelString(),
		EnableAPI:  config.EnableAPI,
		SocketPath: config.SocketPath,
		Version:    config.Version,
		Agent:      config.Agent,
	}

	// Initialize OLM with context and GlobalConfig
	o, err := olmpkg.Init(olmContext, olmConfig)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: Failed to initialize olm: %v", err))
	}
	olm = o

	appLogger.Debug("Init completed successfully")
	return C.CString("Init completed successfully")
}

//export startTunnel
func startTunnel(fd C.int, configJSON *C.char) *C.char {
	if olm == nil {
		return C.CString("Error: olm has not been initialized yet!")
	}

	appLogger.Debug("Starting tunnel")

	tunnelMutex.Lock()
	defer tunnelMutex.Unlock()

	// Check if tunnel is already running
	if tunnelRunning {
		appLogger.Warn("Tunnel is already running")
		return C.CString("Error: Tunnel already running")
	}

	tunnelRunning = true

	// Parse JSON configuration
	configStr := C.GoString(configJSON)
	var config StartTunnelConfig
	if err := json.Unmarshal([]byte(configStr), &config); err != nil {
		appLogger.Error("Failed to parse tunnel config JSON: %v", err)
		tunnelRunning = false
		return C.CString(fmt.Sprintf("Error: Failed to parse config JSON: %v", err))
	}

	// Create OLM Config with tunnel parameters
	tunnelConfig := olmpkg.TunnelConfig{
		Endpoint:             config.Endpoint,
		ID:                   config.ID,
		Secret:               config.Secret,
		MTU:                  config.MTU,
		DNS:                  config.DNS,
		Holepunch:            config.Holepunch,
		PingIntervalDuration: time.Duration(config.PingIntervalSeconds) * time.Second,
		PingTimeoutDuration:  time.Duration(config.PingTimeoutSeconds) * time.Second,
		FileDescriptorTun:    uint32(fd),
		UserToken:            config.UserToken,
		OverrideDNS:          config.OverrideDNS,
		TunnelDNS:            config.TunnelDNS,
		UpstreamDNS:          config.UpstreamDNS,
		OrgID:                config.OrgID,
		InitialFingerprint:   config.Fingerprint,
		InitialPostures:      config.Postures,
	}

	// print the config for debugging
	appLogger.Debug("Tunnel config: %+v", tunnelConfig)

	_ = olm.StartApi()

	// Start OLM tunnel with config
	appLogger.Info("Starting OLM tunnel...")
	go func() {
		olm.StartTunnel(tunnelConfig)
		appLogger.Info("OLM tunnel stopped")

		// Update tunnel state when OLM stops
		tunnelMutex.Lock()
		tunnelRunning = false
		tunnelMutex.Unlock()
	}()

	appLogger.Debug("Start tunnel completed successfully")
	return C.CString("Tunnel started")
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

	// Stop OLM tunnel
	_ = olm.StopTunnel()
	_ = olm.StopApi()

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

//export setPowerMode
func setPowerMode(mode *C.char) *C.char {
	appLogger.Debug("Setting power mode")

	tunnelMutex.Lock()
	running := tunnelRunning
	tunnelMutex.Unlock()

	if !running {
		appLogger.Warn("Tunnel is not running")
		return C.CString("Error: Tunnel not running")
	}

	modeStr := C.GoString(mode)
	// olm.SetPowerMode(modeStr)
	appLogger.Info("Power mode set to: %s", modeStr)
	return C.CString(fmt.Sprintf("Power mode set to: %s", modeStr))
}

//export rebindSocket
func rebindSocket() *C.char {
	appLogger.Debug("Rebinding socket")

	tunnelMutex.Lock()
	running := tunnelRunning
	tunnelMutex.Unlock()

	if !running {
		appLogger.Warn("Tunnel is not running")
		return C.CString("Error: Tunnel not running")
	}

	err := olm.RebindSocket()
	if err != nil {
		appLogger.Error("Failed to rebind socket: %v", err)
		return C.CString(fmt.Sprintf("Error: %v", err))
	}

	appLogger.Info("Socket rebound successfully")
	return C.CString("Socket rebound successfully")
}

// We need an entry point; it's ok for this to be empty
func main() {}
