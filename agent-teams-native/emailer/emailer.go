// Package emailer is a small in-memory outbox, one of the target modules
// for the agent-teams-native showcase. Bugs and coverage gaps are planted
// on purpose — see BACKLOG.md — so a native agent team has real work to
// claim.
package emailer

import (
	"fmt"
	"html/template"
	"strings"
)

// Message is one queued email.
type Message struct {
	To      string
	Subject string
	Body    string
}

// Queue is an in-memory outbox: messages are enqueued and wait for a
// sender (which this demo doesn't have) to drain them.
type Queue struct {
	pending []Message
}

// NewQueue returns an empty Queue.
func NewQueue() *Queue {
	return &Queue{}
}

// Enqueue adds a message to the outbox.
func (q *Queue) Enqueue(to, subject, body string) error {
	if to == "" || !strings.Contains(to, "@") {
		return fmt.Errorf("emailer: to must be an email address, got %q", to)
	}
	if subject == "" {
		return fmt.Errorf("emailer: subject must not be empty")
	}
	q.pending = append(q.pending, Message{To: to, Subject: subject, Body: body})
	return nil
}

// Pending returns a copy of the queued messages in enqueue order.
func (q *Queue) Pending() []Message {
	out := make([]Message, len(q.pending))
	copy(out, q.pending)
	return out
}

// receiptTemplate renders an order receipt. Because it is parsed with
// html/template, every interpolated value (customer name, receipt lines)
// is contextually auto-escaped, so untrusted input cannot inject markup.
var receiptTemplate = template.Must(template.New("receipt").Parse(
	"<h1>Receipt for {{.Customer}}</h1>\n<ul>\n" +
		"{{range .Lines}}  <li>{{.}}</li>\n{{end}}" +
		"</ul>\n<p>Total: {{.Total}}</p>\n"))

// RenderReceiptHTML builds the HTML body for an order receipt: the
// customer's name, one line per purchased item, and the charged total.
//
// The customer name and receipt lines are HTML-escaped via html/template,
// so a value containing markup such as "<script>" is rendered as inert
// text rather than executable HTML (guards against stored XSS).
func RenderReceiptHTML(customer string, lines []string, total float64) string {
	var b strings.Builder
	data := struct {
		Customer string
		Lines    []string
		Total    string
	}{
		Customer: customer,
		Lines:    lines,
		Total:    fmt.Sprintf("$%.2f", total),
	}
	if err := receiptTemplate.Execute(&b, data); err != nil {
		// The template is a compile-time constant and the data types are
		// fixed, so Execute cannot fail in practice; surface it defensively.
		return fmt.Sprintf("emailer: failed to render receipt: %v", err)
	}
	return b.String()
}
