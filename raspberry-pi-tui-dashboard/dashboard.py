#!/usr/bin/env python3
"""Raspberry Pi TUI Dashboard — optimised for a 4.8" screen."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from datetime import datetime
from zoneinfo import ZoneInfo

import httpx
import yfinance as yf
from rich.text import Text
from textual import work
from textual.app import App, ComposeResult
from textual.containers import ScrollableContainer
from textual.widget import Widget
from textual.widgets import DataTable, Footer, Header, Label, TabbedContent, TabPane

from config import NEWS_FEEDS, REFRESH_INTERVAL, STOCKS, TIMEZONES


class StocksWidget(Widget):
    """Live stock quote table, refreshed every REFRESH_INTERVAL seconds."""

    DEFAULT_CSS = "StocksWidget { height: 1fr; }"

    def compose(self) -> ComposeResult:
        yield DataTable(id="stocks-table", zebra_stripes=True)

    def on_mount(self) -> None:
        table = self.query_one("#stocks-table", DataTable)
        table.add_columns("Symbol", "Price", "Change", "% Chg", "3M Avg Vol")
        self.load_stocks()
        self.set_interval(REFRESH_INTERVAL, self.load_stocks)

    @work(exclusive=True, thread=True)
    def load_stocks(self) -> None:
        rows: list[tuple] = []
        for symbol in STOCKS:
            try:
                info = yf.Ticker(symbol).fast_info
                price = info.last_price or 0.0
                prev = info.previous_close or price
                change = price - prev
                pct = (change / prev * 100) if prev else 0.0
                vol = info.three_month_average_volume or 0
                color = "green" if change >= 0 else "red"
                sign = "+" if change >= 0 else ""
                rows.append((
                    symbol,
                    f"${price:.2f}",
                    Text(f"{sign}{change:.2f}", style=color),
                    Text(f"{sign}{pct:.2f}%", style=color),
                    f"{vol / 1_000_000:.1f}M",
                ))
            except Exception:
                rows.append((symbol, "—", "—", "—", "—"))

        def _update() -> None:
            table = self.query_one("#stocks-table", DataTable)
            table.clear()
            for row in rows:
                table.add_row(*row)

        self.app.call_from_thread(_update)


class NewsWidget(Widget):
    """Scrollable news headlines from RSS feeds."""

    DEFAULT_CSS = """
    NewsWidget { height: 1fr; }
    .news-source { color: $accent; text-style: bold; padding: 0 1; }
    .news-item   { padding: 0 1; }
    """

    def compose(self) -> ComposeResult:
        yield ScrollableContainer(id="news-scroll")

    def on_mount(self) -> None:
        self.load_news()
        self.set_interval(REFRESH_INTERVAL, self.load_news)

    @work(exclusive=True, thread=True)
    def load_news(self) -> None:
        entries: list[tuple[str, str]] = []
        for source, url in NEWS_FEEDS:
            try:
                r = httpx.get(url, timeout=10, follow_redirects=True)
                root = ET.fromstring(r.text)
                items = root.findall(".//item")[:6]
                entries.append(("header", f"── {source} ──"))
                for item in items:
                    title = (item.findtext("title") or "").strip()
                    entries.append(("item", f"• {title[:72]}"))
            except Exception:
                entries.append(("header", f"── {source}: unavailable ──"))

        def _update() -> None:
            scroll = self.query_one("#news-scroll", ScrollableContainer)
            scroll.remove_children()
            for kind, text in entries:
                scroll.mount(Label(text, classes="news-source" if kind == "header" else "news-item"))

        self.app.call_from_thread(_update)


class ClockWidget(Widget):
    """World clock — updates every second."""

    DEFAULT_CSS = "ClockWidget { height: 1fr; }"

    def compose(self) -> ComposeResult:
        yield DataTable(id="clock-table", zebra_stripes=True)

    def on_mount(self) -> None:
        table = self.query_one("#clock-table", DataTable)
        table.add_columns("City", "Time", "Date", "UTC Offset")
        self._tick()
        self.set_interval(1, self._tick)

    def _tick(self) -> None:
        table = self.query_one("#clock-table", DataTable)
        table.clear()
        for city, tz_name in TIMEZONES:
            now = datetime.now(ZoneInfo(tz_name))
            off = now.strftime("%z")  # e.g. +0530
            offset_str = f"UTC{off[:3]}:{off[3:]}"
            table.add_row(city, now.strftime("%H:%M:%S"), now.strftime("%a %b %d"), offset_str)


class DashboardApp(App):
    """Raspberry Pi TUI Dashboard."""

    TITLE = "Pi Dashboard"

    CSS = """
    Screen { background: $surface; }
    Header { height: 1; }
    TabbedContent { height: 1fr; }
    """

    BINDINGS = [
        ("q", "quit", "Quit"),
        ("1", "switch_tab('stocks')", "Stocks"),
        ("2", "switch_tab('news')", "News"),
        ("3", "switch_tab('clock')", "Clock"),
    ]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with TabbedContent(initial="stocks"):
            with TabPane("Stocks [1]", id="stocks"):
                yield StocksWidget()
            with TabPane("News [2]", id="news"):
                yield NewsWidget()
            with TabPane("Clock [3]", id="clock"):
                yield ClockWidget()
        yield Footer()

    def action_switch_tab(self, tab_id: str) -> None:
        self.query_one(TabbedContent).active = tab_id


def main() -> None:
    DashboardApp().run()


if __name__ == "__main__":
    main()
