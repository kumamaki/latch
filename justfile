# Latch task runner.

default:
    @just --list

# Type-check and run unit tests.
test:
    swift test

# Lint Swift sources and the CLI script.
lint:
    swift format lint --strict --recursive Sources Tests examples Package.swift
    shellcheck cli/latch.sh

# Tests plus lint. The full pre-ship gate.
check:
    just test
    just lint

# Print the CLI usage.
cli-help:
    bash cli/latch.sh --help

# Build and launch the Notes demo (GUI, Debug).
demo:
    swift run --package-path examples/Notes Notes
