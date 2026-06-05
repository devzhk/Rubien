#!/bin/sh
# Mimics a CLI that predates the `version` subcommand.
echo 'error: unknown subcommand "version"' >&2
exit 64
