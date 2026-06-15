package tabs

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// StatusData is passed from the main model
type StatusData struct {
	Timestamp   string
	Host        string
	Mode        string
	Fswatch     bool
	Selfguard   bool
	Egress      bool
	Launchd     bool
	AuditTotal  int
	AuditBlocked int
	HealthScore int
}

// RecentActivity is a recent event
type RecentActivity struct {
	Time     string
	Decision string
	Reason   string
}

// StatusModel for the Status tab
type StatusModel struct {
	data           *StatusData
	recentActivity []RecentActivity
	width          int
	height         int
}

func NewStatusModel() StatusModel {
	return StatusModel{
		data: &StatusData{Mode: "loading...", Host: "...", HealthScore: 0},
	}
}

func (m StatusModel) Update(msg tea.Msg) (StatusModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	}
	return m, nil
}

func (m StatusModel) SetData(data *StatusData) StatusModel {
	m.data = data
	return m
}

func (m StatusModel) SetRecentActivity(activities []RecentActivity) StatusModel {
	m.recentActivity = activities
	return m
}

func (m StatusModel) View() string {
	if m.width == 0 {
		m.width = 80
	}
	boxWidth := m.width - 6

	var sections []string

	// Main info box
	var mainContent strings.Builder
	mainContent.WriteString(fmt.Sprintf("  %s          %s     %s %d/100\n",
		BoldStyle.Render("Mode:"),
		WarningStyle.Render(m.data.Mode),
		BoldStyle.Render("Health:"),
		m.data.HealthScore,
	))
	mainContent.WriteString(fmt.Sprintf("  %s          %s\n",
		BoldStyle.Render("Host:"),
		m.data.Host,
	))

	sections = append(sections, RenderBox("Agentic Sentry", mainContent.String(), boxWidth))

	// Components box
	var compContent strings.Builder
	components := []struct {
		name   string
		ok     bool
		detail string
	}{
		{"fswatch monitor", m.data.Fswatch, statusDetail(m.data.Fswatch, "running", "not running")},
		{"selfguard", m.data.Selfguard, statusDetail(m.data.Selfguard, "running", "not running")},
		{"egress watcher", m.data.Egress, statusDetail(m.data.Egress, "running", "not running")},
		{"launchd agent", m.data.Launchd, statusDetail(m.data.Launchd, "loaded", "not loaded")},
	}

	for _, c := range components {
		dot := StatusDot(c.ok, false)
		line := fmt.Sprintf("  %s  %-20s %s\n", dot, c.name, MutedStyle.Render(c.detail))
		compContent.WriteString(line)
	}

	sections = append(sections, RenderBox("Components", compContent.String(), boxWidth))

	// Events summary
	var eventsContent strings.Builder
	safe := m.data.AuditTotal - m.data.AuditBlocked
	if m.data.AuditTotal == 0 {
		safe = 0
	}
	eventsContent.WriteString(fmt.Sprintf("  Total: %-8d Blocked: %-8d Safe: %d\n",
		m.data.AuditTotal, m.data.AuditBlocked, safe))

	// Health bar
	bar := HealthBar(m.data.HealthScore, 20)
	safePercent := 0
	if m.data.AuditTotal > 0 {
		safePercent = safe * 100 / m.data.AuditTotal
	}
	eventsContent.WriteString(fmt.Sprintf("\n  %s  %d%% safe\n", bar, safePercent))

	sections = append(sections, RenderBox("Events (all time)", eventsContent.String(), boxWidth))

	// Recent activity
	var recentContent strings.Builder
	if len(m.recentActivity) == 0 {
		recentContent.WriteString("  " + MutedStyle.Render("(no recent activity)") + "\n")
	} else {
		for _, a := range m.recentActivity {
			color := AccentStyle
			icon := "ℹ"
			switch {
			case strings.Contains(a.Decision, "BLOCK") || strings.Contains(a.Decision, "HARD"):
				color = DangerStyle
				icon = "⛔"
			case a.Decision == "DETECTED":
				color = WarningStyle
				icon = "⚠"
			}

			reason := a.Reason
			maxReason := boxWidth - 35
			if maxReason > 0 && len(reason) > maxReason {
				reason = reason[:maxReason-1] + "…"
			}

			recentContent.WriteString(fmt.Sprintf("  %s %s %s %s — %s\n",
				MutedStyle.Render(a.Time),
				icon,
				color.Render(a.Decision),
				"",
				reason,
			))
		}
	}

	sections = append(sections, RenderBox("Recent Activity", recentContent.String(), boxWidth))

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

func statusDetail(ok bool, yes, no string) string {
	if ok {
		return yes
	}
	return no
}
