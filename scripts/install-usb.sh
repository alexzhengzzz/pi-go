#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
studio="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
hdc="${HDC_BIN:-$studio/sdk/default/openharmony/toolchains/hdc}"
hap="${PIGO_HAP:-$project_root/harmony/entry/build/default/outputs/default/entry-default-signed.hap}"
port="${PIGO_USB_PORT:-18977}"
bundle="${PIGO_BUNDLE:-com.alex.pigo}"
target_flags=()
if [[ -n "${HDC_TARGET:-}" ]]; then target_flags=(-t "$HDC_TARGET"); fi
if [[ ! -f "$hap" ]]; then
  print -u2 '没有已签名 HAP；请先在 DevEco Studio 配置真机调试签名并构建。'
  exit 1
fi
result="$("$hdc" "${target_flags[@]}" install -r "$hap")"
print -r -- "$result"
[[ "$result" == *'successfully'* || "$result" == *'Success'* ]] || exit 1
if ! "$hdc" "${target_flags[@]}" fport ls | rg -q "tcp:$port tcp:$port.*Reverse"; then
  "$hdc" "${target_flags[@]}" rport "tcp:$port" "tcp:$port"
fi
"$hdc" "${target_flags[@]}" shell aa start -a EntryAbility -b "$bundle" --ps address "http://127.0.0.1:$port"
