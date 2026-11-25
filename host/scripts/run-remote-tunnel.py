"""Publish the Mac's HTTPS broker through a VPS that has SSH and Python 3."""

import argparse
import shlex
import subprocess
import time


RELAY = """
import asyncio
import socket
import sys
from collections import OrderedDict

peers = {}
budgets = OrderedDict()
connections = 0

def tune(writer):
    sock = writer.get_extra_info('socket')
    if sock is None:
        return
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except OSError:
        pass

def admit(ip):
    now = asyncio.get_running_loop().time()
    tokens, updated = budgets.pop(ip, (36, now))
    tokens = min(36, tokens + 10 * (now - updated))
    accepted = tokens >= 1 and peers.get(ip, 0) < 16 and connections < 32
    budgets[ip] = (tokens - 1 if accepted else tokens, now)
    if len(budgets) > 2048:
        budgets.popitem(last=False)
    return accepted

async def pipe(reader, writer):
    while chunk := await reader.read(65536):
        writer.write(chunk)
        await writer.drain()

async def forward(reader, client, relay_port):
    global connections
    ip = client.get_extra_info('peername')[0]
    if not admit(ip):
        client.close()
        return
    tune(client)
    connections += 1
    peers[ip] = peers.get(ip, 0) + 1
    upstream = None
    try:
        source, upstream = await asyncio.wait_for(
            asyncio.open_connection('127.0.0.1', relay_port), 5)
        tune(upstream)
        paths = [asyncio.create_task(pipe(reader, upstream)),
                 asyncio.create_task(pipe(source, client))]
        _, pending = await asyncio.wait(paths, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        await asyncio.gather(*paths, return_exceptions=True)
    except (OSError, asyncio.TimeoutError):
        pass
    finally:
        connections -= 1
        peers[ip] -= 1
        if not peers[ip]:
            del peers[ip]
        client.close()
        if upstream:
            upstream.close()

async def main():
    public_port, relay_port = map(int, sys.argv[1:])
    loop = asyncio.get_running_loop()
    heartbeat = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(heartbeat), sys.stdin.buffer)
    server = await asyncio.start_server(
        lambda reader, writer: forward(reader, writer, relay_port), '0.0.0.0', public_port)
    print(f'Pi Go TCP relay listening on {public_port}', flush=True)
    async with server:
        while await asyncio.wait_for(heartbeat.readline(), 45):
            pass

try:
    asyncio.run(main())
except asyncio.TimeoutError:
    print('Pi Go SSH heartbeat timed out', file=sys.stderr)
"""


def port(value):
    number = int(value)
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError('Port must be between 1 and 65535')
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ssh_host', help='SSH config alias for the VPS')
    parser.add_argument('--public-port', type=port, default=8443)
    parser.add_argument('--relay-port', type=port, default=29082)
    parser.add_argument('--broker-port', type=port, default=18982)
    args = parser.parse_args()
    command = shlex.join(['python3', '-u', '-c', RELAY, str(args.public_port), str(args.relay_port)])
    ssh = subprocess.Popen([
        '/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2',
        '-o', 'TCPKeepAlive=yes', '-o', 'IPQoS=lowdelay',
        '-o', 'ExitOnForwardFailure=yes',
        '-R', f'127.0.0.1:{args.relay_port}:127.0.0.1:{args.broker_port}',
        '--', args.ssh_host, command,
    ], stdin=subprocess.PIPE)
    try:
        while ssh.poll() is None:
            ssh.stdin.write(b'\n')
            ssh.stdin.flush()
            time.sleep(10)
    except BrokenPipeError:
        pass
    finally:
        try:
            ssh.stdin.close()
        except BrokenPipeError:
            pass
    return ssh.wait()


if __name__ == '__main__':
    raise SystemExit(main())
