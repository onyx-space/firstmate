import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const home = resolve(process.env.FM_HOME);
const work = resolve(process.env.FM_WORK);
mkdirSync(`${home}/state`, { recursive: true });
mkdirSync(`${home}/config`, { recursive: true });
mkdirSync(`${work}/repo`, { recursive: true });
mkdirSync(`${work}/sessions`, { recursive: true });
// This process owns the fleet lock, so the branch extension's ownership read
// says "owned" exactly as it does for the real main session.
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);

const pkg = resolve(process.env.PI_PACKAGE_DIR);
const {
  DefaultResourceLoader, ModelRegistry, ModelRuntime, SessionManager, SettingsManager, createAgentSession,
} = await import(pathToFileURL(`${pkg}/dist/index.js`).href);

// Local fake provider: never leaves the machine.
const chunk = (delta, finish) => `data: ${JSON.stringify({
  id: "fm-live-probe",
  object: "chat.completion.chunk",
  created: 1,
  model: "fm-live-probe-model",
  choices: [{ index: 0, delta, finish_reason: finish }],
  ...(finish ? { usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } } : {}),
})}\n\n`;
let completions = 0;
globalThis.fetch = async (input) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith("https://fm-live-probe.invalid/")) {
    throw new Error(`unexpected network request in the fake-provider probe: ${url}`);
  }
  completions += 1;
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(chunk({ role: "assistant", content: "OK" }, null)));
      controller.enqueue(encoder.encode(chunk({}, "stop")));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
};

const events = [];
const agentDir = resolve(process.env.PI_CODING_AGENT_DIR);
const settings = SettingsManager.create(resolve(process.env.FM_WORK, "repo"), agentDir);
const loader = new DefaultResourceLoader({
  cwd: resolve(process.env.FM_WORK, "repo"),
  agentDir,
  settingsManager: settings,
  additionalExtensionPaths: process.env.PLUGIN ? [process.env.PLUGIN] : [],
  extensionFactories: [{
    name: "fm-before-agent-start-probe",
    factory: (pi) => {
      pi.on("before_agent_start", (event) => {
        process.stderr.write(`PROBE before_agent_start keys=${Object.keys(event).join(",")}\n`);
        events.push({ type: "before_agent_start", hasPrompt: "prompt" in event, prompt: event.prompt, messageType: event.messageType });
      });
      pi.on("agent_settled", () => events.push({ type: "agent_settled" }));
      pi.on("agent_start", () => events.push({ type: "agent_start" }));
      pi.on("message_start", (event) => events.push({ type: "message_start", role: event.message?.role, customType: event.message?.customType }));
    },
  }],
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
});
await loader.reload();
const loaded = loader.getExtensions();
process.stderr.write(`LOADED extensions=${JSON.stringify((loaded.extensions ?? []).map((e) => e.path))} errors=${JSON.stringify(loaded.errors ?? loaded.runtime?.errors ?? null)}\n`);
const runtime = await ModelRuntime.create({
  authPath: `${agentDir}/auth.json`,
  modelsPath: `${agentDir}/models.json`,
});
const registry = new ModelRegistry(runtime);
await registry.refresh();
const model = registry.find("fm-live-probe", "fm-live-probe-model");
if (!model) throw new Error("the real registry did not resolve the local probe model");
const { session } = await createAgentSession({
  cwd: resolve(process.env.FM_WORK, "repo"),
  sessionManager: SessionManager.create(resolve(process.env.FM_WORK, "repo"), resolve(process.env.FM_WORK, "sessions")),
  settingsManager: settings,
  resourceLoader: loader,
  modelRuntime: runtime,
  model,
  noTools: "builtin",
});

// The same listener Pi's own interactive mode binds: it is what turned the
// reported TypeError into the "Extension ... error: Cannot read properties of
// undefined (reading 'trim')" line the captain saw.
const extensionErrors = [];
await session.bindExtensions({
  onError: (error) => extensionErrors.push({ path: error.extensionPath, event: error.event, message: error.error }),
});

const settled = () => events.filter((event) => event.type === "agent_settled").length;
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 600; i += 1) {
    if (predicate()) return;
    await new Promise((tick) => setTimeout(tick, 50));
  }
  throw new Error(`timeout waiting for ${label}: ${JSON.stringify({ events, extensionErrors })}`);
};

// Control: an ordinary captain prompt still raises before_agent_start WITH a
// prompt, and the extension must not error on it.
await session.prompt("Please send the branch a normal captain request.");
await waitFor(() => settled() === 1, "the captain-prompt run to settle");

// The reported path: a programmatic run, exactly how the branch delivers its
// own hidden processing request.
await session.sendCustomMessage(
  { customType: "fm-branch-processing", content: [{ type: "text", text: "hidden branch processing request" }], display: false },
  { triggerTurn: true },
);
await waitFor(() => settled() === 2, "the programmatic custom-message run to settle");

const report = {
  completions,
  events,
  promptEvents: events.filter((event) => event.type === "before_agent_start"),
  extensionErrors,
};
session.dispose();
console.log(JSON.stringify(report, null, 2));
// A supervision extension may still hold a watcher child; the probe ends here.
process.exit(0);
