#!/bin/sh

set -eu

SCREENSTAMP_SOURCE_URL="${SCREENSTAMP_SOURCE_URL:-https://raw.githubusercontent.com/maclir/screenstamp/main/bin/screenstamp}"
SCREENSTAMP_BREW="${BREW:-brew}"
SCREENSTAMP_DISPLAYPLACER="${DISPLAYPLACER:-displayplacer}"
SCREENSTAMP_CURL="${CURL:-curl}"
temporary_file=""

die() {
  printf 'screenstamp installer: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$temporary_file" ] && [ -f "$temporary_file" ]; then
    rm -f -- "$temporary_file"
  fi
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

[ "$(uname -s)" = "Darwin" ] || die "macOS is required"
command -v "$SCREENSTAMP_BREW" >/dev/null 2>&1 || \
  die "Homebrew is required: https://brew.sh"

if ! command -v "$SCREENSTAMP_DISPLAYPLACER" >/dev/null 2>&1; then
  printf 'Installing required dependency: displayplacer\n'
  "$SCREENSTAMP_BREW" install displayplacer
fi

if [ -n "${SCREENSTAMP_INSTALL_DIR:-}" ]; then
  install_dir="$SCREENSTAMP_INSTALL_DIR"
else
  install_dir="$("$SCREENSTAMP_BREW" --prefix)/bin"
fi

if [ -n "${SCREENSTAMP_SOURCE_FILE:-}" ]; then
  source_file="$SCREENSTAMP_SOURCE_FILE"
  [ -f "$source_file" ] || die "source file does not exist: $source_file"
else
  command -v "$SCREENSTAMP_CURL" >/dev/null 2>&1 || die "curl is required"
  temporary_file="$(mktemp "${TMPDIR:-/tmp}/screenstamp.XXXXXX")" || \
    die "could not create a temporary file"
  "$SCREENSTAMP_CURL" -fsSL "$SCREENSTAMP_SOURCE_URL" -o "$temporary_file" || \
    die "could not download Screenstamp"
  source_file="$temporary_file"
fi

[ -s "$source_file" ] || die "downloaded Screenstamp is empty"
install -d "$install_dir"
install -m 755 "$source_file" "$install_dir/screenstamp"

printf '\nScreenstamp is ready:\n'
printf '  screenstamp save office\n'
printf '  screenstamp load office\n'
