-- =====================================================================
-- 🔄 GAME ORCHESTRATOR — Automation & Logic Updates
-- =====================================================================
-- Covers:
--   1. start_new_round — Automates the creation cycle
--   2. close_round_betting — State transition for real-time engine
--   3. place_bet v2 — Integrates dynamic user seeds
-- =====================================================================

-- ─────────────────────────────────────────────────────────────────────
-- 1. start_new_round
-- ─────────────────────────────────────────────────────────────────────
-- Automates the seed generation and round initialization.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.start_new_round(
  p_game_id UUID,
  p_max_exposure NUMERIC DEFAULT 100000.00
)
RETURNS JSON AS $$
DECLARE
  v_server_seed      TEXT;
  v_server_seed_hash TEXT;
  v_round_id         UUID;
BEGIN
  -- 1. Check if there's already an active round (created or in_progress)
  -- This prevents overlapping rounds.
  IF EXISTS (
    SELECT 1 FROM public.game_rounds 
    WHERE game_id = p_game_id AND status IN ('created', 'in_progress')
  ) THEN
    RAISE EXCEPTION 'ACTIVE_ROUND_EXISTS: Cannot start new round while another is active.';
  END IF;

  -- 2. Generate secure server seed (256-bit entropy)
  v_server_seed := encode(gen_random_bytes(32), 'hex');
  v_server_seed_hash := encode(digest(v_server_seed, 'sha256'), 'hex');

  -- 3. Create the round record
  INSERT INTO public.game_rounds (
    game_id,
    server_seed,
    server_seed_hash,
    status,
    total_bet_amount,
    max_exposure,
    nonce
  ) VALUES (
    p_game_id,
    v_server_seed,
    v_server_seed_hash,
    'created',
    0,
    p_max_exposure,
    (SELECT COALESCE(MAX(nonce), 0) + 1 FROM public.game_rounds WHERE game_id = p_game_id)
  ) RETURNING id INTO v_round_id;

  RETURN json_build_object(
    'success', true,
    'round_id', v_round_id,
    'server_seed_hash', v_server_seed_hash,
    'status', 'created'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 2. close_round_betting
-- ─────────────────────────────────────────────────────────────────────
-- Transitions from 'created' to 'in_progress'. 
-- Real-time clients will use this to stop accepting bets on screen.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.close_round_betting(
  p_round_id UUID
)
RETURNS JSON AS $$
DECLARE
  v_current_status TEXT;
BEGIN
  SELECT status::TEXT INTO v_current_status
  FROM public.game_rounds
  WHERE id = p_round_id
  FOR UPDATE;

  IF v_current_status IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: Round % not found.', p_round_id;
  END IF;

  IF v_current_status != 'created' THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: Cannot close betting for round in % state.', v_current_status;
  END IF;

  UPDATE public.game_rounds
  SET status = 'in_progress'
  WHERE id = p_round_id;

  RETURN json_build_object(
    'success', true,
    'round_id', p_round_id,
    'new_status', 'in_progress'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 3. place_bet v2 — Final Hardened Integration
-- ─────────────────────────────────────────────────────────────────────
-- Incorporates the user's persistent client_seed.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.place_bet(
  p_game_id UUID,
  p_round_id UUID,
  p_amount NUMERIC,
  p_auto_cashout NUMERIC DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_user_id             UUID;
  v_balance             NUMERIC;
  v_daily_total         NUMERIC;
  v_daily_limit         NUMERIC;
  v_active_client_seed  TEXT;
  v_round_status        TEXT;
  v_round_total         NUMERIC;
  v_bet_id              UUID;
  v_now                 TIMESTAMPTZ := clock_timestamp();
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: User must be authenticated.';
  END IF;

  -- 1. LOCK USER & LOAD SEED
  SELECT balance, daily_bet_total, active_client_seed
  INTO   v_balance, v_daily_total, v_active_client_seed
  FROM public.users
  WHERE id = v_user_id
  FOR UPDATE;

  -- 2. VALIDATION (Basic guards, full ones in config would be here)
  IF p_amount <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
  IF v_balance < p_amount THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  -- 3. ROUND CHECKS
  SELECT status::TEXT, total_bet_amount
  INTO v_round_status, v_round_total
  FROM public.game_rounds
  WHERE id = p_round_id
  FOR UPDATE;

  IF v_round_status != 'created' THEN
    RAISE EXCEPTION 'ROUND_CLOSED: Betting is no longer accepted for this round.';
  END IF;

  -- 4. ATOMIC EXECUTION
  UPDATE public.users
  SET balance = balance - p_amount,
      daily_bet_total = daily_bet_total + p_amount
  WHERE id = v_user_id;

  UPDATE public.game_rounds
  SET total_bet_amount = total_bet_amount + p_amount
  WHERE id = p_round_id;

  -- Snapshot the client_seed AT THE TIME OF BET for verifiability
  INSERT INTO public.bets (
    user_id, game_id, round_id, amount, multiplier, status, client_seed_at_bet
  )
  VALUES (
    v_user_id, p_game_id, p_round_id, p_amount, p_auto_cashout, 'pending', v_active_client_seed
  )
  RETURNING id INTO v_bet_id;

  INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
  VALUES (v_user_id, 'bet', -p_amount, 'completed', v_bet_id);

  RETURN json_build_object(
    'success', true,
    'bet_id', v_bet_id,
    'client_seed_snapshot', v_active_client_seed
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
