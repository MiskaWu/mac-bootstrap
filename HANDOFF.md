# HANDOFF：把家裡的 MacBook Pro M4 設定成「隨時可遠端叫 Claude 工作」的節點（r2）

> 給執行這份文件的代理：
> 這台 Mac 屬於 Miska。目標是讓它常駐、不睡眠、重開機後能遠端救回來，並且能從手機或網頁隨時派 Claude 在上面工作。
> 你在這台 Mac 的 Claude Desktop「Code」分頁裡執行，工作資料夾是 `~/Developer/mac-bootstrap`。
> 依照下面的階段順序做。每個階段做完先驗證，再做下一階段。所有結果記錄在 `~/Developer/mac-bootstrap/SETUP-LOG.md`。

## r2 修訂摘要（相對於第一版）

- 工作區從 `~/work` 改成 `~/Developer`。設定檔和腳本的原始檔放在 `~/Developer/mac-bootstrap` 這個 repo，裝到系統位置的動作集中在 `install.sh`。
- 新增階段 0.5：Homebrew、Command Line Tools、repo 初始化。乾淨的 Mac 沒有 git 和 brew。
- Remote Control 一律明確加上 `--spawn same-dir`，啟動腳本改用絕對路徑。
- sshd 設定檔改名為 `010-hardening.conf`，並用 `sshd -T` 驗證。
- Tailscale：GUI 版要登入後才會跑，所以子網路路由從「可選」改成「看 §9 的結果決定，很可能是必要的」。
- iPhone 捷徑的主機改填 MagicDNS 名稱。
- 驗收清單的「Tailscale SSH」改成「經由 Tailscale 的一般 SSH」。

## 0. 執行規則（先讀）

- **sudo 指令**：先把完整指令列出來，請 Miska 自己在終端機執行或當場確認。不要要求他把密碼貼給你，也不要把密碼存在任何地方。
- **不要做的事**：
  - 不要關閉 FileVault。
  - 不要開啟自動登入。
  - 不要在路由器（UniFi）上開任何對外連接埠。
  - 不要把任何 2FA 密鑰存到這台機器上。
- **GUI 步驟**：系統設定、權限提示、登入這類需要點畫面的步驟，列成「人工步驟」交給 Miska，等他回報完成再繼續。
- **不確定就問**：不確定的值（主機名稱、Remote Control 根目錄、要開哪些 App）直接問，不要猜。
- **檔案寫入範圍**：你的工作資料夾是 `~/Developer/mac-bootstrap`。要放到 `~/bin`、`~/Library/LaunchAgents`、`/etc/ssh/...` 的檔案，一律先寫在 repo 裡：
  - 使用者層級的檔案由 `install.sh` 安裝。
  - 系統層級的檔案列成 sudo 指令交給 Miska。
  - 不要用 `/add-dir` 把整個家目錄加進來。
- **repo 不放公開位置**：`SETUP-LOG.md` 會記錄區網 IP 和 Tailscale 名稱。要推到 GitHub 的話用 private repo。
- **先確認環境**：開始前先跑 `sw_vers` 和 `uname -m`。FileVault 遠端解鎖需要 Apple Silicon 加 macOS 26 以上。版本不符就停下來回報。

---

## 階段 0.5：基礎工具與 repo

1. **Homebrew**（列給 Miska 在終端機執行；過程會要 sudo 密碼，也會一併安裝 Command Line Tools）：
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
   裝完照安裝程式最後的提示，把 `eval "$(/opt/homebrew/bin/brew shellenv)"` 寫進 `~/.zprofile`。要寫在 `.zprofile`，不能寫在 `.zshrc`，因為後面 LaunchAgent 用的 login shell 只會讀 `.zprofile`。
2. **驗證**：`git --version`、`brew --version`。
3. **tmux**：`brew install tmux`。
4. **初始化 repo**：
   ```bash
   cd ~/Developer/mac-bootstrap && git init
   ```
   - git 的 `user.name` 和 `user.email` 還沒設的話，問 Miska，設在這個 repo 裡就好。
   - 建立以下結構，之後每完成一個階段就 commit 一次：
   ```
   mac-bootstrap/
   ├── HANDOFF.md
   ├── SETUP-LOG.md
   ├── install.sh              # 使用者層級安裝：bin/*.sh → ~/bin，launchd/*.plist → ~/Library/LaunchAgents
   ├── bin/
   │   ├── claude-rc-server.sh
   │   └── arrive-home.sh
   ├── launchd/
   │   └── local.claude-rc.plist
   └── ssh/
       └── 010-hardening.conf
   ```
   `install.sh`：
   ```zsh
   #!/bin/zsh
   set -euo pipefail
   REPO="${0:A:h}"
   mkdir -p ~/bin ~/Library/LaunchAgents
   for f in "$REPO"/bin/*.sh(N); do install -m 755 "$f" ~/bin/; done
   for f in "$REPO"/launchd/*.plist(N); do install -m 644 "$f" ~/Library/LaunchAgents/; done
   ```

## 階段 1：基本資料與網路

1. **主機名稱**：問 Miska 要用什麼名字，然後列給他執行：
   ```bash
   sudo scutil --set ComputerName  "<name>"
   sudo scutil --set HostName      "<name>"
   sudo scutil --set LocalHostName "<name>"
   ```
2. **固定 IP**（人工步驟）：在 UniFi 幫這台 Mac 設 DHCP 保留 IP。記下它的區網 IP，重開機後遠端解鎖要用。
3. **有線網路**：建議接 USB-C 有線網路。早期的 macOS 26 版本，開機前走 Wi-Fi 的 SSH 不穩；有人回報 26.5 起 Wi-Fi 也能解鎖。有線還是最保險。
4. **Tailscale**：
   - 安裝 GUI 版（Standalone 或 App Store 版都可以），登入 Miska 的 tailnet，打開「登入時啟動」。
   - 記下 Tailscale IP 和 MagicDNS 名稱。
   - **限制**：GUI 版要使用者登入之後才會跑。這代表兩件事：
     - 開機前的 SSH 解鎖走不了 Tailscale。
     - 如果 §9 測出 SSH 解鎖後沒有 GUI 工作階段，Tailscale 也不會起來，螢幕共享只剩區網連得到。這時人在外面遇到意外重開機（kernel panic、系統更新），就沒有任何方法從外面救回來。
   - **補救方式**：問 Miska 要用哪一種，也可以等 §9 實測完再決定。
     - **A**：在 Synology NAS 的 Tailscale 套件開子網路路由 `--advertise-routes=<家裡網段>/24`，再到 Tailscale 管理後台核准（人工步驟）。這樣在外面也能經由 NAS 連到這台 Mac 的區網 IP，做 SSH 解鎖和螢幕共享。
     - **B**：改用開源版 `tailscaled`，裝成系統 daemon。解鎖之後不需要登入就會啟動，但不能和 GUI 版同時安裝。

## 階段 2：電源與不休眠

1. **接電源時永不睡眠，可被網路喚醒**（sudo，列給 Miska）：
   ```bash
   sudo pmset -c sleep 0 disksleep 0 displaysleep 10 womp 1 tcpkeepalive 1
   pmset -g    # 驗證 AC Power 區段：sleep 0、womp 1
   ```
2. **系統設定**（人工步驟）：電池 → 選項，打開「接上電源轉換器且顯示器關閉時，防止自動進入睡眠」和「網路喚醒」。實際字樣以 Miska 那台的版本為準。
3. **蓋子要保持打開**：蓋上螢幕一定會睡。三個選項：
   - **A（預設）**：開蓋放著，螢幕 10 分鐘後自己關。
   - **B**：接外接螢幕加電源，用闔蓋模式。
   - **C**：`sudo pmset -a disablesleep 1`，蓋上也不睡。有散熱風險，絕對不能放進包包。帶出門前必須改回 `disablesleep 0`。
   - 問 Miska 選哪個。沒有回覆就用 A。
4. **電池**：確認「最佳化電池充電」是開著的。
5. **自動更新**：關掉 macOS 自動安裝，避免半夜自己重開，但保留安全性回應（sudo，列給 Miska）：
   ```bash
   sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
   ```
   到系統設定 → 一般 → 軟體更新 →「自動更新」確認狀態（人工步驟）。

## 階段 3：遠端存取（SSH、螢幕共享、FileVault 遠端解鎖）

1. **開啟 SSH 和螢幕共享**（人工步驟）：
   - 系統設定 → 一般 → 共享，打開「遠端登入」，只允許 Miska 的帳號。
   - 同一頁打開「螢幕共享」，需要點 GUI 的時候透過 Tailscale 連。
2. **SSH 金鑰**：
   - 把 Miska 的公鑰（Windows 桌機的，以及 iPhone 捷徑稍後產生的）加進 `~/.ssh/authorized_keys`。
   - 權限要正確：`chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`。
3. **一般 SSH 只允許金鑰登入**：
   - 在 repo 寫 `ssh/010-hardening.conf`：
     ```
     PasswordAuthentication no
     KbdInteractiveAuthentication no
     PermitRootLogin no
     ```
   - 安裝並驗證（sudo，列給 Miska）：
     ```bash
     sudo install -m 644 -o root -g wheel ~/Developer/mac-bootstrap/ssh/010-hardening.conf /etc/ssh/sshd_config.d/010-hardening.conf
     sudo sshd -T | grep -E 'passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication'
     # 預期：passwordauthentication no、kbdinteractiveauthentication no、pubkeyauthentication yes
     ```
   - 為什麼檔名用 `010-`：OpenSSH 以第一個讀到的值為準，`sshd_config.d` 裡的檔案按字母順序載入。`010-` 保證排在 macOS 自帶的 `100-macos.conf` 前面。
   - 最後從另一台機器確認：用金鑰登得進去，用密碼登不進去。
4. **FileVault 維持開著**。macOS 26 以上開了「遠端登入」之後，重開機會停在解鎖畫面，可以用 SSH 連進去輸入密碼解鎖：
   - 解鎖用的連線只負責解鎖，不是 shell。解鎖完要重新連。
   - 開機前的解鎖階段，平常設定的驗證方式和 shell 都不能用，但仍然接受密碼驗證來解鎖。這時加密的資料磁碟區還鎖著，第 3 步的設定根本讀不到，所以關掉密碼登入預期不會影響解鎖。**還是一定要實測一次**（見第 9 節）。不行的話回報 Miska，再決定怎麼調整。
5. **計畫性重開機**：用 `sudo fdesetup authrestart`，這次重開會自動跳過 FileVault 解鎖。

## 階段 4：Claude Desktop

1. **安裝並登入**：已完成（你現在就在 Desktop 裡執行）。確認登入的是 Miska 的 claude.ai 帳號。
2. **登入時自動開啟**：把 Claude Desktop 加進登入項目（人工步驟）。
3. **設定**（人工步驟），各項名稱以 app 版本為準：
   - **Keep computer awake**：在 Settings → Desktop app，或 Settings → This computer → System，打開。
   - **Computer use**：在 Settings → General（Desktop app 底下）打開。macOS 會跳出「輔助使用」和「螢幕錄製」兩個授權，兩個都要允許。
   - **Connect new sessions to Remote Control**：在 Settings → Claude Code，打開。
4. **Dispatch**（人工步驟）：用手機的 Claude app 和這台 Desktop 配對，然後從手機傳一個簡單任務測試。
5. **Trusted devices**（人工步驟）：到 claude.ai 的 Account 或 Cowork 設定頁，打開「Require trusted devices」。這台可以被遠端操控，要綁定已驗證的裝置。

## 階段 5：Claude Code CLI 和 Remote Control 常駐伺服器

1. **安裝並登入**：
   - 安裝 Claude Code CLI，執行 `claude`，再用 `/login` 以 claude.ai 帳號登入。
   - 用 `command -v claude` 記下 claude 的實際路徑，下面的腳本要用。
   - 確認沒有設定 `ANTHROPIC_BASE_URL`、`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`、`DISABLE_GROWTHBOOK`。這幾個變數會讓 Remote Control 無法使用。
2. **權限規則**：問 Miska 要不要沿用他 Windows/WSL 那邊 `~/.claude/settings.json` 的 `permissions.deny`、`permissions.ask` 和 autoMode 設定。要的話請他提供，原樣搬過來。
3. **Remote Control 根目錄**：問 Miska，預設 `~/Developer`。same-dir 模式下，所有遠端工作階段都從這裡開始，也可以進到任何子資料夾的 repo。
4. **第一次要在真的終端機裡手動跑一次**。伺服器第一次會問問題，而且不在終端機裡就會直接退出：
   ```bash
   cd ~/Developer && claude remote-control --name "home-mac" --spawn same-dir
   ```
   - 「Enable Remote Control?」回答 `y`。
   - 「Trust <dir>?」回答 `y`。
   - 已經用 `--spawn` 指定模式，就不會再問 spawn mode。之後每次啟動也都要帶這個參數，否則它會卡在選單等輸入，看起來卻像正常在跑。
   - 如果 Miska 主要在某個 repo 工作，就在那個 repo 另外開一個伺服器：`cd ~/Developer/<repo> && claude remote-control --name "<repo>" --spawn worktree`。這樣每個工作階段各自一個 worktree，不會互相改到檔案。
   - 確認手機或 claude.ai/code 看得到這個工作階段之後，按 Ctrl+C 結束。
5. **常駐方式：launchd 加 tmux 加自動重啟迴圈**。原因有兩個：
   - 伺服器模式斷網大約 10 分鐘後會自己結束，需要自動重啟。
   - 官方建議在遠端機器上放在 tmux 裡跑。

   要用 LaunchAgent，不要用 LaunchDaemon。LaunchAgent 跑在使用者的登入工作階段裡，才讀得到 Keychain 裡的 Claude 登入資訊。

   `bin/claude-rc-server.sh`（在 repo 裡）：
   ```zsh
   #!/bin/zsh -l
   # 冪等：tmux session 不存在才建立。裡面是無限迴圈，claude 結束後 10 秒重啟。
   # 一律用絕對路徑：launchd 的 login shell 只讀 .zprofile，不保證有 .zshrc 裡的 PATH。
   SESSION=claude-rc
   WORKDIR="$HOME/Developer"
   TMUX_BIN=/opt/homebrew/bin/tmux
   CLAUDE_BIN="$HOME/.local/bin/claude"   # 以 `command -v claude` 的實際結果為準
   for b in "$TMUX_BIN" "$CLAUDE_BIN"; do
     [[ -x "$b" ]] || { echo "[$(date)] missing: $b" >&2; exit 1; }
   done
   if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
     "$TMUX_BIN" new-session -d -s "$SESSION" -c "$WORKDIR" \
       "while true; do '$CLAUDE_BIN' remote-control --name home-mac --spawn same-dir; echo \"[\$(date)] exited, restart in 10s\"; sleep 10; done"
   fi
   ```
   `launchd/local.claude-rc.plist`（在 repo 裡）：
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key><string>local.claude-rc</string>
     <key>ProgramArguments</key>
     <array>
       <string>/bin/zsh</string><string>-l</string><string>-c</string>
       <string>$HOME/bin/claude-rc-server.sh</string>
     </array>
     <key>RunAtLoad</key><true/>
     <key>StartInterval</key><integer>300</integer>
     <key>StandardOutPath</key><string>/tmp/claude-rc.log</string>
     <key>StandardErrorPath</key><string>/tmp/claude-rc.err</string>
   </dict>
   </plist>
   ```
   啟用：
   ```bash
   ~/Developer/mac-bootstrap/install.sh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.claude-rc.plist
   /opt/homebrew/bin/tmux ls          # 應該看到 claude-rc
   ```
   - `StartInterval` 設 300，表示每 5 分鐘檢查一次，tmux 被關掉也會自己補回來。
   - 之後改了 plist 要重新載入：先跑 `launchctl bootout gui/$(id -u)/local.claude-rc`，再跑 `install.sh`，最後重新 `bootstrap`。

## 階段 6：到家就緒（骨架先建，內容待 Miska 決定）

1. **建立 `bin/arrive-home.sh`**（在 repo 裡，用 `install.sh` 裝到 `~/bin`）：
   - 內容先只放註解和範例：`open -a "<App>"`，或 App 自己的 URL scheme、命令列參數。
   - 問 Miska 到家要開哪些 App。
   - 只放確定、可以重複執行的步驟。沒有命令列可用的 GUI 操作先列出來，不要用 computer use 硬做。
2. **iPhone 捷徑**（人工步驟，給 Miska 照做）：
   - 個人自動化 →「抵達」家 → 動作選「透過 SSH 執行指令碼」。
   - 主機填這台 Mac 的 **MagicDNS 名稱**（或 Tailscale IP）。不要填區網 IP：觸發「抵達」的時候，手機常常還沒連上家裡的 Wi-Fi。iPhone 上的 Tailscale 要保持連線。
   - 驗證方式用捷徑產生的 SSH 金鑰，把公鑰加進 `authorized_keys`。
   - 指令填 `~/bin/arrive-home.sh`，設成立即執行。
3. **需要 2FA 的遊戲**：這一版先不處理，等 Miska 決定用哪種方式。在那之前，不要把驗證碼的密鑰或遊戲密碼存到這台機器上。

## 階段 7：本機排程任務（可選）

Claude Desktop 的 Scheduled 頁面可以建立本機排程任務。它只在 app 開著、電腦醒著時才會跑；睡過頭的話，醒來只補跑最近一次。先問 Miska 有沒有固定要跑的工作，沒有就跳過。

## 8. 驗收清單（逐項執行，把結果寫進 SETUP-LOG.md）

- [ ] `pmset -g`：AC Power 下 `sleep 0`、`womp 1`
- [ ] 螢幕關閉、閒置 30 分鐘後，從別台機器經由 Tailscale 連一般 SSH 連得進來（`ssh <user>@<MagicDNS 名稱>`）。這裡測的不是 Tailscale 自家的「Tailscale SSH」功能，macOS GUI 版不支援那個功能。
- [ ] `sudo sshd -T`：`passwordauthentication no`、`kbdinteractiveauthentication no`
- [ ] 一般 SSH 用密碼登入會被拒絕，用金鑰可以登入
- [ ] 手機或 claude.ai/code 看得到 `home-mac` 工作階段，送一個小任務能正常執行
- [ ] `/opt/homebrew/bin/tmux kill-session -t claude-rc` 之後，5 分鐘內自動重建
- [ ] 拔網路 15 分鐘再接回：伺服器退出後被迴圈重啟，手機那邊重新連上
- [ ] Dispatch：從手機丟任務，Desktop 有開出工作階段
- [ ] Computer use：從 Dispatch 叫它打開「計算機」並截圖
- [ ] repo 已 commit，`git status` 乾淨

## 9. 重開機實測（最後做，Miska 必須在場）

1. 執行 `sudo shutdown -r now`。這次故意不用 authrestart，用來測 FileVault 解鎖。
2. 從同一個區網的另一台機器 `ssh <user>@<區網IP>`，應該會出現 FileVault 解鎖提示，輸入登入密碼。
3. 解鎖完重新連 SSH，檢查以下幾項：
   - 有沒有 GUI 登入工作階段：`who`、`launchctl print gui/$(id -u) | head`
   - Claude Desktop、Tailscale、tmux 的 `claude-rc` 有沒有自己起來
4. 如果 SSH 解鎖之後沒有 GUI 工作階段，Desktop、LaunchAgent 和 GUI 版 Tailscale 都不會跑。這時：
   - 用螢幕共享（區網）登入一次，確認服務都起來了。
   - 在 SETUP-LOG.md 寫下「重開機後需要用螢幕共享登入一次」作為標準程序。
   - 回到階段 1.4 的補救方式 A 或 B，請 Miska 決定，否則人在外面時救不回來。
5. 再測一次 `sudo fdesetup authrestart`，確認計畫性重開機不需要手動解鎖。

## 10. 完成時回報給 Miska

- 每個階段：完成、失敗、還是跳過，以及原因。
- 還剩哪些人工步驟沒做。
- 這台機器的連線資訊：主機名稱、區網 IP、Tailscale 名稱，以及 Remote Control 工作階段名稱。
- 重開機的標準程序（第 9 節的實測結果），以及階段 1.4 選了哪個補救方式。
- repo 最後一個 commit。
