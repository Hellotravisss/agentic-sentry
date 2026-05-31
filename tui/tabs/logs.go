package tabs

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// LogEntry for the logs tab
type LogEntry struct {
	Time     string
	Mode     string
	Decision string
	Reason   string
	Cmd      string
	Cwd      string
	Severity string
}

// LogsModel for the Logs tab
type LogsModel struct {
	entries  []LogEntry
	filtered []LogEntry
	width    int
	height   int
	scroll   int
	paused   bool
	search   string
	filter   string // ALL, BLOCKED, DETECTED
	live     bool
}

func NewLogsModel() LogsModel {
	return LogsModel{
		live:   true,
		filter: "ALL",
	}
}

func (m LogsModel) Update(msg tea.Msg) (LogsModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if m.scroll > 0 {
				m.scroll--
			}
		case "down", "j":
			maxScroll := len(m.filtered) - m.visibleLines()
			if maxScroll < 0 {
				maxScroll = 0
			}
			if m.scroll < maxScroll {
				m.scroll++
			}
		case "p":
			m.paused = !m.paused
			m.live = !m.paused
		}
	}
	return m, nil
}

func (m LogsModel) SetEntries(entries []LogEntry) LogsModel {
	m.entries = entries
	m.applyFilter()
	return m
}

func (m LogsModel) AddEntry(entry LogEntry) LogsModel {
	if !m.paused {
		m.entries = append(m.entries, entry)
		// Keep last 1000
		if len(m.entries) > 1000 {
			m.entries = m.entries[len(m.entries)-1000:]
		}
		m.applyFilter()
		// Auto-scroll to bottom if live
		if m.live {
			maxScroll := len(m.filtered) - m.visibleLines()
			if maxScroll > 0 {
				m.scroll = maxScroll
			}
		}
	}
	return m
}

func (m *LogsModel) applyFilter() {
	m.filtered = nil
	for _, e := range m.entries {
		// Apply decision filter
		switch m.filter {
		case "BLOCKED":
			if !strings.Contains(e.Decision, "BLOCK") && !strings.Contains(e.Decision, "HARD") {
				continue
			}
		case "DETECTED":
			if e.Decision != "DETECTED" {
				continue
			}
		}
		// Apply search filter
		if m.search != "" {
			haystack := strings.ToLower(e.Reason + " " + e.Cmd + " " + e.Decision)
			if !strings.Contains(haystack, strings.ToLower(m.search)) {
				continue
			}
		}
		m.filtered = append(m.filtered, e)
	}
}

func (m LogsModel) visibleLines() int {
	v := m.height - 12 // header + footer + filter bar
	if v < 5 {
		v = 5
	}
	return v
}

func (m LogsModel) View() string {
	if m.width == 0 {
		m.width = 80
	}
	boxWidth := m.width - 6

	var sections []string

	// Filter bar
	liveIndicator := AccentStyle.Render("● Live")
	if m.paused {
		liveIndicator = WarningStyle.Render("○ Paused")
	}

	filterBar := fmt.Sprintf("  %s  Filter: %s  |  %s  |  Entries: %d / %d",
		liveIndicator,
		BoldStyle.Render(m.filter),
		func() string {
			if m.search != "" {
				return fmt.Sprintf("Search: %q", m.search)
			}
			return MutedStyle.Render("Press / to search")
		}(),
		len(m.filtered),
		len(m.entries),
	)
	sections = append(sections, filterBar)

	// Log entries
	var logContent strings.Builder
	if len(m.filtered) == 0 {
		logContent.WriteString("\n  " + MutedStyle.Render("(no log entries — waiting for events...)") + "\n\n")
	} else {
		visible := m.visibleLines()
		start := m.scroll
		end := start + visible
		if end > len(m.filtered) {
			end = len(m.filtered)
		}
		if start >= len(m.filtered) {
			start = 0
		}

		for _, e := range m.filtered[start:end] {
			color := AccentStyle
			icon := "ℹ"
			switch {
			case strings.Contains(e.Decision, "BLOCK") || strings.Contains(e.Decision, "HARD"):
				color = DangerStyle
				icon = "⛔"
			case e.Decision == "DETECTED":
				color = WarningStyle
				icon = "⚠"
			}

			timeStr := e.Time
			if len(timeStr) > 8 {
				timeStr = timeStr[:8]
			}

			reason := e.Reason
			maxReason := boxWidth - 30
			if maxReason > 0 && len(reason) > maxReason {
				reason = reason[:maxReason-1] + "…"
			}

			logContent.WriteString(fmt.Sprintf("  %s %s %s\n",
				MutedStyle.Render(timeStr),
				icon,
				color.Render(e.Decision)))
			logContent.WriteString(fmt.Sprintf("     %s\n", reason))
			if e.Cmd != "" {
				cmd := e.Cmd
				if len(cmd) > boxWidth-10 {
					cmd = cmd[:boxWidth-11] + "…"
				}
				logContent.WriteString(fmt.Sprintf("     %s %s\n",
					MutedStyle.Render("cmd:"), cmd))
			}
			logContent.WriteString("\n")
		}
	}

	sections = append(sections, RenderBox("Log Stream", logContent.String(), boxWidth))

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}
