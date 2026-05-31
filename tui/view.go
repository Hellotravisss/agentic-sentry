package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

func (m Model) View() string {
	if m.width == 0 {
		return "Loading..."
	}

	var sections []string

	// Title bar
	titleBar := m.renderTitleBar()
	sections = append(sections, titleBar)

	// Tab bar
	tabBar := m.renderTabBar()
	sections = append(sections, tabBar)

	// Active tab content
	var content string
	switch m.activeTab {
	case TabStatus:
		content = m.status.View()
	case TabViolations:
		content = m.violations.View()
	case TabSelfguard:
		content = m.selfguard.View()
	case TabLogs:
		content = m.logs.View()
	case TabConfig:
		content = m.config.View()
	}

	sections = append(sections, content)

	// Help overlay
	if m.showHelp {
		sections = append(sections, m.renderHelpOverlay())
	}

	// Footer
	footer := m.renderFooter()
	sections = append(sections, footer)

	return strings.Join(sections, "\n")
}

func (m Model) renderTitleBar() string {
	title := " ◆ AGENTIC SANDBOX SENTRY "
	style := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#FFFFFF")).
		Background(lipgloss.Color("#1E3A5F")).
		Width(m.width).
		Align(lipgloss.Left)
	return style.Render(title)
}

func (m Model) renderTabBar() string {
	var tabStrings []string
	for i, name := range TabNames {
		if i == m.activeTab {
			tabStrings = append(tabStrings,
				TabActiveStyle.Render(fmt.Sprintf(" ◉ %s ", name)))
		} else {
			tabStrings = append(tabStrings,
				TabInactiveStyle.Render(fmt.Sprintf(" ○ %s ", name)))
		}
	}
	bar := strings.Join(tabStrings, "")
	divider := MutedStyle.Render(strings.Repeat("─", m.width))
	return bar + "\n" + divider
}

func (m Model) renderFooter() string {
	divider := MutedStyle.Render(strings.Repeat("─", m.width))

	keys := []string{
		MutedStyle.Render("← →") + " tabs",
		MutedStyle.Render("↑↓") + " navigate",
		MutedStyle.Render("r") + " refresh",
		MutedStyle.Render("?") + " help",
		MutedStyle.Render("q") + " quit",
	}

	// Tab-specific hints
	switch m.activeTab {
	case TabLogs:
		keys = append(keys,
			MutedStyle.Render("p")+" pause",
			MutedStyle.Render("/")+" search")
	case TabSelfguard:
		keys = append(keys,
			MutedStyle.Render("v")+" verify")
	case TabViolations:
		keys = append(keys,
			MutedStyle.Render("e")+" export")
	}

	footer := strings.Join(keys, "  ")
	return divider + "\n" + FooterStyle.Render("  "+footer)
}

func (m Model) renderHelpOverlay() string {
	help := `
  ┌─ Key Bindings ──────────────────────────────────┐
  │                                                  │
  │  ← / →     Switch tabs                          │
  │  1-5       Jump to tab                          │
  │  ↑ / ↓     Scroll / navigate                    │
  │  r         Refresh current view                 │
  │  q         Quit                                 │
  │  ?         Toggle this help                     │
  │                                                  │
  │  Logs tab:                                       │
  │    p       Pause/resume live stream             │
  │    /       Search (coming soon)                 │
  │                                                  │
  │  Selfguard tab:                                  │
  │    v       Verify integrity (coming soon)       │
  │                                                  │
  │  Violations tab:                                 │
  │    e       Export (coming soon)                 │
  │                                                  │
  └──────────────────────────────────────────────────┘
`
	return MutedStyle.Render(help)
}
