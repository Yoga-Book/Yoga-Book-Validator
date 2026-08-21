SHELL := /bin/bash

.PHONY: all test deb clean

all:
	@:

test:
	./tests/check-project.sh

deb: test
	dpkg-buildpackage -us -uc -b

clean:
	dh_clean
