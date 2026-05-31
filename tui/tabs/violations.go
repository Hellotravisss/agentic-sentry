package tabs

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

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

// CountEntry is a counted text
type CountEntry struct {
	Count int
	Text  string
}

// SeverityBreakdown
type SeverityBreakdown struct {
	Critical int
	Warning  int
	Info     int
}

// ViolationsModel for the Violations tab
type ViolationsModel struct {
	stats  ViolationStats
	width  int
	height int
	scroll int
}

func NewViolationsModel() ViolationsModel {
	return ViolationsModel{}
}

func (m ViolationsModel) Update(msg tea.Msg) (ViolationsModel, tea.Cmd) {
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
			m.scroll++
		}
	}
	return m, nil
}

func (m ViolationsModel) SetStats(stats ViolationStats) ViolationsModel {
	m.stats = stats
	return m
}

func (m ViolationsModel) View() string {
	if m.width == 0 {
		m.width = 80
	}
	boxWidth := m.width - 6

	var sections []string

	// Summary box
	var summaryContent strings.Builder
	summaryContent.WriteString(fmt.Sprintf("  Total: %d events\n", m.stats.Total))
	if m.stats.FirstEvent != "" {
		summaryContent.WriteString(fmt.Sprintf("  Time range: %s → %s\n",
			formatDateShort(m.stats.FirstEvent), formatDateShort(m.stats.LastEvent)))
	}

	summaryContent.WriteString("\n")

	// Three stat boxes side by side
	blockedBox := fmt.Sprintf("  %s\n  %s\n",
		BoldStyle.Render("Blocked"),
		DangerStyle.Render(fmt.Sprintf("    %d", m.stats.Blocked)))
	hardBox := fmt.Sprintf("  %s\n  %s\n",
		BoldStyle.Render("Hard"),
		DangerStyle.Render(fmt.Sprintf("    %d", m.stats.Hard)))
	detectedBox := fmt.Sprintf("  %s\n  %s\n",
		BoldStyle.Render("Detected"),
		WarningStyle.Render(fmt.Sprintf("    %d", m.stats.Detected)))

	row := lipgloss.JoinHorizontal(lipgloss.Top, blockedBox+"  ", hardBox+"  ", detectedBox)
	summaryContent.WriteString(row + "\n")

	sections = append(sections, RenderBox("Summary", summaryContent.String(), boxWidth))

	// Top violation reasons
	var reasonsContent strings.Builder
	if len(m.stats.TopReasons) == 0 {
		reasonsContent.WriteString("  " + MutedStyle.Render("(no data)") + "\n")
	} else {
		for _, r := range m.stats.TopReasons {
			reasonsContent.WriteString(fmt.Sprintf("  %4d  %s\n", r.Count, r.Text))
		}
	}
	sections = append(sections, RenderBox("Top Violation Reasons", reasonsContent.String(), boxWidth))

	// Top commands
	var cmdsContent strings.Builder
	if len(m.stats.TopCommands) == 0 {
		cmdsContent.WriteString("  " + MutedStyle.Render("(no data)") + "\n")
	} else {
		for _, c := range m.stats.TopCommands {
			cmdsContent.WriteString(fmt.Sprintf("  %4d  %s\n", c.Count, c.Text))
		}
	}
	sections = append(sections, RenderBox("Most-Triggered Commands", cmdsContent.String(), boxWidth))

	// Severity breakdown
	var sevContent strings.Builder
	maxCount := m.stats.Severity.Info
	if m.stats.Severity.Warning > maxCount {
		maxCount = m.stats.Severity.Warning
	}
	if m.stats.Severity.Critical > maxCount {
		maxCount = m.stats.Severity.Critical
	}
	if maxCount == 0 {
		maxCount = 1
	}

	barWidth := 30
	sevContent.WriteString(fmt.Sprintf("  %s %s\n",
		DangerStyle.Render(fmt.Sprintf("Critical: %4d", m.stats.Severity.Critical)),
		smallBar(m.stats.Severity.Critical, maxCount, barWidth, DangerColor)))
	sevContent.WriteString(fmt.Sprintf("  %s %s\n",
		WarningStyle.Render(fmt.Sprintf("Warning:  %4d", m.stats.Severity.Warning)),
		smallBar(m.stats.Severity.Warning, maxCount, barWidth, WarningColor)))
	sevContent.WriteString(fmt.Sprintf("  %s %s\n",
		lipgloss.NewStyle().Render(fmt.Sprintf("Info:     %4d", m.stats.Severity.Info)),
		smallBar(m.stats.Severity.Info, maxCount, barWidth, AccentColor)))

	sections = append(sections, RenderBox("Severity Breakdown", sevContent.String(), boxWidth))

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

func smallBar(count, max, width int, color lipgloss.Color) string {
	if max == 0 {
		max = 1
	}
	filled := count * width / max
	if filled > width {
		filled = width
	}
	empty := width - filled
	return lipgloss.NewStyle().Foreground(color).Render(strings.Repeat("▓", filled)) +
		MutedStyle.Render(strings.Repeat("░", empty))
}

func formatDateShort(ts string) string {
	if idx := strings.Index(ts, "T"); idx >= 0 {
		return ts[:idx]
	}
	if len(ts) >= 10 {
		return ts[:10]
	}
	return ts
}
