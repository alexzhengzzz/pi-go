import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFile } from "node:fs/promises";
import { join } from "node:path";

export default function (pi: ExtensionAPI) {
  pi.on("input", async (event, ctx) => {
    if (event.text === "Pi Go fixture: ask for text") {
      const value = await ctx.ui.input("Pi Go input fixture", "Type fixture answer", { timeout: 90_000 });
      const original = "  first line\nsecond line\n";
      const edited = await ctx.ui.editor("Pi Go editor fixture", original);
      await appendFile(join(ctx.cwd, "pi-go-fixture-result.jsonl"), `${JSON.stringify({
        inputMatches: value === "fixture answer", editorMatches: edited === original,
      })}\n`, { mode: 0o600 });
      return { action: "handled" };
    }
    if (event.text !== "Pi Go fixture: ask for confirmation") return { action: "continue" };
    const confirmed = await ctx.ui.confirm("Pi Go interaction fixture", "Confirm the harmless test request?", { timeout: 90_000 });
    ctx.ui.notify(confirmed ? "Pi Go fixture confirmed" : "Pi Go fixture declined", "info");
    return { action: "handled" };
  });
}
