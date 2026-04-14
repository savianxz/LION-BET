-- =====================================================================
-- 🔐 USER SEED MANAGEMENT — Provably Fair Trust Enhancement
-- =====================================================================
-- Allows users to persist their own client_seed and update it.
-- This ensures that the platform cannot guess the user's next seed
-- and manipulate the outcome.
-- =====================================================================

-- ─────────────────────────────────────────────────────────────────────
-- 1. ADD SEED COLUMNS TO USERS
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS active_client_seed TEXT NOT NULL DEFAULT gen_random_uuid()::TEXT,
  ADD COLUMN IF NOT EXISTS seed_updated_at    TIMESTAMPTZ DEFAULT NOW();


-- ─────────────────────────────────────────────────────────────────────
-- 2. update_client_seed — User RPC
-- ─────────────────────────────────────────────────────────────────────
-- Flow:
--   1. Authenticate user
--   2. Rate limit: 10 seconds between seed changes
--   3. Apply new seed (immediately affects the NEXT round they join)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_client_seed(
  p_new_seed TEXT
)
RETURNS JSON AS $$
DECLARE
  v_user_id UUID;
  v_last_updated TIMESTAMPTZ;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: User must be authenticated.';
  END IF;

  IF p_new_seed IS NULL OR length(p_new_seed) < 4 OR length(p_new_seed) > 64 THEN
    RAISE EXCEPTION 'INVALID_SEED: Must be between 4 and 64 characters.';
  END IF;

  SELECT seed_updated_at INTO v_last_updated
  FROM public.users WHERE id = v_user_id;

  IF v_last_updated IS NOT NULL AND (NOW() - v_last_updated) < interval '10 seconds' THEN
    RAISE EXCEPTION 'RATE_LIMITED: Please wait before changing your seed again.';
  END IF;

  UPDATE public.users
  SET active_client_seed = p_new_seed,
      seed_updated_at = NOW()
  WHERE id = v_user_id;

  RETURN json_build_object(
    'success', true,
    'new_seed', p_new_seed,
    'updated_at', NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 3. update place_bet to use the user's active_client_seed
-- ─────────────────────────────────────────────────────────────────────
-- We'll modify the place_bet function to snapshot the user's seed
-- into the bet record at the time of placement.
-- First, add the column to the bets table if it doesn't exist.
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.bets
  ADD COLUMN IF NOT EXISTS client_seed_at_bet TEXT;

-- NOTE: The actual `place_bet` modification will be handled in the next
-- migration to ensure atomicity of the logic changes.
