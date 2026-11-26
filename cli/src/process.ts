import { spawn } from "node:child_process";
import { constants } from "node:os";

/**
 * - `capture`: stdout and stderr are captured silently.
 * - `tee`: captured, and also streamed to our stderr so progress stays visible while stdout carries JSON.
 */
export type Stdio = "capture" | "tee";

export interface CommandResult {
  code: number;
  stdout: string;
  stderr: string;
}

export type Run = (program: string, args: readonly string[], options?: { cwd?: string; env?: NodeJS.ProcessEnv; stdio?: Stdio }) =>
  Promise<CommandResult>;

export const run: Run = (program, args, { cwd, env, stdio = "capture" } = {}) => new Promise((resolve, reject) => {
  const child = spawn(program, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (data: string) => {
    stdout += data;
    if (stdio === "tee") process.stderr.write(data);
  });
  child.stderr.setEncoding("utf8").on("data", (data: string) => {
    stderr += data;
    if (stdio === "tee") process.stderr.write(data);
  });
  child.on("error", reject);
  // Shell convention: a child killed by a signal reports 128 + the signal number.
  child.on("close", (code, signal) =>
    resolve({ code: code ?? 128 + (signal ? constants.signals[signal] : 0), stdout, stderr }));
});

export class CommandError extends Error {
  readonly result: CommandResult;

  constructor(program: string, result: CommandResult) {
    super(result.stderr.trim() || result.stdout.trim() || `${program} exited with status ${result.code}`);
    this.result = result;
  }
}

/** Returns stdout, or throws CommandError for a non-zero exit. */
export async function checked(program: string, pending: Promise<CommandResult>): Promise<string> {
  const result = await pending;
  if (result.code !== 0) throw new CommandError(program, result);
  return result.stdout;
}
