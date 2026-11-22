#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
node_bin="$(command -v node)"
pi_bin="${PIGO_PI_BIN:-$(command -v pi)}"
pi_bin="$(command -v "$pi_bin")"
[[ -x "$node_bin" && -x "$pi_bin" ]]
domain="gui/$(id -u)"
agents_dir="${HOME}/Library/LaunchAgents"
logs_dir="${HOME}/Library/Logs"
mkdir -p "$agents_dir" "$logs_dir"

install_agent() {
  local label="$1"
  shift
  local plist="$agents_dir/$label.plist"
  local draft="$(mktemp "$agents_dir/.pi-go.XXXXXX")"
  "$node_bin" --input-type=module - "$draft" "$label" "$logs_dir" "$node_bin" "$pi_bin" "$@" <<'JS'
import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
const [file, label, logs, node, pi, ...args] = process.argv.slice(2);
const environment = {
  PATH: [...new Set([dirname(node), dirname(pi), '/opt/homebrew/bin', '/usr/local/bin',
    '/usr/bin', '/bin', '/usr/sbin', '/sbin'])].join(':'),
  TMPDIR: tmpdir(),
  PIGO_PI_BIN: pi,
};
for (const name of ['PI_CODING_AGENT_DIR', 'PIGO_IPC_DIR', 'PIGO_STATE_DIR', 'PIGO_PI_ARGS', 'PIGO_PUSH_ACCOUNT_FILE']) {
  if (process.env[name] !== undefined) environment[name] = process.env[name];
}
writeFileSync(file, JSON.stringify({
  Label: label,
  ProgramArguments: [node, ...args],
  RunAtLoad: true,
  KeepAlive: true,
  ProcessType: label === 'dev.pi.go.daemon' ? 'Interactive' : 'Background',
  StandardErrorPath: join(logs, label + '.log'),
  EnvironmentVariables: environment,
}));
JS
  /usr/bin/plutil -convert xml1 "$draft"
  launchctl bootout "$domain/$label" 2>/dev/null || true
  mv "$draft" "$plist"
  if [[ "$label" == dev.pi.go.bridge.* ]]; then
    "$node_bin" --input-type=module - "$root" "$2" <<'JS'
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, port] = process.argv.slice(2);
const { ipcDirectory, localRequest } = await import(pathToFileURL(join(root, 'bridge/local-ipc.mjs')));
try {
  const stopped = await localRequest(join(ipcDirectory(), `bridge-${port}.sock`), 'POST', '/stop');
  if (stopped.status !== 200) throw new Error(`Existing bridge refused to stop (${stopped.status})`);
} catch (error) {
  if (error.code !== 'ENOENT' && error.code !== 'ECONNREFUSED') throw error;
}
JS
  fi
  launchctl bootstrap "$domain" "$plist"
  print "Installed $label"
}

if [[ -n "${PIGO_USB_PORT:-}" ]]; then
  if [[ ! "$PIGO_USB_PORT" =~ '^[1-9][0-9]{3,4}$' ]] || (( PIGO_USB_PORT < 1024 || PIGO_USB_PORT > 65535 )); then
    print -u2 "Invalid PIGO_USB_PORT"
    exit 1
  fi
fi

install_agent dev.pi.go.daemon "$root/daemon/daemon.mjs"
if [[ -n "${PIGO_USB_PORT:-}" ]]; then
  install_agent "dev.pi.go.bridge.usb.$PIGO_USB_PORT" "$root/bridge/broker.mjs" "$PIGO_USB_PORT"
fi
