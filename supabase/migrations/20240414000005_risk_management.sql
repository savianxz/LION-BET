-- =====================================================================
-- 📊 RISK MANAGEMENT SYSTEM
-- =====================================================================
-- Protects the platform from excessive financial exposure via:
--   1. Per-bet max limit (already existed, now configurable)
--   2. Per-user daily betting limit
--   3. Per-round total exposure cap
--   4. Daily reset mechanism
-- All enforced atomically inside place_bet — no bypass via concurrency.
-- =====================================================================


-- ─────────────────────────────────────────────────────────────────────
-- 1. PLATFORM RISK CONFIGURATION TABLE
-- ─────────────────────────────────────────────────────────────────────
-- Centralizes all limits instead of hardcoding in functions.
-- Single-row config pattern: only one row allowed.
CREATE TABLE IF NOT EXISTS public.platform_config (
  id             INT PRIMARY KEY DEFAULT 1 CHECK (id = 1), -- enforces single row
  max_bet        NUMERIC(20, 8) NOT NULL DEFAULT 10000.00,
  daily_limit    NUMERIC(20, 8) NOT NULL DEFAULT 50000.00,
  round_limit    NUMERIC(20, 8) NOT NULL DEFAULT 100000.00,
  min_bet        NUMERIC(20, 8) NOT NULL DEFAULT 1.00,
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);

-- Insert default config
INSERT INTO public.platform_config (max_bet, daily_limit, round_limit, min_bet)
VALUES (10000.00, 50000.00, 100000.00, 1.00)
ON CONFLICT (id) DO NOTHING;

-- RLS: readable by system functions, no direct user writes
ALTER TABLE public.platform_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read platform config" ON public.platform_config
  FOR SELECT USING (true);
CREATE POLICY "No direct writes on config" ON public.platform_config
  FOR ALL USING (false);


-- ─────────────────────────────────────────────────────────────────────
-- 2. ADD RISK TRACKING COLUMNS
-- ─────────────────────────────────────────────────────────────────────

-- Users: track daily betting volume
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS daily_bet_total    NUMERIC(20, 8) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS daily_bet_reset_at DATE NOT NULL DEFAULT CURRENT_DATE;

-- Game Rounds: track total exposure per round
ALTER TABLE public.game_rounds
  ADD COLUMN IF NOT EXISTS total_bet_amount NUMERIC(20, 8) NOT NULL DEFAULT 0;

-- Constraint: daily total can never be negative
DO $$
BEGIN
  ALTER TABLE public.users ADD CONSTRAINT users_daily_bet_total_non_negative CHECK (daily_bet_total >= 0);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- Constraint: round total can never be negative
DO $$
BEGIN
  ALTER TABLE public.game_rounds ADD CONSTRAINT game_rounds_total_bet_non_negative CHECK (total_bet_amount >= 0);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ─────────────────────────────────────────────────────────────────────
-- 3. UPDATED place_bet — Full Risk Management
-- ─────────────────────────────────────────────────────────────────────
-- Replaces the existing function with all risk checks embedded.
-- Lock order: users → game_rounds → insert bets (prevents deadlocks)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.place_bet(
  p_game_id UUID,
  p_round_id UUID,
  p_amount NUMERIC,
  p_auto_cashout NUMERIC DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_user_id         UUID;
  v_balance         NUMERIC;
  v_daily_total     NUMERIC;
  v_daily_reset_at  DATE;
  v_round_status    TEXT;
  v_round_total     NUMERIC;
  v_bet_id          UUID;
  -- Risk limits (loaded from config table)
  v_max_bet         NUMERIC;
  v_daily_limit     NUMERIC;
  v_round_limit     NUMERIC;
  v_min_bet         NUMERIC;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 1: AUTHENTICATION
  -- ═══════════════════════════════════════════════════════════════════
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: User must be authenticated.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 2: LOAD PLATFORM CONFIG
  -- ═══════════════════════════════════════════════════════════════════
  SELECT max_bet, daily_limit, round_limit, min_bet
  INTO v_max_bet, v_daily_limit, v_round_limit, v_min_bet
  FROM public.platform_config
  WHERE id = 1;

  -- Fallback defaults if config somehow missing
  v_max_bet     := COALESCE(v_max_bet, 10000.00);
  v_daily_limit := COALESCE(v_daily_limit, 50000.00);
  v_round_limit := COALESCE(v_round_limit, 100000.00);
  v_min_bet     := COALESCE(v_min_bet, 1.00);

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 3: INPUT VALIDATION
  -- ═══════════════════════════════════════════════════════════════════
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Bet amount must be greater than zero.';
  END IF;

  IF p_amount < v_min_bet THEN
    RAISE EXCEPTION 'BELOW_MINIMUM: Minimum bet is %.', v_min_bet;
  END IF;

  IF p_amount > v_max_bet THEN
    RAISE EXCEPTION 'BET_EXCEEDS_MAXIMUM: Maximum bet is %.', v_max_bet;
  END IF;

  IF p_auto_cashout IS NOT NULL AND p_auto_cashout <= 1.0 THEN
    RAISE EXCEPTION 'INVALID_CASHOUT: Auto-cashout multiplier must be > 1.0.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 4: LOCK USER ROW + DAILY TOTAL CHECK
  -- ═══════════════════════════════════════════════════════════════════
  SELECT balance, daily_bet_total, daily_bet_reset_at
  INTO v_balance, v_daily_total, v_daily_reset_at
  FROM public.users
  WHERE id = v_user_id
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND: User record not found.';
  END IF;

  -- Auto-reset daily total if it's a new day
  IF v_daily_reset_at < CURRENT_DATE THEN
    v_daily_total := 0;
    UPDATE public.users
    SET daily_bet_total = 0,
        daily_bet_reset_at = CURRENT_DATE
    WHERE id = v_user_id;
  END IF;

  -- CHECK: Daily limit
  IF (v_daily_total + p_amount) > v_daily_limit THEN
    RAISE EXCEPTION 'DAILY_LIMIT_EXCEEDED: Daily betting limit is %. You have used %. This bet of % would exceed it.',
      v_daily_limit, v_daily_total, p_amount;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 5: RATE LIMITING (1 bet per second)
  -- ═══════════════════════════════════════════════════════════════════
  IF EXISTS (
    SELECT 1 FROM public.bets
    WHERE user_id = v_user_id
    AND created_at > clock_timestamp() - interval '1 second'
  ) THEN
    RAISE EXCEPTION 'RATE_LIMITED: Please wait before placing another bet.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 6: BALANCE CHECK
  -- ═══════════════════════════════════════════════════════════════════
  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Balance: %. Required: %.', v_balance, p_amount;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 7: LOCK ROUND ROW + ROUND EXPOSURE CHECK
  -- ═══════════════════════════════════════════════════════════════════
  SELECT status::TEXT, total_bet_amount
  INTO v_round_status, v_round_total
  FROM public.game_rounds
  WHERE id = p_round_id
  FOR UPDATE;  -- Lock the round row to prevent concurrent total_bet_amount races

  IF v_round_status IS NULL THEN
    RAISE EXCEPTION 'ROUND_NOT_FOUND: Round does not exist.';
  END IF;

  IF v_round_status != 'created' THEN
    RAISE EXCEPTION 'ROUND_CLOSED: Round is not accepting bets (status: %).', v_round_status;
  END IF;

  -- CHECK: Round exposure limit
  IF (v_round_total + p_amount) > v_round_limit THEN
    RAISE EXCEPTION 'ROUND_LIMIT_EXCEEDED: This round has reached maximum exposure of %.', v_round_limit;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 8: ATOMIC EXECUTION
  -- ═══════════════════════════════════════════════════════════════════

  -- 8.1 Debit user balance + increment daily total
  UPDATE public.users
  SET balance = balance - p_amount,
      daily_bet_total = daily_bet_total + p_amount
  WHERE id = v_user_id;

  -- 8.2 Increment round total exposure
  UPDATE public.game_rounds
  SET total_bet_amount = total_bet_amount + p_amount
  WHERE id = p_round_id;

  -- 8.3 Create bet record
  INSERT INTO public.bets (user_id, game_id, round_id, amount, multiplier, status)
  VALUES (v_user_id, p_game_id, p_round_id, p_amount, p_auto_cashout, 'pending')
  RETURNING id INTO v_bet_id;

  -- 8.4 Create transaction log
  INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
  VALUES (v_user_id, 'bet', -p_amount, 'completed', v_bet_id);

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 9: SUCCESS
  -- ═══════════════════════════════════════════════════════════════════
  RETURN json_build_object(
    'success',       true,
    'bet_id',        v_bet_id,
    'new_balance',   v_balance - p_amount,
    'amount',        p_amount,
    'auto_cashout',  p_auto_cashout,
    'daily_used',    v_daily_total + p_amount,
    'daily_limit',   v_daily_limit,
    'round_exposure', v_round_total + p_amount
  );

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'ALREADY_BET: You already placed a bet this round.';
  WHEN check_violation THEN
    RAISE EXCEPTION 'CONSTRAINT_VIOLATION: Operation aborted by database safety check.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 4. DAILY RESET FUNCTION
-- ─────────────────────────────────────────────────────────────────────
-- Can be called by a pg_cron job, a Supabase scheduled function,
-- or simply auto-resets on-demand (Phase 4 of place_bet above).
-- This batch function is for operational cleanup.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reset_daily_bet_totals()
RETURNS JSON AS $$
DECLARE
  v_rows_updated INT;
BEGIN
  UPDATE public.users
  SET daily_bet_total = 0,
      daily_bet_reset_at = CURRENT_DATE
  WHERE daily_bet_reset_at < CURRENT_DATE
    AND daily_bet_total > 0;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  RETURN json_build_object(
    'success', true,
    'users_reset', v_rows_updated,
    'reset_date', CURRENT_DATE
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 5. pg_cron SCHEDULING (if extension available)
-- ─────────────────────────────────────────────────────────────────────
-- Uncomment the following if pg_cron is enabled on your Supabase project.
-- This runs the batch reset every day at midnight UTC.
--
-- SELECT cron.schedule(
--   'daily-bet-total-reset',
--   '0 0 * * *',
--   $$SELECT public.reset_daily_bet_totals()$$
-- );
