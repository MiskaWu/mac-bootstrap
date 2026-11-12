# 需要 GNU make 4.x：內建的 /usr/bin/make 是 3.81，不支援 .ONESHELL，多行 recipe 會被拆成
# 一行一個 shell、變數全部失效，而且不會報錯。bootstrap.sh 會用 brew 裝好 4.x，並由
# `TAGS=profile` 把它的 gnubin 放進 PATH。檢查放在最前面，版本不對就直接停。
ifeq ($(filter oneshell,$(.FEATURES)),)
$(error 這份 Makefile 需要 GNU make 4.x（現在是 $(MAKE_VERSION)）。先跑 ./bootstrap.sh，再用 /opt/homebrew/opt/make/libexec/gnubin/make)
endif

# 寫死 /bin/bash（macOS 內建的 3.2）：不要讓 PATH 決定用哪個 bash。recipe 只用 3.2 有的語法。
SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules
.NOTPARALLEL:

# ---- 可由外部覆蓋 ----------------------------------------------------------
# 注意：這些 ?= 後面不要接行內 `# 註解` —— make 會把「值到 `#` 之間的空白」算進變數值
# （同 dev-env-ansible 踩過的坑），註解一律另起一行。
INVENTORY ?= inventory/hosts.yml
PLAYBOOK  ?= site.yml
# 機器專屬的值（gitignored）。範本是 config.example.yml。
CONFIG    ?= config.yml
# TAGS：要做什麼就寫在這裡，例 `make install TAGS=claude-rc`、`TAGS=tmux,profile`。
# 不設就是全部。有哪些可用跑 `make list`。另有兩個整層的：TAGS=user、TAGS=system。
TAGS      ?=
LIMIT     ?=
# LOCAL=1：對本機 localhost 跑；從別台遠端管設 LOCAL=0
LOCAL     ?= 1
EXTRA     ?=

BREW := /opt/homebrew/bin/brew
# 剛跑完 bootstrap.sh、~/.zprofile 還沒套用時，PATH 裡沒有 brew 與 ansible。
# 在這裡補，讓 make init 不必先重開終端機。
export PATH := /opt/homebrew/bin:$(PATH)

# ---- 內部組裝 --------------------------------------------------------------
COMMA  := ,
_CONN  := $(if $(filter 1,$(LOCAL)),-i localhost$(COMMA) -c local,-i $(INVENTORY))
_TAGS  := $(if $(TAGS),--tags $(TAGS),)
_LIMIT := $(if $(LIMIT),--limit $(LIMIT),)
_CFG   := $(if $(wildcard $(CONFIG)),-e @$(CONFIG),)
_ARGS  := $(_CONN) $(_CFG) $(_TAGS) $(_LIMIT) $(EXTRA)

# 直接跟 playbook 要真實的 tag 清單（單一事實來源）。濾掉 never / always。
# BSD paste 一定要給檔名，stdin 要寫 `-`。
_TAGS_OF_PLAYBOOK = ansible-playbook $(PLAYBOOK) $(_CONN) --list-tags \
	| sed -n 's/.*TASK TAGS: \[\(.*\)\]/\1/p' \
	| tr -d ' ' | tr ',' '\n' | grep -vxE 'never|always' | sort -u | paste -sd' ' -

# 要 sudo 的 tag：system 那個 play 的 TASK TAGS（play 名字以 "mac_node system" 開頭，見 site.yml）。
_SYSTEM_TAGS_OF = ansible-playbook $(PLAYBOOK) $(_CONN) --list-tags \
	| awk '/play \#[0-9]+ \([^)]*\): mac_node system/ {f=1; next} \
	       f && /TASK TAGS:/ {sub(/.*TASK TAGS: \[/, ""); sub(/\].*/, ""); gsub(/ /, ""); gsub(/,/, " "); print; exit}'

# 這次要不要 -K：不帶 TAGS（＝全部）一定要；帶了就看有沒有碰到 system 層的 tag。
# 印出 "-K" 或空字串，給 recipe 用 $$(...) 接。
#
# **這裡不能用 case**：macOS 的 bash 3.2 解析 $( ) 裡的 case 時，會把 pattern 後面的 `)`
# 當成 $( 的結尾，直接 syntax error（實測）。改用 [[ == ]]。
define _BECOME_FLAG
if [ -z "$(TAGS)" ]; then echo -K; exit 0; fi
sys=" $$($(_SYSTEM_TAGS_OF)) "
for t in $$(echo '$(TAGS)' | tr ',' ' '); do
	if [[ "$$sys" == *" $$t "* ]]; then echo -K; exit 0; fi
done
endef

.PHONY: help init list check install facts verify syntax lint \
	_ensure-ansible _ensure-config _check-tags

help: ## 顯示所有可用命令
	@awk 'BEGIN {FS = ":.*##"; printf "\n使用方式:\n  make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	echo
	echo "要做什麼用 TAGS=，例 make install TAGS=claude-rc 或 TAGS=tmux,profile。"
	echo "TAGS=user 是所有不用 sudo 的；TAGS=system 是所有要 sudo 的（會問密碼）。"
	echo "不確定有什麼？先跑 make list。"

##@ 起手
# bring-up（bootstrap.sh）給的是 Homebrew 加 GNU make。這裡補上 ansible，然後印出下一步。
# 刻意不裝任何其他東西：要裝什麼由 TAGS 點名。
init: _ensure-ansible ## 起手：補上 ansible，並印出下一步
	@echo
	if [ ! -f "$(CONFIG)" ]; then
		echo "還沒有 $(CONFIG)。先複製範本再改："
		echo "  cp config.example.yml $(CONFIG)"
		echo
	fi
	echo "ansible 就緒。接下來："
	echo "  make list                       看有哪些項目、這台已經有哪些"
	echo "  make check TAGS=user            預覽不用 sudo 的部分會改什麼"
	echo "  make install TAGS=user          套用不用 sudo 的部分"
	echo "  make install TAGS=system        套用要 sudo 的部分（會問密碼，請自己在終端機跑）"
	echo "  make verify                     驗收清單裡能自動檢查的部分"
	echo
	echo "手動的事（刻意不自動化，make verify 會檢查有沒有做）："
	echo "  1. 系統設定 → 一般 → 共享：打開「遠端登入」（只允許自己的帳號）與「螢幕共享」"
	echo "  2. Tailscale 登入，並打開「登入時啟動」"
	echo "  3. 裝好 Claude 後，在真的終端機跑一次 claude 做 /login"
	echo "  4. 第一次在真的終端機手動跑 claude remote-control，回答兩個 y（見 README）"
	echo "  5. 公鑰貼到 GitHub（make install TAGS=ssh-keys 會印出來）"

##@ 安裝
# 不帶 TAGS = 不帶 --tags = 全部（含 system 層，會問密碼）。
# 先把 -K 算好再印一行乾淨的指令：直接寫在參數裡，make 會把整段判斷腳本一起印出來。
install: _ensure-ansible _ensure-config _check-tags ## 套用：不帶 TAGS 全部，或 TAGS=claude-rc / TAGS=user
	@become=$$($(call _BECOME_FLAG))
	echo "+ ansible-playbook $(PLAYBOOK) $(_ARGS) $$become"
	ansible-playbook $(PLAYBOOK) $(_ARGS) $$become

##@ 先看再動
# list   —— 有哪些項目、這台已經有哪些（唯讀）
# check  —— 這次會改哪些檔（--check --diff，真的去比對）
# facts  —— 偵測到的環境
# verify —— 驗收清單裡能自動檢查的部分（唯讀）
list: _ensure-ansible ## 有哪些項目、已經有哪些、可用的 tag（唯讀）
	@ANSIBLE_CALLBACK_RESULT_FORMAT=yaml \
		ansible-playbook $(PLAYBOOK) $(_CONN) $(_CFG) $(_LIMIT) $(EXTRA) --tags list
	echo "可用的 tag（直接跟 playbook 要的，不是手抄）："
	echo "    $$($(_TAGS_OF_PLAYBOOK))"
	echo "要 sudo 的（TAGS 碰到這些會問密碼）："
	echo "    $$($(_SYSTEM_TAGS_OF))"
	echo

check: _ensure-ansible _ensure-config _check-tags ## 乾跑預覽（--check --diff）；同樣吃 TAGS=
	@become=$$($(call _BECOME_FLAG))
	echo "+ ansible-playbook $(PLAYBOOK) $(_ARGS) --check --diff $$become"
	ansible-playbook $(PLAYBOOK) $(_ARGS) --check --diff $$become

facts: _ensure-ansible ## 印出偵測到的環境
	ansible-playbook $(PLAYBOOK) $(_CONN) $(_LIMIT) $(EXTRA) --tags always

verify: _ensure-ansible ## 驗收：能自動檢查的項目逐條跑，有失敗就 exit 非零（唯讀）
	@ANSIBLE_CALLBACK_RESULT_FORMAT=yaml \
		ansible-playbook $(PLAYBOOK) $(_CONN) $(_CFG) $(_LIMIT) $(EXTRA) --tags verify

##@ 檢查
syntax: _ensure-ansible ## 語法檢查（不連線）
	ansible-playbook $(PLAYBOOK) $(_CONN) --syntax-check

lint: ## ansible-lint（需先裝 ansible-lint）
	@command -v ansible-lint >/dev/null 2>&1 || { echo "Error: ansible-lint 未安裝"; exit 1; }
	ansible-lint

# ---- 內部 ------------------------------------------------------------------
# ansible 對不存在的 tag 不報錯，只是什麼都不做。動作前先比對真實的 tag 清單。
# **別把這個 guard 拿掉**（同 dev-env-ansible）。
_check-tags: _ensure-ansible
	@[ -n "$(TAGS)" ] || exit 0
	known="$$($(_TAGS_OF_PLAYBOOK))"
	bad=""
	for t in $$(echo '$(TAGS)' | tr ',' ' '); do
		case " $$known " in
			*" $$t "*) ;;
			*) bad="$$bad $$t" ;;
		esac
	done
	if [ -n "$$bad" ]; then
		echo "Error: playbook 裡沒有這些 tag：$$bad" >&2
		echo "可用：$$known" >&2
		exit 1
	fi

_ensure-config:
	@[ -f "$(CONFIG)" ] && exit 0
	echo "Error: 找不到 $(CONFIG)。先複製範本再改：" >&2
	echo "    cp config.example.yml $(CONFIG)" >&2
	exit 1

# bring-up 只給 Homebrew + make；ansible 由這裡補（不能用 ansible 裝 ansible）。
# 裝的是 brew 的 ansible（不是 ansible-core）：homebrew / osx_defaults / git_config 在
# community.general，authorized_key 在 ansible.posix，兩者都不在 ansible-core 裡。
_ensure-ansible:
	@command -v ansible-playbook >/dev/null 2>&1 && exit 0
	[ -x "$(BREW)" ] || { echo "Error: 找不到 Homebrew，先跑 ./bootstrap.sh" >&2; exit 1; }
	echo "[make] 安裝 ansible（brew）..."
	"$(BREW)" install ansible
	command -v ansible-playbook >/dev/null 2>&1 || { echo "Error: ansible 裝完卻找不到 ansible-playbook" >&2; exit 1; }
