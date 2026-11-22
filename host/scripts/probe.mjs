import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";

async function main(file) {
  if (!file) throw new Error("用法：node host/scripts/probe.mjs <pair.json 路径>");
  const { url, ticket } = JSON.parse(await readFile(file, "utf8"));
  if (typeof url !== "string" || !/^http:\/\/127\.0\.0\.1:\d{1,5}$/.test(url) || !/^[a-f0-9]{64}$/.test(ticket)) {
    throw new Error("无效的本机配对文件");
  }
  let token;
  const request = (route, data, signal = AbortSignal.timeout(10000)) => fetch(`${url}${route}`, {
    method: data === undefined ? "GET" : "POST", signal, redirect: "error",
    headers: { ...(data === undefined ? {} : { "content-type": "application/json" }),
      ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: data === undefined ? undefined : JSON.stringify(data),
  });
  const pair = await request("/pair", { ticket });
  if (!pair.ok) throw new Error(`配对失败：HTTP ${pair.status}`);
  ({ token } = await pair.json());

  const controller = new AbortController();
  const feed = request("/events", undefined, controller.signal).then(async (response) => {
    if (!response.ok) throw new Error(`事件连接失败：HTTP ${response.status}`);
    const lines = createInterface({ input: Readable.fromWeb(response.body), crlfDelay: Infinity });
    for await (const line of lines) if (line.startsWith("data: ")) console.log(line.slice(6));
  }).catch((error) => {
    if (!controller.signal.aborted) console.error(error.message);
  });

  const input = createInterface({ input: process.stdin });
  console.log("命令：list | state | open <id> | prompt <文本> | abort | quit");
  try {
    for await (const line of input) {
      const [command, ...words] = line.trim().split(" ");
      if (command === "quit") break;
      try {
        let response;
        if (command === "list") response = await request("/sessions");
        else if (command === "state") response = await request("/session");
        else if (command === "open") response = await request("/open", { id: words[0] });
        else if (command === "prompt" || command === "abort") {
          const state = await request("/session");
          if (!state.ok) throw new Error(`读取当前会话失败：HTTP ${state.status}`);
          const { session } = await state.json();
          const data = command === "prompt" ? { text: words.join(" "), requestId: randomUUID() } : {};
          response = await request(`/${command}`, { id: session.id, ...data });
        } else { console.log("未知命令"); continue; }
        console.log(`${response.status} ${await response.text()}`);
      } catch (error) { console.error(error.message); }
    }
  } finally {
    input.close();
    controller.abort();
    await feed;
  }
}

main(process.argv[2]).catch((error) => { console.error(error.message); process.exitCode = 1; });
