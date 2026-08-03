// POST /functions/v1/item-image  { image:{data(b64),mimeType}, instruction }
// Generate a flat e-commerce PRODUCT SHOT of a garment (no person) for the
// editor's option thumbnails. The client passes a blank white canvas as `image`;
// the prompt here — unlike generate-fix — never mentions a person, so Gemini
// draws the garment alone. Returns { image:{ data(b64), mimeType } }.
import { admin, getUser } from "../_shared/supabase.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { cacheGet, cachePut, sha256Hex } from "../_shared/tryon_cache.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { image, instruction } = await req.json().catch(() => ({}));
  if (!image?.data || !image?.mimeType) return json({ error: "image { data, mimeType } required" }, 400);
  if (!instruction) return json({ error: "instruction required" }, 400);

  const prompt = [
    `A clean e-commerce flat-lay product photograph of ${instruction}.`,
    "Show ONLY the clothing item itself — laid flat or on an invisible ghost mannequin — centered and filling the frame on a plain pure-white (#FFFFFF) background.",
    "Absolutely NO person, NO human, NO model, NO face, NO body, NO hands, NO mannequin, NO hanger, NO text, NO logos, NO props, NO shadows scene — just the garment on white.",
  ].join(" ");

  // Thumbnails are re-requested on EVERY editor entry with identical inputs —
  // the cache turns those repeats into sub-second responses. Keyed on the
  // instruction + source canvas + model (the canvas is a constant white JPEG,
  // so effectively: same garment description = same thumb, for everyone).
  const model = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
  const cacheKey = await sha256Hex(["item:v1", model, image.data, instruction].join("|"));
  const cached = await cacheGet(db, cacheKey);
  if (cached) return json({ image: cached, cached: true });

  try {
    const out = await generateLookImage({ data: image.data, mimeType: image.mimeType }, prompt);
    await cachePut(db, cacheKey, user.id, "item", out);
    return json({ image: out });
  } catch (err) {
    console.error("[item-image]", (err as Error).message);
    return json({ error: "item_failed" }, 502);
  }
});
