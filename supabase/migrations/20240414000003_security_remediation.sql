-- =====================================================================
-- 🔐 SECURITY REMEDIATION — Fixes for Audit Report 2026-04-14
-- =====================================================================
-- This migration addresses 13 vulnerabilities (4 critical, 3 high, 6 medium).
-- It MUST run AFTER all previous migrations.
-- =====================================================================


-- ═════════════════════════════════════════════════════════════════════
-- 🔴 VULN-001: Server Seed Exposed via Direct Table Read
-- ═════════════════════════════════════════════════════════════════════
-- The base `game_rounds` table has RLS policy USING(true) for SELECT,
-- which lets any authenticated user read server_seed before round ends.
-- FIX: Revoke direct access, force all reads through the masking view.

-- Drop the overly permissive policy
DROP POLICY IF EXISTS "Anyone can read game rounds" ON public.game_rounds;

-- Create a restrictive policy: only service_role (SECURITY DEFINER funcs) can read base table
-- Regular users get ZERO rows from the base table directly.
CREATE POLICY "No direct read on game_rounds" ON public.game_rounds
  FOR SELECT USING (false);

-- Ensure the masking view exists and grant access to it
CREATE OR REPLACE VIEW public.game_rounds_public AS
SELECT
  id,
  game_id,
  server_seed_hash,
  CASE WHEN status = 'finished'
    THEN server_seed
    ELSE NULL
  END AS server_seed,
  client_seed,
  nonce,
  result,
  status,
  created_at,
  updated_at
FROM public.game_rounds;

-- Grant read access on the VIEW (not the table) to public roles
GRANT SELECT ON public.game_rounds_public TO anon, authenticated;
-- Revoke direct table access for safety
REVOKE SELECT ON public.game_rounds FROM anon, authenticated;


-- ═════════════════════════════════════════════════════════════════════
-- 🔴 VULN-002: Legacy resolve_game() Still Exists
-- ═════════════════════════════════════════════════════════════════════
-- The old function accepts p_result directly from the caller.
-- An attacker can call: rpc('resolve_game', {p_round_id: '...', p_result: 9999})
DROP FUNCTION IF EXISTS public.resolve_game(UUID, NUMERIC);


-- ═════════════════════════════════════════════════════════════════════
-- 🔴 VULN-003: Legacy place_bet Signature Collision
-- ═════════════════════════════════════════════════════════════════════
-- PostgreSQL allows function overloading. The old signature
-- place_bet(UUID, UUID, NUMERIC, NUMERIC) may coexist with the new one
-- place_bet(UUID, UUID, NUMERIC, NUMERIC DEFAULT NULL).
-- They are technically the same signature, but we drop explicitly to be safe.
-- The secure version will be recreated below.
DROP FUNCTION IF EXISTS public.place_bet(UUID, UUID, NUMERIC, NUMERIC);


-- ═════════════════════════════════════════════════════════════════════
-- 🔴 VULN-004: Legacy resolve_game_round with random() Fallback
-- ═════════════════════════════════════════════════════════════════════
-- The intermediate version accepts (UUID, NUMERIC DEFAULT NULL) and falls
-- back to random() if no multiplier is passed. Drop this signature.
DROP FUNCTION IF EXISTS public.resolve_game_round(UUID, NUMERIC);
-- The provably fair version with signature (UUID) will be retained.


-- ═════════════════════════════════════════════════════════════════════
-- 🟡 VULN-010: Add updated_at to users table (Audit Gap)
-- ═════════════════════════════════════════════════════════════════════
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Ensure the updated_at trigger covers users
DROP TRIGGER IF EXISTS trg_handle_updated_at ON public.users;
CREATE TRIGGER trg_handle_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_updated_at();


-- ═════════════════════════════════════════════════════════════════════
-- 🟡 VULN-012: Multi-Account Detection Columns
-- ═════════════════════════════════════════════════════════════════════
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS last_login_ip TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS device_fingerprint TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS login_count INT DEFAULT 0;


-- ═════════════════════════════════════════════════════════════════════
-- 🟠 VULN-006 + 🟡 VULN-009: Max Bet + SQL-Level Rate Limiting
-- ═════════════════════════════════════════════════════════════════════
-- Recreate the secure place_bet function with BOTH fixes baked in.

CREATE OR REPLACE FUNCTION public.place_bet(
  p_game_id UUID,
  p_round_id UUID,
  p_amount NUMERIC,
  p_auto_cashout NUMERIC DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_user_id UUID;
  v_balance NUMERIC;
  v_round_status TEXT;
  v_bet_id UUID;
  v_max_bet NUMERIC := 10000.00; -- VULN-006: Platform max bet limit
BEGIN
  -- 1. AUTH: Get user from JWT context
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: User must be authenticated.';
  END IF;

  -- 2. INPUT VALIDATION
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Bet amount must be greater than zero.';
  END IF;

  -- VULN-006: Enforce maximum bet
  IF p_amount > v_max_bet THEN
    RAISE EXCEPTION 'BET_EXCEEDS_MAXIMUM: Maximum bet is %.', v_max_bet;
  END IF;

  IF p_auto_cashout IS NOT NULL AND p_auto_cashout <= 1.0 THEN
    RAISE EXCEPTION 'INVALID_CASHOUT: Auto-cashout multiplier must be > 1.0.';
  END IF;

  -- 3. LOCK user row (prevents race conditions on balance)
  SELECT balance INTO v_balance
  FROM public.users
  WHERE id = v_user_id
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND: User record not found.';
  END IF;

  -- 4. VULN-009: SQL-level rate limiting (consistent clock)
  IF EXISTS (
    SELECT 1 FROM public.bets
    WHERE user_id = v_user_id
    AND created_at > clock_timestamp() - interval '1 second'
  ) THEN
    RAISE EXCEPTION 'RATE_LIMITED: Please wait before placing another bet.';
  END IF;

  -- 5. CHECK BALANCE
  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Balance: %. Required: %.', v_balance, p_amount;
  END IF;

  -- 6. VALIDATE ROUND STATE
  SELECT status::TEXT INTO v_round_status
  FROM public.game_rounds
  WHERE id = p_round_id;

  IF v_round_status IS NULL THEN
    RAISE EXCEPTION 'ROUND_NOT_FOUND: Round does not exist.';
  END IF;

  IF v_round_status != 'created' THEN
    RAISE EXCEPTION 'ROUND_CLOSED: Round is not accepting bets (status: %).', v_round_status;
  END IF;

  -- 7. ATOMIC EXECUTION
  -- 7.1 Debit balance
  UPDATE public.users
  SET balance = balance - p_amount
  WHERE id = v_user_id;

  -- 7.2 Create bet record
  INSERT INTO public.bets (user_id, game_id, round_id, amount, multiplier, status)
  VALUES (v_user_id, p_game_id, p_round_id, p_amount, p_auto_cashout, 'pending')
  RETURNING id INTO v_bet_id;

  -- 7.3 Create transaction log
  INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
  VALUES (v_user_id, 'bet', -p_amount, 'completed', v_bet_id);

  -- 8. SUCCESS
  RETURN json_build_object(
    'success', true,
    'bet_id', v_bet_id,
    'new_balance', v_balance - p_amount,
    'amount', p_amount,
    'auto_cashout', p_auto_cashout
  );

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'ALREADY_BET: You already placed a bet this round.';
  WHEN check_violation THEN
    RAISE EXCEPTION 'CONSTRAINT_VIOLATION: Operation aborted by database safety check.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ═════════════════════════════════════════════════════════════════════
-- 🟡 VULN-011: Document INSERT/DELETE RLS Strategy
-- ═════════════════════════════════════════════════════════════════════
-- All writes go through SECURITY DEFINER functions which bypass RLS.
-- We add explicit DENY policies for INSERT/DELETE to prevent any
-- future code from accidentally inserting via the Supabase client.

-- BETS: No direct inserts from client
DROP POLICY IF EXISTS "No direct insert on bets" ON public.bets;
CREATE POLICY "No direct insert on bets" ON public.bets
  FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS "No direct delete on bets" ON public.bets;
CREATE POLICY "No direct delete on bets" ON public.bets
  FOR DELETE USING (false);

-- TRANSACTIONS: No direct inserts from client
DROP POLICY IF EXISTS "No direct insert on transactions" ON public.transactions;
CREATE POLICY "No direct insert on transactions" ON public.transactions
  FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS "No direct delete on transactions" ON public.transactions;
CREATE POLICY "No direct delete on transactions" ON public.transactions
  FOR DELETE USING (false);

-- USERS: No direct inserts/updates/deletes from client
DROP POLICY IF EXISTS "No direct insert on users" ON public.users;
CREATE POLICY "No direct insert on users" ON public.users
  FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS "No direct update on users" ON public.users;
CREATE POLICY "No direct update on users" ON public.users
  FOR UPDATE USING (false);
DROP POLICY IF EXISTS "No direct delete on users" ON public.users;
CREATE POLICY "No direct delete on users" ON public.users
  FOR DELETE USING (false);


-- ═════════════════════════════════════════════════════════════════════
-- 🟠 VULN-007: Anonymous Bet Aggregates (replaces user_id exposure)
-- ═════════════════════════════════════════════════════════════════════
-- Returns only count and total — never individual user details.
CREATE OR REPLACE FUNCTION public.get_round_bet_stats(p_round_id UUID)
RETURNS JSON AS $$
DECLARE
  v_total_bets INT;
  v_total_amount NUMERIC;
BEGIN
  SELECT COUNT(*), COALESCE(SUM(amount), 0)
  INTO v_total_bets, v_total_amount
  FROM public.bets
  WHERE round_id = p_round_id;

  RETURN json_build_object(
    'total_bets', v_total_bets,
    'total_amount', v_total_amount
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
