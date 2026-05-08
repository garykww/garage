package main

import "time"

var symbols = []string{"AAPL", "MSFT", "GOOGL", "AMZN", "TSLA", "NVDA", "SPY", "QQQ"}

type tzEntry struct{ City, Zone string }

var tzones = []tzEntry{
	{"New York", "America/New_York"},
	{"Chicago", "America/Chicago"},
	{"Los Angeles", "America/Los_Angeles"},
	{"London", "Europe/London"},
	{"Paris", "Europe/Paris"},
	{"Dubai", "Asia/Dubai"},
	{"Mumbai", "Asia/Kolkata"},
	{"Singapore", "Asia/Singapore"},
	{"Tokyo", "Asia/Tokyo"},
	{"Sydney", "Australia/Sydney"},
}

type feedEntry struct{ Name, URL string }

var newsFeeds = []feedEntry{
	{"BBC", "https://feeds.bbci.co.uk/news/rss.xml"},
	{"Hacker News", "https://hnrss.org/frontpage"},
}

const refreshInterval = 60 * time.Second
