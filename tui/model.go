package main

import (
	"os"
	"path/filepath"

	"github.com/agentic-sentry/tui/tabs"
	tea "github.com/charmbracelet/bubbletea"
)

// Tab indices
const (
	TabStatus = iota
	TabViolations
	TabSelfguard
	TabLogs
	TabConfig
	TabCount
)

// Messages
type StatusUpdateMsg struct {
	Data *StatusData
}

type ViolationUpdateMsg struct {
	Entries []ViolationEntry
}

type SelfguardUpdateMsg struct {
	Data *SelfguardData
}

type ConfigUpdateMsg struct {
	Data *ConfigData
}

type NewLogEntryMsg struct {
	Entry ViolationEntry
}

type TickMsg struct{}

type logTailStartMsg struct {
	path string
}

// Model is the root model
type Model struct {
	activeTab int
	width     int
	height    int
	showHelp  bool

	// Tab models
	status     tabs.StatusModel
	violations tabs.ViolationsModel
	selfguard  tabs.SelfguardModel
	logs       tabs.LogsModel
	config     tabs.ConfigModel

	// Shared data
	statusData    *StatusData
	violationData []ViolationEntry
	selfguardData *SelfguardData
	configData    *ConfigData
	auditLogPath  string
	tailDone      chan struct{}
}

func NewModel() Model {
	return Model{
		activeTab:  TabStatus,
		status:     tabs.NewStatusModel(),
		violations: tabs.NewViolationsModel(),
		selfguard:  tabs.NewSelfguardModel(),
		logs:       tabs.NewLogsModel(),
		config:     tabs.NewConfigModel(),
		tailDone:   make(chan struct{}),
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(
		m.fetchStatus(),
		m.fetchViolations(),
		m.fetchSelfguard(),
		m.fetchConfig(),
		m.startLogTailing(),
	)
}

func (m Model) fetchStatus() tea.Cmd {
	return func() tea.Msg {
		data, err := FetchStatusData()
		if err != nil {
			return StatusUpdateMsg{Data: &StatusData{Mode: "unknown", Host: "error", HealthScore: 0}}
		}
		return StatusUpdateMsg{Data: data}
	}
}

func (m Model) fetchViolations() tea.Cmd {
	return func() tea.Msg {
		entries := FetchAuditLog(m.auditLogPath, 500)
		return ViolationUpdateMsg{Entries: entries}
	}
}

func (m Model) fetchSelfguard() tea.Cmd {
	return func() tea.Msg {
		data := FetchSelfguardData()
		return SelfguardUpdateMsg{Data: data}
	}
}

func (m Model) fetchConfig() tea.Cmd {
	return func() tea.Msg {
		data := FetchConfigData()
		return ConfigUpdateMsg{Data: data}
	}
}

func (m Model) startLogTailing() tea.Cmd {
	return func() tea.Msg {
		home, _ := os.UserHomeDir()
		path := filepath.Join(home, ".hermes", "logs", "sandbox-audit.log")
		if _, err := os.Stat(path); err != nil {
			path = "/tmp/sandbox-audit.log"
		}
		return logTailStartMsg{path: path}
	}
}
