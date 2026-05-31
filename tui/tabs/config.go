package tabs

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ConfigInfo holds configuration data
type ConfigInfo struct {
	Mode           string
	Notifications  bool
	LogLevel       string
	AuditLog       string
	LogRotation    string
	AllowedDirs    []string
	SensitivePaths []string
	DetectPatterns []string
}

// ConfigModel for the Config tab
type ConfigModel struct {
	data   ConfigInfo
	width  int
	height int
	scroll int
}

func NewConfigModel() ConfigModel {
	return ConfigModel{
		data: ConfigInfo{
			Mode:     "soft-block",
			LogLevel: "info",
		},
	}
}

func (m ConfigModel) Update(msg tea.Msg) (ConfigModel, tea.Cmd) {
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

func (m ConfigModel) SetData(data ConfigInfo) ConfigModel {
	m.data = data
	return m
}

func (m ConfigModel) View() string {
	if m.width == 0 {
		m.width = 80
	}
	boxWidth := m.width - 6

	var sections []string

	// Current Configuration
	var configContent strings.Builder
	notifStatus := MutedStyle.Render("OFF")
	if m.data.Notifications {
		notifStatus = AccentStyle.Render("ON ●")
	}

	configContent.WriteString(fmt.Sprintf("  %s              %s\n",
		BoldStyle.Render("Mode:"),
		WarningStyle.Render(m.data.Mode)))
	configContent.WriteString(fmt.Sprintf("  %s     %s\n",
		BoldStyle.Render("Notifications:"),
		notifStatus))
	configContent.WriteString(fmt.Sprintf("  %s         %s\n",
		BoldStyle.Render("Log level:"),
		m.data.LogLevel))
	configContent.WriteString(fmt.Sprintf("  %s        %s\n",
		BoldStyle.Render("Audit log:"),
		MutedStyle.Render(m.data.AuditLog)))
	configContent.WriteString(fmt.Sprintf("  %s     %s\n",
		BoldStyle.Render("Log rotation:"),
		m.data.LogRotation))

	sections = append(sections, RenderBox("Current Configuration", configContent.String(), boxWidth))

	// Allowed Project Directories
	var dirsContent strings.Builder
	if len(m.data.AllowedDirs) == 0 {
		dirsContent.WriteString("  " + MutedStyle.Render("(no allowed directories configured)") + "\n")
	} else {
		for i, dir := range m.data.AllowedDirs {
			// Shorten home dir
			display := dir
			if strings.HasPrefix(display, "/Users/") {
				parts := strings.SplitN(display, "/", 4)
				if len(parts) >= 4 {
					display = "~/" + parts[3]
				}
			}
			dirsContent.WriteString(fmt.Sprintf("  %d. %s\n", i+1, display))
		}
	}
	sections = append(sections, RenderBox("Allowed Project Directories", dirsContent.String(), boxWidth))

	// Sensitive Paths
	var sensContent strings.Builder
	if len(m.data.SensitivePaths) == 0 {
		sensContent.WriteString("  " + MutedStyle.Render("(default paths)") + "\n")
		sensContent.WriteString("  ~/.ssh, ~/.gnupg, ~/Library/Keychains, /etc\n")
	} else {
		paths := strings.Join(m.data.SensitivePaths, ", ")
		// Wrap long lines
		maxLine := boxWidth - 6
		for len(paths) > maxLine {
			// Find a good break point
			breakAt := strings.LastIndex(paths[:maxLine], ",")
			if breakAt < 0 {
				breakAt = maxLine
			}
			sensContent.WriteString("  " + paths[:breakAt+1] + "\n")
			paths = paths[breakAt+1:]
		}
		if paths != "" {
			sensContent.WriteString("  " + paths + "\n")
		}
	}
	sections = append(sections, RenderBox("Sensitive Paths", sensContent.String(), boxWidth))

	// Detection Patterns
	var patternsContent strings.Builder
	if len(m.data.DetectPatterns) == 0 {
		patternsContent.WriteString("  rm -rf, sudo, curl|bash, chmod 777, exec, subshell bypass\n")
	} else {
		patterns := strings.Join(m.data.DetectPatterns, ", ")
		patternsContent.WriteString("  " + patterns + "\n")
	}
	sections = append(sections, RenderBox("Detection Patterns", patternsContent.String(), boxWidth))

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}
