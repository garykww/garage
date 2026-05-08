"""Dashboard configuration — edit to customise stocks, timezones, and news feeds."""

STOCKS = ["AAPL", "MSFT", "GOOGL", "AMZN", "TSLA", "NVDA", "SPY", "QQQ"]

TIMEZONES = [
    ("New York", "America/New_York"),
    ("Chicago", "America/Chicago"),
    ("Los Angeles", "America/Los_Angeles"),
    ("London", "Europe/London"),
    ("Paris", "Europe/Paris"),
    ("Dubai", "Asia/Dubai"),
    ("Mumbai", "Asia/Kolkata"),
    ("Singapore", "Asia/Singapore"),
    ("Tokyo", "Asia/Tokyo"),
    ("Sydney", "Australia/Sydney"),
]

NEWS_FEEDS = [
    ("BBC", "https://feeds.bbci.co.uk/news/rss.xml"),
    ("Hacker News", "https://hnrss.org/frontpage"),
]

# How often (seconds) stocks and news are refreshed
REFRESH_INTERVAL = 60
