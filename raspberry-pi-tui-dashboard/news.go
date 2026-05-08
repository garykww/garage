package main

import (
	"encoding/xml"
	"io"
	"net/http"
	"time"
)

type newsItem struct {
	Source string
	Title  string
}

type rssFeed struct {
	Items []struct {
		Title string `xml:"title"`
	} `xml:"channel>item"`
}

func parseRSS(r io.Reader) ([]string, error) {
	var feed rssFeed
	if err := xml.NewDecoder(r).Decode(&feed); err != nil {
		return nil, err
	}
	titles := make([]string, 0, len(feed.Items))
	for _, item := range feed.Items {
		titles = append(titles, item.Title)
	}
	return titles, nil
}

func fetchNews(feeds []feedEntry) []newsItem {
	client := &http.Client{Timeout: 10 * time.Second}
	var items []newsItem
	for _, feed := range feeds {
		resp, err := client.Get(feed.URL)
		if err != nil {
			items = append(items, newsItem{Source: feed.Name, Title: "(unavailable)"})
			continue
		}
		titles, err := parseRSS(resp.Body)
		resp.Body.Close()
		if err != nil {
			items = append(items, newsItem{Source: feed.Name, Title: "(parse error)"})
			continue
		}
		for i, t := range titles {
			if i >= 6 {
				break
			}
			items = append(items, newsItem{Source: feed.Name, Title: t})
		}
	}
	return items
}
