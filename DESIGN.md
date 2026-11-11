# DESIGN：這台 Mac 的 IaC 做法（提案，待 Miska 確認）

> 狀態：**提案**。確認後，「架構決策」和「慣例」兩節搬進 `CLAUDE.md`，當作之後所有改動的依據。
> 調查日期：2026-11-12。依據：`dev-env-ansible`、`wsl-bootstrap` 兩個 repo 的現行慣例，加上這台機器的實測和官方文件。
> 每一條都標了來源：**［實測］** 在這台跑過、**［文件］** 官方文件、**［社群］** 只有社群回報、**［待驗］** 實作時要先驗證。

## 1. 這台機器

| 項目 | 值 | 來源 |
|---|---|---|
| 機型 | MacBook Pro 16 吋（Mac16,5），M4 Max 16 核 CPU / 40 核 GPU，64 GB，1 TB | ［實測］ |
| 系統 | macOS 27.2.1，arm64，FileVault 開 | ［實測］ |
| 已有 | Command Line Tools、git 2.54、GNU make **3.81**、bash **3.2**、python 3.9.6 | ［實測］ |
| 沒有 | Homebrew、tmux、Ansible、Claude Code CLI、Tailscale | ［實測］ |
| sudo | 要密碼（WSL 那邊是免密碼，這台不是） | ［實測］ |

## 2. 分層：沿用 Windows 那邊的兩層，但放在同一個 repo

| 層 | Windows / WSL | 這台 Mac |
|---|---|---|
| bring-up（一次性、平台專屬） | `wsl-bootstrap`：`bootstrap.ps1` + `provision.sh` | `bootstrap.sh` |
| 組態（冪等、可重跑） | `dev-env-ansible`：`make install TAGS=…` | 同一個 repo 裡的 Ansible role `mac_node` |
| 機器專屬的值 | `config.ps1`（gitignored）+ `config.example.ps1` | `config.yml`（gitignored）+ `config.example.yml` |

**為什麼不拆成兩個 repo**：Windows 拆開是因為 Ansible role 要跨任何 Linux 主機用，不該綁在 WSL 專屬的 bring-up 上。這裡兩層都是 Mac 專屬，bring-up 又只有十幾行，拆開只會多一次 clone。

**為什麼不併進 `dev-env-ansible`**：那個 role 是 apt 加 systemd 的 Linux role，而這台要管的幾乎都是系統設定（pmset、sshd、launchd、主機名稱），不是開發工具。硬併進去，每個 task 都要加作業系統判斷。之後這台如果要裝 Go / Node / Python 這類開發工具，再決定是在 `dev-env-ansible` 加 Darwin 支援，還是在這裡加 tag。現在沒有需求，先不做。

### bring-up 只做 Ansible 做不了的事

1. 裝 Homebrew（要 sudo、要互動，也是之後所有東西的前提）。
2. 用 brew 裝 GNU make 4.x（原因見 §6 地雷 1）。
3. 印出下一步：`make init`。

跟 WSL 一樣，Ansible 本身不由 bring-up 裝，由 Makefile 的 `_ensure-ansible` 補。

**跟 `wsl-bootstrap` 不同的地方**：git 身分和 SSH key 不放 bring-up，改成 Ansible 的 tag（`git-identity`、`ssh-keys`）。WSL 那邊放 bring-up 是因為要先有 key 才能 clone 私有的組態 repo；這台的 repo 已經在本機，沒有這個先後問題，所以 bring-up 可以不讀任何設定檔。命名仍沿用 `wsl-bootstrap`：`id_ed25519_<tag>_<scope>`，註解 `<user>@<環境>-<scope> <日期>`，`~/.ssh/config` 用 managed 區塊。公鑰只印出來，貼到 GitHub 是手動。

## 3. repo 結構

```
mac-bootstrap/
├── CLAUDE.md                 # 架構決策、慣例、地雷（本文件確認後搬過去）
├── README.md
├── HANDOFF.md                # 原始需求，保留不改
├── bootstrap.sh              # bring-up
├── config.example.yml        # 機器專屬值的範本；config.yml 不進版控
├── Makefile                  # init / list / check / install TAGS= / facts / verify
├── ansible.cfg
├── site.yml                  # 兩個 play：user 層（不用 sudo）、system 層（become）
├── inventory/hosts.yml       # 只給 LOCAL=0 用；預設打 localhost
└── roles/mac_node/
    ├── defaults/main.yml
    ├── tasks/
    │   ├── main-user.yml     # user 層的 import，一個 import 一個 tag
    │   ├── main-system.yml   # system 層的 import
    │   ├── detect.yml  list.yml  verify.yml
    │   ├── tmux.yml  tailscale.yml  claude.yml  claude-rc.yml
    │   ├── arrive-home.yml  authorized-keys.yml  profile.yml
    │   └── hostname.yml  power.yml  softwareupdate.yml  sshd.yml
    └── templates/
        ├── claude-rc-server.sh.j2
        ├── local.claude-rc.plist.j2
        └── 010-hardening.conf.j2
```

已經寫好的 `install.sh`、`bin/`、`launchd/`、`ssh/` 會搬成 templates，`install.sh` 由 Ansible 取代。

## 4. tag 對照（HANDOFF 的每個階段落在哪裡）

| tag | 層 | 做什麼 | 冪等方式 |
|---|---|---|---|
| `tmux` | user | brew 裝 tmux | `community.general.homebrew`，`state: present` |
| `tailscale` | user | brew cask 裝 GUI 版 | `homebrew_cask`。登入和「登入時啟動」手動 |
| `claude` | user | 官方 installer 裝到 `~/.local/bin` | `creates:` 加 `set -o pipefail`，同 `dev-env-ansible` |
| `claude-rc` | user | 啟動腳本、Remote Control 設定檔、LaunchAgent。自動帶 `tmux`、`claude` | template；先 `launchctl print` 看有沒有載入，沒有才 `bootstrap`；plist 有變才重載 |
| `arrive-home` | user | `~/bin/arrive-home.sh` | template |
| `authorized-keys` | user | `~/.ssh/authorized_keys`，公鑰來自 `config.yml` | `ansible.posix.authorized_key` |
| `git-identity` | user | 全域的 `user.name` / `user.email` | `community.general.git_config` |
| `ssh-keys` | user | 對外用的 key（GitHub 等）和 `~/.ssh/config` 的 managed 區塊 | key 已存在就跳過；`blockinfile` |
| `profile` | user | `~/.zprofile` 唯一一個 managed block | `blockinfile`；內容看機器上實際有什麼，不看開關 |
| `hostname` | system | 三個 `scutil --set` | 先 `scutil --get`，不同才改 |
| `power` | system | `pmset -c …`，蓋子選項由變數決定 | 先讀 `pmset -g custom`，不同才改 |
| `softwareupdate` | system | 關掉自動安裝 macOS 更新 | `osx_defaults`（system domain） |
| `sshd` | system | `/etc/ssh/sshd_config.d/010-hardening.conf` | template 加 `validate`；事後 `sshd -T` 斷言三個值 |
| `list` | — | 有哪些項目、這台已經有哪些（唯讀） | `[list, never]` |
| `verify` | — | 驗收清單裡能自動檢查的部分（唯讀） | `[verify, never]` |

`make verify` 對應 `wsl-bootstrap` 的 `scripts/verify.sh`。它檢查：pmset 的值、`sshd -T`、FileVault 開著、22 和 5900 埠有在聽、tmux 的 `claude-rc` session 存在、LaunchAgent 已載入、claude 可執行、登入 shell 裡沒有那三個會弄壞 Remote Control 的環境變數。

### 不進 IaC、維持手動的事

`make init` 會把這些印成清單，`make verify` 能檢查的就檢查，沒做會報錯提醒。

| 手動步驟 | 為什麼不自動化 |
|---|---|
| 開「遠端登入」和「螢幕共享」 | 用命令列開，呼叫它的程式要有「完整磁碟取用權限」［文件］。為了一個開關給終端機這麼大的權限不划算 |
| Tailscale 登入、UniFi 的 DHCP 保留 | 帳號登入和別台設備 |
| Chrome 遠端桌面 | 已經裝好而且在跑［實測］。它有自己的 LaunchAgent（`/Library/LaunchAgents/org.chromium.chromoting.plist`），註冊要 Google 帳號和 PIN。IaC 不安裝也不設定它，只在 `make verify` 檢查它還在 |
| Claude Desktop 的各項設定、`/login`、Trusted devices | 都是帳號層的 OAuth 或 GUI 設定。同 `wsl-bootstrap` 的原則：平台憑證不帶進自動化 |
| 第一次手動跑 `claude remote-control` 回答兩個 y | 要真的終端機 |
| iPhone 捷徑、FileVault 重開機實測 | 在別的設備上，或要人在場 |

## 5. sudo 怎麼處理

這台 sudo 要密碼，HANDOFF 也規定 sudo 由 Miska 自己執行。做法：

- `site.yml` 分成兩個 play。**user 層**不用 sudo，**system 層**整個 play 開 `become`。
- Makefile 用 `--list-tags` 讀出 system 層有哪些 tag（從 playbook 投影，不手抄）。這次要跑的 tag 有碰到 system 層，才加 `-K`，Ansible 會在你的終端機問一次密碼。
- 分工：user 層的 tag 和所有 `make check`、`make verify`，Claude 可以直接跑。system 層的 `make install TAGS=…` 由 Miska 在終端機跑。密碼只進 Ansible 的提示，不經過 Claude，也不存檔。

［待驗］`--check` 對 system 層需不需要密碼。`sshd -T` 要 root，可能得把它排除在 check 之外。

## 6. Mac 專屬的地雷

1. **內建的 make 是 3.81，不支援 `.ONESHELL`**［實測版本］。`dev-env-ansible` 的 Makefile 整份靠 `.ONESHELL`，直接搬過來，多行 recipe 會被拆成一行一個 shell，變數全部失效，而且不會報錯。做法：bring-up 用 brew 裝 make 4.x，並把它的 `gnubin` 放進 `~/.zprofile` 的 PATH。Makefile 開頭檢查 `$(.FEATURES)` 有沒有 `oneshell`，沒有就直接 `$(error …)`。
2. **內建的 bash 是 3.2，工具是 BSD 版**［實測］。`paste -sd' '` 要補 `-`，`sed -i` 要寫成 `sed -i ''`，沒有 `grep -P`。Makefile 和 shell task 只用兩邊都通的寫法。
3. **Homebrew 不能用 root 跑**。brew 的 task 只放 user 層。
4. **本機連線要指定 Python 直譯器**：`ansible_python_interpreter: "{{ ansible_playbook_python }}"`。不指定的話，Ansible 可能挑到系統的 python 3.9.6，跟 brew 那份 Ansible 用的不是同一個。［待驗］
5. **Desktop 的 Claude 工作階段會漏環境變數**［實測］。環境裡有約 40 個 `CLAUDE_*` / `ANTHROPIC_*` 變數，包括 `ANTHROPIC_BASE_URL`、`CLAUDECODE`、`CLAUDE_CODE_SESSION_ID`；乾淨的登入 shell 和 launchd 都沒有。所以 Remote Control 伺服器**只能由 launchd 啟動**。在 Claude 工作階段裡手動跑啟動腳本，tmux 會繼承這些變數，Remote Control 就壞了。啟動腳本另外用 `env -i` 起乾淨環境當第二道保險（逐一 `unset` 擋不完）；`make verify` 會直接檢查伺服器程序的環境。
6. **LaunchAgent 的登入 shell 只讀 `.zprofile`**。腳本裡的執行檔一律寫絕對路徑。
7. **launchd 的冪等要自己做**。`community.general.launchd` 走的是舊的 `load` / `unload`。這裡改用 `launchctl print gui/<uid>/<label>` 判斷，再決定要不要 `bootstrap` 或 `bootout`。［待驗］
8. **開機解鎖之前什麼都還沒起來**。GUI 版 Tailscale、LaunchAgent、Claude Desktop 都要等 GUI 登入。只有開源版 `tailscaled` 能在登入前啟動，也只有它能當 Tailscale SSH 的伺服器［文件］。
9. **FileVault 的 SSH 解鎖**：Apple silicon 加 macOS 26 以上、開了遠端登入、有網路就能用［文件］。「一定要有線網路」只有社群回報［社群］。這台現在只有 Wi-Fi，要到 HANDOFF §9 實測才知道。
10. **睡著之後沒有可靠的遠端喚醒方式**。網路喚醒要同一個區網送封包，Wi-Fi 上不可靠［社群］；Tailscale、Chrome 遠端桌面、SSH 都叫不醒睡著的機器。所以做法是接電時永不睡眠（`sleep 0`），只讓螢幕關。蓋上蓋子或拔掉電源就會睡，那時只能到現場處理。
11. **Chrome 遠端桌面是 HANDOFF 沒列的第二條 GUI 通道**［實測］。它的 LaunchAgent 掛在 `Aqua` 和 `LoginWindow` 兩種工作階段，照設定在登入畫面就會啟動，而且走 Google 的中繼，不靠 Tailscale。FileVault 解鎖之後、GUI 登入之前，它有可能是從外面連進來登入的路。［待驗］HANDOFF §9 重開機實測時一起測。
12. **brew 的名稱會改**：Tailscale GUI 版的 cask 名稱先用 `brew info --cask` 確認再寫進 task。Ansible 是裝 `ansible`（含 community.general）還是 `ansible-core` 加 collection，也先用 `brew info` 確認。［待驗］

## 7. Remote Control 的設定也進版控

這台 CLI 的 `claude remote-control`（2.1.321）［實測］：

- `--name` 和 `--spawn same-dir|worktree|session` 都存在，HANDOFF 的寫法可用。
- 有 `--settings <file>`：給遠端工作階段用的設定檔，只在啟動時讀一次。說明文字要求放在工作階段寫不到的地方。
- 有 `--permission-mode`、`--capacity`（預設 32）。

做法：權限規則（`permissions.deny` / `ask`）寫成 template，由 Ansible 放到固定位置，啟動腳本用 `--settings` 指過去。這樣遠端工作階段能做什麼，是版控裡看得到的一份檔案，不是散在 `~/.claude` 裡。

## 8. 沿用的慣例（跟 `dev-env-ansible` 相同，不重新論證）

- 裝不裝由 tag 決定，沒有布林開關。沒有「無條件裝」的東西。
- 一個項目一個 task 檔。相依關係用 tag 表達。
- 指令介面只有 `make install TAGS=…`，不帶 TAGS 就是全部。`_check-tags` 擋打錯字。
- `make init` 只補 Ansible，並印出下一步。
- 可安裝的清單從 playbook 投影（`make list`），不手抄。
- `curl | bash` 類一律 `creates:` 加 `set -o pipefail`。
- 設定檔用 `.d` drop-in 或 managed block，不整檔覆寫。
- fact 一律用 `ansible_facts.*`。
- 註解、commit 訊息、README 用繁體中文。`.gitattributes` 全 LF。

## 9. 乾淨原則：主機只留最少的東西（Miska 2026-11-12 要求）

這台會被遠端的 Claude 工作階段拿來做各種開發，沒有人盯著時最容易越裝越髒。原則和 Linux 那邊一樣：**主機乾淨，開發用的東西隔離起來跑**。

**主機上允許有的東西**只有 §4 的 tag 裝的那些，加上 bring-up 的 Homebrew 和 make。要多裝一樣，就要多一個 tag，並說得出為什麼不能放進容器。

**隔離的手段**

| 需求 | 做法 |
|---|---|
| 同一個 repo 平行做幾件事 | git worktree。Remote Control 對主要的 repo 用 `--spawn worktree` |
| 專案要某個語言或某個版本 | 放進容器，或用語言自己的機制裝在專案目錄裡（uv 的 `.venv`、Go 的 `GOTOOLCHAIN`、專案內的 `node_modules`）。不裝通用版本管理器，同 `dev-env-ansible` |
| 資料庫、訊息佇列這類服務 | 容器，不裝在主機 |

**容器 runtime 還沒選**［待定］。Mac 上跑 Linux 容器一定要經過一台虛擬機，候選是 podman machine（指令和 Linux 那邊完全一樣）和 Apple 自己的 `container`。等第一個真的需要容器的專案出現再選、再加 tag，現在不先裝。

**怎麼防止越裝越髒**

1. **`make verify` 加一項漂移檢查**：把 `brew leaves` 和 `brew list --cask` 跟 playbook 宣告的清單比對，多出來的列出來。這樣「有人手動裝了東西」會被看到。只報告，不自動移除（同 `dev-env-ansible`「不替你做移除的決定」）。
2. **遠端工作階段的權限規則**（§7 的 `--settings` 檔）：`brew install`、`npm install -g`、`pip install`（不在虛擬環境裡）、`sudo` 設成要詢問，不能默默執行。
3. **寫進給 Claude 的指示**：這台的 `~/.claude/CLAUDE.md` 放一段同樣的原則，由 Ansible 管（managed block）。遠端工作階段開始時就會讀到。
4. **移除有路可走**：比照 `dev-env-ansible` 的 `make uninstall TAGS=…`，role 自己放的檔案可以點名移除。

## 10. 要 Miska 決定的事

1. **分層和 repo**：同意 §2 的「一個 repo、兩層」嗎？
2. **公開或私人**：另外兩個 repo 是公開的。建議這個也照同樣方式設計：機器專屬的值（主機名稱、IP、公鑰）只放 gitignored 的 `config.yml`，追蹤的檔案裡沒有任何這台的資訊。`SETUP-LOG.md` 會記 IP，要嘛也 gitignore，要嘛 repo 維持私人。
3. **git 身分和 GitHub 的 SSH key**：HANDOFF 只說 git 身分設在這個 repo。但遠端工作階段會在 `~/Developer` 底下別的 repo commit 和 push，所以建議照 `wsl-bootstrap` 的做法，bring-up 就設全域身分並生成 key。
4. **`config.yml` 的值**：主機名稱、蓋子選項（A / B / C）、Remote Control 根目錄、SSH key 的 tag 和環境名稱（例如 `miskawu@home-mac`）。
