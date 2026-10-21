#!/usr/bin/env bash
# mawk does not treat \b as a word boundary. The probe list is created by the
# scanner itself, so a fresh clone does not need tests/no-literals.words.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/tests/no-literals.sh" --boundary
