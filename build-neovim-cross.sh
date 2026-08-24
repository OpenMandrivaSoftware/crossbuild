#!/bin/sh
# Build the neovim set for one or both bootstrap targets.
# With no arguments, both riscv64-linux and loongarch64-linux are built.
# Extra arguments are passed to create-omv-env.sh (e.g. -r luajit -t loongarch64-linux).
set -e
cd "$(dirname "$0")"
if [ $# -gt 0 ]; then
	exec ./create-omv-env.sh "$@" neovim
fi
for t in riscv64-linux loongarch64-linux; do
	./create-omv-env.sh -t "$t" neovim
done
