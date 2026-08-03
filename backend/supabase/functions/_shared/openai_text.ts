// OpenAI text+vision JSON helper — the reliable half of the vision seam.
//
// Gemini gave us `responseSchema`; the local Qwen worker has no constrained
// decoding at all and needs a tolerant parser. OpenAI sits in between and is
// the strictest of the three: `response_format: json_schema` with
// `strict: true` GUARANTEES a conforming object, so callers can trust shapes
// instead of coercing them.
//
// strict mode rules that bite (they are why this helper normalises schemas):
//   • every object needs additionalProperties: false
//   • EVERY property must be listed in `required` — optional fields do not
//     exist; model them as nullable or as arrays that may be empty.
import type { Inline } from "./gemini.ts";

export const TEXT_MODEL = () => Deno.env.get("OPENAI_TEXT_MODEL") ?? "gpt-5.4-mini";

/** Recursively enforce the two strict-mode invariants so call sites can write
 * ordinary JSON Schema and not think about it. */
export function strictify(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(strictify);
  if (!schema || typeof schema !== "object") return schema;
  const s = { ...(schema as Record<string, unknown>) };
  if (s.type === "object" && s.properties && typeof s.properties === "object") {
    const props = s.properties as Record<string, unknown>;
    for (const k of Object.keys(props)) props[k] = strictify(props[k]);
    s.required = Object.keys(props);
    s.additionalProperties = false;
  }
  if (s.type === "array" && s.items) s.items = strictify(s.items);
  return s;
}

export async function openaiJson<T = unknown>(args: {
  system: string;
  user: string;
  images?: Inline[];
  schema: { name: string; schema: unknown };
  temperature?: number;
  maxTokens?: number;
}): Promise<T> {
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) throw new Error("OPENAI_API_KEY missing");

  const content: unknown[] = [{ type: "text", text: args.user }];
  for (const im of args.images ?? []) {
    content.push({
      type: "image_url",
      image_url: { url: `data:${im.mimeType};base64,${im.data}` },
    });
  }

  const body: Record<string, unknown> = {
    model: TEXT_MODEL(),
    messages: [
      { role: "system", content: args.system },
      { role: "user", content },
    ],
    response_format: {
      type: "json_schema",
      json_schema: { name: args.schema.name, strict: true, schema: strictify(args.schema.schema) },
    },
    max_completion_tokens: args.maxTokens ?? 4000,
  };
  // Reasoning-era models reject a non-default temperature; only send it when asked.
  if (args.temperature !== undefined) body.temperature = args.temperature;

  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(Number(Deno.env.get("OPENAI_TEXT_TIMEOUT_MS") ?? 120_000)),
  });
  if (!res.ok) throw new Error(`openai text ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const j = await res.json();
  const txt = j?.choices?.[0]?.message?.content;
  if (!txt) {
    // A refusal or a length cut-off both land here; surface which.
    const why = j?.choices?.[0]?.message?.refusal ?? j?.choices?.[0]?.finish_reason ?? "no content";
    throw new Error(`openai text: ${why}`);
  }
  return JSON.parse(txt) as T;
}
