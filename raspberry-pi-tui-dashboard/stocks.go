package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type quote struct {
	Symbol        string  `json:"symbol"`
	Price         float64 `json:"regularMarketPrice"`
	Change        float64 `json:"regularMarketChange"`
	ChangePercent float64 `json:"regularMarketChangePercent"`
	Volume        int64   `json:"regularMarketVolume"`
}

func fetchQuotes(syms []string) ([]quote, error) {
	url := "https://query1.finance.yahoo.com/v7/finance/quote?symbols=" +
		strings.Join(syms, ",")
	client := &http.Client{Timeout: 10 * time.Second}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var result struct {
		QuoteResponse struct {
			Result []quote `json:"result"`
		} `json:"quoteResponse"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	return result.QuoteResponse.Result, nil
}
