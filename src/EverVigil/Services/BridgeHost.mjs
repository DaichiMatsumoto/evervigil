import { statSync } from "node:fs";
import { isAbsolute } from "node:path";
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
    await import(new URL("../dist/index.js", cliUrl));
}
