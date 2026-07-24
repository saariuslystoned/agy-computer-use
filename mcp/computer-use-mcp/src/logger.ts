/**
 * Stderr-only logger.
 * IMPORTANT: Standard output (stdout) is reserved exclusively for MCP JSON-RPC protocol frames.
 * All diagnostic logs must be written strictly to stderr.
 */
export class Logger {
  public static info(message: string, ...meta: unknown[]): void {
    const formatted = `[INFO] ${new Date().toISOString()} - ${message}`;
    if (meta.length > 0) {
      console.error(formatted, ...meta);
    } else {
      console.error(formatted);
    }
  }

  public static warn(message: string, ...meta: unknown[]): void {
    const formatted = `[WARN] ${new Date().toISOString()} - ${message}`;
    if (meta.length > 0) {
      console.error(formatted, ...meta);
    } else {
      console.error(formatted);
    }
  }

  public static error(message: string, ...meta: unknown[]): void {
    const formatted = `[ERROR] ${new Date().toISOString()} - ${message}`;
    if (meta.length > 0) {
      console.error(formatted, ...meta);
    } else {
      console.error(formatted);
    }
  }
}
