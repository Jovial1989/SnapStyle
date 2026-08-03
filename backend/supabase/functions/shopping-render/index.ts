// POST /functions/v1/shopping-render  { itemImage:{data,mimeType}, pairing? }
// P0-2 follow-up: render the checked garment on the user's own avatar (their
// stored body photo), optionally paired with a wardrobe combo. Streams AFTER
// the textual verdict. Authed, NO credit burned (rides on the paid check).
import { admin, getUser, signedUrl } from "../_shared/supabase.ts";
import { fetchInline } from "../_shared/gemini.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { itemImage, pairing, category } = await req.json().catch(() => ({}));
  if (!itemImage?.data || !itemImage?.mimeType) return json({ error: "itemImage { data, mimeType } required" }, 400);
  const cat = typeof category === "string" ? category : null;

  const { data: sp } = await db.from("style_profiles").select("source_photo_path").eq("user_id", user.id).maybeSingle();
  const photoPath = sp?.source_photo_path as string | null;
  if (!photoPath) return json({ error: "no_body_photo" }, 409);

  try {
    const person = await fetchInline(await signedUrl(db, "body-photos", photoPath, 300));
    const prompt = [
      "The first image is a person; the second image is a garment.",
      cat ? `Show the person wearing that exact garment as their ${cat}.` : "Show the person wearing that exact garment.",
      "Reproduce the garment from the second image FAITHFULLY — its exact colour, pattern and print (stripes, checks, graphics), cut and length. Do NOT substitute a plain or different garment.",
      pairing ? `Pair it with ${pairing}.` : "Keep the rest of their current outfit simple and neutral.",
      "Keep their face, hair, body, pose and identity completely unchanged.",
      "Photorealistic, full-body head-to-toe, centered and filling the frame, on a plain seamless pure-white (#FFFFFF) studio background, soft even lighting.",
      "No logos, no brand names, no text, no watermarks.",
    ].join(" ");
    const out = await generateLookImage(person, prompt, [{ data: itemImage.data, mimeType: itemImage.mimeType }]);
    return json({ image: out });
  } catch (err) {
    console.error("[shopping-render]", (err as Error).message);
    return json({ error: "render_failed" }, 502);
  }
});
