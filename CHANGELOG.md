# Changelog

## Unreleased

- First release: a Net::HTTP client for mailscore's HTTP API, with no dependencies
- Each `/check` symbol has its `description`, nil from servers before 0.1.1
- `check` sends `reverse_dns_status` and `unconfirmed_hostname`
- Each `/check` result has the spam `headers` to add, none from older servers
