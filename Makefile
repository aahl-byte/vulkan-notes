# vulkan-notes — local dev commands
#
# The site is a static docsify app under notes/ (docsify is loaded from a CDN,
# so there's no build step). These targets just serve the folder and run the
# link/structure checker.

NOTES   := notes
PORT    ?= 3000
URL     := http://localhost:$(PORT)/
VERIFY  := $(CLAUDE_PLUGIN_ROOT)/scripts/verify.js

.DEFAULT_GOAL := help

.PHONY: help serve open stop verify

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

serve: ## serve the notes locally (PORT=3000 by default)
	@echo "serving $(NOTES)/ at $(URL)  (ctrl-c to stop)"
	@cd $(NOTES) && python3 -m http.server $(PORT)

open: ## open the served site in your browser
	@open $(URL)

stop: ## stop a server left running on $(PORT)
	@lsof -ti:$(PORT) | xargs kill 2>/dev/null && echo "stopped server on $(PORT)" || echo "nothing running on $(PORT)"

verify: ## run the link/structure checker over notes/
	@node $(VERIFY) $(NOTES)
