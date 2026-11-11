export class HttpError extends Error {
  constructor(public status: number, message: string, public code = "error") {
    super(message);
  }
}

export function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new HttpError(400, "Body must be valid JSON", "bad_json");
  }
}

export function str(v: unknown, name: string, opts: { optional?: boolean; max?: number } = {}): string {
  if (v === undefined || v === null || v === "") {
    if (opts.optional) return "";
    throw new HttpError(400, `${name} is required`, "validation");
  }
  if (typeof v !== "string") throw new HttpError(400, `${name} must be a string`, "validation");
  if (opts.max && v.length > opts.max) throw new HttpError(400, `${name} is too long`, "validation");
  return v;
}

type Handler<C> = (req: Request, params: Record<string, string>, ctx: C) => Promise<Response>;

export class Router<C> {
  private routes: { method: string; re: RegExp; keys: string[]; h: Handler<C> }[] = [];
  on(method: string, path: string, h: Handler<C>) {
    const keys: string[] = [];
    const re = new RegExp(
      "^" + path.replace(/:(\w+)/g, (_, k) => (keys.push(k), "([^/]+)")) + "/?$",
    );
    this.routes.push({ method, re, keys, h });
    return this;
  }
  match(method: string, pathname: string): { h: Handler<C>; params: Record<string, string> } | null {
    for (const r of this.routes) {
      if (r.method !== method) continue;
      const m = r.re.exec(pathname);
      if (!m) continue;
      const params: Record<string, string> = {};
      r.keys.forEach((k, i) => (params[k] = decodeURIComponent(m[i + 1])));
      return { h: r.h, params };
    }
    return null;
  }
}
