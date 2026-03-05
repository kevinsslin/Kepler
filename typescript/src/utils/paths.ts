import path from "node:path";
import os from "node:os";

export function expandHome(rawPath: string): string {
  if (rawPath === "~") {
    return os.homedir();
  }

  if (rawPath.startsWith("~/")) {
    return path.join(os.homedir(), rawPath.slice(2));
  }

  return rawPath;
}

export function expandEnvRef(raw: string | null | undefined, fallback: string | null = null): string | null {
  if (raw == null) {
    return fallback;
  }

  const trimmed = raw.trim();
  if (trimmed === "") {
    return fallback;
  }

  if (trimmed.startsWith("$") && trimmed.length > 1) {
    return process.env[trimmed.slice(1)] ?? fallback;
  }

  return trimmed;
}

export function normalizePath(rawPath: string): string {
  return path.resolve(expandHome(rawPath));
}

export function isSubpath(root: string, candidate: string): boolean {
  const normalizedRoot = path.resolve(root);
  const normalizedCandidate = path.resolve(candidate);

  if (normalizedRoot === normalizedCandidate) {
    return false;
  }

  return normalizedCandidate.startsWith(`${normalizedRoot}${path.sep}`);
}
