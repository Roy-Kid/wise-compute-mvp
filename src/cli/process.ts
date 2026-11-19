import { spawn } from "node:child_process";

export interface Execution {
  cwd?: string;
  signal?: AbortSignal;
  inherit?: boolean;
  logs?: boolean;
}

export interface CommandResult {
  code: number;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
}

export type Run = (program: string, args: readonly string[], execution?: Execution) =>
  Promise<CommandResult>;

export const run: Run = (program, args, execution = {}) => new Promise((resolve, reject) => {
  const child = spawn(program, args, {
    cwd: execution.cwd,
    signal: execution.signal,
    stdio: execution.inherit ? "inherit" : ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout?.setEncoding("utf8").on("data", (data: string) => {
    stdout += data;
    if (execution.logs) process.stderr.write(data);
  });
  child.stderr?.setEncoding("utf8").on("data", (data: string) => {
    stderr += data;
    if (execution.logs) process.stderr.write(data);
  });
  child.on("error", reject);
  child.on("close", (code, signal) => resolve({ code: code ?? 1, signal, stdout, stderr }));
});

export class CommandError extends Error {
  constructor(readonly result: CommandResult) {
    super(result.stderr.trim() || result.stdout.trim() || `command exited with status ${result.code}`);
  }
}

export function checked(result: CommandResult): string {
  if (result.code !== 0) throw new CommandError(result);
  return result.stdout;
}
