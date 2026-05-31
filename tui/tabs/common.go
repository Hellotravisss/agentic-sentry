package tabs

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Shared styles for tabs package
var (
	AccentColor    = lipgloss.Color("#04B575")
	WarningColor   = lipgloss.Color("#FFD700")
	DangerColor    = lipgloss.Color("#FF4672")
	InfoColor      = lipgloss.Color("#7C3AED")
	HighlightColor = lipgloss.Color("#00DFFF")
	MutedColor     = lipgloss.Color("#626262")
	BorderColor    = lipgloss.Color("#3C3C3C")

	BoxStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(BorderColor).
			Padding(0, 1)

	HeaderStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(HighlightColor)

	MutedStyle = lipgloss.NewStyle().
			Foreground(MutedColor)

	AccentStyle = lipgloss.NewStyle().
			Foreground(AccentColor)

	WarningStyle = lipgloss.NewStyle().
			Foreground(WarningColor)

	DangerStyle = lipgloss.NewStyle().
			Foreground(DangerColor)

	BoldStyle = lipgloss.NewStyle().Bold(true)
)

// RenderBox renders content inside a titled box
func RenderBox(title string, content string, width int) string {
	boxWidth := width - 4
	if boxWidth < 20 {
		boxWidth = 20
	}

	headerText := fmt.Sprintf("─ %s ", title)
	remaining := boxWidth - lipgloss.Width(headerText) - 2
	if remaining < 0 {
		remaining = 0
	}
	headerLine := headerText + strings.Repeat("─", remaining) + "┐"

	top := "┌" + headerLine
	bottom := "└" + strings.Repeat("─", boxWidth-1) + "┘"

	lines := strings.Split(content, "\n")
	var borderedLines []string
	borderedLines = append(borderedLines, top)
	for _, line := range lines {
		if line == "" {
			line = " "
		}
		borderedLines = append(borderedLines, "│ "+line+strings.Repeat(" ", max(0, boxWidth-lipgloss.Width(line)-3))+" │")
	}
	borderedLines = append(borderedLines, bottom)

	return strings.Join(borderedLines, "\n")
}

// StatusDot returns a colored status indicator
func StatusDot(ok bool, critical bool) string {
	if ok {
		return lipgloss.NewStyle().Foreground(AccentColor).Render("✓")
	}
	if critical {
		return lipgloss.NewStyle().Foreground(DangerColor).Render("✗")
	}
	return lipgloss.NewStyle().Foreground(WarningColor).Render("○")
}

// HealthBar renders a progress bar
func HealthBar(score, width int) string {
	if width < 4 {
		width = 10
	}
	filled := score * width / 100
	empty := width - filled

	color := AccentColor
	if score < 80 {
		color = WarningColor
	}
	if score < 50 {
		color = DangerColor
	}

	bar := lipgloss.NewStyle().Foreground(color).Render(strings.Repeat("█", filled)) +
		lipgloss.NewStyle().Foreground(MutedColor).Render(strings.Repeat("░", empty))
	return bar
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
