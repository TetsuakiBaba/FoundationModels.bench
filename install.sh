#!/bin/sh
# Installs the prebuilt fmbench binary (Apple Silicon, macOS 26+). No Xcode required.
#   curl -fsSL https://raw.githubusercontent.com/TetsuakiBaba/FoundationModels.bench/main/install.sh | sh
# Options (environment variables):
#   FMBENCH_VERSION=0.3.0        install a specific release instead of the latest
#   FMBENCH_INSTALL_DIR=/path    install directory (default: ~/.local/bin, or /usr/local/bin if it is writable and on PATH)
set -eu

REPO="${FMBENCH_REPO:-TetsuakiBaba/FoundationModels.bench}"
ASSET="fmbench-macos-arm64.tar.gz"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "fmbench only runs on macOS."
[ "$(uname -m)" = "arm64" ] || fail "fmbench needs an Apple Silicon Mac (this is $(uname -m))."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || fail "fmbench needs macOS 26 or later (this is $(sw_vers -productVersion))."

if [ -n "${FMBENCH_VERSION:-}" ]; then
  url="https://github.com/$REPO/releases/download/v${FMBENCH_VERSION#v}/$ASSET"
else
  url="https://github.com/$REPO/releases/latest/download/$ASSET"
fi

if [ -n "${FMBENCH_INSTALL_DIR:-}" ]; then
  dir="$FMBENCH_INSTALL_DIR"
elif [ -w /usr/local/bin ] && case ":$PATH:" in *:/usr/local/bin:*) true;; *) false;; esac; then
  dir=/usr/local/bin
else
  dir="$HOME/.local/bin"
fi
mkdir -p "$dir"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'Downloading %s\n' "$url"
curl -fsSL --retry 3 -o "$tmp/$ASSET" "$url" || fail "download failed. Is there a published release at https://github.com/$REPO/releases ?"
if curl -fsSL -o "$tmp/$ASSET.sha256" "$url.sha256" 2>/dev/null; then
  expected=$(cut -d' ' -f1 "$tmp/$ASSET.sha256")
  actual=$(shasum -a 256 "$tmp/$ASSET" | cut -d' ' -f1)
  [ "$expected" = "$actual" ] || fail "checksum mismatch (expected $expected, got $actual)"
fi
tar -xzf "$tmp/$ASSET" -C "$tmp"
[ -f "$tmp/fmbench" ] || fail "archive did not contain fmbench"
install -m 755 "$tmp/fmbench" "$dir/fmbench"
xattr -d com.apple.quarantine "$dir/fmbench" 2>/dev/null || true

printf 'Installed %s (%s)\n' "$dir/fmbench" "$("$dir/fmbench" --version 2>/dev/null || echo 'version unknown')"

# Make sure `fmbench` resolves: add the install dir to the shell profile if it is not on PATH yet.
on_path=false
case ":$PATH:" in *":$dir:"*) on_path=true;; esac
if [ "$on_path" = false ]; then
  case "${SHELL:-/bin/zsh}" in
    */zsh)  rc="$HOME/.zshrc" ;;
    */bash) rc="$HOME/.bash_profile" ;;
    *)      rc="$HOME/.profile" ;;
  esac
  line="export PATH=\"$dir:\$PATH\""
  if ! grep -qsF "$line" "$rc" 2>/dev/null; then
    printf '\n# fmbench (added by install.sh)\n%s\n' "$line" >> "$rc"
    printf 'Added %s to PATH in %s (takes effect in new terminals).\n' "$dir" "$rc"
  fi
fi

cat <<MSG

Next steps (5-15 min, Apple Intelligence must be enabled). Copy-paste the whole block:
MSG
[ "$on_path" = true ] || printf '  export PATH="%s:$PATH"\n' "$dir"
cat <<'MSG'
  mkdir -p ~/fmbench && cd ~/fmbench
  fmbench bench speed
  fmbench bench accuracy
  fmbench probe tokens
  fmbench probe context
  fmbench submit            # share your results (opens a GitHub issue)
MSG
