package main

/*
#cgo CFLAGS: -I../PacketTunnel/Shared
#include "../PacketTunnel/Shared/GoLoggerBridge.h"
#include <stdlib.h>
*/
import "C"
import (
	"fmt"
	"time"
	"unsafe"

	"github.com/fosrl/newt/logger"
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

// GetLevel returns the current log level
func (l *Logger) GetLevel() LogLevel {
	return l.logLevel
}

// formatMessage formats a log message with timestamp, level, prefix, and caller info
func (l *Logger) formatMessage(level string, format string, args ...interface{}) string {
	if len(args) > 0 {
		return fmt.Sprintf(format, args...)
	}
	return format
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

// OSLogWriter adapts our Logger to the newt/logger LogWriter interface
type OSLogWriter struct {
	logger *Logger
}

// Write implements the logger.LogWriter interface
func (w *OSLogWriter) Write(level logger.LogLevel, timestamp time.Time, message string) {
	// Map newt/logger.LogLevel to our LogLevel
	var ourLevel LogLevel
	switch level {
	case logger.DEBUG:
		ourLevel = LogLevelDebug
	case logger.INFO:
		ourLevel = LogLevelInfo
	case logger.WARN:
		ourLevel = LogLevelWarn
	case logger.ERROR:
		ourLevel = LogLevelError
	default:
		ourLevel = LogLevelInfo
	}

	// Call the appropriate method on our logger
	switch ourLevel {
	case LogLevelDebug:
		w.logger.Debug("%s", message)
	case LogLevelInfo:
		w.logger.Info("%s", message)
	case LogLevelWarn:
		w.logger.Warn("%s", message)
	case LogLevelError:
		w.logger.Error("%s", message)
	}
}

// NewOSLogWriter creates a new OSLogWriter that wraps our Logger
func NewOSLogWriter(logger *Logger) *OSLogWriter {
	return &OSLogWriter{logger: logger}
}

// global logger instance
var appLogger *Logger

func init() {
	appLogger = NewLogger("PangolinGo")
	// Log level will be set from Swift via setLogLevel
	appLogger.Info("Logger initialized")
}

// setLogLevel sets the log level for the Go logger
// level: 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR
//
//export setLogLevel
func setLogLevel(level C.int) {
	appLogger.SetLevel(LogLevel(level))
}

// getCurrentLogLevel returns the current log level from appLogger
func getCurrentLogLevel() LogLevel {
	return appLogger.GetLevel()
}

// logLevelToNewtLoggerLevel converts LogLevel to logger.LogLevel from newt/logger package
func logLevelToNewtLoggerLevel(level LogLevel) logger.LogLevel {
	switch level {
	case LogLevelDebug:
		return logger.DEBUG
	case LogLevelInfo:
		return logger.INFO
	case LogLevelWarn:
		return logger.WARN
	case LogLevelError:
		return logger.ERROR
	default:
		return logger.INFO
	}
}

// logLevelToString converts LogLevel to a string representation
func logLevelToString(level LogLevel) string {
	switch level {
	case LogLevelDebug:
		return "debug"
	case LogLevelInfo:
		return "info"
	case LogLevelWarn:
		return "warn"
	case LogLevelError:
		return "error"
	default:
		return "info"
	}
}

// InitOLMLogger initializes the OLM logger with the current log level from appLogger
func InitOLMLogger() {
	// Create a LogWriter adapter that wraps our appLogger
	osLogWriter := NewOSLogWriter(appLogger)

	// Create a logger instance using the newt/logger package with our custom writer
	olmLogger := logger.NewLoggerWithWriter(osLogWriter)
	olmLogger.SetLevel(logLevelToNewtLoggerLevel(getCurrentLogLevel()))

	logger.Init(olmLogger)
}

// GetLogLevelString returns the current log level as a string for OLM config
func GetLogLevelString() string {
	return logLevelToString(getCurrentLogLevel())
}
