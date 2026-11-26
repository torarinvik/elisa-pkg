.PHONY: build lint test

build:
	./scripts/build.sh

test:
	./scripts/test.sh

lint:
	python3 ./scripts/check_source_layout.py
	./scripts/build.sh --check
