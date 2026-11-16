# mac-bootstrap

Miska 家裡這台 MacBook Pro（Mac16,5，M4 Max，64 GB，macOS 27）的 IaC。目標：讓它成為一台常駐、可遠端叫用 Claude 的節點（Remote Control），而且**主機保持乾淨、每一項都能乾淨移除**。

原始需求在 `HANDOFF.md`（不改）。這台的實測紀錄在 `SETUP-LOG.md`（gitignored）。語言與容器的選型依據在 `research/language-versions.md`。

慣例沿用 Miska 的 Linux 兩個 repo：`dev-env-ansible`（Ansible role + Make、冪等、`make uninstall`）與 `wsl-bootstrap`（bring-up、SSH key 命名、`verify`）。**跟它們一致的地方不重新論證**；不一致的地方在這裡寫明理由。

---

## 硬規矩

1. **sudo 由 Miska 自己在終端機跑。** 列出完整指令，不要求、不經手、不保存密碼。system 層的 tag 會讓 Makefile 自動加 `-K`，密碼只進 Ansible 的提示。
2. **不關 FileVault、不開自動登入、UniFi 不開任何對外 port、這台不存任何 2FA secret。**
3. **主機乾淨。** 主機上只能有 tag 裝的東西（加上 bring-up 的 Homebrew、make，與 Makefile 補的 ansible）。要多一樣：多一個 tag、多一段 uninstall、說得出為什麼不能放進容器或專案自己的宣告。`make verify` 的漂移檢查會抓到手動裝的東西：brew、`/Applications` 與 `~/Applications` 的 App、.pkg 收據、LaunchAgents / LaunchDaemons、`~/.local/bin` 與 `~/bin`、npm / pnpm / cargo / uv tool / go install 的全域安裝。允許清單在 `defaults/main.yml` 的 `mac_node_brew_allowed_*` 與 `mac_node_allowed_*`。
4. **每一項都要能乾淨移除。** 新增 tag 時，同一個 commit 裡要有 `uninstall-user.yml`（或 `uninstall-system.yml`）的對應段落，或在 Makefile 的 `_check-uninstall-tags` 寫明為什麼只能手動。
5. **repo 不公開。** 機器專屬的值只放 `config.yml`（gitignored）；`SETUP-LOG.md` 記了 IP、公鑰指紋，也 gitignored。
6. **改設定走 IaC。** 不要直接改 `~/.zshenv`、`~/.zprofile`、LaunchAgent、`/etc`；改 repo 再 `make install TAGS=…`。
7. GUI、帳號、別的設備上的步驟列成手動步驟，不自動化（見「手動的事」）。

## 結構

```
mac-bootstrap/
├── CLAUDE.md  README.md  HANDOFF.md（原始需求，不改）
├── research/language-versions.md   # 語言、容器的選型調查（Miska 2026-11-12 核准）
├── bootstrap.sh                    # bring-up：Homebrew + GNU make 4.x
├── config.example.yml              # config.yml（gitignored）的範本
├── Makefile                        # init / list / check / install / uninstall / verify …
├── site.yml                        # 安裝：user play（不用 sudo）+ system play（become）
├── uninstall.yml                   # 移除：同樣兩個 play（理由見檔頭）
└── roles/mac_node/
    ├── defaults/main.yml
    ├── tasks/
    │   ├── main-user.yml  main-system.yml          # 一個 import 一個 tag
    │   ├── uninstall-user.yml  uninstall-system.yml
    │   ├── detect.yml  list.yml  verify.yml        # list / verify 是 [x, never]
    │   ├── tmux  claude  claude-rc  tailscale  git-identity  ssh-keys  authorized-keys
    │   ├── arrive-home  go  python  node  pnpm  rust  podman  docker-compat  godot  claude-md  profile
    │   ├── codex
    │   ├── bash  awscli  gh
    │   └── hostname  power  softwareupdate  sshd
    └── templates/  env.zsh.j2  claude-rc-server.sh.j2  local.claude-rc.plist.j2
                    010-hardening.conf.j2  arrive-home.sh.j2  claude-md.j2  docker-shim.sh.j2
```

一個 repo、兩層（bring-up + Ansible）：兩層都是 Mac 專屬，bring-up 只有十幾行，拆兩個 repo 只多一次 clone。不併進 `dev-env-ansible`：那是 apt + systemd 的 Linux role，這台要管的多半是 pmset、sshd、launchd。

## tag 一覽

| tag | 層 | 做什麼 | `make uninstall` |
|---|---|---|---|
| `tmux` | user | brew | brew 移除（claude-rc 還在就拒絕） |
| `claude` | user | 官方 installer → `~/.local/bin/claude` | 刪入口與 `~/.local/share/claude`；`~/.claude` 永遠保留（claude-rc 還在就拒絕） |
| `claude-rc` | user | Remote Control：啟動腳本 + LaunchAgent + tmux（自動帶 tmux、claude、profile） | bootout、關 tmux、刪 plist 與腳本；DATA=1 刪 log |
| `tailscale` | user | 只檢查 GUI 版裝了沒（cask 是 .pkg、要 sudo，手動裝） | 手動（Makefile 印步驟） |
| `git-identity` | user | 全域 user.name / user.email | unset |
| `ssh-keys` | user | `id_ed25519_<tag>_<scope>` + `~/.ssh/config` managed block | 拿掉 block；**私鑰永遠不自動刪** |
| `authorized-keys` | user | 加入 `ssh_authorized_keys`；`ssh_authorized_keys_revoked` 裡的刪掉 | 拿掉列出的公鑰（sshd 只收金鑰時拒絕，防鎖死） |
| `arrive-home` | user | `~/bin/arrive-home.sh` | 刪 |
| `go` / `python` / `pnpm` / `podman` | user | brew（python = 只裝 uv）；podman 另外 `machine init`（不啟動） | brew 移除 + `brew autoremove`；DATA=1 刪快取、下載的 runtime、VM 磁碟 |
| `node` | user | 官方 tarball（SHASUMS256 驗證）→ `~/.local/node-<版本>`，`~/.local/node` symlink | 刪所有版本目錄；DATA=1 刪 `~/.npm` |
| `rust` | user | 官方 rustup-init `--no-modify-path` | 同 Linux 的拆法：`~/.rustup` 整包、`~/.cargo` 拆開；config/credentials 永遠保留 |
| `docker-compat` | user | brew `docker-compose`（`podman compose` 的 provider）、`~/.local/bin/docker`（`exec podman` 的 shim）、`containers.conf` 關掉 provider 提示。引擎與指令都是 podman | brew 移除、刪 shim（只刪自己放的）、拿掉設定；檔案空了就刪 |
| `godot` | user | 官方 zip（SHA512-SUMS 驗證）→ `~/Applications/Godot-<版本>.app`；`godot_versions` 列幾個裝幾個，清單外的刪掉；`godot-<版本>` 與 `godot` 指令 | 刪所有版本與指令（Godot 開著就拒絕）；DATA=1 刪編輯器設定與匯出範本 |
| `codex` | user | OpenAI 官方 release 的完整套件 `codex-package-aarch64-apple-darwin.tar.gz`（tag `rust-v<版本>`，`codex_version` pin，對官方的 `codex-package_SHA256SUMS` 驗證）→ `~/.local/codex-<版本>`，`~/.local/bin/codex` 是連到裡面 `bin/codex` 的 symlink；附屬程式（`codex-code-mode-host`、`rg`）留在套件裡。裝完與 `make verify` 都檢查 `codex-code-mode-host` 在 codex 會去找的位置而且起得來。easel 生圖用（easel 在 macOS 用內建 sips 做縮圖，只需要 codex）。登入是手動的事 | 刪 symlink（只刪自己放的）與所有 `~/.local/codex-<版本>`；`~/.codex` 拆開：`auth.json`、`config.toml`、`AGENTS.md`、`.env`、`sessions`（對話紀錄，easel 改圖要接回去）永遠保留，DATA=1 刪生出來的圖、輸入紀錄、log、快取、暫存；沒列到的不動並印出來 |
| `bash` | user | brew 的 bash 5。不改 PATH、不改 shebang：靠 `env.zsh` 把 `/opt/homebrew/bin` 排在 `/bin` 前面，`#!/usr/bin/env bash` 就拿到 5.x（`make verify` 檢查 ssh 與 launchd 兩種情境）。寫死 `/bin/bash` 的照舊是 3.2 | brew 移除（登入 shell 是它就拒絕，防鎖死） |
| `awscli` / `gh` | user | brew。登入是手動的事：`aws configure sso`、`gh auth login` | brew 移除；**登入設定與長期秘密永遠不自動刪**（`~/.aws/config`、`~/.aws/credentials`、`~/.config/gh`，同私鑰的理由）；DATA=1 只刪會自己過期的 SSO token 快取、gh 的擴充與快取 |
| `claude-guard` | system | 整台電腦層 `/Library/Application Support/ClaudeCode/managed-settings.d/mac-bootstrap.json` 的 `permissions.ask`：安裝類指令與 `sudo`，「指令開頭」與「前面接路徑」兩種寫法各一條 | 刪檔；目錄空了才刪 |
| `claude-md` | system | 整台電腦層 `/Library/Application Support/ClaudeCode/CLAUDE.md`：只有這台成立的細節（跨電腦的原則在 claude-config 的 `rules/tools-and-versions.md`）。固定文字，不看裝了什麼 | 刪檔；目錄空了才刪 |
| `profile` | user | `env.zsh`，由 `~/.zshenv` 與 `~/.zprofile` 各 source 一次 | 拿掉兩個 block、刪 env.zsh；rc 檔只剩空白就刪 |
| `hostname` | system | 三個 `scutil --set` | 沒有「移除」：改 config 的名字再 install（Makefile 印說明） |
| `power` | system | `pmset -c`（不同才改）、蓋子模式 | 收斂回 config 的 `mac_node_pmset_ac_original` |
| `softwareupdate` | system | 關掉自動安裝 macOS 更新 | 刪 key，回到系統預設 |
| `sshd` | system | `sshd_config.d/010-hardening.conf`（只收金鑰） | 刪檔 |

### 加一個項目

1. `tasks/<tag>.yml`；在 `main-user.yml`（或 `main-system.yml`）import，tag 掛 `[user, <tag>]`。它需要什麼，就把自己的 tag 掛到那些前置 import 上。
2. 影響 PATH 或環境變數 → `profile.yml` 的 stat 清單、`env.zsh.j2` 各補一段，並把 tag 加到 profile 那行 import。
3. `uninstall-user.yml` 補一段（tag 同名、登記 `_uninstall_data` / `_uninstall_keep` / `_uninstall_rmdir`），順序放在它相依的東西**之前**（移除是反向）。
4. `list.yml` 補一行；`verify.yml` 補檢查；brew 套件補到 `mac_node_brew_allowed_formulae`，App、.pkg、plist、`~/.local/bin` 的執行檔補到對應的 `mac_node_allowed_*`。
5. 實測：`make check` → `make install` → 再跑一次要 `changed=0` → `make uninstall` → `make uninstall DATA=1` 後確認沒有殘留 → 再裝回來。

## 慣例

- 裝不裝由 tag 決定，沒有布林開關。`make install` 不帶 TAGS = 全部；`make uninstall` 不帶 TAGS = 拒絕。
- 可用的 tag 從 playbook 投影（`--list-tags`），不手抄；`_check-tags` / `_check-uninstall-tags` 擋打錯字。
- 要不要 `-K`：Makefile 讀 play 名字以 `mac_node system` 開頭的那個 play 的 tag。**改 play 名字會壞掉。**
- PATH 只有一份：`~/.config/mac-bootstrap/env.zsh`（偵測式：看機器上實際有什麼）。安裝程式一律不准碰 rc 檔（`--no-modify-path`、brew 版）。
- 設定檔用 drop-in 或 managed block，不整檔覆寫。既有目錄只確保存在、不改權限（`~/Library/Logs`、`~/.claude`）。
- launchd 的冪等自己做：`launchctl print` 判斷，再 `bootout` / `bootstrap`（不用 `community.general.launchd`）。
- 下載的東西：先到暫存目錄、驗證、再整包搬過去；`--check` 時不下載，只報告「會下載」。
- 註解、commit、文件用繁體中文。LF。commit 結尾加 Co-Authored-By。

## 地雷（都踩過或實測過）

1. **macOS 內建 make 3.81 沒有 `.ONESHELL`** → bootstrap.sh 裝 GNU make 4.x，Makefile 開頭檢查 `.FEATURES`。用 `/opt/homebrew/opt/make/libexec/gnubin/make`，或 profile 套用後的 `make`。
2. **bash 3.2**：`$( )` 裡不能用 `case`（會 syntax error）→ 用 `[[ == ]]`。BSD 工具：`paste -sd' ' -`、`sed -i ''`、沒有 `grep -P`。
3. **ansible 底下的 bash，變數後面緊接中文會吃掉中文的第一個 byte** → 輸出不是合法 UTF-8，整個 task 炸掉。一律寫 `${var}`。
4. **ansible-core 2.21 的 Jinja 不處理字串裡的反斜線跳脫** → regex 只寫一個反斜線，而且寫在 YAML 的 `>-` 或單引號裡。
5. **OpenSSH 10.5 的 `sshd -T` 印 CamelCase**（`PasswordAuthentication no`）→ 轉小寫比對。不用 root 也能讀：`sshd -T -h <暫時主機金鑰>`。
6. **`tmux capture-pane -t =name` 找不到** → 寫 `=name:`。
7. **Desktop 的 Claude 工作階段漏約 40 個 `CLAUDE_*` / `ANTHROPIC_*` 變數** → Remote Control 只能由 launchd 起，腳本再 `env -i`。不要在 Desktop 工作階段裡（或用 `!`）跑 `claude remote-control`。
8. **PATH**：`ssh host 'cmd'` 只讀 `~/.zshenv`，起始 PATH 是寫死的 `/usr/bin:/bin:/usr/sbin:/sbin`；`zsh -l` 的 path_helper 會把 `.zshenv` 加的路徑排到後面 → 兩個檔都要 source。`/usr/local/bin` 這台不存在。
9. **profile 套用之前開的終端機視窗**拿不到新 PATH → `exec zsh -l` 或開新視窗。
10. **手機上的「裝置」名稱是主機名稱**（`hostname`），不是 `--name`；`--name` 只是預先開好的工作階段名字。
11. **`ansible.builtin.unarchive` 在 macOS 要 GNU tar** → 用 `/usr/bin/tar --strip-components`。**`tempfile` 在 `--check` 不給路徑** → 下載段落 check 時跳過。
12. **Homebrew 不能用 root**；cask 是 .pkg 的（tailscale-app）安裝要 sudo → 只能手動。
13. **第一次跑 Ansible 會跳「允許 Python 尋找區域網路上的裝置」**（gather_facts 查主機名稱觸發）→ 本機模式不需要，按不允許。
14. **Windows 內建 OpenSSH 9.5 的 `ssh-keyscan` 會選 sntrup761 再自己報錯** → Windows 上比對指紋用 `ssh -v`。
15. **睡著的機器叫不醒**（Wi-Fi 上的網路喚醒不可靠）→ 接電永不睡、只關螢幕。**開機解鎖前什麼都沒起來**：GUI 版 Tailscale、LaunchAgent 都要等 GUI 登入。
16. **macOS 的 `pgrep` 預設不列出自己的上層程序** → 從手機開的工作階段是 remote-control 伺服器的子程序，用 `pgrep` 找伺服器永遠找不到。一律 `pgrep -a`。
17. **Remote Control 畫面上的 `Connected` 只在一開始印一次**，跑久了會被 `Reconnected after …` 的紀錄擠出畫面 → 判斷連線看伺服器程序有沒有 443 的 ESTABLISHED（`lsof -a -p <pid> -iTCP:443 -sTCP:ESTABLISHED`）。
18. **`make … EXTRA='-e {"k":[…]}'` 的 JSON 會被 shell 拆掉**（recipe 裡沒加引號，雙引號被吃掉，什麼都沒覆蓋也不報錯）→ 臨時覆蓋變數寫成檔案：`EXTRA="-e @/tmp/x.yml"`。
19. **verify 不准有副作用**：`cargo install --list` 會建出空的 `~/.cargo/.crates.toml` / `.crates2.json`；`pnpm ls -g` 會建出 `~/Library/pnpm/bin` → 直接讀它們的清單檔。
20. **Go 的 `toolchain` 只會往新版切**：go.mod 寫比主機舊的版本不會降版，要舊版得帶 `GOTOOLCHAIN=go1.x.y`。**pnpm 的 devEngines.runtime 只對 `pnpm exec` / `pnpm run` 生效**，直接打 `node` 還是主機的。
21. **Claude 的規矩與護欄分三層，依「管到誰」放**：每台電腦都成立的放個人層（`~/.claude`，由 claude-config 共用到 Mac、WSL、Windows）；只有這台成立的放整台電腦層（`/Library/Application Support/ClaudeCode/`，這個 repo 的 system 層）；只有某個 repo 成立的放那個 repo。**這個 repo 不准寫 `~/.claude`**（那是共用 repo 的連結）。整台電腦層只用最高的 managed 來源：有 MDM 描述檔或組織後台政策時，這裡的檔會被整個略過。
22. **護欄規則開頭不要加 `*`**：`Bash(*sudo *)` 連引號裡的文字也比對到（實測 `grep "要 sudo 的"` 被攔）。用「指令開頭」與「`*/` 接路徑」兩種寫法。
23. **`codex` 每次執行都會寫 `~/.codex`**，連 `--version` 也是：解析參數之前就先建 `$CODEX_HOME/tmp/arg0-macos`（讀 0.167.0 的 `codex-rs/arg0/src/lib.rs` 確認）。只是要讀版本（安裝後的斷言、`make verify`）就給它一個用完即丟的 `CODEX_HOME`。
24. **只放 `codex` 一個執行檔（單檔版）生不了圖**（2026-11-16 實測）：內建的 image_gen 走 code mode，要另一支 `codex-code-mode-host`；單檔版 `codex --version` 正常，生圖時才報「failed to spawn code-mode host …: host executable was not found」。一定要裝完整套件（`codex-package-*`）。codex 找它的規則在 `codex-rs/install-context/src/lib.rs`：把自己的路徑解到底（symlink 會解開），所在目錄叫 `bin`、上一層有 `codex-package.json` 才算套件配置，再找 `codex-resources/`、`bin/`。檢查要看「easel 真正要的東西在不在」，不是「`--version` 會不會動」；檢查內容只有一份，在 defaults 的 `mac_node_codex_*_probe`。

## 手動的事（刻意不自動化）

| 步驟 | 為什麼 |
|---|---|
| 遠端登入（只允許自己）、螢幕共享；不開「遠端使用者完全取用磁碟」 | 命令列開要給終端機完整磁碟取用權限，不划算 |
| Tailscale 安裝（.pkg）、登入、登入時啟動；UniFi 的 DHCP 保留 | sudo / 帳號 / 別台設備 |
| `claude auth login`；第一次手動跑 `claude remote-control` 回答開啟與信任 | 帳號 OAuth；要真的終端機 |
| 公鑰貼到 GitHub；別台機器的公鑰貼進 `config.yml` | 帳號 / 別台設備 |
| `aws configure sso`（或從別台搬 `~/.aws/config`）、`aws sso login`；`gh auth login` | 帳號 OAuth；`make verify` 只提醒設定在不在 |
| `codex login`（ChatGPT 帳號；或讓 easel 第一次開面板時帶你用裝置碼登入，要先在 ChatGPT 的安全性設定開啟裝置碼登入） | 帳號 OAuth |
| Claude Desktop 的設定（登入時開啟、保持喚醒、Computer use、Dispatch、Trusted devices） | GUI / 帳號 |
| Chrome 遠端桌面 | 已在跑；只在 `make verify` 檢查 |
| 重開機實測（FileVault 的 SSH 解鎖、登入畫面能不能從外面過） | 要人在場 |

## 還沒做 / 待決定

- 子網路路由放 NAS 還是之後的 Mac mini（重開機實測後決定）；朋友連家裡服務的 Tailscale 存取規則（先改成明確允許清單再讓人進來）。
- arrive-home 要開哪些 App、iPhone 捷徑；HANDOFF 階段 7 的排程任務。
