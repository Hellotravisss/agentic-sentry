package main

import (
	"time"

	"github.com/agentic-sentry/tui/tabs"
	tea "github.com/charmbracelet/bubbletea"
)

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyMsg:
		// Global keys
		switch msg.String() {
		case "q", "ctrl+c":
			close(m.tailDone)
			return m, tea.Quit
		case "?":
			m.showHelp = !m.showHelp
			return m, nil
		case "r":
			// Refresh
			return m, tea.Batch(
				m.fetchStatus(),
				m.fetchViolations(),
				m.fetchSelfguard(),
				m.fetchConfig(),
			)
		case "left", "h":
			if m.activeTab > 0 {
				m.activeTab--
			}
			return m, nil
		case "right", "l":
			if m.activeTab < TabCount-1 {
				m.activeTab++
			}
			return m, nil
		case "1":
			m.activeTab = TabStatus
			return m, nil
		case "2":
			m.activeTab = TabViolations
			return m, nil
		case "3":
			m.activeTab = TabSelfguard
			return m, nil
		case "4":
			m.activeTab = TabLogs
			return m, nil
		case "5":
			m.activeTab = TabConfig
			return m, nil
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case StatusUpdateMsg:
		m.statusData = msg.Data
		if msg.Data != nil {
			m.status = m.status.SetData(&tabs.StatusData{
				Timestamp:    msg.Data.Timestamp,
				Host:         msg.Data.Host,
				Mode:         msg.Data.Mode,
				Fswatch:      msg.Data.Components.Fswatch,
				Selfguard:    msg.Data.Components.Selfguard,
				Egress:       msg.Data.Components.Egress,
				Launchd:      msg.Data.Components.Launchd,
				AuditTotal:   msg.Data.Logs.AuditTotal,
				AuditBlocked: msg.Data.Logs.AuditBlocked,
				HealthScore:  msg.Data.HealthScore,
			})
			// Set audit log path for future fetches
			if msg.Data.Logs.AuditFile != "" {
				m.auditLogPath = msg.Data.Logs.AuditFile
			}
		}
		// Schedule next refresh
		cmds = append(cmds, m.scheduleRefresh())
		return m, tea.Batch(cmds...)

	case ViolationUpdateMsg:
		m.violationData = msg.Entries
		stats := ComputeViolationStats(msg.Entries)
		m.violations = m.violations.SetStats(tabs.ViolationStats{
			Total:      stats.Total,
			Blocked:    stats.Blocked,
			Hard:       stats.Hard,
			Detected:   stats.Detected,
			FirstEvent: stats.FirstEvent,
			LastEvent:  stats.LastEvent,
			TopReasons: convertCountEntries(stats.TopReasons),
			TopCommands: convertCountEntries(stats.TopCommands),
			Severity: tabs.SeverityBreakdown{
				Critical: stats.Severity.Critical,
				Warning:  stats.Severity.Warning,
				Info:     stats.Severity.Info,
			},
		})

		// Update recent activity on status tab
		var activities []tabs.RecentActivity
		for i := len(msg.Entries) - 1; i >= 0 && i >= len(msg.Entries)-8; i-- {
			e := msg.Entries[i]
			activities = append(activities, tabs.RecentActivity{
				Time:     FormatTimestamp(e.Timestamp),
				Decision: e.Decision,
				Reason:   e.Reason,
			})
		}
		m.status = m.status.SetRecentActivity(activities)

	case SelfguardUpdateMsg:
		m.selfguardData = msg.Data
		if msg.Data != nil {
			var files []tabs.ProtectedFileInfo
			for _, f := range msg.Data.Files {
				files = append(files, tabs.ProtectedFileInfo{
					Name: f.Name,
					Hash: f.Hash,
					OK:   f.OK,
				})
			}
			m.selfguard = m.selfguard.SetData(tabs.SelfguardInfo{
				Running:      msg.Data.Running,
				PID:          msg.Data.PID,
				Mode:         msg.Data.Mode,
				Interval:     msg.Data.Interval,
				BaselineFile: msg.Data.BaselineFile,
				BaselineTime: msg.Data.BaselineTime,
				BaselineHash: msg.Data.BaselineHash,
				ChainStatus:  msg.Data.ChainStatus,
				Files:        files,
				RecentEvents: msg.Data.RecentEvents,
			})
		}

	case ConfigUpdateMsg:
		m.configData = msg.Data
		if msg.Data != nil {
			m.config = m.config.SetData(tabs.ConfigInfo{
				Mode:           msg.Data.Mode,
				Notifications:  msg.Data.Notifications,
				LogLevel:       msg.Data.LogLevel,
				AuditLog:       msg.Data.AuditLog,
				LogRotation:    msg.Data.LogRotation,
				AllowedDirs:    msg.Data.AllowedDirs,
				SensitivePaths: msg.Data.SensitivePaths,
				DetectPatterns: msg.Data.DetectPatterns,
			})
		}

	case logTailStartMsg:
		// Start tailing in background
		ch := make(chan ViolationEntry, 100)
		go TailAuditLog(msg.path, ch, m.tailDone)
		cmds = append(cmds, waitForLogEntry(ch))

	case NewLogEntryMsg:
		entry := tabs.LogEntry{
			Time:     FormatTimestamp(msg.Entry.Timestamp),
			Mode:     msg.Entry.Mode,
			Decision: msg.Entry.Decision,
			Reason:   msg.Entry.Reason,
			Cmd:      msg.Entry.Cmd,
			Cwd:      msg.Entry.Cwd,
			Severity: msg.Entry.Severity,
		}
		m.logs = m.logs.AddEntry(entry)
		// Keep waiting for more
		// The waitForLogEntry cmd is re-issued in the case handler
	}

	// Forward to active tab
	var cmd tea.Cmd
	switch m.activeTab {
	case TabStatus:
		m.status, cmd = m.status.Update(msg)
	case TabViolations:
		m.violations, cmd = m.violations.Update(msg)
	case TabSelfguard:
		m.selfguard, cmd = m.selfguard.Update(msg)
	case TabLogs:
		m.logs, cmd = m.logs.Update(msg)
		// Re-issue log wait if we consumed a log entry
		if _, ok := msg.(NewLogEntryMsg); ok {
			// Need to re-wait — but we don't have the channel here
			// This is handled by the persistent goroutine
		}
	case TabConfig:
		m.config, cmd = m.config.Update(msg)
	}
	if cmd != nil {
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

func (m Model) scheduleRefresh() tea.Cmd {
	return tea.Tick(5*time.Second, func(t time.Time) tea.Msg {
		data, err := FetchStatusData()
		if err != nil {
			return StatusUpdateMsg{Data: &StatusData{Mode: "unknown", Host: "error", HealthScore: 0}}
		}
		return StatusUpdateMsg{Data: data}
	})
}

func waitForLogEntry(ch chan ViolationEntry) tea.Cmd {
	return func() tea.Msg {
		entry, ok := <-ch
		if !ok {
			return nil
		}
		return NewLogEntryMsg{Entry: entry}
	}
}

func convertCountEntries(entries []CountEntry) []tabs.CountEntry {
	var result []tabs.CountEntry
	for _, e := range entries {
		result = append(result, tabs.CountEntry{Count: e.Count, Text: e.Text})
	}
	return result
}
