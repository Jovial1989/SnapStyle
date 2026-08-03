// Garment NAMES injected into image prompts can override the reference
// photo: "Off-White Regular Fit Tee" made gemini-2.5-flash-image draw
// Off-White™ diagonal stripes over a plain cream tee (spike 28.07.2026).
// Neutralize brand-homonym words; the photos stay the source of truth.
const BRAND_HOMONYMS: [RegExp, string][] = [
  [/\boff[- ]white\b/gi, "cream"],
  [/\bsupreme\b/gi, "premium"],
  [/\bchampion\b/gi, "athletic"],
  [/\bobey\b/gi, "casual"],
  [/\bguess\b/gi, "classic"],
  [/\bcoach\b/gi, "varsity"],
  [/\bhollister\b/gi, "coastal"],
  [/\bgap\b/gi, "everyday"],
];

export function promptSafeName(name: string): string {
  let out = name;
  for (const [re, sub] of BRAND_HOMONYMS) out = out.replace(re, sub);
  return out.replace(/\s{2,}/g, " ").trim();
}

// One clause for every prompt that lists garments by name.
export const NO_BRAND_CLAUSE =
  "Reference photos are the ONLY source of truth for graphics, logos and " +
  "patterns — never add a brand logo or brand pattern implied by a name. ";
