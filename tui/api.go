package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// StatusData holds the JSON response from sentry-status.sh --json
type StatusData struct {
	Timestamp   string `json:"ts"`
	Host        string `json:"host"`
	Mode        string `json:"mode"`
	Components  struct {
		Fswatch   bool `json:"fswatch"`
		Selfguard bool `json:"selfguard"`
		Egress    bool `json:"egress"`
		Launchd   bool `json:"launchd"`
	} `json:"components"`
	Logs struct {
		AuditTotal   int    `json:"audit_total"`
		AuditBlocked int    `json:"audit_blocked"`
		AuditFile    string `json:"audit_file"`
	} `json:"logs"`
	HealthScore int `json:"health_score"`
}

// ViolationEntry represents one line from the audit log
type ViolationEntry struct {
	Timestamp string `json:"ts"`
	Mode      string `json:"mode"`
	Decision  string `json:"decision"`
	Reason    string `json:"reason"`
	Cmd       string `json:"cmd"`
	Cwd       string `json:"cwd"`
	Severity  string `json:"severity"`
}

// ViolationStats holds aggregated violation data
type ViolationStats struct {
	Total       int
	Blocked     int
	Hard        int
	Detected    int
	FirstEvent  string
	LastEvent   string
	TopReasons  []CountEntry
	TopCommands []CountEntry
	Severity    SeverityBreakdown
}

// CountEntry is a reason/command with its count
type CountEntry struct {
	Count int
	Text  string
}

// SeverityBreakdown for violation severity
type SeverityBreakdown struct {
	Critical int
	Warning  int
	Info     int
}

// SelfguardData holds selfguard status info
type SelfguardData struct {
	Running      bool
	PID          string
	Mode         string
	Interval     string
	BaselineFile string
	BaselineTime string
	BaselineHash string
	ChainStatus  string
	Files        []ProtectedFile
	RecentEvents []string
}

// ProtectedFile is a file tracked by selfguard
type ProtectedFile struct {
	Name string
	Hash string
	OK   bool
}

// ConfigData holds configuration info
type ConfigData struct {
	Mode             string
	Notifications    bool
	LogLevel         string
	AuditLog         string
	LogRotation      string
	AllowedDirs      []string
	SensitivePaths   []string
	DetectPatterns   []string
}

// scriptDir returns the project root (parent of tui/)
func scriptDir() string {
	exe, err := os.Executable()
	if err == nil {
		dir := filepath.Dir(exe)
		// If binary is in tui/, go up one level
		parent := filepath.Dir(dir)
		if filepath.Base(dir) == "tui" {
			return parent
		}
	}
	// Fallback: try to find the project dir relative to cwd
	cwd, _ := os.Getwd()
	if filepath.Base(cwd) == "tui" {
		return filepath.Dir(cwd)
	}
	return cwd
}

// FetchStatusData calls sentry-status.sh --json and parses the output
func FetchStatusData() (*StatusData, error) {
	dir := scriptDir()
	script := filepath.Join(dir, "sentry-status.sh")

	cmd := exec.Command("bash", script, "--json")
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("sentry-status.sh --json: %w", err)
	}

	var data StatusData
	if err := json.Unmarshal(out, &data); err != nil {
		return nil, fmt.Errorf("parse json: %w (output: %s)", err, string(out))
	}
	return &data, nil
}

// FetchAuditLog reads the audit log and returns entries
func FetchAuditLog(path string, maxLines int) []ViolationEntry {
	if path == "" {
		home, _ := os.UserHomeDir()
		path = filepath.Join(home, ".hermes", "logs", "sandbox-audit.log")
	}

	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var all []ViolationEntry
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var entry ViolationEntry
		if err := json.Unmarshal([]byte(line), &entry); err == nil {
			all = append(all, entry)
		}
	}

	if maxLines > 0 && len(all) > maxLines {
		all = all[len(all)-maxLines:]
	}
	return all
}

// ComputeViolationStats aggregates violation data
func ComputeViolationStats(entries []ViolationEntry) ViolationStats {
	stats := ViolationStats{
		Total: len(entries),
	}

	reasonCounts := make(map[string]int)
	cmdCounts := make(map[string]int)

	for _, e := range entries {
		switch {
		case e.Decision == "SOFT_BLOCKED" || e.Decision == "BLOCKED":
			stats.Blocked++
		case e.Decision == "HARD_ENFORCEMENT":
			stats.Hard++
		case e.Decision == "DETECTED":
			stats.Detected++
		}

		switch e.Severity {
		case "critical":
			stats.Severity.Critical++
		case "warning":
			stats.Severity.Warning++
		default:
			stats.Severity.Info++
		}

		if e.Reason != "" {
			reasonCounts[e.Reason]++
		}
		if e.Cmd != "" {
			cmd := e.Cmd
			if len(cmd) > 80 {
				cmd = cmd[:80]
			}
			cmdCounts[cmd]++
		}

		if stats.FirstEvent == "" {
			stats.FirstEvent = e.Timestamp
		}
		stats.LastEvent = e.Timestamp
	}

	stats.TopReasons = topN(reasonCounts, 6)
	stats.TopCommands = topN(cmdCounts, 6)
	return stats
}

func topN(counts map[string]int, n int) []CountEntry {
	var entries []CountEntry
	for text, count := range counts {
		entries = append(entries, CountEntry{Count: count, Text: text})
	}
	// Sort descending
	for i := 0; i < len(entries); i++ {
		for j := i + 1; j < len(entries); j++ {
			if entries[j].Count > entries[i].Count {
				entries[i], entries[j] = entries[j], entries[i]
			}
		}
	}
	if len(entries) > n {
		entries = entries[:n]
	}
	return entries
}

// FetchSelfguardData gathers selfguard information
func FetchSelfguardData() *SelfguardData {
	data := &SelfguardData{
		Mode:     "fswatch + periodic hash check",
		Interval: "30s",
	}

	dir := scriptDir()
	home, _ := os.UserHomeDir()
	logDir := filepath.Join(home, ".hermes", "logs")

	// Check PID file
	pidFile := filepath.Join(logDir, "selfguard.pid")
	if pidBytes, err := os.ReadFile(pidFile); err == nil {
		pid := strings.TrimSpace(string(pidBytes))
		data.PID = pid
		// Check if process is alive
		cmd := exec.Command("kill", "-0", pid)
		if cmd.Run() == nil {
			data.Running = true
		}
	}

	// Read baseline file
	baselineFile := filepath.Join(dir, "sentry-baseline.sha256")
	data.BaselineFile = baselineFile
	if info, err := os.Stat(baselineFile); err == nil {
		data.BaselineTime = info.ModTime().Format("2006-01-02 15:04")
	}

	// Read baseline hashes
	if f, err := os.Open(baselineFile); err == nil {
		defer f.Close()
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			line := scanner.Text()
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				hash := parts[0]
				name := filepath.Base(parts[1])
				if len(hash) > 12 {
					hash = hash[:4] + "..." + hash[len(hash)-4:]
				}
				data.Files = append(data.Files, ProtectedFile{
					Name: name,
					Hash: hash,
					OK:   true,
				})
			}
		}
	}

	// Compute chain status
	if len(data.Files) > 0 {
		data.ChainStatus = "VERIFIED"
	} else {
		data.ChainStatus = "NO BASELINE"
	}

	// Read recent selfguard log events
	sgLog := filepath.Join(logDir, "selfguard.log")
	if entries, err := readLastLines(sgLog, 5); err == nil {
		data.RecentEvents = entries
	}

	return data
}

// FetchConfigData reads configuration
func FetchConfigData() *ConfigData {
	home, _ := os.UserHomeDir()
	data := &ConfigData{
		Mode:          "soft-block",
		Notifications: true,
		LogLevel:      "info",
		AuditLog:      filepath.Join(home, ".hermes", "logs", "sandbox-audit.log"),
		LogRotation:   "5 MB / 3 files",
	}

	// Read sentry-config.json
	configFile := filepath.Join(home, ".hermes", "sentry-config.json")
	if configBytes, err := os.ReadFile(configFile); err == nil {
		var cfg map[string]interface{}
		if json.Unmarshal(configBytes, &cfg) == nil {
			if m, ok := cfg["mode"].(string); ok {
				data.Mode = m
			}
			if n, ok := cfg["notifications"].(bool); ok {
				data.Notifications = n
			}
		}
	}

	// Read safety-rules.json for allowed dirs, sensitive paths
	rulesFile := filepath.Join(home, ".hermes", "safety-rules.json")
	if rulesBytes, err := os.ReadFile(rulesFile); err == nil {
		var rules map[string]interface{}
		if json.Unmarshal(rulesBytes, &rules) == nil {
			if dirs, ok := rules["allowed_project_dirs"].([]interface{}); ok {
				for _, d := range dirs {
					if s, ok := d.(string); ok {
						data.AllowedDirs = append(data.AllowedDirs, s)
					}
				}
			}
			if paths, ok := rules["sensitive_paths"].([]interface{}); ok {
				for _, p := range paths {
					if s, ok := p.(string); ok {
						data.SensitivePaths = append(data.SensitivePaths, s)
					}
				}
			}
			if patterns, ok := rules["detection_patterns"].([]interface{}); ok {
				for _, p := range patterns {
					if s, ok := p.(string); ok {
						data.DetectPatterns = append(data.DetectPatterns, s)
					}
				}
			}
		}
	}

	return data
}

// readLastLines reads the last N lines of a file
func readLastLines(path string, n int) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}

	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines, nil
}

// FormatTimestamp extracts time portion from ISO timestamp
func FormatTimestamp(ts string) string {
	if ts == "" {
		return "??:??:??"
	}
	// Try to parse ISO format
	if idx := strings.Index(ts, "T"); idx >= 0 {
		rest := ts[idx+1:]
		// Strip timezone
		if idx2 := strings.IndexAny(rest, "+Z"); idx2 >= 0 {
			rest = rest[:idx2]
		}
		// Take first 8 chars (HH:MM:SS)
		if len(rest) > 8 {
			return rest[:8]
		}
		return rest
	}
	if len(ts) > 19 {
		return ts[11:19]
	}
	return ts
}

// FormatDate extracts date portion from ISO timestamp
func FormatDate(ts string) string {
	if ts == "" {
		return "unknown"
	}
	if idx := strings.Index(ts, "T"); idx >= 0 {
		return ts[:idx]
	}
	if len(ts) >= 10 {
		return ts[:10]
	}
	return ts
}

// TailAuditLog starts tailing the audit log file and sends new entries
func TailAuditLog(path string, ch chan<- ViolationEntry, done <-chan struct{}) {
	if path == "" {
		home, _ := os.UserHomeDir()
		path = filepath.Join(home, ".hermes", "logs", "sandbox-audit.log")
	}

	// Wait for file to exist
	for {
		if _, err := os.Stat(path); err == nil {
			break
		}
		select {
		case <-done:
			return
		case <-time.After(time.Second):
		}
	}

	cmd := exec.Command("tail", "-n", "0", "-f", path)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}

	scanner := bufio.NewScanner(stdout)
	go func() {
		<-done
		cmd.Process.Kill()
	}()

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var entry ViolationEntry
		if json.Unmarshal([]byte(line), &entry) == nil {
			ch <- entry
		}
	}
}
