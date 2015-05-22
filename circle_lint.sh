#!/usr/bin/env sh

set -eux

go get github.com/barakmich/go-nyet
go get github.com/golang/lint/golint
go get github.com/kisielk/errcheck
go get golang.org/x/tools/cmd/goimports

# Check where the committer upset our linters
make check | tee "${CIRCLE_ARTIFACTS}/check.log"; test ${PIPESTATUS[0]} -eq 0
