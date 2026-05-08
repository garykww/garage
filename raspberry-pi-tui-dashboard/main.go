package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type tabID int

const (
	stocksTab tabID = iota
	newsTab
	clockTab
	numTabs
)

type (
	quotesMsg  struct{ quotes []quote }
	newsMsg    struct{ items []newsItem }
	tickMsg    time.Time
	refreshMsg struct{}
)

type model struct {
	active tabID
	width  int
	height int
	quotes []quote
	news   []newsItem
}

var (
	headerStyle = lipgloss.NewStyle().
			Background(lipgloss.Color("62")).
			Foreground(lipgloss.Color("230")).
			Padding(0, 1).Bold(true)
	inactiveTabStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("240")).Padding(0, 2)
	activeTabStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("86")).Bold(true).
			Padding(0, 2).Underline(true)
	footerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	accentStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("86")).Bold(true)
	greenStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	redStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))
)

func (m model) Init() tea.Cmd {
	return tea.Batch(loadQuotesCmd(), loadNewsCmd(), tickCmd(), scheduleRefreshCmd())
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "1":
			m.active = stocksTab
		case "2":
			m.active = newsTab
		case "3":
			m.active = clockTab
		case "tab", "right", "l":
			m.active = (m.active + 1) % numTabs
		case "shift+tab", "left", "h":
			m.active = (m.active + numTabs - 1) % numTabs
		}
	case quotesMsg:
		m.quotes = msg.quotes
	case newsMsg:
		m.news = msg.items
	case tickMsg:
		return m, tickCmd()
	case refreshMsg:
		return m, tea.Batch(loadQuotesCmd(), loadNewsCmd(), scheduleRefreshCmd())
	}
	return m, nil
}

func (m model) View() string {
	if m.width == 0 {
		return "Loading…"
	}
	header := m.headerView()
	tabBar := m.tabBarView()
	footer := m.footerView()
	contentH := m.height - lipgloss.Height(header) - lipgloss.Height(tabBar) - lipgloss.Height(footer)
	if contentH < 0 {
		contentH = 0
	}
	var content string
	switch m.active {
	case stocksTab:
		content = m.stocksView(contentH)
	case newsTab:
		content = m.newsView(contentH)
	default:
		content = m.clockView(contentH)
	}
	return lipgloss.JoinVertical(lipgloss.Left, header, tabBar, content, footer)
}

func (m model) headerView() string {
	now := time.Now().Format("15:04:05")
	title := "Pi Dashboard"
	gap := m.width - len(title) - len(now) - 2
	if gap < 1 {
		gap = 1
	}
	return headerStyle.Width(m.width).Render(title + strings.Repeat(" ", gap) + now)
}

func (m model) tabBarView() string {
	labels := []string{"1 Stocks", "2 News", "3 Clock"}
	parts := make([]string, numTabs)
	for i, lbl := range labels {
		if tabID(i) == m.active {
			parts[i] = activeTabStyle.Render(" " + lbl + " ")
		} else {
			parts[i] = inactiveTabStyle.Render(" " + lbl + " ")
		}
	}
	return lipgloss.JoinVertical(lipgloss.Left,
		lipgloss.JoinHorizontal(lipgloss.Top, parts...),
		strings.Repeat("─", m.width),
	)
}

func (m model) footerView() string {
	return footerStyle.Render(strings.Repeat("─", m.width) +
		"\n 1-3 Switch  tab Next  ←→ / h/l Navigate  q Quit")
}

func (m model) stocksView(height int) string {
	if len(m.quotes) == 0 {
		return padLines([]string{"  Loading stocks…"}, height)
	}
	lines := []string{
		fmt.Sprintf("  %-8s  %10s  %-10s  %-9s  %9s",
			"SYMBOL", "PRICE", "CHANGE", "% CHG", "VOL (M)"),
		"  " + strings.Repeat("─", max(m.width-4, 40)),
	}
	for _, q := range m.quotes {
		sign := "+"
		st := greenStyle
		if q.Change < 0 {
			sign, st = "", redStyle
		}
		lines = append(lines, fmt.Sprintf("  %-8s  %10s  %s  %s  %9s",
			q.Symbol,
			fmt.Sprintf("$%.2f", q.Price),
			padRight(st.Render(fmt.Sprintf("%s%.2f", sign, q.Change)), 10),
			padRight(st.Render(fmt.Sprintf("%s%.2f%%", sign, q.ChangePercent)), 9),
			fmt.Sprintf("%.1fM", float64(q.Volume)/1e6),
		))
	}
	return padLines(lines, height)
}

func (m model) newsView(height int) string {
	if len(m.news) == 0 {
		return padLines([]string{"  Loading news…"}, height)
	}
	maxW := max(m.width-6, 10)
	var lines []string
	cur := ""
	for _, item := range m.news {
		if item.Source != cur {
			if len(lines) > 0 {
				lines = append(lines, "")
			}
			cur = item.Source
			lines = append(lines, "  "+accentStyle.Render("── "+item.Source+" ──"))
		}
		t := item.Title
		if len(t) > maxW {
			t = t[:maxW] + "…"
		}
		lines = append(lines, "  • "+t)
	}
	return padLines(lines, height)
}

func (m model) clockView(height int) string {
	lines := []string{
		fmt.Sprintf("  %-16s  %10s  %-14s  %s", "CITY", "TIME", "DATE", "UTC OFFSET"),
		"  " + strings.Repeat("─", max(m.width-4, 40)),
	}
	for _, tz := range tzones {
		loc, err := time.LoadLocation(tz.Zone)
		if err != nil {
			continue
		}
		now := time.Now().In(loc)
		_, off := now.Zone()
		h := off / 3600
		mins := off % 3600 / 60
		if mins < 0 {
			mins = -mins
		}
		sign := "+"
		if off < 0 {
			sign = "-"
			h = -h
		}
		lines = append(lines, fmt.Sprintf("  %-16s  %10s  %-14s  UTC%s%02d:%02d",
			tz.City,
			now.Format("15:04:05"),
			now.Format("Mon Jan 02"),
			sign, h, mins,
		))
	}
	return padLines(lines, height)
}

func padLines(lines []string, height int) string {
	for len(lines) < height {
		lines = append(lines, "")
	}
	return strings.Join(lines[:min(len(lines), height)], "\n")
}

// padRight pads s to visual width n, accounting for ANSI escape codes.
func padRight(s string, n int) string {
	w := lipgloss.Width(s)
	if w >= n {
		return s
	}
	return s + strings.Repeat(" ", n-w)
}

func loadQuotesCmd() tea.Cmd {
	return func() tea.Msg {
		quotes, _ := fetchQuotes(symbols)
		return quotesMsg{quotes: quotes}
	}
}

func loadNewsCmd() tea.Cmd {
	return func() tea.Msg {
		return newsMsg{items: fetchNews(newsFeeds)}
	}
}

func tickCmd() tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func scheduleRefreshCmd() tea.Cmd {
	return tea.Tick(refreshInterval, func(time.Time) tea.Msg { return refreshMsg{} })
}

func main() {
	p := tea.NewProgram(model{}, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
