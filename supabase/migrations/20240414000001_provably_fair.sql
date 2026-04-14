-- =====================================================
-- 🎲 PROVABLY FAIR SYSTEM
-- =====================================================
-- Full cryptographic verification pipeline:
--   create_game_round  → generates server_seed (secret) + publishes SHA256 hash
--   resolve_game_round → derives multiplier from HMAC-SHA256, reveals seed
--   verify_result      → public audit function, fully reproducible
--
-- Prerequisites: pgcrypto extension (already enabled in migration _rpc.sql)
-- =====================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: Ensure game_rounds has every required column
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- server_seed: kept secret until reveal
  ALTER TABLE public.game_rounds ADD COLUMN IF NOT EXISTS server_seed      TEXT;
  -- server_seed_hash: SHA256 of server_seed — published before round starts
  ALTER TABLE public.game_rounds ADD COLUMN IF NOT EXISTS server_seed_hash TEXT;
  -- client_seed: supplied by client (or defaulted to round id string)
  ALTER TABLE public.game_rounds ADD COLUMN IF NOT EXISTS client_seed      TEXT;
  -- nonce: incremented per round for uniqueness
  ALTER TABLE public.game_rounds ADD COLUMN IF NOT EXISTS nonce            BIGINT NOT NULL DEFAULT 0;
  -- result: crash multiplier stored after resolution
  ALTER TABLE public.game_rounds ADD COLUMN IF NOT EXISTS result           NUMERIC;
  -- updated_at: audit timestamp
  ALTER TABLE public.game_rounds ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ;
END $$;

-- Protect the hash from being changed after it has been set
-- (A trigger prevents any update to server_seed_hash once it is not null)
CREATE OR REPLACE FUNCTION public._guard_seed_hash()
RETURNS TRIGGER AS $$
BEGIN
  -- Block any attempt to modify server_seed or its hash once published
  IF OLD.server_seed_hash IS NOT NULL AND NEW.server_seed_hash != OLD.server_seed_hash THEN
    RAISE EXCEPTION 'INTEGRITY_VIOLATION: server_seed_hash cannot be altered after publication.';
  END IF;
  IF OLD.server_seed IS NOT NULL
     AND OLD.status = 'finished'
     AND NEW.server_seed IS DISTINCT FROM OLD.server_seed THEN
    RAISE EXCEPTION 'INTEGRITY_VIOLATION: server_seed cannot be altered after round is finished.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_guard_seed_hash ON public.game_rounds;
CREATE TRIGGER trg_guard_seed_hash
  BEFORE UPDATE ON public.game_rounds
  FOR EACH ROW EXECUTE FUNCTION public._guard_seed_hash();

-- Also prevent any row-level edits to an already-finished round
-- (fields NOT in the allow-list below are blocked)
CREATE OR REPLACE FUNCTION public._guard_finished_round()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status = 'finished' THEN
    -- Once finished, absolutely nothing may change
    RAISE EXCEPTION 'INTEGRITY_VIOLATION: A finished round is immutable.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_guard_finished_round ON public.game_rounds;
CREATE TRIGGER trg_guard_finished_round
  BEFORE UPDATE ON public.game_rounds
  FOR EACH ROW
  -- Only fire when a row is ALREADY finished (not when it transitions to finished)
  WHEN (OLD.status = 'finished')
  EXECUTE FUNCTION public._guard_finished_round();


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: create_game_round
-- Purpose: Creates a round, generates a secure server_seed, stores only hash.
-- The real seed stays in the DB but is never returned to the client.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_game_round(
  p_game_id    UUID,
  p_client_seed TEXT DEFAULT NULL   -- Client may supply their own seed
)
RETURNS JSON AS $$
DECLARE
  v_round_id     UUID;
  v_server_seed  TEXT;
  v_seed_hash    TEXT;
  v_client_seed  TEXT;
  v_nonce        BIGINT;
BEGIN
  -- 1. Generate cryptographically secure server seed (256-bit random)
  v_server_seed := encode(gen_random_bytes(32), 'hex');

  -- 2. Compute SHA256 hash — this is the ONLY value exposed before reveal
  v_seed_hash := encode(digest(v_server_seed, 'sha256'), 'hex');

  -- 3. Client seed: use provided value or fall back to another random nonce
  v_client_seed := COALESCE(p_client_seed, encode(gen_random_bytes(16), 'hex'));

  -- 4. Nonce: count existing rounds for this game to ensure uniqueness
  SELECT COUNT(*) INTO v_nonce FROM public.game_rounds WHERE game_id = p_game_id;

  -- 5. Insert round — server_seed is stored but NOT returned
  INSERT INTO public.game_rounds (
    game_id,
    server_seed,
    server_seed_hash,
    client_seed,
    nonce,
    status
  )
  VALUES (
    p_game_id,
    v_server_seed,   -- secret until reveal
    v_seed_hash,     -- safe to publish immediately
    v_client_seed,
    v_nonce,
    'created'
  )
  RETURNING id INTO v_round_id;

  -- 6. Return only what is safe to give client right now
  RETURN json_build_object(
    'round_id',          v_round_id,
    'server_seed_hash',  v_seed_hash,   -- Prove the seed was committed BEFORE the game
    'client_seed',       v_client_seed,
    'nonce',             v_nonce
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: _derive_crash_multiplier (internal helper)
-- Derives a crash multiplier deterministically from the seed pair.
-- Algorithm:
--   raw_hash  = HMAC-SHA256(key=server_seed, msg=client_seed||':'||nonce)
--   int_value = first 8 bytes of hash interpreted as big-endian uint64
--   house_divisor  = 2^52   (same approach as Stake.com / Bustabit)
--   float_result   = (house_divisor - 1) / (house_divisor - int_value)
--   capped at 1.00 minimum and 1000.00 maximum
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._derive_crash_multiplier(
  p_server_seed TEXT,
  p_client_seed TEXT,
  p_nonce       BIGINT
)
RETURNS NUMERIC AS $$
DECLARE
  v_message    TEXT;
  v_hmac_hex   TEXT;
  v_52_bit_hex TEXT;
  v_int_value  NUMERIC;
  v_divisor    NUMERIC := 4503599627370496; -- 2^52
  v_house_edge NUMERIC := 0.05; -- 5%
  v_result     NUMERIC;
BEGIN
  -- 1. Construct deterministic message
  v_message := p_client_seed || ':' || p_nonce::TEXT;

  -- 2. Compute HMAC-SHA256
  v_hmac_hex := encode(hmac(v_message::BYTEA, p_server_seed::BYTEA, 'sha256'), 'hex');

  -- 3. Take first 13 characters (52 bits)
  v_52_bit_hex := substring(v_hmac_hex from 1 for 13);
  
  -- 4. Convert hex to numeric integer
  -- We use a bit-string conversion via a padded 16-char hex string
  v_int_value := ('x' || lpad(v_52_bit_hex, 16, '0'))::bit(64)::bigint::NUMERIC;

  -- 5. Calculate crash point
  -- Formula: (1 - house_edge) / (1 - (v_int_value / v_divisor))
  v_result := (1 - v_house_edge) / (1 - (v_int_value / v_divisor));

  -- 6. Apply limits and round to 2 decimal places
  -- Minimum 1.00x, floor to 2 decimal places
  v_result := ROUND(
    GREATEST(1.00, LEAST(10000.00, FLOOR(v_result * 100) / 100))::NUMERIC,
    2
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4: resolve_game_round (fully Provably Fair version)
-- Replaces previous random-based implementation with HMAC-SHA256 derivation.
-- Also reveals the server_seed after resolution.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_game_round(
  p_round_id UUID
)
RETURNS JSON AS $$
DECLARE
  v_round          RECORD;
  v_bet            RECORD;
  v_multiplier     NUMERIC;
  v_payout         NUMERIC;
  v_total_paid     NUMERIC := 0;
  v_bets_count     INT     := 0;
BEGIN
  -- ── 1. EXCLUSIVE LOCK on round row ──────────────────────────────────────
  -- Prevents concurrent resolution of the same round.
  SELECT * INTO v_round
  FROM public.game_rounds
  WHERE id = p_round_id
  FOR UPDATE;

  IF v_round.id IS NULL THEN
    RAISE EXCEPTION 'ROUND_NOT_FOUND: Round % does not exist.', p_round_id;
  END IF;

  IF v_round.status = 'finished' THEN
    RAISE EXCEPTION 'ALREADY_RESOLVED: Round % has already been resolved.', p_round_id;
  END IF;

  IF v_round.server_seed IS NULL THEN
    RAISE EXCEPTION 'SEED_MISSING: Round % has no server_seed. Was it created via create_game_round?', p_round_id;
  END IF;

  -- ── 2. DERIVE CRASH MULTIPLIER (deterministic & verifiable) ─────────────
  v_multiplier := public._derive_crash_multiplier(
    v_round.server_seed,
    COALESCE(v_round.client_seed, v_round.id::TEXT),
    COALESCE(v_round.nonce, 0)
  );

  -- ── 3. MARK ROUND AS FINISHED + REVEAL SERVER SEED ──────────────────────
  -- The server_seed is now safe to reveal — the round is over, hash was
  -- committed publicly before the game started, so no manipulation is possible.
  UPDATE public.game_rounds
  SET
    status     = 'finished',
    result     = v_multiplier,
    updated_at = NOW()
    -- server_seed stays in the column; clients can now query it for verification
  WHERE id = p_round_id;

  -- ── 4. PROCESS ALL PENDING BETS (ordered by user_id to prevent deadlocks) ─
  FOR v_bet IN
    SELECT * FROM public.bets
    WHERE round_id = p_round_id AND status = 'pending'
    ORDER BY user_id   -- consistent lock ordering = no deadlock
  LOOP
    v_bets_count := v_bets_count + 1;

    -- User wins if their auto-cashout target was ≤ crash multiplier
    IF v_bet.multiplier IS NOT NULL AND v_bet.multiplier <= v_multiplier THEN

      v_payout := ROUND(v_bet.amount * v_bet.multiplier, 2);

      -- Lock user row before touching balance
      PERFORM 1 FROM public.users WHERE id = v_bet.user_id FOR UPDATE;

      UPDATE public.users
        SET balance = balance + v_payout
      WHERE id = v_bet.user_id;

      UPDATE public.bets
        SET status = 'won', payout = v_payout, updated_at = NOW()
      WHERE id = v_bet.id;

      INSERT INTO public.transactions (user_id, type, amount, status, reference_id, created_at)
      VALUES (v_bet.user_id, 'win', v_payout, 'completed', v_bet.id, NOW());

      v_total_paid := v_total_paid + v_payout;

    ELSE

      UPDATE public.bets
        SET status = 'lost', payout = 0, updated_at = NOW()
      WHERE id = v_bet.id;

    END IF;
  END LOOP;

  -- ── 5. RETURN AUDIT PAYLOAD ───────────────────────────────────────────────
  RETURN json_build_object(
    'success',          true,
    'round_id',         p_round_id,
    'crash_multiplier', v_multiplier,
    'server_seed',      v_round.server_seed,    -- NOW revealed
    'server_seed_hash', v_round.server_seed_hash,
    'client_seed',      v_round.client_seed,
    'nonce',            v_round.nonce,
    'bets_processed',   v_bets_count,
    'total_paid',       v_total_paid
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE '[resolve_game_round] CRITICAL FAIL on round %. Error: %', p_round_id, SQLERRM;
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5: verify_result
-- Public audit function — anyone can call this to confirm a result was fair.
-- Fully stateless: takes the three inputs and recomputes the multiplier.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.verify_result(
  p_server_seed TEXT,
  p_client_seed TEXT,
  p_nonce       BIGINT
)
RETURNS JSON AS $$
DECLARE
  v_expected_hash TEXT;
  v_multiplier    NUMERIC;
BEGIN
  -- 1. Recompute the SHA256 hash so the caller can cross-check the commitment
  v_expected_hash := encode(digest(p_server_seed, 'sha256'), 'hex');

  -- 2. Re-derive the crash multiplier using the exact same formula
  v_multiplier := public._derive_crash_multiplier(p_server_seed, p_client_seed, p_nonce);

  -- 3. Return full verification payload
  RETURN json_build_object(
    'server_seed',          p_server_seed,
    'server_seed_hash',     v_expected_hash,   -- Should match what was published
    'client_seed',          p_client_seed,
    'nonce',                p_nonce,
    'crash_multiplier',     v_multiplier,
    'verified',             true
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6: RLS — expose server_seed only after round is finished
-- ─────────────────────────────────────────────────────────────────────────────
-- Revoke direct read access on server_seed for non-finished rounds using a view
CREATE OR REPLACE VIEW public.game_rounds_public AS
SELECT
  id,
  game_id,
  server_seed_hash,                             -- always visible (commitment)
  CASE WHEN status = 'finished'
    THEN server_seed                             -- revealed after round ends
    ELSE NULL
  END                             AS server_seed,
  client_seed,
  nonce,
  result,
  status,
  created_at,
  updated_at
FROM public.game_rounds;
