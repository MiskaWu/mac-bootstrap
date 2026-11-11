#!/bin/bash
# =============================================================================
# mac-bootstrap bring-up
# -----------------------------------------------------------------------------
# 只做 Ansible 做不了的事：Homebrew，以及跑得動 Makefile 的 GNU make。
# 其他一律歸 Ansible（`make install TAGS=…`）。對應 Windows 那邊的 wsl-bootstrap。
#
# **冪等**：重跑不爆不重複（已安裝就跳過）。
# **不要用 sudo 跑**：Homebrew 不能用 root 裝；需要密碼時它自己會問。
# **要在真的終端機跑**：Homebrew 的安裝程式會互動（確認 + sudo 密碼）。
#
# 寫法限制：macOS 內建的 bash 是 3.2，這支只用 3.2 有的語法。
# =============================================================================
set -euo pipefail

log() { printf '\033[34m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[bootstrap] %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || die "只支援 Apple silicon 的 macOS"
[[ "${EUID}" -ne 0 ]] || die "不要用 sudo 跑這支；需要密碼時 Homebrew 會自己問"

BREW=/opt/homebrew/bin/brew
GMAKE=/opt/homebrew/opt/make/libexec/gnubin/make

# ---- Homebrew ---------------------------------------------------------------
# 先下載成檔案再執行，不用 `bash -c "$(curl …)"`：後者 curl 失敗時 bash 收到空字串、
# 乾淨結束，整行回 0 —— 看起來成功，機器上卻沒有 brew（同 dev-env-ansible 記的
# 「curl | bash 要 pipefail」那個洞，換一個形狀）。
if [[ -x "${BREW}" ]]; then
  log "Homebrew 已安裝，跳過"
else
  [[ -t 0 ]] || die "Homebrew 的安裝程式要互動，請在真的終端機跑這支"
  log "安裝 Homebrew（會要你按 Return 確認，並問一次 sudo 密碼）"
  installer="$(mktemp -t brew-install)"
  trap 'rm -f "${installer}"' EXIT
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "${installer}"
  /bin/bash "${installer}"
fi
[[ -x "${BREW}" ]] || die "Homebrew 裝完卻找不到 ${BREW}"

# ---- GNU make 4.x -----------------------------------------------------------
# 內建的 /usr/bin/make 是 3.81，不支援 .ONESHELL；Makefile 整份靠它（理由見 CLAUDE.md）。
# brew 的 make 裝成 gmake，另外在 libexec/gnubin 放一支叫 make 的；不會取代系統那支。
if [[ -x "${GMAKE}" ]]; then
  log "GNU make 已安裝，跳過"
else
  log "安裝 GNU make"
  "${BREW}" install make
fi
[[ -x "${GMAKE}" ]] || die "make 裝完卻找不到 ${GMAKE}"

log "完成：$("${BREW}" --version | head -1)、$("${GMAKE}" --version | head -1)"
cat <<EOF

下一步（~/.zprofile 的 PATH 還沒設，所以先用完整路徑；之後直接打 make 就好）：

    cd "$(cd "$(dirname "$0")" && pwd)" && ${GMAKE} init

EOF
