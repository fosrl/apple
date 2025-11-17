package main

/*
#include <stdint.h>
*/
import (
	"C"
	"encoding/json"
	"sync"
)

// NetworkSettings represents the network configuration for the tunnel
type NetworkSettings struct {
	TunnelRemoteAddress string      `json:"tunnel_remote_address,omitempty"`
	MTU                 *int        `json:"mtu,omitempty"`
	DNSServers          []string    `json:"dns_servers,omitempty"`
	IPv4Addresses       []string    `json:"ipv4_addresses,omitempty"`
	IPv4SubnetMasks     []string    `json:"ipv4_subnet_masks,omitempty"`
	IPv4IncludedRoutes  []IPv4Route `json:"ipv4_included_routes,omitempty"`
	IPv4ExcludedRoutes  []IPv4Route `json:"ipv4_excluded_routes,omitempty"`
	IPv6Addresses       []string    `json:"ipv6_addresses,omitempty"`
	IPv6NetworkPrefixes []string    `json:"ipv6_network_prefixes,omitempty"`
	IPv6IncludedRoutes  []IPv6Route `json:"ipv6_included_routes,omitempty"`
	IPv6ExcludedRoutes  []IPv6Route `json:"ipv6_excluded_routes,omitempty"`
}

// IPv4Route represents an IPv4 route
type IPv4Route struct {
	DestinationAddress string `json:"destination_address"`
	SubnetMask         string `json:"subnet_mask,omitempty"`
	GatewayAddress     string `json:"gateway_address,omitempty"`
	IsDefault          bool   `json:"is_default,omitempty"`
}

// IPv6Route represents an IPv6 route
type IPv6Route struct {
	DestinationAddress  string `json:"destination_address"`
	NetworkPrefixLength int    `json:"network_prefix_length,omitempty"`
	GatewayAddress      string `json:"gateway_address,omitempty"`
	IsDefault           bool   `json:"is_default,omitempty"`
}

var (
	networkSettings      NetworkSettings
	networkSettingsMutex sync.RWMutex
)

// SetTunnelRemoteAddress sets the tunnel remote address
func SetTunnelRemoteAddress(address string) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.TunnelRemoteAddress = address
	appLogger.Info("Set tunnel remote address: %s", address)
}

// SetMTU sets the MTU value
func SetMTU(mtu int) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.MTU = &mtu
	appLogger.Info("Set MTU: %d", mtu)
}

// SetDNSServers sets the DNS servers
func SetDNSServers(servers []string) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.DNSServers = servers
	appLogger.Info("Set DNS servers: %v", servers)
}

// SetIPv4Settings sets IPv4 addresses and subnet masks
func SetIPv4Settings(addresses []string, subnetMasks []string) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.IPv4Addresses = addresses
	networkSettings.IPv4SubnetMasks = subnetMasks
	appLogger.Info("Set IPv4 addresses: %v, subnet masks: %v", addresses, subnetMasks)
}

// SetIPv4IncludedRoutes sets the included IPv4 routes
func SetIPv4IncludedRoutes(routes []IPv4Route) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.IPv4IncludedRoutes = routes
	appLogger.Info("Set IPv4 included routes: %d routes", len(routes))
}

// SetIPv4ExcludedRoutes sets the excluded IPv4 routes
func SetIPv4ExcludedRoutes(routes []IPv4Route) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.IPv4ExcludedRoutes = routes
	appLogger.Info("Set IPv4 excluded routes: %d routes", len(routes))
}

// SetIPv6Settings sets IPv6 addresses and network prefixes
func SetIPv6Settings(addresses []string, networkPrefixes []string) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.IPv6Addresses = addresses
	networkSettings.IPv6NetworkPrefixes = networkPrefixes
	appLogger.Info("Set IPv6 addresses: %v, network prefixes: %v", addresses, networkPrefixes)
}

// SetIPv6IncludedRoutes sets the included IPv6 routes
func SetIPv6IncludedRoutes(routes []IPv6Route) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.IPv6IncludedRoutes = routes
	appLogger.Info("Set IPv6 included routes: %d routes", len(routes))
}

// SetIPv6ExcludedRoutes sets the excluded IPv6 routes
func SetIPv6ExcludedRoutes(routes []IPv6Route) {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings.IPv6ExcludedRoutes = routes
	appLogger.Info("Set IPv6 excluded routes: %d routes", len(routes))
}

// ClearNetworkSettings clears all network settings
func ClearNetworkSettings() {
	networkSettingsMutex.Lock()
	defer networkSettingsMutex.Unlock()
	networkSettings = NetworkSettings{}
	appLogger.Info("Cleared all network settings")
}

// getNetworkSettings returns the current network settings as a JSON string
//
//export getNetworkSettings
func getNetworkSettings() *C.char {
	networkSettingsMutex.RLock()
	defer networkSettingsMutex.RUnlock()

	jsonData, err := json.Marshal(networkSettings)
	if err != nil {
		appLogger.Error("Failed to marshal network settings: %v", err)
		return C.CString("{}")
	}

	return C.CString(string(jsonData))
}
