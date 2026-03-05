export function nowIso(): string {
  return new Date().toISOString();
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function monotonicMs(): number {
  return Math.floor(performance.now());
}

export function nextDelayWithBackoff(baseMs: number, attempt: number, maxMs: number): number {
  const exponent = Math.max(0, attempt - 1);
  const raw = baseMs * 2 ** exponent;
  return Math.min(maxMs, Number.isFinite(raw) ? raw : maxMs);
}
