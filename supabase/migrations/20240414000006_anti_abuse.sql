-- =====================================================================
-- 🛡️ ANTI-ABUSE PROTECTION SYSTEM
-- =====================================================================
-- Prevents bots, spam, and abusive betting behavior via:
--   1. Per-second rate limiting (already existed, now with dedicated columns)
--   2. Per-minute bet frequency cap
--   3. Automatic suspicious user flagging
--   4. Abuse event logging for forensics
--   5. Sliding window decay logic
-- All enforced atomically inside place_bet — no bypass via concurrency.
-- =====================================================================


-- ─────────────────────────────────────────────────────────────────────
-- 1. ADD ANTI-ABUSE COLUMNS TO USERS
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS last_bet_at            TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS bet_count_last_minute  INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS minute_window_start    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ADD COLUMN IF NOT EXISTS is_suspicious          BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS suspicious_flags       INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS suspended_until        TIMESTAMPTZ;

-- Index: fast lookups for admin dashboards monitoring suspicious users
CREATE INDEX IF NOT EXISTS idx_users_suspicious
  ON public.users (is_suspicious) WHERE is_suspicious = true;

-- Index: find suspended users
CREATE INDEX IF NOT EXISTS idx_users_suspended
  ON public.users (suspended_until) WHERE suspended_until IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────
-- 2. ADD ANTI-ABUSE LIMITS TO PLATFORM CONFIG
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.platform_config
  ADD COLUMN IF NOT EXISTS max_bets_per_minute   INT NOT NULL DEFAULT 20,
  ADD COLUMN IF NOT EXISTS min_bet_interval_ms   INT NOT NULL DEFAULT 1000,   -- 1 second
  ADD COLUMN IF NOT EXISTS suspicious_threshold  INT NOT NULL DEFAULT 5,      -- flags before auto-suspend
  ADD COLUMN IF NOT EXISTS suspend_duration_min  INT NOT NULL DEFAULT 30;     -- minutes of suspension


-- ─────────────────────────────────────────────────────────────────────
-- 3. ABUSE LOG TABLE — Forensics & Analytics
-- ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.abuse_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES public.users(id),
  event_type  TEXT NOT NULL,  -- 'rate_limited', 'minute_cap', 'suspicious_flagged', 'auto_suspended'
  details     JSONB,          -- Contextual data (bet amount, counts, etc.)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_abuse_events_user_time
  ON public.abuse_events (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_abuse_events_type
  ON public.abuse_events (event_type, created_at DESC);

-- RLS: users cannot see abuse events, only system/admin
ALTER TABLE public.abuse_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "No user access to abuse events" ON public.abuse_events
  FOR SELECT USING (false);
CREATE POLICY "No direct writes on abuse events" ON public.abuse_events
  FOR INSERT WITH CHECK (false);


-- ─────────────────────────────────────────────────────────────────────
-- 4. UPDATED place_bet — Full Anti-Abuse Integration
-- ─────────────────────────────────────────────────────────────────────
-- Replaces previous version with all existing checks PLUS:
--   - Suspension check
--   - Per-second rate limit (dedicated column)
--   - Per-minute sliding window cap
--   - Suspicious flag escalation
--   - Abuse event logging
-- Lock order: users → game_rounds → insert bets (prevents deadlocks)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.place_bet(
  p_game_id UUID,
  p_round_id UUID,
  p_amount NUMERIC,
  p_auto_cashout NUMERIC DEFAULT NULL,
  p_ip TEXT DEFAULT NULL,
  p_ua TEXT DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_user_id             UUID;
  v_balance             NUMERIC;
  v_daily_total         NUMERIC;
  v_daily_reset_at      DATE;
  v_round_status        TEXT;
  v_round_total         NUMERIC;
  v_bet_id              UUID;
  -- Anti-abuse columns
  v_last_bet_at         TIMESTAMPTZ;
  v_bet_count_minute    INT;
  v_minute_window_start TIMESTAMPTZ;
  v_is_suspicious       BOOLEAN;
  v_suspicious_flags    INT;
  v_suspended_until     TIMESTAMPTZ;
  -- Risk limits (loaded from config table)
  v_max_bet             NUMERIC;
  v_daily_limit         NUMERIC;
  v_round_limit         NUMERIC;
  v_min_bet             NUMERIC;
  -- Anti-abuse limits
  v_max_bets_per_minute INT;
  v_min_interval_ms     INT;
  v_suspicious_threshold INT;
  v_suspend_duration    INT;
  -- Timing
  v_now                 TIMESTAMPTZ;
  v_elapsed_ms          NUMERIC;
BEGIN
  v_now := clock_timestamp(); -- Consistent clock for all checks

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 1: AUTHENTICATION
  -- ═══════════════════════════════════════════════════════════════════
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: User must be authenticated.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 2: LOAD PLATFORM CONFIG (risk + abuse limits)
  -- ═══════════════════════════════════════════════════════════════════
  SELECT max_bet, daily_limit, round_limit, min_bet,
         max_bets_per_minute, min_bet_interval_ms,
         suspicious_threshold, suspend_duration_min
  INTO   v_max_bet, v_daily_limit, v_round_limit, v_min_bet,
         v_max_bets_per_minute, v_min_interval_ms,
         v_suspicious_threshold, v_suspend_duration
  FROM public.platform_config
  WHERE id = 1;

  -- Fallback defaults
  v_max_bet              := COALESCE(v_max_bet, 10000.00);
  v_daily_limit          := COALESCE(v_daily_limit, 50000.00);
  v_round_limit          := COALESCE(v_round_limit, 100000.00);
  v_min_bet              := COALESCE(v_min_bet, 1.00);
  v_max_bets_per_minute  := COALESCE(v_max_bets_per_minute, 20);
  v_min_interval_ms      := COALESCE(v_min_interval_ms, 1000);
  v_suspicious_threshold := COALESCE(v_suspicious_threshold, 5);
  v_suspend_duration     := COALESCE(v_suspend_duration, 30);

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
  -- PHASE 4: LOCK USER ROW + LOAD ALL USER STATE
  -- ═══════════════════════════════════════════════════════════════════
  SELECT balance, daily_bet_total, daily_bet_reset_at,
         last_bet_at, bet_count_last_minute, minute_window_start,
         is_suspicious, suspicious_flags, suspended_until
  INTO   v_balance, v_daily_total, v_daily_reset_at,
         v_last_bet_at, v_bet_count_minute, v_minute_window_start,
         v_is_suspicious, v_suspicious_flags, v_suspended_until
  FROM public.users
  WHERE id = v_user_id
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND: User record not found.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 5: SUSPENSION CHECK
  -- ═══════════════════════════════════════════════════════════════════
  IF v_suspended_until IS NOT NULL AND v_suspended_until > v_now THEN
    RAISE EXCEPTION 'ACCOUNT_SUSPENDED: Your account is temporarily suspended until %.', v_suspended_until;
  END IF;

  -- Clear expired suspension
  IF v_suspended_until IS NOT NULL AND v_suspended_until <= v_now THEN
    UPDATE public.users
    SET suspended_until = NULL
    WHERE id = v_user_id;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 6: ANTI-ABUSE — Per-Second Rate Limit
  -- ═══════════════════════════════════════════════════════════════════
  IF v_last_bet_at IS NOT NULL THEN
    v_elapsed_ms := EXTRACT(EPOCH FROM (v_now - v_last_bet_at)) * 1000;

    IF v_elapsed_ms < v_min_interval_ms THEN
      -- Log the abuse event
      INSERT INTO public.abuse_events (user_id, event_type, details)
      VALUES (v_user_id, 'rate_limited', jsonb_build_object(
        'elapsed_ms', v_elapsed_ms,
        'min_interval_ms', v_min_interval_ms,
        'attempted_amount', p_amount
      ));

      -- Increment Risk Score (Phase 5: Fraud Detection)
      PERFORM public.increment_risk_score(
        v_user_id, 2, 'rate_limit_violation', 
        jsonb_build_object('elapsed_ms', v_elapsed_ms, 'min', v_min_interval_ms)
      );

      -- Increment suspicious flags
      UPDATE public.users
      SET suspicious_flags = suspicious_flags + 1
      WHERE id = v_user_id;
      v_suspicious_flags := v_suspicious_flags + 1;

      -- Check if should escalate to suspension
      IF v_suspicious_flags >= v_suspicious_threshold THEN
        UPDATE public.users
        SET is_suspicious = true,
            suspended_until = v_now + (v_suspend_duration || ' minutes')::interval
        WHERE id = v_user_id;

        INSERT INTO public.abuse_events (user_id, event_type, details)
        VALUES (v_user_id, 'auto_suspended', jsonb_build_object(
          'flags', v_suspicious_flags,
          'threshold', v_suspicious_threshold,
          'suspended_minutes', v_suspend_duration
        ));

        RAISE EXCEPTION 'ACCOUNT_SUSPENDED: Suspicious activity detected. Account suspended for % minutes.', v_suspend_duration;
      END IF;

      RAISE EXCEPTION 'RATE_LIMITED: Please wait before placing another bet.';
    END IF;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 7: ANTI-ABUSE — Per-Minute Sliding Window
  -- ═══════════════════════════════════════════════════════════════════

  -- Reset window if it's been more than 60 seconds
  IF v_minute_window_start IS NULL OR (v_now - v_minute_window_start) > interval '60 seconds' THEN
    v_bet_count_minute := 0;
    v_minute_window_start := v_now;
  END IF;

  IF v_bet_count_minute >= v_max_bets_per_minute THEN
    -- Log the abuse event
    INSERT INTO public.abuse_events (user_id, event_type, details)
    VALUES (v_user_id, 'minute_cap', jsonb_build_object(
      'count', v_bet_count_minute,
      'max', v_max_bets_per_minute,
      'window_start', v_minute_window_start
    ));

    -- Increment Risk Score (Phase 5: Fraud Detection)
    PERFORM public.increment_risk_score(
      v_user_id, 5, 'minute_cap_violation', 
      jsonb_build_object('count', v_bet_count_minute, 'max', v_max_bets_per_minute)
    );

    -- Increment suspicious flags
    UPDATE public.users
    SET suspicious_flags = suspicious_flags + 1
    WHERE id = v_user_id;
    v_suspicious_flags := v_suspicious_flags + 1;

    -- Check if should escalate to suspension
    IF v_suspicious_flags >= v_suspicious_threshold THEN
      UPDATE public.users
      SET is_suspicious = true,
          suspended_until = v_now + (v_suspend_duration || ' minutes')::interval
      WHERE id = v_user_id;

      INSERT INTO public.abuse_events (user_id, event_type, details)
      VALUES (v_user_id, 'auto_suspended', jsonb_build_object(
        'flags', v_suspicious_flags,
        'threshold', v_suspicious_threshold,
        'trigger', 'minute_cap',
        'suspended_minutes', v_suspend_duration
      ));

      RAISE EXCEPTION 'ACCOUNT_SUSPENDED: Suspicious activity detected. Account suspended for % minutes.', v_suspend_duration;
    END IF;

    RAISE EXCEPTION 'MINUTE_CAP_EXCEEDED: Too many bets per minute. Maximum is % per minute.', v_max_bets_per_minute;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 8: DAILY TOTAL CHECK + AUTO-RESET
  -- ═══════════════════════════════════════════════════════════════════

  -- Auto-reset daily total if it's a new day
  IF v_daily_reset_at < CURRENT_DATE THEN
    v_daily_total := 0;
    UPDATE public.users
    SET daily_bet_total = 0,
        daily_bet_reset_at = CURRENT_DATE
    WHERE id = v_user_id;
  END IF;

  IF (v_daily_total + p_amount) > v_daily_limit THEN
    RAISE EXCEPTION 'DAILY_LIMIT_EXCEEDED: Daily betting limit is %. You have used %. This bet of % would exceed it.',
      v_daily_limit, v_daily_total, p_amount;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 9: BALANCE CHECK
  -- ═══════════════════════════════════════════════════════════════════
  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Balance: %. Required: %.', v_balance, p_amount;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 10: LOCK ROUND + EXPOSURE CHECK
  -- ═══════════════════════════════════════════════════════════════════
  SELECT status::TEXT, total_bet_amount
  INTO v_round_status, v_round_total
  FROM public.game_rounds
  WHERE id = p_round_id
  FOR UPDATE;

  IF v_round_status IS NULL THEN
    RAISE EXCEPTION 'ROUND_NOT_FOUND: Round does not exist.';
  END IF;

  IF v_round_status != 'created' THEN
    RAISE EXCEPTION 'ROUND_CLOSED: Round is not accepting bets (status: %).', v_round_status;
  END IF;

  IF (v_round_total + p_amount) > v_round_limit THEN
    RAISE EXCEPTION 'ROUND_LIMIT_EXCEEDED: This round has reached maximum exposure of %.', v_round_limit;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 11: ATOMIC EXECUTION
  -- ═══════════════════════════════════════════════════════════════════

  -- 11.1 Debit balance + update daily total + update abuse tracking
  UPDATE public.users
  SET balance              = balance - p_amount,
      daily_bet_total      = daily_bet_total + p_amount,
      last_bet_at          = v_now,
      last_login_ip        = COALESCE(p_ip, last_login_ip),
      device_fingerprint   = COALESCE(p_ua, device_fingerprint),
      bet_count_last_minute = CASE
        WHEN v_minute_window_start IS NULL OR (v_now - v_minute_window_start) > interval '60 seconds'
        THEN 1
        ELSE bet_count_last_minute + 1
      END,
      minute_window_start  = CASE
        WHEN v_minute_window_start IS NULL OR (v_now - v_minute_window_start) > interval '60 seconds'
        THEN v_now
        ELSE minute_window_start
      END
  WHERE id = v_user_id;

  -- 11.2 Increment round total exposure
  UPDATE public.game_rounds
  SET total_bet_amount = total_bet_amount + p_amount
  WHERE id = p_round_id;

  -- 11.3 Create bet record
  INSERT INTO public.bets (user_id, game_id, round_id, amount, multiplier, status)
  VALUES (v_user_id, p_game_id, p_round_id, p_amount, p_auto_cashout, 'pending')
  RETURNING id INTO v_bet_id;

  -- 11.4 Create transaction log
  INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
  VALUES (v_user_id, 'bet', -p_amount, 'completed', v_bet_id);

  -- ═══════════════════════════════════════════════════════════════════
  -- PHASE 12: SUCCESS
  -- ═══════════════════════════════════════════════════════════════════
  RETURN json_build_object(
    'success',        true,
    'bet_id',         v_bet_id,
    'new_balance',    v_balance - p_amount,
    'amount',         p_amount,
    'auto_cashout',   p_auto_cashout,
    'daily_used',     v_daily_total + p_amount,
    'daily_limit',    v_daily_limit,
    'round_exposure', v_round_total + p_amount,
    'bets_this_minute', v_bet_count_minute + 1
  );

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'ALREADY_BET: You already placed a bet this round.';
  WHEN check_violation THEN
    RAISE EXCEPTION 'CONSTRAINT_VIOLATION: Operation aborted by database safety check.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 5. ADMIN FUNCTION: Review & Manage Suspicious Users
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_manage_user_abuse(
  p_user_id UUID,
  p_action  TEXT,  -- 'clear' (reset flags), 'suspend' (manual), 'unsuspend'
  p_notes   TEXT DEFAULT NULL,
  p_suspend_minutes INT DEFAULT 60
)
RETURNS JSON AS $$
BEGIN
  IF p_action = 'clear' THEN
    -- Reset all abuse flags, keep the user active
    UPDATE public.users
    SET suspicious_flags = 0,
        is_suspicious = false,
        suspended_until = NULL
    WHERE id = p_user_id;

    INSERT INTO public.abuse_events (user_id, event_type, details)
    VALUES (p_user_id, 'admin_cleared', jsonb_build_object(
      'notes', COALESCE(p_notes, 'Flags cleared by admin')
    ));

    RETURN json_build_object('success', true, 'action', 'cleared');

  ELSIF p_action = 'suspend' THEN
    -- Manual suspension by admin
    UPDATE public.users
    SET is_suspicious = true,
        suspended_until = NOW() + (p_suspend_minutes || ' minutes')::interval
    WHERE id = p_user_id;

    INSERT INTO public.abuse_events (user_id, event_type, details)
    VALUES (p_user_id, 'admin_suspended', jsonb_build_object(
      'minutes', p_suspend_minutes,
      'notes', COALESCE(p_notes, 'Manual suspension by admin')
    ));

    RETURN json_build_object('success', true, 'action', 'suspended', 'minutes', p_suspend_minutes);

  ELSIF p_action = 'unsuspend' THEN
    UPDATE public.users
    SET suspended_until = NULL
    WHERE id = p_user_id;

    INSERT INTO public.abuse_events (user_id, event_type, details)
    VALUES (p_user_id, 'admin_unsuspended', jsonb_build_object(
      'notes', COALESCE(p_notes, 'Unsuspended by admin')
    ));

    RETURN json_build_object('success', true, 'action', 'unsuspended');

  ELSE
    RAISE EXCEPTION 'INVALID_ACTION: Must be clear, suspend, or unsuspend.';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 6. DAILY DECAY: Reduce suspicious_flags over time
-- ─────────────────────────────────────────────────────────────────────
-- Prevents permanent punishment for one-time bursts.
-- Run via pg_cron or scheduled Edge Function daily.
CREATE OR REPLACE FUNCTION public.decay_abuse_flags()
RETURNS JSON AS $$
DECLARE
  v_rows_updated INT;
BEGIN
  -- Decay: reduce by 1 flag per day, minimum 0
  UPDATE public.users
  SET suspicious_flags = GREATEST(suspicious_flags - 1, 0),
      is_suspicious = CASE WHEN suspicious_flags - 1 <= 0 THEN false ELSE is_suspicious END
  WHERE suspicious_flags > 0;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  RETURN json_build_object(
    'success', true,
    'users_decayed', v_rows_updated,
    'decay_date', CURRENT_DATE
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- pg_cron scheduling (uncomment if pg_cron enabled):
-- SELECT cron.schedule(
--   'daily-abuse-flag-decay',
--   '5 0 * * *',   -- 00:05 UTC daily
--   $$SELECT public.decay_abuse_flags()$$
-- );
