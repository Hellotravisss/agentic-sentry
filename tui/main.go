package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	// Parse flags
	startTab := 0
	for i, arg := range os.Args[1:] {
		switch arg {
		case "--tab":
			if i+2 < len(os.Args) {
				switch os.Args[i+2] {
				case "status":
					startTab = TabStatus
				case "violations":
					startTab = TabViolations
				case "selfguard":
					startTab = TabSelfguard
				case "logs":
					startTab = TabLogs
				case "config":
					startTab = TabConfig
				}
			}
		case "-h", "--help":
			fmt.Println("sentry-tui — Interactive TUI for Agentic Sentry")
			fmt.Println()
			fmt.Println("Usage: sentry-tui [options]")
			fmt.Println()
			fmt.Println("Options:")
			fmt.Println("  --tab <name>   Start on specific tab (status|violations|selfguard|logs|config)")
			fmt.Println("  -h, --help     Show this help")
			fmt.Println()
			fmt.Println("Controls:")
			fmt.Println("  ←/→ or h/l    Switch tabs")
			fmt.Println("  1-5           Jump to tab")
			fmt.Println("  ↑/↓ or j/k    Scroll")
			fmt.Println("  r             Refresh")
			fmt.Println("  p             Pause logs (Logs tab)")
			fmt.Println("  ?             Help overlay")
			fmt.Println("  q / Ctrl-C    Quit")
			os.Exit(0)
		}
	}

	m := NewModel()
	m.activeTab = startTab

	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
