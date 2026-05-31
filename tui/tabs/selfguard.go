package tabs

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// SelfguardInfo holds selfguard data
type SelfguardInfo struct {
	Running      bool
	PID          string
	Mode         string
	Interval     string
	BaselineFile string
	BaselineTime string
	BaselineHash string
	ChainStatus  string
	Files        []ProtectedFileInfo
	RecentEvents []string
}

// ProtectedFileInfo for display
type ProtectedFileInfo struct {
	Name string
	Hash string
	OK   bool
}

// SelfguardModel for the Selfguard tab
type SelfguardModel struct {
	data   SelfguardInfo
	width  int
	height int
	scroll int
}

func NewSelfguardModel() SelfguardModel {
	return SelfguardModel{
		data: SelfguardInfo{
			Mode:     "fswatch + periodic hash check",
			Interval: "30s",
		},
	}
}

func (m SelfguardModel) Update(msg tea.Msg) (SelfguardModel, tea.Cmd) {
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

func (m SelfguardModel) SetData(data SelfguardInfo) SelfguardModel {
	m.data = data
	return m
}

func (m SelfguardModel) View() string {
	if m.width == 0 {
		m.width = 80
	}
	boxWidth := m.width - 6

	var sections []string

	// Self-Protection Status
	var statusContent strings.Builder
	monitorStatus := MutedStyle.Render("Not Running")
	if m.data.Running {
		monitorStatus = fmt.Sprintf("%s (PID %s)",
			AccentStyle.Render("Running"),
			m.data.PID)
	}
	statusContent.WriteString(fmt.Sprintf("  %s    %s\n", BoldStyle.Render("Monitor:"), monitorStatus))
	statusContent.WriteString(fmt.Sprintf("  %s       %s\n", BoldStyle.Render("Mode:"), m.data.Mode))
	statusContent.WriteString(fmt.Sprintf("  %s    %s\n", BoldStyle.Render("Interval:"), m.data.Interval))

	sections = append(sections, RenderBox("Self-Protection Status", statusContent.String(), boxWidth))

	// Integrity Chain
	var chainContent strings.Builder
	baselineInfo := MutedStyle.Render("not created")
	if m.data.BaselineFile != "" {
		baselineInfo = m.data.BaselineFile
		if m.data.BaselineTime != "" {
			baselineInfo += fmt.Sprintf(" (updated: %s)", m.data.BaselineTime)
		}
	}
	chainContent.WriteString(fmt.Sprintf("  %s  %s\n", BoldStyle.Render("Baseline:"), baselineInfo))

	chainStatusColor := AccentStyle
	if m.data.ChainStatus != "VERIFIED" {
		chainStatusColor = WarningStyle
	}
	chainContent.WriteString(fmt.Sprintf("  %s       %s\n",
		BoldStyle.Render("Status:"),
		chainStatusColor.Render(m.data.ChainStatus)))

	sections = append(sections, RenderBox("Integrity Chain", chainContent.String(), boxWidth))

	// Protected Files
	var filesContent strings.Builder
	if len(m.data.Files) == 0 {
		filesContent.WriteString("  " + MutedStyle.Render("(no baseline created yet)") + "\n")
	} else {
		displayFiles := m.data.Files
		if m.scroll > 0 && m.scroll < len(displayFiles) {
			displayFiles = displayFiles[m.scroll:]
		}
		maxShow := 10
		remaining := 0
		if len(displayFiles) > maxShow {
			remaining = len(displayFiles) - maxShow
			displayFiles = displayFiles[:maxShow]
		}

		for _, f := range displayFiles {
			dot := StatusDot(f.OK, false)
			filesContent.WriteString(fmt.Sprintf("  %s %-30s %s\n",
				dot, f.Name, MutedStyle.Render(f.Hash)))
		}
		if remaining > 0 {
			filesContent.WriteString(fmt.Sprintf("  %s\n",
				MutedStyle.Render(fmt.Sprintf("▼ %d more files...", remaining))))
		}
	}

	title := fmt.Sprintf("Protected Files (%d)", len(m.data.Files))
	sections = append(sections, RenderBox(title, filesContent.String(), boxWidth))

	// Recent Events
	var eventsContent strings.Builder
	if len(m.data.RecentEvents) == 0 {
		eventsContent.WriteString("  " + MutedStyle.Render("(no selfguard events)") + "\n")
	} else {
		for _, e := range m.data.RecentEvents {
			eventsContent.WriteString(fmt.Sprintf("  %s %s\n",
				AccentStyle.Render("✓"),
				truncate(e, boxWidth-10)))
		}
	}
	sections = append(sections, RenderBox("Recent Selfguard Events", eventsContent.String(), boxWidth))

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

func truncate(s string, max int) string {
	if max <= 0 || len(s) <= max {
		return s
	}
	return s[:max-1] + "…"
}
