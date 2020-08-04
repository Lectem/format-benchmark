#!/bin/bash

if [ ! -d fmt ]; then

    git clone https://github.com/fmtlib/fmt.git fmt

    pushd fmt
    git config --add remote.origin.fetch +refs/pull/*/merge:refs/remotes/origin/pull/*/merge
    git config --add remote.origin.fetch +refs/pull/*/head:refs/remotes/origin/pull/*/head
    git fetch
    popd
else
    echo "fmt already exists."
    echo "If you need access to the pull requests, be sure to execute `git config --add remote.origin.fetch +refs/merge-requests/*/merge:refs/remotes/origin/merge-requests/*/merge` inside fmt."
fi
