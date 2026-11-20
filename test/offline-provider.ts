import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";

export default function (pi: ExtensionAPI) {
  pi.on("input", (event, ctx) => {
    if (event.text.startsWith("Pi Go queue fixture:")) ctx.ui.notify(`Pi Go fixture mode: ${event.streamingBehavior ?? "direct"}`, "info");
    return { action: "continue" };
  });
  pi.registerProvider("pi-go-test", {
    baseUrl: "http://127.0.0.1",
    api: "pi-go-offline",
    apiKey: "unused-test-key",
    models: [{
      id: "fixture", name: "Fixture", input: ["text", "image"], reasoning: false,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 10000, maxTokens: 1024,
    }, {
      id: "text-only", name: "Text-only fixture", input: ["text"], reasoning: false,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 10000, maxTokens: 1024,
    }, ...Array.from({ length: 105 }, (_, index) => ({
      id: `reasoning-${index}`, name: `Reasoning fixture ${index}`, input: ["text"], reasoning: true,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 10000, maxTokens: 1024,
    }))],
    streamSimple: (model, context, options) => {
      const stream = createAssistantMessageEventStream();
      const last = context.messages.at(-1);
      const approvalProbe = last?.role === "user" && Array.isArray(last.content) &&
        last.content.some((item) => item.type === "text" && item.text === "Pi Go fixture: check native tool approval");
      const longAnswer = last?.role === "user" && Array.isArray(last.content) &&
        last.content.some((item) => item.type === "text" && item.text === "Pi Go fixture: long answer");
      const receivedImage = last?.role === "user" && Array.isArray(last.content) &&
        last.content.some((item) => item.type === "image" && item.mimeType === "image/jpeg");
      const answer = receivedImage ? "fixture image received" : "fixture delta";
      const reasoning = model.reasoning === true;
      const thought = "fixture thinking before answering";
      const message: AssistantMessage = {
        role: "assistant",
        content: reasoning ? [
          { type: "thinking" as const, thinking: thought },
          { type: "text" as const, text: answer },
        ] : [{ type: "text" as const, text: answer }],
        api: model.api, provider: model.provider, model: model.id, stopReason: "stop", timestamp: Date.now(),
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      };
      if (approvalProbe) {
        message.content = [{
          type: "toolCall", id: "pi-go-approval-call", name: "bash",
          arguments: { command: "printf pi-go-approval-fixture > pi-go-approval-result.txt\nprintf pi-go-output" },
        }];
        message.stopReason = "toolUse";
        stream.push({ type: "done", reason: "toolUse", message });
        stream.end();
        return stream;
      }
      const finish = () => {
        options?.signal?.removeEventListener("abort", abort);
        stream.push({ type: "done", reason: "stop", message });
        stream.end();
      };
      const timer = setTimeout(finish, longAnswer ? 22_000 : 1200);
      const abort = () => {
        clearTimeout(timer);
        stream.push({ type: "error", reason: "aborted", error: { ...message, stopReason: "aborted" } });
        stream.end();
      };
      options?.signal?.addEventListener("abort", abort, { once: true });
      if (options?.signal?.aborted) abort();
      else {
        stream.push({ type: "start", partial: message });
        if (reasoning) {
          stream.push({ type: "thinking_start", contentIndex: 0, partial: message });
          stream.push({ type: "thinking_delta", contentIndex: 0, delta: "fixture thinking ", partial: message });
          stream.push({ type: "thinking_delta", contentIndex: 0, delta: "before answering", partial: message });
          stream.push({ type: "thinking_end", contentIndex: 0, content: thought, partial: message });
          stream.push({ type: "text_start", contentIndex: 1, partial: message });
          stream.push({ type: "text_delta", contentIndex: 1, delta: answer, partial: message });
        } else {
          stream.push({ type: "text_delta", contentIndex: 0, delta: answer, partial: message });
        }
      }
      return stream;
    },
  });
}
