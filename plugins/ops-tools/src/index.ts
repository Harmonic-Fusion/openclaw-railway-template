import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

import { defineToolPlugin } from "openclaw/plugin-sdk/tool-plugin";
import { Type, type TSchema } from "typebox";

const execFileAsync = promisify(execFile);

const DEFAULT_BIN_DIR = "/app/bin";
const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_OUTPUT_BYTES = 8 * 1024 * 1024;

type ParameterSpec = {
  type: "string" | "integer" | "number" | "boolean";
  description?: string;
  required?: boolean;
  /** Flag the value is passed with, e.g. "--min-size". Booleans pass the flag alone. */
  flag?: string;
  /** Pass as a positional argument instead. Positionals keep declaration order. */
  positional?: boolean;
};

type ToolSpec = {
  name: string;
  label?: string;
  description: string;
  /** Script name inside the bin directory. */
  command: string;
  /** Arguments always passed, e.g. ["--json"]. */
  args?: string[];
  /** Register as optional so it stays hidden until allowlisted in tools.allow. */
  optional?: boolean;
  result?: {
    format?: "json" | "text";
    /** Wrapper key for the parsed value. Keeps reserved names out of `details`. */
    key?: string;
  };
  parameters?: Record<string, ParameterSpec>;
};

type OpsConfig = {
  binDir?: string;
  timeoutMs?: number;
};

type ExecuteContext = {
  signal?: AbortSignal;
};

const specs = loadToolSpecs();

function loadToolSpecs(): ToolSpec[] {
  const file = new URL("../tools.json", import.meta.url);
  const parsed = JSON.parse(readFileSync(file, "utf8")) as { tools?: ToolSpec[] };
  if (!Array.isArray(parsed.tools) || parsed.tools.length === 0) {
    throw new Error("tools.json must declare a non-empty tools array");
  }
  return parsed.tools;
}

function parameterSchema(spec: ParameterSpec): TSchema {
  const options = spec.description ? { description: spec.description } : {};
  switch (spec.type) {
    case "string":
      return Type.String(options);
    case "integer":
      return Type.Integer(options);
    case "number":
      return Type.Number(options);
    case "boolean":
      return Type.Boolean(options);
  }
}

function toolParameters(spec: ToolSpec) {
  const properties: Record<string, TSchema> = {};
  for (const [name, parameter] of Object.entries(spec.parameters ?? {})) {
    const schema = parameterSchema(parameter);
    properties[name] = parameter.required ? schema : Type.Optional(schema);
  }
  return Type.Object(properties, { additionalProperties: false });
}

function toolArguments(spec: ToolSpec, params: Record<string, unknown>): string[] {
  const positionals: string[] = [];
  const flags: string[] = [];
  for (const [name, parameter] of Object.entries(spec.parameters ?? {})) {
    const value = params[name];
    if (value === undefined || value === null) {
      continue;
    }
    if (parameter.type === "boolean") {
      if (value === true && parameter.flag) {
        flags.push(parameter.flag);
      }
      continue;
    }
    if (parameter.positional) {
      positionals.push(String(value));
    } else if (parameter.flag) {
      flags.push(parameter.flag, String(value));
    }
  }
  return [...positionals, ...(spec.args ?? []), ...flags];
}

async function runTool(
  spec: ToolSpec,
  params: Record<string, unknown>,
  config: OpsConfig,
  context: ExecuteContext,
): Promise<unknown> {
  context.signal?.throwIfAborted();
  const file = path.join(config.binDir ?? DEFAULT_BIN_DIR, spec.command);
  const { stdout } = await execFileAsync(file, toolArguments(spec, params), {
    timeout: config.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxBuffer: MAX_OUTPUT_BYTES,
    signal: context.signal,
  });
  if (spec.result?.format !== "json") {
    return stdout;
  }
  const parsed: unknown = JSON.parse(stdout);
  return spec.result.key ? { [spec.result.key]: parsed } : parsed;
}

export default defineToolPlugin({
  id: "ops-tools",
  name: "Ops Tools",
  description: "Typed tools for the console helper scripts in /app/bin.",
  configSchema: Type.Object({
    binDir: Type.Optional(
      Type.String({ description: "Directory holding the helper scripts (default /app/bin)." }),
    ),
    timeoutMs: Type.Optional(
      Type.Number({ description: "Per-command timeout in milliseconds (default 120000)." }),
    ),
  }),
  tools: (tool) =>
    specs.map((spec) =>
      tool({
        name: spec.name,
        label: spec.label,
        description: spec.description,
        optional: spec.optional,
        parameters: toolParameters(spec),
        execute: (params, config, context) =>
          runTool(spec, params as Record<string, unknown>, config, context),
      }),
    ),
});
