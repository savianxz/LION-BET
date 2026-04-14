-- =====================================================================
-- 🕵️ BEHAVIORAL FRAUD DETECTION SYSTEM
-- =====================================================================
-- Detects suspicious users and prevents abuse via risk scoring.
-- integrates with place_bet, resolve_game_round, and withdrawal system.
-- =====================================================================

-- ─────────────────────────────────────────────────────────────────────
-- 1. EXTEND USERS & CONFIG
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS risk_score  INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_flagged  BOOLEAN NOT NULL DEFAULT false;

-- Platforms limits for fraud
ALTER TABLE public.platform_config
  ADD COLUMN IF NOT EXISTS fraud_flag_threshold  INT NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS win_rate_threshold     NUMERIC NOT NULL DEFAULT 0.85, -- 85% win rate
  ADD COLUMN IF NOT EXISTS min_bets_for_stats     INT NOT NULL DEFAULT 10,      -- min bets before stats analysis
  ADD COLUMN IF NOT EXISTS perfect_cashout_limit  NUMERIC NOT NULL DEFAULT 0.98; -- cashout/crash ratio

-- Indexing for fraud analytics
CREATE INDEX IF NOT EXISTS idx_users_risk_score ON public.users (risk_score) WHERE risk_score > 0;
CREATE INDEX IF NOT EXISTS idx_users_flagged ON public.users (is_flagged) WHERE is_flagged = true;


-- ─────────────────────────────────────────────────────────────────────
-- 2. FRAUD LOGS TABLE
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.fraud_logs (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES public.users(id),
  reason           TEXT NOT NULL,
  score_increment  INT NOT NULL,
  total_score      INT NOT NULL,
  details          JSONB,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS: Only admin/system
ALTER TABLE public.fraud_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "No user access to fraud logs" ON public.fraud_logs FOR SELECT USING (false);

CREATE INDEX IF NOT EXISTS idx_fraud_logs_user ON public.fraud_logs (user_id, created_at DESC);


-- ─────────────────────────────────────────────────────────────────────
-- 3. CORE LOGIC: Increment Risk Score
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.increment_risk_score(
  p_user_id UUID,
  p_points  INT,
  p_reason  TEXT,
  p_details JSONB DEFAULT '{}'::jsonb
)
RETURNS VOID AS $$
DECLARE
  v_current_score INT;
  v_threshold     INT;
BEGIN
  -- 1. Load threshold
  SELECT fraud_flag_threshold INTO v_threshold FROM public.platform_config WHERE id = 1;

  -- 2. Update user score
  UPDATE public.users
  SET risk_score = risk_score + p_points
  WHERE id = p_user_id
  RETURNING risk_score INTO v_current_score;

  -- 3. Auto-flag if threshold reached
  IF v_current_score >= v_threshold THEN
    UPDATE public.users SET is_flagged = true WHERE id = p_user_id;
  END IF;

  -- 4. Log the event
  INSERT INTO public.fraud_logs (user_id, reason, score_increment, total_score, details)
  VALUES (p_user_id, p_reason, p_points, v_current_score, p_details);

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 4. PATTERN DETECTION: Statistical Fraud Check
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.check_user_fraud_patterns(p_user_id UUID)
RETURNS JSON AS $$
DECLARE
  v_win_rate            NUMERIC;
  v_total_bets          INT;
  v_perfect_cashouts    INT;
  v_multi_account_count INT;
  v_last_ip             TEXT;
  -- Threshold cached
  v_win_rate_th         NUMERIC;
  v_min_bets            INT;
  v_perfect_ratio       NUMERIC;
  -- Result tracking
  v_points_added        INT := 0;
  v_detections          JSONB := '[]'::jsonb;
BEGIN
  -- 1. Load config
  SELECT win_rate_threshold, min_bets_for_stats, perfect_cashout_limit
  INTO v_win_rate_th, v_min_bets, v_perfect_ratio
  FROM public.platform_config WHERE id = 1;

  -- 2. Load User Context
  SELECT last_login_ip INTO v_last_ip FROM public.users WHERE id = p_user_id;

  -- 3. Check Multi-Account (Same IP)
  IF v_last_ip IS NOT NULL THEN
    SELECT COUNT(DISTINCT id) INTO v_multi_account_count
    FROM public.users
    WHERE last_login_ip = v_last_ip AND id != p_user_id;

    IF v_multi_account_count > 1 THEN
      PERFORM public.increment_risk_score(
        p_user_id, 40, 'multi_account_detected', 
        jsonb_build_object('ip', v_last_ip, 'other_accounts', v_multi_account_count)
      );
      v_points_added := v_points_added + 40;
      v_detections := v_detections || jsonb_build_object('type', 'multi_account', 'points', 40);
    END IF;
  END IF;

  -- 4. Statistical Analysis (Last 20 bets)
  SELECT 
    COUNT(*),
    COUNT(*) FILTER (WHERE status = 'won'),
    COUNT(*) FILTER (WHERE status = 'won' AND (payout / amount) / (NULLIF(rounds.result, 0)) >= v_perfect_ratio)
  INTO v_total_bets, v_perfect_cashouts, v_perfect_cashouts -- Reusing var for simplicity in count
  FROM (
    SELECT b.status, b.amount, b.payout, r.result
    FROM public.bets b
    JOIN public.game_rounds r ON b.round_id = r.id
    WHERE b.user_id = p_user_id
    ORDER BY b.created_at DESC
    LIMIT 20
  ) as recent_history;

  -- 4.1 Win Rate Check
  IF v_total_bets >= v_min_bets THEN
    v_win_rate := (SELECT COUNT(*) FILTER (WHERE status = 'won') FROM recent_history)::NUMERIC / v_total_bets;
    
    IF v_win_rate >= v_win_rate_th THEN
      PERFORM public.increment_risk_score(
        p_user_id, 50, 'abnormal_win_rate',
        jsonb_build_object('win_rate', v_win_rate, 'total_bets', v_total_bets)
      );
      v_points_added := v_points_added + 50;
      v_detections := v_detections || jsonb_build_object('type', 'win_rate', 'points', 50);
    END IF;

    -- 4.2 Near-Perfect Cashouts Check
    -- (Counting wins where user cashed out at > 98% of crash point)
    IF v_perfect_cashouts >= 3 THEN
      PERFORM public.increment_risk_score(
        p_user_id, 30, 'near_perfect_cashouts',
        jsonb_build_object('count', v_perfect_cashouts, 'threshold', 3)
      );
      v_points_added := v_points_added + 30;
      v_detections := v_detections || jsonb_build_object('type', 'perfect_cashouts', 'points', 30);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'points_added', v_points_added,
    'detections', v_detections
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
