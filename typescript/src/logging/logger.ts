export type LogLevel = "debug" | "info" | "warn" | "error";

function serialize(value: unknown): unknown {
  if (value instanceof Error) {
    return {
      name: value.name,
      message: value.message,
      stack: value.stack
    };
  }

  return value;
}

function redact(value: unknown): unknown {
  if (value == null) {
    return value;
  }

  if (Array.isArray(value)) {
    return value.map((entry) => redact(entry));
  }

  if (typeof value === "object") {
    const out: Record<string, unknown> = {};

    for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
      if (/(token|api[_-]?key|secret|password)/i.test(key)) {
        out[key] = "[redacted]";
      } else {
        out[key] = redact(entry);
      }
    }

    return out;
  }

  return value;
}

export function log(level: LogLevel, message: string, fields: Record<string, unknown> = {}): void {
  const extra = (redact(serialize(fields)) ?? {}) as Record<string, unknown>;
  const payload = {
    timestamp: new Date().toISOString(),
    level,
    ...extra,
    message
  };

  const line = JSON.stringify(payload);

  if (level === "error") {
    console.error(line);
    return;
  }

  if (level === "warn") {
    console.warn(line);
    return;
  }

  console.log(line);
}

export const logger = {
  debug: (message: string, fields?: Record<string, unknown>) => log("debug", message, fields),
  info: (message: string, fields?: Record<string, unknown>) => log("info", message, fields),
  warn: (message: string, fields?: Record<string, unknown>) => log("warn", message, fields),
  error: (message: string, fields?: Record<string, unknown>) => log("error", message, fields)
};
