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

TAGS 可以一次給多個：`TAGS=go,node`。碰到 system 層（`hostname`、`power`、`softwareupdate`、`sshd`）會自動問 sudo 密碼。

## 項目

| 類別 | tag |
|---|---|
| Remote Control | `claude`、`tmux`、`claude-rc`、`claude-md` |
| 連線與身分 | `tailscale`、`authorized-keys`、`ssh-keys`、`git-identity`、`sshd` |
| 常駐節點 | `power`、`softwareupdate`、`hostname`、`arrive-home` |
| 語言與容器 | `go`、`python`（只有 uv）、`node`、`pnpm`、`rust`、`podman` |
| 環境 | `profile`（PATH，由其他 tag 自動帶） |

語言的原則：**不裝通用版本管理器**。專案自己宣告版本，交給語言自己的機制下載：

- Go：`go.mod` 的 `toolchain`
- Python：`.python-version`，一律 `uv run`
- Node：`package.json` 的 `devEngines.runtime`，由 pnpm 下載
- Rust：`rust-toolchain.toml`

主機上只放 bootstrap 用的那一份。服務類（資料庫等）一律進 podman 容器。

## 移除

```bash
make uninstall TAGS=go                 # 只移除工具，資料留著並列出大小
make uninstall TAGS=go,node DATA=1     # 連快取、模組、下載的東西一起刪
make uninstall TAGS=claude-rc,claude   # 有相依的要一起點名，不然會被擋
```

不會被刪的：`~/.claude`（設定、對話紀錄）、私鑰、`~/.cargo/config.toml` 和 `credentials.toml`。報告裡會列出來。

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
