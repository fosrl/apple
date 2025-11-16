package main

import (
	"fmt"
	"log"
	"os"
	"runtime"
	"time"
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
	prefix   string
	logLevel LogLevel
	logger   *log.Logger
}

// NewLogger creates a new logger instance
func NewLogger(prefix string) *Logger {
	return &Logger{
		prefix:   prefix,
		logLevel: LogLevelInfo,
		logger:   log.New(os.Stderr, "", 0), // We'll format everything ourselves
	}
}

// SetLevel sets the minimum log level
func (l *Logger) SetLevel(level LogLevel) {
	l.logLevel = level
}

// formatMessage formats a log message with timestamp, level, prefix, and caller info
func (l *Logger) formatMessage(level string, format string, args ...interface{}) string {
	// Get caller information (skip 2 frames: formatMessage and the log method)
	_, file, line, ok := runtime.Caller(2)
	if !ok {
		file = "unknown"
		line = 0
	} else {
		// Get just the filename, not the full path
		for i := len(file) - 1; i > 0; i-- {
			if file[i] == '/' {
				file = file[i+1:]
				break
			}
		}
	}

	timestamp := time.Now().Format("2006-01-02 15:04:05.000")
	message := format
	if len(args) > 0 {
		message = fmt.Sprintf(format, args...)
	}

	return fmt.Sprintf("[%s] [%s] [%s] %s:%d - %s",
		timestamp, level, l.prefix, file, line, message)
}

// Debug logs a debug message
func (l *Logger) Debug(format string, args ...interface{}) {
	if l.logLevel <= LogLevelDebug {
		l.logger.Println(l.formatMessage("DEBUG", format, args...))
	}
}

// Info logs an info message
func (l *Logger) Info(format string, args ...interface{}) {
	if l.logLevel <= LogLevelInfo {
		l.logger.Println(l.formatMessage("INFO", format, args...))
	}
}

// Warn logs a warning message
func (l *Logger) Warn(format string, args ...interface{}) {
	if l.logLevel <= LogLevelWarn {
		l.logger.Println(l.formatMessage("WARN", format, args...))
	}
}

// Error logs an error message
func (l *Logger) Error(format string, args ...interface{}) {
	if l.logLevel <= LogLevelError {
		l.logger.Println(l.formatMessage("ERROR", format, args...))
	}
}

// global logger instance
var appLogger *Logger

func init() {
	appLogger = NewLogger("PangolinGo")
	appLogger.Info("Logger initialized")
}
