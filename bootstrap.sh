#!/usr/bin/env bash
# bootstrap.sh: set up a fresh, sudo-less workstation the way I do.
#
# What it does:
#   1. Installs gh (github CLI) into ~/.local/bin
#   2. Installs shellcheck and bats into ~/.local/bin
#   3. Ensures ~/.local/bin is on PATH (via ~/.bashrc and ~/.profile)
#   4. Writes ~/.config/truffle/env.sh that sources the token at runtime
#   5. Configures git globally (name, email, default branch, autoSetupRemote)
#   6. Clones the truffle CLI into ~/repos/truffle and puts its bin/ on PATH
#
# What it does NOT do:
#   - Hardcode anyone's GitHub token. You set $GH_TOKEN before running, or
#     drop the token into ~/.config/truffle/github_token (mode 0600) yourself.
#   - sudo anywhere. If you have root, this script still works the same.
#
# Usage:
#   GIT_USER_NAME="Your Name" GIT_USER_EMAIL="you@example.com" \
#     bash <(curl -fsSL https://truffle.ghostwright.dev/public/bootstrap.sh)
#
# Or download first, read it, then run:
#   curl -fsSL https://truffle.ghostwright.dev/public/bootstrap.sh -o bootstrap.sh
#   less bootstrap.sh
#   GIT_USER_NAME=... GIT_USER_EMAIL=... bash bootstrap.sh

set -euo pipefail

GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
GH_VERSION="${GH_VERSION:-2.90.0}"
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-0.10.0}"
BATS_VERSION="${BATS_VERSION:-1.11.0}"
TRUFFLE_REPO_URL="${TRUFFLE_REPO_URL:-https://github.com/truffle-dev/truffle.git}"

LOCAL_BIN="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/truffle"
REPOS_DIR="${HOME}/repos"
TMPDIR_BS="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_BS}"' EXIT

note() { printf '==> %s\n' "$*"; }

ensure_dirs() {
    mkdir -p "${LOCAL_BIN}" "${CONFIG_DIR}" "${REPOS_DIR}"
}

arch_suffix() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac
}

install_gh() {
    if [ -x "${LOCAL_BIN}/gh" ] && "${LOCAL_BIN}/gh" --version 2>/dev/null | grep -q "${GH_VERSION}"; then
        note "gh ${GH_VERSION} already installed"
        return
    fi
    note "installing gh ${GH_VERSION}"
    local arch tarball url
    arch="$(arch_suffix)"
    tarball="gh_${GH_VERSION}_linux_${arch}.tar.gz"
    url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${tarball}"
    curl -fsSL "${url}" -o "${TMPDIR_BS}/${tarball}"
    tar -xzf "${TMPDIR_BS}/${tarball}" -C "${TMPDIR_BS}"
    install -m 0755 "${TMPDIR_BS}/gh_${GH_VERSION}_linux_${arch}/bin/gh" "${LOCAL_BIN}/gh"
}

install_shellcheck() {
    if [ -x "${LOCAL_BIN}/shellcheck" ] && "${LOCAL_BIN}/shellcheck" --version 2>/dev/null | grep -q "${SHELLCHECK_VERSION}"; then
        note "shellcheck ${SHELLCHECK_VERSION} already installed"
        return
    fi
    if ! command -v xz >/dev/null 2>&1; then
        note "shellcheck releases ship as .tar.xz; xz is not on PATH, skipping"
        note "install xz (or unpack manually) and rerun if you want shellcheck"
        return
    fi
    note "installing shellcheck ${SHELLCHECK_VERSION}"
    local url
    url="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
    curl -fsSL "${url}" -o "${TMPDIR_BS}/sc.tar.xz"
    xz -d "${TMPDIR_BS}/sc.tar.xz"
    tar -xf "${TMPDIR_BS}/sc.tar" -C "${TMPDIR_BS}"
    install -m 0755 "${TMPDIR_BS}/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "${LOCAL_BIN}/shellcheck"
}

install_bats() {
    if [ -x "${LOCAL_BIN}/bats" ] && "${LOCAL_BIN}/bats" --version 2>/dev/null | grep -q "${BATS_VERSION}"; then
        note "bats ${BATS_VERSION} already installed"
        return
    fi
    note "installing bats ${BATS_VERSION}"
    git -c advice.detachedHead=false clone --quiet --depth 1 \
        --branch "v${BATS_VERSION}" \
        https://github.com/bats-core/bats-core.git "${TMPDIR_BS}/bats-core"
    "${TMPDIR_BS}/bats-core/install.sh" "${HOME}/.local" >/dev/null
}

write_env_sh() {
    local env_file="${CONFIG_DIR}/env.sh"
    if [ -f "${env_file}" ]; then
        note "${env_file} already exists, leaving untouched"
        return
    fi
    note "writing ${env_file}"
    cat > "${env_file}" <<'EOF'
# ~/.config/truffle/env.sh
# Sourced by ~/.bashrc and ~/.profile. Also safe to `source` directly
# from any non-interactive script that needs gh / git auth.
#
# Token lives in a 0600 file alongside this script, never in shell rc.

if [ -r "$HOME/.config/truffle/github_token" ]; then
  GITHUB_TOKEN="$(cat "$HOME/.config/truffle/github_token")"
  export GITHUB_TOKEN
  # gh respects GH_TOKEN with higher priority than GITHUB_TOKEN.
  export GH_TOKEN="$GITHUB_TOKEN"
fi

# Make ~/.local/bin available (gh, shellcheck, bats live here).
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# truffle CLI: put its bin/ on PATH if the repo is checked out here.
if [ -d "$HOME/repos/truffle/bin" ]; then
  case ":$PATH:" in
    *":$HOME/repos/truffle/bin:"*) ;;
    *) export PATH="$HOME/repos/truffle/bin:$PATH" ;;
  esac
fi
EOF
}

stash_token_if_provided() {
    local token_file="${CONFIG_DIR}/github_token"
    if [ -f "${token_file}" ]; then
        return
    fi
    if [ -n "${GH_TOKEN:-}" ]; then
        note "stashing \$GH_TOKEN into ${token_file} (mode 0600)"
        umask 077
        printf '%s' "${GH_TOKEN}" > "${token_file}"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        note "stashing \$GITHUB_TOKEN into ${token_file} (mode 0600)"
        umask 077
        printf '%s' "${GITHUB_TOKEN}" > "${token_file}"
    else
        note "no GH_TOKEN/GITHUB_TOKEN in env; drop your token into ${token_file} (mode 0600) when ready"
    fi
}

wire_shell_rc() {
    # The single quotes are intentional: this string is a literal source
    # line written to ~/.bashrc and ~/.profile, evaluated at shell startup,
    # not now.
    # shellcheck disable=SC2016
    local source_line='[ -f "$HOME/.config/truffle/env.sh" ] && . "$HOME/.config/truffle/env.sh"'
    for rc in "${HOME}/.bashrc" "${HOME}/.profile"; do
        touch "${rc}"
        # Match the literal source line we wrote (no $HOME expansion), so
        # this stays idempotent across runs.
        if ! grep -qF '.config/truffle/env.sh' "${rc}"; then
            note "appending source line to ${rc}"
            printf '\n# truffle env\n%s\n' "${source_line}" >> "${rc}"
        else
            note "${rc} already sources truffle env"
        fi
    done
}

configure_git() {
    if [ -z "${GIT_USER_NAME}" ] || [ -z "${GIT_USER_EMAIL}" ]; then
        note "GIT_USER_NAME and GIT_USER_EMAIL not set; skipping git config"
        note "set them before rerunning, or run: git config --global user.name/email"
        return
    fi
    note "configuring git globally"
    git config --global user.name "${GIT_USER_NAME}"
    git config --global user.email "${GIT_USER_EMAIL}"
    git config --global init.defaultBranch main
    git config --global push.autoSetupRemote true
}

clone_truffle_cli() {
    local dest="${REPOS_DIR}/truffle"
    if [ -d "${dest}/.git" ]; then
        note "truffle CLI already cloned at ${dest}"
        return
    fi
    note "cloning truffle CLI into ${dest}"
    git clone --quiet "${TRUFFLE_REPO_URL}" "${dest}"
}

verify() {
    note "verifying"
    "${LOCAL_BIN}/gh" --version | head -1
    if [ -x "${LOCAL_BIN}/shellcheck" ]; then
        "${LOCAL_BIN}/shellcheck" --version | head -2 | tail -1
    fi
    if [ -x "${LOCAL_BIN}/bats" ]; then
        "${LOCAL_BIN}/bats" --version
    fi
    if [ -x "${REPOS_DIR}/truffle/bin/truffle" ]; then
        "${REPOS_DIR}/truffle/bin/truffle" version
    fi
    if command -v git >/dev/null 2>&1; then
        printf 'git: %s / %s\n' \
            "$(git config --global --get user.name || echo unset)" \
            "$(git config --global --get user.email || echo unset)"
    fi
}

main() {
    ensure_dirs
    install_gh
    install_shellcheck
    install_bats
    write_env_sh
    stash_token_if_provided
    wire_shell_rc
    configure_git
    clone_truffle_cli
    verify
    note "done. open a new shell, then run: gh auth status"
}

main "$@"
