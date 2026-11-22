import { join } from 'node:path';
import { setTimeout as pause } from 'node:timers/promises';
import { ipcDirectory, localRequest } from './local-ipc.mjs';
import { usbForward, usbForwarded, usbLaunch, usbTargets } from './pairing-control.mjs';

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('invalid_port');
const socket = join(ipcDirectory(), `bridge-${port}.sock`);
let previousTarget;
let previousError;

for (;;) {
  try {
    const result = await localRequest(socket, 'GET', '/status', undefined, 800)
      .catch((error) => {
        if (['ENOENT', 'ECONNREFUSED'].includes(error.code)) return undefined;
        throw error;
      });
    const targets = result?.data.transport === 'usb' && result.data.paired === true ? await usbTargets() : [];
    if (targets.length !== 1) {
      previousTarget = undefined;
    } else {
      const [target] = targets;
      if (!await usbForwarded(target, port)) {
        const forward = await usbForward(port, target);
        await usbLaunch(forward.args, port);
      } else if (target !== previousTarget) {
        await usbLaunch(['-t', target], port);
      }
      previousTarget = target;
    }
    previousError = undefined;
  } catch (error) {
    if (previousError !== error.message) process.stderr.write(`${error.message}\n`);
    previousError = error.message;
  }
  await pause(4000);
}
