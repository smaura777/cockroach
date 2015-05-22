#!/usr/bin/env sh

set -eux

# Check whether the committer forgot to run `go generate`.
# Either `go generate` does not change any files or it does, in which case we print the diff and fail.
docker run "(go generate ./... && git ls-files --modified --deleted --others --exclude-standard | diff /dev/null -) || (git add -A && git diff -u HEAD && false)" | tee "${CIRCLE_ARTIFACTS}/generate.log"; test ${PIPESTATUS[0]} -eq 0
docker run "cockroachdb/cockroach-dev" test TESTTIMEOUT=30s TESTFLAGS='-v --vmodule=multiraft=5,raft=1' > "${CIRCLE_ARTIFACTS}/test.log"
docker run "cockroachdb/cockroach-dev" testrace RACETIMEOUT=5m TESTFLAGS='-v --vmodule=multiraft=5,raft=1' > "${CIRCLE_ARTIFACTS}/testrace.log"
# TODO(pmattis): Use "make acceptance" again once we're using cockroachdb/builder on circleci
run/local-cluster.sh stop && run/local-cluster.sh start && run/local-cluster.sh stop
