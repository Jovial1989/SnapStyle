-- Which studio base a user was matched to, and where their swapped copy lives.
--
-- The pieces existed and did not touch: studio_bases holds ten A-pose bodies
-- measured for skin tone and build, faceswap.py transfers a face onto one, and
-- the queue already carries face_url/base_id. What was missing is the pointer
-- between a USER and the result — without it every render would re-run the swap,
-- which is both slow and a different face each time (the transfer is
-- deterministic, but re-selecting a base is not once the library grows).
--
-- studio_base_path is the swapped, dressed-in-basics canvas in `body-photos`,
-- and it slots in ahead of `.bare.png` for exactly the same reason `.bare.png`
-- came ahead of `.avatar.png`: the mask stage stops fighting the input. The
-- mid-stride photograph measured heel_dy 0.056 of the figure's span; the A-pose
-- library measures 0.000-0.009, which is the whole footwear defect class gone
-- upstream of the engine.
alter table public.style_profiles
  add column if not exists studio_base_id uuid references public.studio_bases (id),
  add column if not exists studio_base_path text,
  -- The selfie itself, kept so the swap can be re-run when the library grows or
  -- the transfer improves. Face photos are personal data: same bucket, same
  -- per-user folder, same RLS as the body photo.
  add column if not exists face_photo_path text,
  -- Measured inter-ocular distance of that selfie, in pixels. A gate, not a
  -- statistic: below the chosen base's own face size the transfer upsamples and
  -- smudges (verified at 34 px against a 55 px target), so a too-small selfie
  -- must be REJECTED with a reason the user can act on rather than silently
  -- producing a blurred face.
  add column if not exists face_interocular smallint;
