import { statSync } from "node:fs";
import { createRequire } from "node:module";
import { isAbsolute } from "node:path";
import { PassThrough } from "node:stream";
import { pathToFileURL } from "node:url";

export function configureProviders(core, settings) {
    for (const [name, directory] of [
        ["codex", settings.CodexWorkingDirectory],
        ["claude", settings.ClaudeWorkingDirectory],
    ]) {
        const provider = core.getProvider(name);
        const prompt = provider.prompt.bind(provider);
        provider.prompt = (sessionId, text, cwd) => {
            if (sessionId) return prompt(sessionId, text, undefined);
            const selected = cwd ?? directory;
            let valid = typeof selected === "string" && isAbsolute(selected);
            try { valid &&= statSync(selected).isDirectory(); }
            catch { valid = false; }
            if (!valid) {
                throw Object.assign(new Error("開始フォルダが見つかりません。EverVigilの設定を確認してください。"), { statusCode: 400 });
            }
            return prompt(sessionId, text, selected);
        };
    }
    if (settings.CodexModel) {
        for (const method of ["threadStart", "turnStart"]) {
            const original = core.codexClient[method].bind(core.codexClient);
            core.codexClient[method] = params => original({ ...params, model: settings.CodexModel });
        }
    }
}

export function configureModelCatalog(core, settings, query) {
    core.default.get("/models", async (request, response) => {
        const provider = request.query.provider;
        if (provider !== "codex" && provider !== "claude") {
            return response.status(400).json({ error: "モデル候補の取得先が不正です。" });
        }
        try {
            const models = [];
            if (provider === "codex") {
                let cursor;
                do {
                    const page = await core.codexClient.call("model/list", { cursor, includeHidden: false });
                    models.push(...page.data.filter(model => !model.hidden).map(model => model.model));
                    cursor = page.nextCursor;
                } while (cursor);
            } else {
                const input = new PassThrough({ objectMode: true });
                const abortController = new AbortController();
                const timer = setTimeout(() => abortController.abort(), 20000);
                const env = { ...process.env };
                delete env.BRIDGE_TOKEN;
                let session;
                try {
                    session = query({ prompt: input, options: {
                        cwd: settings.ClaudeWorkingDirectory,
                        pathToClaudeCodeExecutable: settings.ClaudePath || undefined,
                        settingSources: ["user", "project", "local"],
                        persistSession: false,
                        tools: [],
                        stderr: () => {},
                        env,
                        abortController,
                    } });
                    models.push(...(await session.supportedModels()).map(model => model.value));
                } finally {
                    clearTimeout(timer);
                    input.end();
                    session?.close();
                }
            }
            if (models.length === 0 || models.some(model =>
                typeof model !== "string" || model.length === 0 || model.length > 200 || /\s|\p{Cc}/u.test(model))) {
                throw new Error("Invalid model catalog");
            }
            return response.json({ models: [...new Set(models)] });
        } catch {
            return response.status(503).json({ error: "モデル候補を取得できませんでした。CLIの認証と起動状態を確認してください。" });
        }
    });
}

export async function startBridge(cliPath) {
    const settings = JSON.parse(process.env.EVERVIGIL_PROVIDER_SETTINGS);
    delete process.env.EVERVIGIL_PROVIDER_SETTINGS;
    if (settings.ClaudePath) process.env.EVEN_TERMINAL_CLAUDE_CODE_EXECUTABLE = settings.ClaudePath;
    if (settings.ClaudeModel) process.env.ANTHROPIC_MODEL = settings.ClaudeModel;
    // 起動設定はEverVigilが所有し、既存のツール承認ポリシーだけを上流設定から引き継ぐ。
    const cliUrl = pathToFileURL(cliPath);
    const { loadConfig, resolveConfigPath } = await import(new URL("./config.js", cliUrl));
    const { getExposeProviderNames } = await import(new URL("../dist/expose/registry.js", cliUrl));
    const allowedTools = loadConfig(resolveConfigPath(), getExposeProviderNames())?.claude.allowedTools;
    if (allowedTools !== undefined) process.env.EVEN_TERMINAL_CLAUDE_ALLOWED_TOOLS = JSON.stringify(allowedTools);
    const core = await import(new URL("../dist/routes/core.js", cliUrl));
    configureProviders(core, settings);
    const { query } = await import(pathToFileURL(createRequire(cliUrl).resolve("@anthropic-ai/claude-agent-sdk")));
    configureModelCatalog(core, settings, query);
    await import(new URL("../dist/index.js", cliUrl));
}
