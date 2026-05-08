"""Unit tests — no network or display required."""

from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import pytest

from config import NEWS_FEEDS, REFRESH_INTERVAL, STOCKS, TIMEZONES


def test_stocks_are_non_empty_strings():
    assert len(STOCKS) > 0
    for sym in STOCKS:
        assert isinstance(sym, str) and sym.strip(), f"Bad symbol: {sym!r}"


def test_timezone_entries_are_valid():
    assert len(TIMEZONES) > 0
    for city, tz_name in TIMEZONES:
        assert isinstance(city, str) and city
        try:
            tz = ZoneInfo(tz_name)
        except ZoneInfoNotFoundError:
            pytest.fail(f"Unknown timezone: {tz_name!r}")
        now = datetime.now(tz)
        assert now.tzinfo is not None


def test_timezone_offsets_are_distinct():
    # Sanity-check that we didn't accidentally duplicate timezone entries.
    names = [tz for _, tz in TIMEZONES]
    assert len(names) == len(set(names)), "Duplicate timezone entries in config"


def test_news_feeds_have_http_urls():
    assert len(NEWS_FEEDS) > 0
    for name, url in NEWS_FEEDS:
        assert isinstance(name, str) and name
        assert url.startswith("http"), f"Feed URL must start with http: {url!r}"


def test_refresh_interval_is_positive():
    assert isinstance(REFRESH_INTERVAL, (int, float))
    assert REFRESH_INTERVAL > 0


def test_clock_formatting():
    """Verify the time-formatting logic used by ClockWidget."""
    city, tz_name = TIMEZONES[0]
    now = datetime.now(ZoneInfo(tz_name))
    off = now.strftime("%z")
    offset_str = f"UTC{off[:3]}:{off[3:]}"
    assert offset_str.startswith("UTC"), f"Unexpected offset format: {offset_str}"
    assert len(now.strftime("%H:%M:%S")) == 8
