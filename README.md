# mac-bootstrap

把一台 Mac 設成「常駐、可以從手機叫 Claude 來做事」的節點，並保持主機乾淨。Ansible + Make，冪等，每一項都能 `make uninstall`。

設計理由、慣例、地雷在 [CLAUDE.md](CLAUDE.md)；語言與容器的選型在 [research/language-versions.md](research/language-versions.md)。

## 從零開始

```bash
./bootstrap.sh                                   # Homebrew + GNU make 4.x（會問密碼）
cp config.example.yml config.yml                 # 填這台的值
/opt/homebrew/opt/make/libexec/gnubin/make init  # 補上 ansible，印出下一步
make install TAGS=user                           # 不用 sudo 的全部
make install TAGS=system                         # 要 sudo 的（會問密碼，自己在終端機跑）
make verify
```

`TAGS=profile` 套用後，新開的終端機裡 `make` 就是 4.x，不用再打完整路徑。

## 常用指令

| 指令 | 做什麼 |
|---|---|
| `make list` | 有哪些項目、這台已經有哪些、哪些要 sudo、哪些能移除 |
| `make check TAGS=…` | 乾跑：會改什麼（`--check --diff`） |
| `make install TAGS=…` | 套用。不帶 TAGS = 全部 |
| `make uninstall TAGS=…` | 移除。**一定要帶 TAGS** |
| `make uninstall TAGS=… DATA=1` | 連資料一起清（快取、下載的 runtime、podman 的 VM 磁碟） |
| `make verify` | 驗收清單裡能自動檢查的部分（唯讀） |

TAGS 可以一次給多個：`TAGS=go,node`。碰到 system 層（`hostname`、`power`、`softwareupdate`、`sshd`、`claude-md`、`claude-guard`）會自動問 sudo 密碼。

## 項目

| 類別 | tag |
|---|---|
| Remote Control | `claude`、`tmux`、`claude-rc`（含 `claude-rc-entry`：替單一專案臨時開關起點） |
| GUI App | `claude-desktop`、`chrome`、`chrome-remote-desktop`（確認在，不在才裝；移除手動） |
| CI | `gha-runner`（GitHub Actions 自架執行器，跑在 podman 裡、常駐） |
| Claude 的整台電腦層（sudo） | `claude-md`（這台的規矩）、`claude-guard`（要裝東西先問） |
| 連線與身分 | `tailscale`、`authorized-keys`、`ssh-keys`、`git-identity`、`sshd` |
| 常駐節點 | `power`、`softwareupdate`、`hostname`、`arrive-home` |
| 語言與容器 | `go`、`python`（只有 uv）、`node`、`pnpm`、`rust`、`podman`、`docker-compat` |
| 遊戲引擎 | `godot`（多版本並存） |
| easel 的前置工具 | `codex`（OpenAI 官方 Codex CLI 的完整套件，pin 版本，放在 `~/.local/codex-<版本>`；只放一個執行檔的單檔版生不了圖）。easel 在 macOS 用內建 sips 做縮圖，只需要 codex |
| 無頭截圖 | `chrome-headless-shell`（Chrome for Testing 的舊版無頭模式，pin 版本與 sha256，放在 `~/.local/chrome-headless-shell-<版本>`）。jury 拍 390 寬的手機截圖用：一般 Google Chrome 的無頭模式最窄 500，手機寬度的圖會被切掉 |
| 命令列工具 | `bash`（brew 的 5.x，`#!/usr/bin/env bash` 會拿到它）、`awscli`、`gh` |
| 環境 | `profile`（PATH，由其他 tag 自動帶） |

語言的原則：**不裝通用版本管理器**。專案自己宣告版本，交給語言自己的機制下載：

- Go：`go.mod`（比主機新的版本自動下載；要比主機舊的版本得帶 `GOTOOLCHAIN=go1.x.y`）
- Python：`.python-version`，一律 `uv run`
- Node：`pnpm runtime set node <版本>` 寫進 `devEngines.runtime`，由 pnpm 下載；執行要用 `pnpm exec node` / `pnpm run`
- Rust：`rust-toolchain.toml`

主機上只放 bootstrap 用的那一份。服務類（資料庫等）一律進 podman 容器。

容器只用 podman，沒有 Docker：

- compose 用 `podman compose`（provider 是 docker-compose，只透過 podman 的 API 建容器）。
- `docker …` 會交給 podman（`TAGS=docker-compat` 的 shim），寫死 `docker` 的腳本照樣能跑。
- testcontainers 這類走 Docker API 的函式庫靠 `DOCKER_HOST`，不用另外設定。
- VM 常駐（裡面跑 GitHub Actions 的自架執行器，`TAGS=gha-runner`），不要 `podman machine stop`。

Godot 沒有「專案自己下載版本」的機制，所以版本寫在 `config.yml` 的 `godot_versions`：列幾個裝幾個（`~/Applications/Godot-<版本>.app`、`godot-<版本>` 指令），拿掉的會被刪。

## 移除

```bash
make uninstall TAGS=go                 # 只移除工具，資料留著並列出大小
make uninstall TAGS=go,node DATA=1     # 連快取、模組、下載的東西一起刪
make uninstall TAGS=claude-rc,claude   # 有相依的要一起點名，不然會被擋
```

不會被刪的：`~/.claude`（設定、對話紀錄）、私鑰、`~/.cargo/config.toml` 和 `credentials.toml`、`~/.aws/config` 和 `credentials`、`~/.config/gh`（gh 的登入）、`~/.codex` 裡的 `auth.json`（Codex 的登入）、`config.toml`、`AGENTS.md`、`.env`、`sessions`（對話紀錄）。報告裡會列出來。

不能自動移除的：`tailscale`（.pkg，要 sudo）、`hostname`（改 config 再 install）。對它們下 `make uninstall` 會印出手動步驟。

注意：之後跑一次不帶 TAGS 的 `make install`，會把移除的東西裝回來。

## 手動的事

`make init` 會印出清單，`make verify` 會檢查做了沒有：

1. 系統設定 → 一般 → 共享：打開「遠端登入」（只允許自己的帳號）和「螢幕共享」。
2. 安裝並登入 Tailscale：`brew install --cask tailscale-app`，然後打開「登入時啟動」。
3. 登入 Claude：`claude auth login`。然後在**系統內建的「終端機」**手動跑一次：

   ```bash
   cd ~/Developer && claude remote-control --name <名字> --spawn same-dir
   ```

   回答開啟與信任，用手機確認看得到之後按 Ctrl+C，再 `make install TAGS=claude-rc`。
4. 把 `make install TAGS=ssh-keys` 印出來的公鑰貼到 GitHub。別台機器的公鑰放進 `config.yml` 的 `ssh_authorized_keys`。
5. 用金鑰從別台登入成功之後，才 `make install TAGS=sshd`。這一步會關掉密碼登入。
6. 裝了 `awscli`、`gh` 的話：`aws configure sso`（或從別台搬 `~/.aws/config`）再 `aws sso login --profile <名字>`；`gh auth login`。
7. 裝了 `codex` 的話：`codex login`（ChatGPT 帳號）。用 easel 的話也可以不先登入，第一次開面板時它會帶你用裝置碼登入。
