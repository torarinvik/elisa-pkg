.PHONY: build lint test

build:
	./scripts/build.sh

test:
	./scripts/test.sh

lint:
	./scripts/build.sh --check
