.PHONY: run test test-reaper

run:
	npm start

test:
	npm test

test-reaper:
	lua reaper/tests/run.lua
