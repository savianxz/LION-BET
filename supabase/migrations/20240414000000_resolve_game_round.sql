-- ==========================================
-- 🛡️ SECURE RESOLUTION: CRITICAL BETTING HUB
-- ==========================================
-- This migration implements the core logic for closing a round and paying out users.
-- Key security features:
-- 1. Atomic Transactionality: Everything success or everything fails.
-- 2. Concurrency Control: FOR UPDATE locks on rounds and users.
-- 3. Deadlock Prevention: Ordered locks on users.
-- 4. State Integrity: Prevents double-resolution.

-- Safeguard: Ensure required columns exist
DO $$ 
BEGIN
  ALTER TABLE public.game_rounds ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();
  ALTER TABLE public.bets ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();
  ALTER TABLE public.bets ADD COLUMN IF NOT EXISTS payout NUMERIC DEFAULT 0;
  ALTER TABLE public.game_rounds ADD COLUMN IF NOT EXISTS result NUMERIC;
END $$;

CREATE OR REPLACE FUNCTION public.resolve_game_round(
  p_round_id UUID,
  p_crash_multiplier NUMERIC DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_round RECORD;
  v_bet RECORD;
  v_payout NUMERIC;
  v_user_balance NUMERIC;
  v_total_paid NUMERIC := 0;
  v_bets_count INT := 0;
BEGIN
  -- 1. [LOCK] Lock the round to prevent concurrent resolution.
  -- This ensures that only one server instance can process this round at a time.
  SELECT * INTO v_round
  FROM public.game_rounds
  WHERE id = p_round_id
  FOR UPDATE;

  -- 2. [VET] Check if the round exists and its current state.
  IF v_round.id IS NULL THEN
    RAISE EXCEPTION 'ROUND_NOT_FOUND: Round does not exist.';
  END IF;

  -- [VET] Prevent re-processing.
  IF v_round.status = 'finished' THEN
    RAISE EXCEPTION 'ALREADY_RESOLVED: Round is already finished and paid.';
  END IF;

  -- 3. [GENERATE] Generate game result (crash multiplier) if not provided.
  -- Safe fallback formula: 1 / (1 - random()) * 0.99 (house edge adjustment)
  IF p_crash_multiplier IS NULL THEN
    -- A value between 1.00 and 1000.00 (capped for safety)
    -- This formula mimics a standard Crash distribution.
    p_crash_multiplier := LEAST(ROUND((0.99 / (1.0001 - random()))::numeric, 2), 1000.00);
    
    -- Ensure it's at least 1.00
    IF p_crash_multiplier < 1.00 THEN
      p_crash_multiplier := 1.00;
    END IF;
  END IF;

  -- 4. [UPDATE] Mark the round as finished immediately to lock the state.
  UPDATE public.game_rounds
  SET status = 'finished',
      result = p_crash_multiplier,
      updated_at = NOW()
  WHERE id = p_round_id;

  -- 5. [LOOP] Process each bet for this round.
  -- We order by user_id to prevent potential deadlocks when multiple rounds resolve.
  FOR v_bet IN 
    SELECT * FROM public.bets 
    WHERE round_id = p_round_id AND status = 'pending'
    ORDER BY user_id
  LOOP
    v_bets_count := v_bets_count + 1;

    -- 6. [LOGIC] Check if user won.
    -- The user wins if their auto-cashout (multiplier) is <= the crash result.
    IF v_bet.multiplier IS NOT NULL AND v_bet.multiplier <= p_crash_multiplier THEN
      
      -- Calculate total payout (Principal + Profit)
      v_payout := v_bet.amount * v_bet.multiplier;
      
      -- [LOCK] Acquire exclusive lock on the user's row BEFORE updating balance.
      SELECT balance INTO v_user_balance
      FROM public.users
      WHERE id = v_bet.user_id
      FOR UPDATE;

      -- [UPDATE] Update user's balance.
      UPDATE public.users
      SET balance = balance + v_payout
      WHERE id = v_bet.user_id;

      -- [UPDATE] Mark bet as won.
      UPDATE public.bets
      SET status = 'won',
          payout = v_payout,
          updated_at = NOW()
      WHERE id = v_bet.id;

      -- [LOG] Create a transaction record for auditing.
      INSERT INTO public.transactions (
        user_id, 
        type, 
        amount, 
        status, 
        reference_id, 
        created_at
      )
      VALUES (
        v_bet.user_id, 
        'win', 
        v_payout, 
        'completed', 
        v_bet.id, 
        NOW()
      );

      -- [FRAUD] Statistical Pattern Detection (Phase 5)
      PERFORM public.check_user_fraud_patterns(v_bet.user_id);

      v_total_paid := v_total_paid + v_payout;

    ELSE
      -- [UPDATE] Mark bet as lost.
      UPDATE public.bets
      SET status = 'lost',
          payout = 0,
          updated_at = NOW()
      WHERE id = v_bet.id;

    END IF;
  END LOOP;

  -- 7. [RESPONSE] Return detailed audit JSON.
  -- This is useful for backend verification and logging.
  RETURN json_build_object(
    'success', true,
    'round_id', p_round_id,
    'crash_multiplier', p_crash_multiplier,
    'bets_processed', v_bets_count,
    'total_paid', v_total_paid
  );

EXCEPTION
  WHEN OTHERS THEN
    -- Propagate error to abort the outer transaction (atomic rollback).
    RAISE NOTICE 'CRITICAL_FAIL: resolve_game_round failed for round %. Error: %', p_round_id, SQLERRM;
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
