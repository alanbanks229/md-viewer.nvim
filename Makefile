.PHONY: test test-lua test-node

test: test-lua test-node

test-lua:
	NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua

test-node:
	npm test --prefix renderer
