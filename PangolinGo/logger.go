package main

/*
#cgo CFLAGS: -I../PacketTunnel
#include "../PacketTunnel/GoLoggerBridge.h"
#include <stdlib.h>
*/
import "C"
import (
	"fmt"
	"unsafe"
)

// LogLevel represents the severity of a log message
type LogLevel int

const (
	LogLevelDebug LogLevel = iota
	LogLevelInfo
	LogLevelWarn
	LogLevelError
)

// Logger provides formatted logging functionality
type Logger struct {
	prefix    string
	logLevel  LogLevel
	subsystem *C.char
	category  *C.char
}

// NewLogger creates a new logger instance
func NewLogger(prefix string) *Logger {
	return &Logger{
		prefix:    prefix,
		logLevel:  LogLevelInfo,
		subsystem: C.CString("net.pangolin.Pangolin.PacketTunnel"),
		category:  C.CString("PangolinGo"),
	}
}

// SetLevel sets the minimum log level
func (l *Logger) SetLevel(level LogLevel) {
	l.logLevel = level
}

// formatMessage formats a log message with timestamp, level, prefix, and caller info
func (l *Logger) formatMessage(level string, format string, args ...interface{}) string {
	message := format
	if len(args) > 0 {
		message = fmt.Sprintf(format, args...)
	}

	return fmt.Sprintf("%s", message)
}

// logToOSLog sends a log message to os.log via the C bridge
func (l *Logger) logToOSLog(level LogLevel, levelName string, format string, args ...interface{}) {
	if l.logLevel > level {
		return
	}

	message := l.formatMessage(levelName, format, args...)
	cMessage := C.CString(message)
	defer C.free(unsafe.Pointer(cMessage))

	// Map Go log levels to os.log levels:
	// 0=DEBUG, 1=INFO, 2=DEFAULT, 3=ERROR, 4=FAULT
	var osLogLevel C.int
	switch level {
	case LogLevelDebug:
		osLogLevel = 0 // DEBUG
	case LogLevelInfo:
		osLogLevel = 1 // INFO
	case LogLevelWarn:
		osLogLevel = 2 // DEFAULT
	case LogLevelError:
		osLogLevel = 3 // ERROR
	default:
		osLogLevel = 2 // DEFAULT
	}

	C.goLogToOSLog(l.subsystem, l.category, osLogLevel, cMessage)
}

// Debug logs a debug message
func (l *Logger) Debug(format string, args ...interface{}) {
	l.logToOSLog(LogLevelDebug, "DEBUG", format, args...)
}

// Info logs an info message
func (l *Logger) Info(format string, args ...interface{}) {
	l.logToOSLog(LogLevelInfo, "INFO", format, args...)
}

// Warn logs a warning message
func (l *Logger) Warn(format string, args ...interface{}) {
	l.logToOSLog(LogLevelWarn, "WARN", format, args...)
}

// Error logs an error message
func (l *Logger) Error(format string, args ...interface{}) {
	l.logToOSLog(LogLevelError, "ERROR", format, args...)
}

// global logger instance
var appLogger *Logger

func init() {
	appLogger = NewLogger("PangolinGo")
	appLogger.Info("Logger initialized")
}
