package main

import "github.com/charmbracelet/lipgloss"

// Color palette matching sentryctl
var (
	ColorAccent    = lipgloss.Color("#04B575") // green
	ColorWarning   = lipgloss.Color("#FFD700") // yellow
	ColorDanger    = lipgloss.Color("#FF4672") // red
	ColorInfo      = lipgloss.Color("#7C3AED") // purple
	ColorHighlight = lipgloss.Color("#00DFFF") // cyan
	ColorMuted     = lipgloss.Color("#626262") // dim gray
	ColorBorder    = lipgloss.Color("#3C3C3C") // dark border
	ColorBgBlue    = lipgloss.Color("#1E3A5F") // dark blue bg
)

// Shared styles
var (
	TitleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#FFFFFF")).
			Background(ColorBgBlue).
			Padding(0, 1)

	TabActiveStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorHighlight).
			Underline(true)

	TabInactiveStyle = lipgloss.NewStyle().
				Foreground(ColorMuted)

	HeaderStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorHighlight)

	BoxStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(ColorBorder).
			Padding(0, 1)

	FooterStyle = lipgloss.NewStyle().
			Foreground(ColorMuted)

	AccentStyle = lipgloss.NewStyle().
			Foreground(ColorAccent)

	WarningStyle = lipgloss.NewStyle().
			Foreground(ColorWarning)

	DangerStyle = lipgloss.NewStyle().
			Foreground(ColorDanger)

	MutedStyle = lipgloss.NewStyle().
			Foreground(ColorMuted)

	BoldStyle = lipgloss.NewStyle().Bold(true)
)

// Tab names
var TabNames = []string{"Status", "Violations", "Selfguard", "Logs", "Config"}
