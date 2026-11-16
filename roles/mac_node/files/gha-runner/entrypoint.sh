#!/bin/bash
# 註冊資料（.runner、.credentials…）放在磁碟區 /state，容器重建也不用重新註冊。
#   register：第一次用。RUNNER_TOKEN 只在這一次的容器裡（mac-bootstrap 用 gh 取一小時效期的註冊權杖），
#             註冊完把設定搬進 /state 就結束；常駐的容器不帶權杖。
#   run（預設）：從 /state 拿回設定、啟動。
set -euo pipefail
cd /opt/actions-runner
files=(.runner .credentials .credentials_rsaparams)
case "${1:-run}" in
  register)
    : "${RUNNER_TOKEN:?要 RUNNER_TOKEN}" "${RUNNER_URL:?}" "${RUNNER_NAME:?}" "${RUNNER_LABELS:?}"
    ./config.sh --unattended --replace --url "$RUNNER_URL" --token "$RUNNER_TOKEN" \
      --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work /opt/actions-runner/_work
    for f in "${files[@]}"; do cp -p "$f" /state/; done
    echo "註冊完成：$RUNNER_NAME（$RUNNER_LABELS）" ;;
  run)
    [[ -f /state/.runner ]] || { echo "還沒註冊（/state 沒有 .runner）" >&2; exit 1; }
    for f in "${files[@]}"; do cp -p "/state/$f" .; done
    exec ./run.sh ;;
  *) echo "用法：register | run" >&2; exit 2 ;;
esac
