# 語言和工具版本怎麼管理（調查報告）

> 調查日期：2026-11-12。對象：這台 MacBook Pro（M4 Max、64 GB、macOS 27.2.1 build 26B131）。
> 範圍：只調查，不實作。主機上沒有安裝任何東西，也沒有改設定或 dotfiles。實測只用唯讀指令；需要模擬 shell 時，用 `env -i` 加上暫存目錄當 `ZDOTDIR`。
> 來源等級：**［實測］** 在這台跑過；**［文件］** 官方文件、官方原始碼或官方 release notes；**［社群］** 只有社群回報（含廠商自家部落格的效能數字，一律註明「非官方」）；**［待驗］** 還沒確認，實作時要先驗。
> 我親自用第一手來源複核過的說法，列在附錄 A。其他是子代理查的，來源連結都在附錄 B。

---

## 1. 一句話結論

**維持「不裝通用版本管理器」。** Go、Python、Rust 照 Linux 的做法，用語言自己的機制。Node 釘一個 LTS（26），從官方 tarball 放進使用者目錄；專案需要別的版本時，交給 pnpm 的 `devEngines.runtime` 按專案下載，再不行才進容器。容器 runtime 選 brew 裝的 **podman machine**，不裝 mac-helper。PATH 不比照 Linux 那樣 symlink 進 `/usr/local/bin`，改用 `~/.zshenv` 加 `~/.zprofile` 兩個 managed block。

---

## 2. 建議總表

| 類別 | 裝在哪裡、怎麼裝 | 專案怎麼宣告版本 | 不同專案不同版本時怎麼切 | 整個移除要刪什麼 | 理由 |
|---|---|---|---|---|---|
| **Go** | brew `go`（1.27.4，跟上游最新版一致）。只當 bootstrap 用 | `go.mod` 的 `go`（下限）和 `toolchain` 兩行 | 預設 `GOTOOLCHAIN=auto`：`go` 指令自動下載更新的 toolchain 並改用它。**只會往上切，不會往下** | `brew uninstall go`。資料：`~/go`（模組快取是唯讀，先 `go clean -modcache`）、`~/Library/Caches/go-build`、`~/Library/Application Support/go` | ［文件］go.dev/doc/toolchain。brew 版不改 `go.env`，所以 `auto` 照樣生效［文件］。沒有相依套件，也不是 keg-only［實測 brew API］ |
| **Python** | brew `uv`（0.13.7）。主機層**不裝** Python | `.python-version`（`uv python pin`）加上 `pyproject.toml` 的 `requires-python`，以及 `uv.lock` | `uv run` / `uv sync` 讀到宣告就自動下載 python-build-standalone（`python-downloads` 預設 `automatic`） | `brew uninstall uv`。資料：`~/.cache/uv`、`~/.local/share/uv`（`python/`、`tools/`）、`~/.config/uv`，以及 `~/.local/bin/python3.X` 這些連結 | ［文件］docs.astral.sh/uv。macOS 上 uv 也用 XDG 路徑，不用 `~/Library`［文件］ |
| **Node** | 官方 tarball `node-v26.13.1-darwin-arm64.tar.xz`，對 SHASUMS256 驗證後解到 `~/.local/node-<版本>`，再用 `~/.local/node` symlink 指過去。`node_version` 明確 pin，不支援 latest | `package.json` 的 `engines.node`（下限）、`devEngines.runtime` | **npm 不切**：`devEngines` 的 `onFail` 只有 `warn` / `error` / `ignore`，不會下載［文件］。要切的話，交給 pnpm（下一列） | `rm -rf ~/.local/node ~/.local/node-*`（`npm i -g` 裝的也在裡面）。資料：`~/.npm` | 見 §3。不用 brew `node`（追最新 major，帶 19 個相依函式庫［實測 brew API］）；`node@24` 是 keg-only，2027-10 起標記淘汰［文件］；官方 .pkg 寫進 `/usr/local`，而且沒有官方的移除程序［文件］ |
| **pnpm**（選裝） | brew `pnpm`（12.18.0，Rust 原生執行檔，不需要 Node［文件］，沒有相依套件［實測 brew API］） | `packageManager` 或 `devEngines.packageManager`；`devEngines.runtime` 加 `onFail: "download"` | pnpm 10.14 起，照 `devEngines.runtime` 下載專案要的 Node，版本和 checksum 寫進 lockfile［文件］。pnpm 自己的版本由 `pmOnFail`（預設 download）切 | `brew uninstall pnpm`。資料：`~/Library/pnpm`、`~/Library/Caches/pnpm`、`~/.local/state/pnpm`、`~/Library/Preferences/pnpm` | 這是 Node 生態系裡唯一一個「專案宣告、工具自動抓」的機制，跟 uv 同一類。不裝 corepack：Node 25 起不再隨附［文件］ |
| **Rust** | 官方 rustup 腳本，`-y --no-modify-path --profile minimal -c rustfmt,clippy`，裝到 `~/.rustup`、`~/.cargo`。同 Linux | `rust-toolchain.toml`（`channel`，加上 `components = ["rustfmt","clippy"]`） | rustup 的 proxy（`cargo`、`rustc`）讀到 `rust-toolchain.toml` 就自動安裝（`RUSTUP_AUTO_INSTALL` 預設 1）。1.30 的計畫只拿掉子命令的隱性安裝，proxy 保留［文件］ | 同 Linux：`~/.rustup` 整包刪；`~/.cargo` 拆開刪，`config.toml` 和 `credentials.toml` 保留。**不用** `rustup self uninstall` | brew 的 `rustup` 是 keg-only、關掉 self-update、不再附 `rustup-init`，rustup 官方也不維護套件管理器的版本［文件］。linker 靠 Command Line Tools，這台已經有（clang 21）［實測］ |
| **容器** | brew `podman`（6.2.0，Mac 預設 provider 是 libkrun）加 `podman machine` | `devcontainer.json`、`compose.yaml`、Containerfile | 每個專案自己的映像檔 | 見 §4 | 見 §4 |
| **本地 AI（MLX、PyTorch MPS）** | 主機上，**每個專案一個 uv 專案**（`.venv` 放在專案裡） | 同 Python | 同 Python | 刪專案的 `.venv`；模型快取在 `HF_HOME`（預設 `~/.cache/huggingface`） | Linux 容器拿不到 Metal［文件］。見 §5 |
| **Xcode / Swift** | Command Line Tools（已經有，Swift 6.4.2）［實測］。完整的 Xcode 等真的需要再手動裝 | `.xcode-version`；SwiftPM 的 `swift-tools-version` | 每次執行用 `DEVELOPER_DIR=…` 指定，不用 sudo［文件］ | 見 §5 | 見 §5 |
| **通用版本管理器**（mise、asdf、nvm、fnm、volta、pyenv） | **不裝** | — | — | — | 見 §3 |

---

## 3. 「不裝通用版本管理器」：**維持**

### 3.1 Linux 那邊的理由，到了 macOS 還成不成立

| Linux 的理由（`dev-env-ansible` README 和 CLAUDE.md） | 在 macOS 上 | 證據 |
|---|---|---|
| Go 靠 `GOTOOLCHAIN=auto` | **成立**，行為完全一樣 | ［文件］go.dev/doc/toolchain。1.26、1.27 都沒有改語意 |
| Python 靠 uv，讀 `.python-version`，自動下載預編譯版 | **成立** | ［文件］uv 0.13.7。python-build-standalone 仍由 Astral 維護。0.12.12 起 macOS 版的 uv 有簽章和公證［文件］ |
| Rust 靠 rustup 讀 `rust-toolchain.toml`；rustup 是官方管道，不算「跨語言的外掛式管理器」 | **成立** | ［文件］proxy 的自動安裝在 1.30 計畫裡保留 |
| Node：前端專案宣告的多半是下限，一個 LTS 就夠；真的衝突就放進專案層的 devcontainer | **大致成立，但退路變貴了**。Mac 的容器在 VM 裡，bind mount 慢、收不到 inotify（§4） | 見 3.2 |
| nvm 和 fnm 靠 shell function 或 hook，非互動 shell 拿不到 | **更強**。macOS 上 `ssh host 'cmd'` 只讀 `~/.zshenv`，PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin` | ［實測］§6.1。nodejs.org 下載頁現在推薦的正是 nvm 和 fnm［文件］，所以下載頁的建議不適合這台 |
| volta 已不維護 | **成立**。它的 README 宣告不再維護、建議改用 mise；2026-01 也從 nodejs.org 下載頁拿掉了 | ［文件］ |
| mise 有 shims，技術上可行，但沒必要 | **仍然沒必要，而且多了風險**，見 3.3 | |

### 3.2 2026 年 Node 生態的變化：兩個方向都有

- **讓 Node 更難的變化**
  - Corepack 從 Node 25.0.0（2025-10-15）起不再隨附。TSC 在 nodejs/TSC#1697 投票的結果是 24.x 保留、25 起拿掉［文件］。官方給的替代做法是 `npm install -g corepack`［文件］。
  - npm 的 `devEngines`（10.9.0 起）只會檢查，`onFail` 只有 `warn` / `error` / `ignore`。npm 11、12 的文件都一樣，**沒有 `download`**［文件，親自複核］。npm 維護者在 npm/cli#8004 說過，不做 download 是因為安全疑慮［社群］。
  - Node core 拒絕內建版本切換。nodejs/node#62098 在 2026-03-09 以 wontfix 關閉［文件］。
- **讓 Node 更容易的變化**
  - pnpm 10.14 加入 `devEngines.runtime` 加 `onFail: "download"`，pnpm 會下載專案指定的 Node，版本和 checksum 寫進 lockfile［文件］。
  - pnpm 11 拿掉 `useNodeVersion`，改成 `pnpm runtime set`［文件］。
  - pnpm 12 用 Rust 重寫，是原生執行檔［文件，親自複核］。它新增 `globalShims`：**透過 pnpm 全域安裝的** `node`，在專案目錄裡會改跑該專案 pin 的版本。12.7 起也讀 `.node-version` 和 `.nvmrc`［文件，親自複核］。
    - 注意範圍：這只作用在用 pnpm 全域裝的 `node`。照本報告的設計，Node 由官方 tarball 提供，pnpm 不會接手它。
- **Node 的發行時程改了**［文件，親自複核 schedule.json］
  - 26「Lithium」從 2026-10-28 起是 Active LTS，支援到 2029-04-30。
  - 24「Krypton」從 2026-10-20 起進入 Maintenance。
  - 27 起每年一個 major，**每一版都會進 LTS**，不再分奇數版和偶數版。
  - 結論：Linux 那邊「`node_version` 不支援 latest」的理由（奇數版不進 LTS）從 27 起會失效。但新版仍然會先當 6 個月的 Current，所以 pin LTS 的做法不變。
- **交辦裡的一條既有說法要更正**：查不到「`packageManager` 和 `devEngines.packageManager` 同時存在時 npm 會拒絕」的文件或 changelog。拒絕的是 **pnpm**，它會發出警告，從 11.0.0-rc.3 起兩邊值相同時就不警告了；corepack 則是兩邊不一致時報錯［社群］。npm 的行為列為**［待驗］**。

### 3.3 mise 在 macOS 上的實際代價

1. **非互動 shell 要靠 shims，而 shims 有限制。** 官方的做法是在 `.zprofile` 加 `mise activate zsh --shims`［文件］。
   - 但 `ssh host 'cmd'` 根本不讀 `.zprofile`［實測］，所以還是得把 `~/.local/share/mise/shims` 放進 `~/.zshenv`。這跟不裝 mise 時要做的事一樣，mise 沒有省掉這一步。
   - shims 模式下，`[env]` 和 hook 都不會執行，`command -v` 會誤判有這個指令，找不到時還可能退回系統裡的同名執行檔［文件］。
2. **信任機制和遠端工作階段相衝。**
   - 遇到含 env、templates 這類內容、而且還沒信任的設定檔，mise 在不能互動時會直接報錯［文件］。
   - 這台會由遠端的 Claude clone 各種 repo 來跑，等於每個帶 `mise.toml` 的 repo，都要先決定信不信任它。
3. **安全公告集中在 2026 年。** GitHub 上 jdx/mise 列了 14 則公告，好幾則是**信任機制被繞過**或 `GITHUB_TOKEN` 外洩：
   - GHSA-fjj5-v948-whjj（Critical，`.tool-versions` 的 Tera 模板繞過信任）
   - GHSA-6986-cq7v-7cj9
   - GHSA-43hx-4j66-v486（未受信任的設定能把 repo 目錄排到 PATH 最前面）［文件］
   - 對這台「常 clone 外部 repo、沒有人盯著」的使用方式，這正是最在意的那一類風險。
4. **對 Python 和 Rust 沒有加分。**
   - mise 的 Python 也用 python-build-standalone，跟 uv 是同一個來源［文件］。
   - mise 的 Rust 是「先裝 rustup 再交給它」，工具鏈仍然放在 `~/.rustup` 和 `~/.cargo`［文件］。
   - 所以 mise 真正多給的，只有 Node 的版本切換，和讀別人 repo 裡的 `.tool-versions` / `mise.toml`。
5. **變動快，管的範圍也越來越大。**
   - 幾乎每天發版（2026-11-02 到 11-10 之間出了 5 版）［文件］。
   - v2026.11.1 的 lockfile v4 格式，舊版讀不了［文件］。
   - 已經做到裝 brew 套件（`[bootstrap.packages]`）和 dotfiles（`mise dot`），跟 Ansible 的職責重疊［社群］。
6. **idiomatic 版本檔預設不讀。** v2025.10.0 起 `idiomatic_version_file_enable_tools = []`，`.nvmrc`、`.python-version` 要自己打開［文件］。也就是說，它的「零設定相容」也不再是預設行為。

### 3.4 判斷

**維持**，並把 Node 的處理順序寫清楚：

1. **預設**：一個 pinned LTS（26.x）。前端專案大多宣告下限，這和 Linux 的實測結論一樣。
2. **專案用 pnpm**：在專案裡寫 `devEngines.runtime`，加上 `onFail: "download"`，由 pnpm 按專案抓 Node。這和 uv、rustup 同一個模式：專案宣告、工具下載、版本寫進 lockfile。
3. **只跑一次**：`pnx node@22 …`（pnpm 12）［文件］。
4. **npm 專案又要不同的 major**：放進 devcontainer（§4）。
5. **Yarn 專案**：不裝 corepack。pnpm 12 可以用 `pnx` 跑專案指定的 Yarn，或用 `pnpm shim add yarn` 建一個依專案切換版本的 `yarn` 指令；pnpm 不會自己建這個 shim［文件，親自複核］。

**Nix 不納入**：交辦已列出它的代價（建 APFS 磁碟區、建置用的使用者、移除偶爾失敗）［社群］，這次沒有重查。這些代價和「主機乾淨」直接衝突，也沒有找到能抵銷的理由。

**什麼時候要重新評估**：同時出現兩個以上「只用 npm、不能改用 pnpm、需要不同 Node major、而且在容器裡跑太慢」的專案。到那時再考慮加一個 `mise` tag，只管 node，打開 `paranoid`，並 pin mise 的版本。

---

## 4. 容器 runtime：**podman machine（brew 版，不裝 mac-helper）**

### 4.1 比較（2026-11 的現況）

| | podman machine | Apple `container` | OrbStack | Colima |
|---|---|---|---|---|
| 版本 | 6.2.0（2026-11-10）［文件］ | 1.7.1（2026-11-06）；1.0 在 2026-06 推出［文件］ | 2.2.5（2026-10-23）［文件］ | 0.10.3（2026-06-04，**之後 5 個月沒有新版**）［文件］ |
| 架構 | 一台共用的 Fedora VM。6.0 起 Mac 預設 libkrun（krunkit），也可以用 `--provider applehv` | **每個容器一台 VM**，由 `container-apiserver` LaunchAgent 加 XPC helper 管理 | 一台共用的 VM，跑 Docker engine | 一台 Lima VM（vz），跑 rootful dockerd |
| devcontainer | 可以：VS Code 文件寫「Podman 5+ 大致相容」；用 `DOCKER_HOST` 或 `--docker-path podman`［文件］ | **不行**：沒有內建 Docker API；第三方的 socktainer 自己寫「部分相容」［社群］ | 可以［文件］ | 可以［文件］ |
| Compose | 透過 Docker 相容 API（6.0 起 v1.44）［文件］ | 沒有內建，上游的 PR 都關了［社群］ | 可以 | 可以 |
| bind mount | virtiofs，預設掛 `$HOME:$HOME`。**主機的 inotify 事件傳不進容器**［社群，維護者回覆］；virtiofs 處理不了多個 uid/gid［社群］ | 每台 VM 一個 virtiofs，只能掛目錄［社群］ | VirtioFS 加自家快取。廠商說達原生的 75–95%（**非官方**，廠商自測）；2.2.2 修了檔案監看漏事件［文件］ | virtiofs；inotify 是實驗功能，預設關［文件］ |
| 效能參考 | 讀兩萬個檔：Podman 4.3 秒、Colima 3.3 秒、原生 0.34 秒（**非官方**，交辦已附）［社群］ | 無資料 | 見上 | 見左 |
| GPU | **有**：libkrun 走 virtio-gpu Venus，把 Vulkan 經 MoltenVK 轉到 Metal，只支援 compute［文件］。Red Hat 說可達原生的 75–80%（**非官方**）。不能跑 MLX 或 MPS | 沒有 | 沒有［文件］ | krunkit 模式（實驗）［文件］ |
| 授權 | Apache-2.0 | Apache-2.0 | **商用要付費**：自由接案、公司、非營利、政府用途，或用它做的工作年收超過 1 萬美元，都要買授權（每人每月 8 美元）［文件，親自複核］ | MIT |
| 常駐程式 | 機器開著時有 krunkit 加 gvproxy；停了就什麼都沒有。brew 版沒有 root 元件 | apiserver LaunchAgent 加每個容器一個 helper | App、VM 管理器；沒有 GUI 就不能自動更新［文件］ | Lima hostagent |
| 移除 | `podman machine reset -f`，再 `brew uninstall podman`，再刪 `~/.local/share/containers`、`~/.config/containers`、`~/.ssh/podman-machine-default*`［文件］ | 官方腳本 `uninstall-container.sh -d`［文件］ | cask 的 uninstall 加 zap，有八、九個位置要清，還要檢查 `/usr/local/bin` 的連結和 docker.sock［文件］ | `colima delete --data`，再 `brew uninstall colima lima`，再刪 `~/.colima`，再刪 docker context［文件］ |
| macOS 27 的已知問題 | #30080：大量平行建立、刪除容器時，`127.0.0.1` 的轉發埠偶爾收得到連線卻沒有資料，還沒有維護者回應［社群］ | **#2335：啟動容器網路後，Internet Sharing 會在 en0 載入 pf 的 `scrub … no-df` 規則，弄壞主機本身的 IPv4 對外連線**，容器停掉之後還會留著［社群］ | 2.2.4 修好了卡在「Starting」的問題［文件］ | #1664 TCP 逾時、#1660 埠轉發恢復不了［社群］ |

### 4.2 為什麼選 podman machine

1. **跟 Linux 同一套指令和模型**：rootless 加 `DOCKER_HOST`，`dev-env-ansible` 的 devcontainer 習慣可以直接沿用。
2. **brew 版不放任何 root 元件**。podman.io 推薦的 .pkg 會裝這些東西［文件］，brew 版都沒有：
   - root 的 LaunchDaemon（`podman-mac-helper`，用來管 `/var/run/docker.sock`）
   - `/etc/paths.d/podman-pkg`
   - `/opt/podman`
3. **官方有不需要 GUI 的自動啟動做法**：LaunchAgent 加 `RunAtLoad`、`AbandonProcessGroup=true`，**不能**加 `KeepAlive`，再用 `launchctl bootstrap gui/<uid>` 載入［文件，親自複核］。這跟 `claude-rc` 用的機制一樣。
4. **授權乾淨**（Apache-2.0）。四個候選裡，只有它和 Colima 在 GPU 上有一點用處（llama.cpp 走 Vulkan）。
5. **其他候選為什麼不選**：
   - **Apple `container`**：沒有 devcontainer 和 Compose。#2335 更會讓一台遠端節點把自己的對外網路弄壞。
   - **OrbStack**：技術上最好，但閉源，商用要付費，也需要 GUI。
   - **Colima**：可以用，但上游停更了 5 個月。

### 4.3 選了它的代價

- **VM 一直占記憶體**：機器開著就占用。64 GB 夠用，CPU、記憶體、磁碟的配額寫進 `config.yml`。
- **bind mount 慢**：做法是把 `node_modules`、`.venv`、`target` 放進 named volume，不走 bind mount［社群］。
- **主機改檔，容器裡的 watcher 收不到**：dev server 要改用 polling（`CHOKIDAR_USEPOLLING`、`WATCHPACK_POLLING`）［社群］。
- **uid 對應只有一個**：容器裡用多個使用者寫 bind mount 會出問題［社群］。
- **沒有 `/var/run/docker.sock`**：寫死這個路徑的工具會失敗，一律靠 `DOCKER_HOST`。socket 的實際路徑以 `podman machine inspect` 的 `ConnectionInfo.PodmanSocket.Path` 為準［待驗］。
- **brew formula 是社群維護的**：podman.io 自己這樣標註［文件］。
- **自動啟動要有 GUI 登入**：四個候選都一樣，跟 `claude-rc` 的限制相同（DESIGN §6.8）。HANDOFF §9 的重開機實測時一起測。
- **macOS 27 的 #30080**：遇到的話，改用 `--provider applehv` 重建機器［待驗］。
- **devcontainer CLI 要靠 Node**：`@devcontainers/cli` 是 npm 套件，所以要用 devcontainer，就要先有 `node` tag。

---

## 5. 主機上不得不裝的例外

### 5.1 本地 AI（MLX、mlx-lm、PyTorch MPS）

- **為什麼一定在主機**：Linux 容器沒有 Metal。Docker 官方部落格（2026-02）明說容器拿不到 Metal GPU passthrough；Docker Model Runner 在 macOS 上的推論引擎也不在容器裡跑；podman 的 libkrun 只給 Vulkan，不給 Metal［文件］。
- **怎麼隔離**：
  1. 每個 AI 專案都是一個 **uv 專案**，`mlx`、`torch` 寫在 `pyproject.toml`，裝在專案的 `.venv`，鎖在 `uv.lock`。主機上沒有全域的 pip、conda 或 miniforge。conda 本身就是另一套版本管理器，違反 §3。
  2. 直譯器一律用 uv 管理的原生 arm64 Python。**不能用 `/usr/bin/python3`**：它是 3.9.6［實測］，低於 MLX 要求的 3.10［文件］。PyTorch 2.15 的文件寫 MPS 要 macOS 15 以上［文件］。
  3. **模型快取集中在一個地方**：`HF_HOME`（預設 `~/.cache/huggingface`，hub、xet、token 都在底下）［文件］。不必搬位置，但 `make verify` 要報告它的大小。要關掉遙測，可以設 `HF_HUB_DISABLE_TELEMETRY=1`［文件］。
  4. **只要 llama.cpp 的話**，可以放進 podman 容器，經由 libkrun 的 Vulkan 跑，換取隔離，代價是效能折扣（Red Hat 說 75–80%，**非官方**）。MLX 不行。
- **移除**：刪專案的 `.venv`，加上 `HF_HOME`。不會留下別的東西。

### 5.2 Xcode / Swift

- **現況**［實測］：
  - Command Line Tools 27.2 已經有了：Swift 6.4.2、clang 21、`swift build` / `swift test`、Swift Testing。
  - 沒有 `xcodebuild`、`simctl`、XCTest。Apple 文件也寫明 `xcodebuild` 只在完整的 Xcode 裡［文件］。
  - 結論：只做 SwiftPM、而且目標是 macOS 的專案，**CLT 就夠了**。iOS app、模擬器、`.xcodeproj` 才需要完整的 Xcode。
- **完整的 Xcode 不進 IaC，維持手動**：
  - 要 Apple ID 加 2FA，裝完還要 sudo。xcodes 的 CLI 沒有說明怎麼處理 2FA，`mas` 要先在 App Store 登入［文件］。
  - 這跟 DESIGN §4「帳號層的事不自動化」一致。
- **多個 Xcode 並存**：
  - 放成 `/Applications/Xcode-<版本>.app`。
  - 專案用 `.xcode-version` 宣告版本。
  - **每次執行用 `DEVELOPER_DIR=/Applications/Xcode-X.app/Contents/Developer xcodebuild …` 指定，不用 sudo**（`man xcode-select`）［文件］。
  - 不要把 `sudo xcode-select -s` 當成日常切換的方式，它改的是全系統的設定。
- **swiftly**（官方的 Swift 工具鏈管理器，brew 版 1.2.0）：
  - 只有在需要非 Xcode 的開源 Swift 工具鏈時才裝。
  - 它的 `init` 會在 `.zprofile` 加一行 source［文件］，違反「只有一個 managed block」的規則，所以實作時要用參數關掉，或改由 Ansible 寫［待驗］。
  - 工具鏈放在 `~/Library/Developer/Toolchains`。`self-uninstall` 不會刪工具鏈，要先 `swiftly uninstall all`［文件］。
- **會越長越大的資料**：`~/Library/Developer/Xcode/DerivedData`、`~/Library/Developer/CoreSimulator/Devices`、`/Library/Developer/CoreSimulator`（runtime）。`make verify` 報告大小，`xcrun simctl delete unavailable` 只刪裝置紀錄，不刪 runtime［社群］。

---

## 6. 換成 Ansible tag 要怎麼切

tag 怎麼切，取決於 PATH 怎麼設，所以先回答「非互動 shell 拿不拿得到指令」（6.1–6.3），再列 tag（6.4）。

### 6.1 實測：三種情境的 PATH

| 情境 | 起始 PATH | zsh 讀哪些檔 | 來源 |
|---|---|---|---|
| LaunchAgent `/bin/zsh -l -c …` | launchd 的 `default environment`：`/usr/bin:/bin:/usr/sbin:/sbin` | `~/.zshenv`，然後 `/etc/zprofile`（跑 `path_helper`），然後 `~/.zprofile` | ［實測］`launchctl print` 加上模擬 |
| `ssh host 'cmd'` | `/usr/bin:/bin:/usr/sbin:/sbin`，這是 `/usr/libexec/sshd-session` 編譯時寫進去的字串 | **只有 `~/.zshenv`** | ［實測］字串比對加模擬；實際 ssh 還沒測［待驗］（遠端登入還沒開） |
| Claude 的 Bash 工具 | 繼承啟動 Claude 的那個程式的環境 | 非互動、非登入。工作階段開始時會 source `~/.zshrc`，抓下別名、函式和 shell 選項［文件，親自複核］。這台的 snapshot 裡有 `export PATH=…`［實測］ | Desktop 啟動時的環境等於 path_helper 的輸出［實測］；由 Remote Control 開的工作階段，則繼承 `claude-rc` 那個登入 shell 的環境 |

另外幾個實測結果：

- **`/usr/local/bin` 在這台根本不存在**。`/usr/local` 是 root 擁有的空目錄。但 `/etc/paths` 裡第一行就是它［實測］。
- **path_helper 會把既有的 PATH 往後排**。用一個暫存的 `.zshenv` 先放 `/opt/homebrew/bin` 和 `~/.local/bin`，登入 shell 跑完之後，這兩個被排到最後，`/usr/bin` 反而在前面［實測］。
  - 後果：`.zshenv` 裡放 GNU make 的 `gnubin`，到了登入 shell 會輸給 `/usr/bin/make`（3.81）。uv 的 `python3.X` 不會撞名，但 brew 的 `git` 會輸給 `/usr/bin/git`。
- **`/etc/paths.d/10-pmk-global` 指向 `/pkg/env/global/bin`**。`/pkg` 屬於 `com.apple.files.data-template`［實測］，是 macOS 26.4 加入的新 firmlink，用途不明，目前是空的［社群］。當成 Apple 保留的目錄，不要動。

### 6.2 Mac 上要不要比照 Linux symlink 進 `/usr/local/bin`？**不要**

1. **沒用**：ssh 和 launchd 的預設 PATH 本來就**沒有** `/usr/local/bin`［實測］，只有登入 shell 透過 path_helper 才會拿到它。到了那一步，`.zprofile` 早就能設 PATH 了。Linux 那招有效，是因為那邊每個情境的預設 PATH 都含 `/usr/local/bin`（`dev-env-ansible` README 的實測）；macOS 的 ssh 和 launchd 都沒有。
2. **要 sudo**：目錄不存在，`/usr/local` 又是 root 擁有。這會讓 user 層的 tag 多出 become。
3. **沒有任何使用者可寫、而且在所有情境下都在預設 PATH 裡的目錄**［實測］。

### 6.3 建議做法

- **`~/.zshenv` 加一個 managed block**：用靜態的 `path=(…)` 把 brew、`gnubin`、`~/.local/bin`、`~/.local/node/bin`、`~/.cargo/bin`、`~/go/bin` 加到前面，再加上 `DOCKER_HOST` 這類環境變數。
  - 這是**唯一一個** ssh、`zsh -l -c`、Claude 的 Bash 工具都會讀的檔［文件，zsh 手冊］。
  - 每個 zsh 都會讀它，包括 `#!/bin/zsh` 的腳本，所以內容要**沒有副作用、沒有輸出、不開子程序**。不要在裡面跑 `brew shellenv`。
- **`~/.zprofile` 的 managed block 再把同一組路徑加到前面一次**：專門處理 path_helper 的重排。實作上，兩個 block 可以 source 同一份由 Ansible 管的檔，加上 `typeset -U path` 去重複。
  - 這是對 DESIGN §4 `profile` tag 的修正：原本寫「`~/.zprofile` 唯一一個 managed block」。
- **launchd 直接啟動的程式**：照 DESIGN §6.6，一律用絕對路徑。
  - 不用 `launchctl config user path`：要重開機才生效、是持續的系統狀態，社群回報還要 sudo。
  - 不用 sshd 的 `SetEnv PATH=`：屬於 system 層，而且 `.zshenv` 已經夠用。
- **安裝程式不准碰 rc 檔**：
  - rustup 預設會**建立** `~/.zshenv`［文件］；uv 的安裝腳本會改 `.zshrc` 或 `.zshenv`；pnpm 的 `setup` 會改 `.zshrc`；swiftly 會改 `.zprofile`。
  - 所以一律加 `--no-modify-path` / `UV_NO_MODIFY_PATH`，或者直接用 brew 版。
- **驗證方式**：比照 Linux 的 `wsl -d dev -e`。`make verify` 在兩種模擬環境下各跑一次 `command -v <cmd>`：
  - ssh：`env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -c …`
  - launchd：同一行加 `-l`
  - 遠端登入打開之後，再補一次真的 `ssh localhost 'command -v …'`。
  - 用互動 shell 驗，一定是綠的，驗不出問題。

---

### 6.4 tag 建議（只寫設計）

沿用 DESIGN §8 的慣例：一個項目一個 task 檔，有沒有裝由 tag 決定。這些 tag 全部屬於 **user 層**，不需要 sudo。

| tag | 做什麼 | 相依 | 冪等和驗證 | `make uninstall`（預設 / `DATA=1`） |
|---|---|---|---|---|
| `go` | brew `go`，`state: latest`（對應 Linux 的 `go_version: latest`） | — | `go version`；`go env GOTOOLCHAIN` 等於 `auto` | `brew uninstall go` / `~/go`（先 `chmod -R u+w`）、`~/Library/Caches/go-build`、`~/Library/Application Support/go` |
| `python` | brew `uv`，`state: latest`。**不在主機層裝 Python**，也不用實驗中的 `--default` | — | `uv --version`；確認 `uv python list --only-installed` 是空的或符合預期 | `brew uninstall uv` / `~/.cache/uv`、`~/.local/share/uv`、`~/.config/uv`、`~/.local/bin/python3.*` |
| `node` | 官方 tarball，`node_version: "26.13.1"`，下載後對 SHASUMS256 驗證，解到 `~/.local/node-<版本>`，再把 `~/.local/node` symlink 切過去。舊版本目錄刪掉 | — | 用 `creates:` 擋重複下載；symlink 指錯才改；`node -v` 要等於 pin 的版本 | 刪 `~/.local/node*` / `~/.npm` |
| `pnpm` | brew `pnpm`。可以選擇用 Ansible 管 `~/Library/Preferences/pnpm/config.yaml`（例如 `globalShims: false`，見 §7） | — | `pnpm --version` | `brew uninstall pnpm` / `~/Library/pnpm`、`~/Library/Caches/pnpm`、`~/.local/state/pnpm`、`~/Library/Preferences/pnpm` |
| `rust` | 官方 `rustup-init`，`-y --no-modify-path --profile minimal -c rustfmt,clippy`，加上 Linux 那套收斂步驟：`toolchain install stable`，沒有 default 才 `rustup default stable` | CLT（bring-up 已經處理） | 同 Linux | 同 Linux 的拆分刪法 |
| `podman` | brew `podman`（相依的 krunkit 會一起裝）；`podman machine init`（rootless，CPU、記憶體、磁碟取自 `config.yml`）；選配 LaunchAgent，照官方 autostart 教學（`AbandonProcessGroup`，不加 `KeepAlive`）。**不裝** podman-desktop 和 mac-helper | — | 用 `podman machine inspect` 判斷機器在不在；LaunchAgent 沿用 DESIGN §6.7 的 `launchctl print` 判斷 | `podman machine reset -f`、拿掉 LaunchAgent、`brew uninstall podman` 再 `brew autoremove`（帶走 krunkit） / `~/.local/share/containers`、`~/.config/containers`、`~/.ssh/podman-machine-default*` |
| `devcontainer`（選裝） | 用 `npm i -g @devcontainers/cli` 裝進 Node 的 prefix | `node`、`podman` | `devcontainer --version` | 跟著 `node` 走 |
| `profile`（修改） | **`~/.zshenv` 和 `~/.zprofile` 各一個 managed block**，兩個 source 同一份 Ansible 管的檔。內容依「機器上實際裝了什麼」決定：例如偵測到 `~/.local/node/bin/node` 才加那一段，同 Linux 的 `profile.yml` | — | `blockinfile` | — |
| `verify`（擴充） | 在 §6.3 的兩種模擬環境下跑 `command -v`。漂移檢查：`brew leaves` 對照宣告的清單，加上 `npm ls -g`（Node prefix 裡）、`uv tool list`、`cargo install --list`、`ls ~/go/bin`、`pnpm ls -g`。報告大小：`HF_HOME`、DerivedData、podman machine 的磁碟 | — | 唯讀，`[verify, never]` | — |

**刻意不設的 tag**：`mise`、`nvm`、`fnm`、`volta`、`pyenv`、`corepack`、`orbstack`、`colima`、`container`、`xcode`、`mlx`。AI 專案用 uv 專案就好，Xcode 維持手動。

**跟 Linux 的差異和理由**：

- Go、uv、pnpm、podman 在 Mac 上改用 brew。brew 版跟上游同步、沒有額外相依［實測 brew API］，而且能被 `brew leaves` 的漂移檢查看到。
- Node 和 Rust 維持官方來源，原因見 §2。
- brew 的移除比 apt 安全：還有別的套件依賴它時，brew 會拒絕移除。所以 brew 裝的項目可以納入 `make uninstall`，不必像 Linux 那樣列成手動步驟。這是對 DESIGN 的建議［待驗：要確認 `brew uninstall` 的拒絕行為］。

---

## 7. 還沒定案、要 Miska 決定的事

1. **同意「維持不裝通用版本管理器」，以及 §3.4 的 Node 處理順序和重新評估的條件嗎？**
2. **Node 要 pin 26（現在的 Active LTS）還是 24？** 建議 26。24 從 2026-10-20 起已經進入 Maintenance。
   - 這也代表 Linux 那邊 `dev-env-ansible` 的 `node_version: "24.18.0"` 該跟著評估。那是另一個 repo，本報告沒有動，列為後續事項。
   - 另外，Node 26 不附 corepack；Linux 那邊 symlink 的 `corepack` 入口，換到 26 之後就沒有了。
3. **要不要裝 pnpm（`pnpm` tag）？** 要的話，`globalShims` 要保留預設的 `auto`，還是關掉？
   - 照這份設計，Node 不是透過 pnpm 裝的，所以預設值實際上沒有作用。
   - 但如果遠端工作階段自己透過 pnpm 全域裝了 Node（`pnpm runtime set` 這類指令，確切語法［待驗］），pnpm 就會悄悄變成 Node 的版本管理器。關掉比較保險。
4. **podman machine 要開機自動啟動，還是用到時才 `podman machine start`？** 機器的 CPU、記憶體、磁碟配額要多少？
5. **這台會不會做商用工作？** 只有在「確定只做個人非商用」的前提下，OrbStack 才是選項。目前建議不用。
6. **同意修改 DESIGN §4 的 `profile` tag，從「只有 `~/.zprofile`」改成「`~/.zshenv` 加 `~/.zprofile`」嗎？**
7. **uv 要不要關掉 `python3.X` 連結（`UV_PYTHON_INSTALL_BIN=0`）？** 建議關掉。這樣主機的 PATH 上就沒有任何 uv 的 Python，強制大家用 `uv run`。代價是 `python3` 會落到 CLT 的 3.9.6，所以要在 `~/.claude/CLAUDE.md` 寫明「Python 一律用 `uv run`」。
8. **Go、uv 要用 brew，還是比照 Linux 用官方安裝方式？** 建議 brew，理由見 §6.4。兩種都能用，差別只在跟 Linux 的一致性。
9. **Xcode 現在需不需要？** 不需要的話，維持只有 CLT。

---

## 附錄 A：我親自用第一手來源複核過的說法

| 說法 | 怎麼複核 |
|---|---|
| npm `devEngines` 的 `onFail` 只有 `warn` / `error` / `ignore` | 讀 npm/cli 原始碼庫的 `docs/lib/content/configuring-npm/package-json.md`（latest） |
| Node 24 從 2026-10-20 起 Maintenance、26 從 2026-10-28 起 LTS、27 從 2026-10-28 起 alpha | 讀 nodejs/Release 的 `schedule.json` |
| pnpm 12 是原生執行檔、`globalShims` 的預設值和作用範圍、`PNPM_SHIM_BYPASS` | 讀 pnpm.io/installation、/settings/other、/blog/whats-different-in-pnpm-12 |
| podman 的自動啟動要 `AbandonProcessGroup`、不能加 `KeepAlive` | 讀 containers/podman 的 `docs/tutorials/macos_autostart.md` |
| Claude Code 的 Bash 工具在工作階段開始時 source `~/.zshrc` | 讀 code.claude.com/docs/en/tools-reference.md |
| OrbStack 的商用授權條款 | 讀 docs.orbstack.dev/licensing |
| 各 brew 套件的版本、keg-only、相依、caveats、cask 的 zap 清單 | formulae.brew.sh 的 JSON API（2026-11-12 抓取） |
| launchd 的預設 PATH、sshd-session 寫死的 PATH、path_helper 的重排、`/usr/local/bin` 不存在、`/pkg` 的擁有者、CLT 的內容 | 本機唯讀指令，見 §6.1 |

## 附錄 B：來源

**Node / npm / pnpm**
- https://github.com/nodejs/TSC/issues/1697
- https://nodejs.org/en/blog/release/v25.0.0
- https://github.com/nodejs/corepack
- https://github.com/nodejs/Release （`schedule.json`）
- https://nodejs.org/en/blog/announcements/evolving-the-nodejs-release-schedule
- https://nodejs.org/dist/index.json
- https://docs.npmjs.com/cli/v11/configuring-npm/package-json#devengines
- https://github.com/npm/cli/blob/latest/docs/lib/content/configuring-npm/package-json.md
- https://github.com/npm/cli/issues/8004
- https://github.com/npm/cli/releases/tag/v10.9.0
- https://pnpm.io/installation
- https://pnpm.io/settings/other
- https://pnpm.io/blog/whats-different-in-pnpm-12
- https://pnpm.io/blog/releases/10.14
- https://pnpm.io/blog/releases/11.0
- https://pnpm.io/blog/releases/12.0
- https://github.com/nodejs/node/issues/62098
- https://github.com/volta-cli/volta/issues/2080
- https://github.com/nodejs/nodejs.org/blob/main/apps/site/util/download/constants.json
- https://github.com/nodejs/node/blob/main/tools/macos-installer/productbuild/Resources/en.lproj/conclusion.html.tmpl

**Python / uv**
- https://docs.astral.sh/uv/getting-started/installation/
- https://docs.astral.sh/uv/reference/installer/
- https://docs.astral.sh/uv/reference/storage/
- https://docs.astral.sh/uv/concepts/python-versions/
- https://docs.astral.sh/uv/reference/settings/
- https://github.com/astral-sh/uv/blob/main/CHANGELOG.md
- https://github.com/astral-sh/python-build-standalone

**Go**
- https://go.dev/doc/toolchain
- https://go.dev/doc/install
- https://go.dev/doc/manage-install
- https://go.dev/doc/devel/release
- https://go.dev/doc/go1.26
- https://go.dev/doc/go1.27
- https://pkg.go.dev/cmd/go

**Rust**
- https://rust-lang.github.io/rustup/installation/other.html
- https://rust-lang.github.io/rustup/environment-variables.html
- https://rust-lang.github.io/rustup/installation/already-installed-rust.html
- https://github.com/rust-lang/rustup/blob/master/CHANGELOG.md
- https://blog.rust-lang.org/inside-rust/2026/07/03/rustup-update-1.30/
- https://doc.rust-lang.org/book/ch01-01-installation.html

**mise**
- https://github.com/jdx/mise/releases
- https://mise.jdx.dev/dev-tools/shims.html
- https://mise.jdx.dev/cli/trust.html
- https://mise.jdx.dev/paranoid.html
- https://github.com/jdx/mise/security/advisories
- https://mise.jdx.dev/configuration/settings.html
- https://mise.jdx.dev/configuration.html
- https://mise.jdx.dev/core-tools.html
- https://mise.jdx.dev/dev-tools/backends/
- https://mise.jdx.dev/lang/python.html
- https://mise.jdx.dev/lang/rust.html
- https://mise.jdx.dev/lang/node.html
- https://mise.jdx.dev/directories.html
- https://mise.jdx.dev/cli/implode.html
- https://mise.jdx.dev/dev-tools/mise-lock.html

**PATH / shell / macOS**
- https://zsh.sourceforge.io/Doc/Release/Files.html
- 本機 man page：`path_helper(8)`、`launchctl(1)`、`launchd.plist(5)`、`xcode-select(1)`、`sshd_config(5)`
- https://code.claude.com/docs/en/tools-reference
- https://code.claude.com/docs/en/env-vars
- https://code.claude.com/docs/en/hooks
- https://docs.brew.sh/Installation
- https://eclecticlight.co/2026/09/19/macos-tahoe-26-4-changed-boot-volume-structure/ （社群）
- https://anderegg.ca/2026/10/18/what-the-heck-is-pkg （社群）

**容器**
- https://github.com/containers/podman/releases
- https://raw.githubusercontent.com/containers/podman/main/RELEASE_NOTES.md
- https://podman.io/docs/installation
- https://github.com/containers/podman/blob/main/docs/tutorials/macos_autostart.md
- https://docs.podman.io/en/latest/markdown/podman-machine-init.1.html
- https://github.com/containers/podman/discussions/19430 （社群）
- https://github.com/containers/podman/issues/30080 （社群）
- https://podman-desktop.io/docs/podman/gpu
- https://podman-desktop.io/docs/uninstall
- https://developers.redhat.com/articles/2025/06/05/how-we-improved-ai-inference-macos-podman-containers （非官方效能數字）
- https://developers.redhat.com/articles/2025/09/18/reach-native-speed-macos-llamacpp-container-inference （非官方效能數字）
- https://code.visualstudio.com/remote/advancedcontainers/docker-options
- https://github.com/apple/container
- https://github.com/apple/container/releases
- https://github.com/apple/container/blob/main/docs/technical-overview.md
- https://github.com/apple/container/issues/2335 （社群）
- https://github.com/socktainer/socktainer （社群）
- https://docs.orbstack.dev/licensing
- https://orbstack.dev/pricing
- https://docs.orbstack.dev/headless
- https://docs.orbstack.dev/architecture
- https://docs.orbstack.dev/release-notes
- https://docs.orbstack.dev/install
- https://github.com/abiosoft/colima/releases
- https://github.com/abiosoft/colima/blob/main/docs/FAQ.md
- https://lima-vm.io/docs/config/mount/
- https://docs.docker.com/subscription/desktop-license/

**GPU / AI / Xcode**
- https://www.docker.com/blog/docker-model-runner-vllm-metal-macos/
- https://docs.docker.com/ai/model-runner/
- https://ml-explore.github.io/mlx/build/html/install.html
- https://github.com/ml-explore/mlx-lm
- https://developer.apple.com/metal/pytorch/
- https://docs.pytorch.org/docs/2.15/notes/mps.html
- https://huggingface.co/docs/huggingface_hub/package_reference/environment_variables
- https://developer.apple.com/documentation/xcode/installing-the-command-line-tools
- https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components
- https://github.com/XcodesOrg/xcodes
- https://github.com/mas-cli/mas
- https://www.swift.org/install/macos/swiftly/
- https://github.com/swiftlang/swiftly
- https://developer.apple.com/forums/thread/773153 （社群）

**Homebrew（版本、keg-only、相依、cask 的 zap 清單）**
- https://formulae.brew.sh/api/formula/{go,uv,node,node@24,node@22,pnpm,rustup,rust,podman,colima,lima,container,mise,swiftly,xcodes,mas,make,ansible}.json
- https://formulae.brew.sh/api/cask/{orbstack,podman-desktop,docker-desktop}.json

**參考 repo**
- https://github.com/MiskaWu/dev-env-ansible （README 的「版本管理：為什麼沒有 mise / nvm / pyenv」一段；CLAUDE.md 約第 324 行起）
- https://github.com/MiskaWu/wsl-bootstrap
