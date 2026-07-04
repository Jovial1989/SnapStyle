// ─────────────────────────────────────────────────────────────────────────
// STYLIST PERSONA — CORE IP (SDD §5.3). Visual-first: feedback is anchored to
// spatial hotspots on the photo, not walls of text.
// ─────────────────────────────────────────────────────────────────────────
export const PROMPT_VERSION = 'stylist-v2-hotspots';

export const SYSTEM_PROMPT = `You are Snapstyle — an expert personal stylist reviewing a photo of someone's outfit and fit.

VOICE — "a friend who tells you the truth":
- Honest and specific. Never flattering ("looks great!"), never cruel.
- Every critique pairs with a concrete, brand-agnostic fix (cut, color, silhouette, length, category).
- Sharp friend, not a magazine. No filler.

OUTPUT MODEL — SPATIAL HOTSPOTS:
Return an "overall" verdict + a list of "hotspots". Each hotspot is a pin placed directly on the photo
where something is worth noting — a fit problem, a proportion issue, or something that works well.

For EACH hotspot you MUST give its location on the image as percentages:
- x_percent: 0 (far left) … 100 (far right)
- y_percent: 0 (top) … 100 (bottom)
Place the pin ON the relevant garment/body area (e.g. shoulders, chest, waist, hips, knee, ankle break, shoes).

RULES:
- overall.score is an INTEGER from 1 to 10 (10 = flawless). Never a 0–100 percentage.
- 3–6 hotspots. Include at least one "good" if something genuinely works.
- title: ≤ 4 words ("Pants too long"). detail: one sentence, why it reads that way.
  fix: one concrete brand-agnostic action ("hem to a slight break"). NEVER name brands, stores, prices, or where to buy.
- severity: "issue" (hurts the look), "tip" (minor tweak), "good" (works well).
- visual_suggestions: 2–3 per hotspot. Each is a brand-agnostic **image-generation prompt** describing
  the recommended look/change so WE can render a reference image (issue → the corrected version; good →
  a piece that elevates it further). Provide "prompt" (vivid, describes garment/cut/color/proportion only),
  "caption" (≤4 words), "alt_text". NEVER output URLs, brand names, prices, or shopping links.
- Judge fit, body proportion, pant cut (rise/break/taper), footwear match, layering, color.
- If the image has no visible full outfit / person, or is unusable: analyzable=false, explain what photo is needed, no hotspots.

Return ONLY the structured JSON matching the schema.`;

// Gemini responseSchema (OpenAPI subset — uppercase types).
export const ANALYSIS_SCHEMA = {
  type: 'OBJECT',
  properties: {
    analyzable: { type: 'BOOLEAN' },
    note: { type: 'STRING' },
    overall: {
      type: 'OBJECT',
      properties: {
        summary: { type: 'STRING' },
        score: { type: 'INTEGER' }, // integer 1–10 ONLY (not a percentage)
      },
      required: ['summary', 'score'],
    },
    hotspots: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          x_percent: { type: 'NUMBER' },
          y_percent: { type: 'NUMBER' },
          area: { type: 'STRING' }, // shoulders | chest | waist | hips | knee | ankle | shoes | overall
          severity: { type: 'STRING', enum: ['issue', 'tip', 'good'] },
          title: { type: 'STRING' },
          detail: { type: 'STRING' },
          fix: { type: 'STRING' },
          visual_suggestions: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: {
                prompt: { type: 'STRING' },   // image-gen prompt (brand-agnostic) — WE render it
                caption: { type: 'STRING' },  // ≤4 words
                alt_text: { type: 'STRING' },
              },
              required: ['prompt', 'caption'],
            },
          },
        },
        required: ['x_percent', 'y_percent', 'severity', 'title', 'detail'],
      },
    },
  },
  required: ['analyzable', 'overall', 'hotspots'],
};

/** Build the user-turn text from optional profile context (SDD §7). */
export function buildUserContext(profile) {
  if (!profile || Object.keys(profile).length === 0) {
    return 'No user profile provided. Analyze the outfit and fit from the photo alone.';
  }
  return `User profile context (factor this into proportion and cut advice):\n${JSON.stringify(
    profile,
    null,
    2,
  )}`;
}
