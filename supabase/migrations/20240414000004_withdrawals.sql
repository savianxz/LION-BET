-- =====================================================================
-- 💸 WITHDRAWAL SYSTEM — Financial-Grade Implementation
-- =====================================================================
-- Covers:
--   1. withdrawals table with enum status
--   2. request_withdrawal — atomic, locked, rate-limited
--   3. process_withdrawal — admin-only, safe refund on rejection
--   4. RLS policies — user isolation, immutability
--   5. Indexes for operational queries
-- =====================================================================


-- ─────────────────────────────────────────────────────────────────────
-- 1. WITHDRAWAL STATUS ENUM
-- ─────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'withdrawal_status') THEN
    CREATE TYPE public.withdrawal_status AS ENUM (
      'pending',    -- User requested, funds locked (already deducted)
      'approved',   -- Admin approved, awaiting external payout
      'rejected',   -- Admin rejected, funds refunded to user
      'completed'   -- External payout confirmed
    );
  END IF;
END $$;


-- ─────────────────────────────────────────────────────────────────────
-- 2. WITHDRAWALS TABLE
-- ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.withdrawals (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.users(id),
  amount          NUMERIC(20, 8) NOT NULL CHECK (amount > 0),
  status          public.withdrawal_status NOT NULL DEFAULT 'pending',
  admin_notes     TEXT,                          -- Reason for rejection, approval notes
  transaction_id  UUID REFERENCES public.transactions(id),  -- Link to debit transaction
  refund_transaction_id UUID REFERENCES public.transactions(id),  -- Link to refund (if rejected)
  processed_by    TEXT,                          -- Admin identifier
  processed_at    TIMESTAMPTZ,                   -- When admin acted
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Prevent a user from having multiple pending withdrawals simultaneously
CREATE UNIQUE INDEX IF NOT EXISTS idx_withdrawals_one_pending_per_user
  ON public.withdrawals (user_id)
  WHERE status = 'pending';

-- Operational index: admin dashboard queries
CREATE INDEX IF NOT EXISTS idx_withdrawals_status_created
  ON public.withdrawals (status, created_at DESC);

-- User history lookups
CREATE INDEX IF NOT EXISTS idx_withdrawals_user_history
  ON public.withdrawals (user_id, created_at DESC);

-- Updated_at trigger
DROP TRIGGER IF EXISTS trg_handle_updated_at ON public.withdrawals;
CREATE TRIGGER trg_handle_updated_at
  BEFORE UPDATE ON public.withdrawals
  FOR EACH ROW EXECUTE PROCEDURE public.handle_updated_at();


-- ─────────────────────────────────────────────────────────────────────
-- 3. ROW LEVEL SECURITY
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;

-- Users can see only their own withdrawals
CREATE POLICY "Users can read own withdrawals" ON public.withdrawals
  FOR SELECT USING (auth.uid() = user_id);

-- No direct writes from client — all through SECURITY DEFINER RPCs
CREATE POLICY "No direct insert on withdrawals" ON public.withdrawals
  FOR INSERT WITH CHECK (false);
CREATE POLICY "No direct update on withdrawals" ON public.withdrawals
  FOR UPDATE USING (false);
CREATE POLICY "No direct delete on withdrawals" ON public.withdrawals
  FOR DELETE USING (false);


-- ─────────────────────────────────────────────────────────────────────
-- 4. request_withdrawal — User-facing, atomic, locked
-- ─────────────────────────────────────────────────────────────────────
-- Flow:
--   1. Authenticate user via JWT
--   2. Lock user row (FOR UPDATE)
--   3. Validate: balance >= amount, amount >= minimum
--   4. Rate limit: no withdrawal in the last 60 seconds
--   5. Check: no existing pending withdrawal
--   6. Deduct balance immediately (funds locked)
--   7. Insert withdrawal record
--   8. Insert transaction log
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.request_withdrawal(
  p_amount NUMERIC
)
RETURNS JSON AS $$
DECLARE
  v_user_id         UUID;
  v_balance         NUMERIC;
  v_min_withdrawal  NUMERIC := 10.00;    -- Configurable minimum
  v_max_withdrawal  NUMERIC := 50000.00; -- Configurable maximum
  v_withdrawal_id   UUID;
  v_transaction_id  UUID;
  v_is_flagged      BOOLEAN;
BEGIN
  -- ── 1. AUTHENTICATION ──────────────────────────────────────────────
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: User must be authenticated.';
  END IF;

  -- ── 2. INPUT VALIDATION ────────────────────────────────────────────
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Withdrawal amount must be positive.';
  END IF;

  IF p_amount < v_min_withdrawal THEN
    RAISE EXCEPTION 'BELOW_MINIMUM: Minimum withdrawal is %.', v_min_withdrawal;
  END IF;

  IF p_amount > v_max_withdrawal THEN
    RAISE EXCEPTION 'ABOVE_MAXIMUM: Maximum withdrawal is %.', v_max_withdrawal;
  END IF;

  -- ── 3. LOCK USER ROW ──────────────────────────────────────────────
  -- Prevents any concurrent balance operation (bet, another withdrawal)
  SELECT balance, is_flagged INTO v_balance, v_is_flagged
  FROM public.users
  WHERE id = v_user_id
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND: User record not found.';
  END IF;

  -- ── 3.1 FRAUD BLOCK CHECK (Phase 5) ──────────────────────────────
  IF v_is_flagged THEN
    RAISE EXCEPTION 'WITHDRAWAL_BLOCKED: Your account is currently under review for suspicious activity. Withdrawals are temporarily disabled.';
  END IF;

  -- ── 4. BALANCE CHECK ──────────────────────────────────────────────
  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Balance: %. Requested: %.', v_balance, p_amount;
  END IF;

  -- ── 5. RATE LIMITING ──────────────────────────────────────────────
  -- Prevent abuse: max 1 withdrawal request per 60 seconds
  IF EXISTS (
    SELECT 1 FROM public.withdrawals
    WHERE user_id = v_user_id
    AND created_at > clock_timestamp() - interval '60 seconds'
  ) THEN
    RAISE EXCEPTION 'RATE_LIMITED: Please wait before requesting another withdrawal.';
  END IF;

  -- ── 6. PENDING CHECK ──────────────────────────────────────────────
  -- The UNIQUE partial index enforces this at DB level too, but we
  -- raise a cleaner error here.
  IF EXISTS (
    SELECT 1 FROM public.withdrawals
    WHERE user_id = v_user_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'PENDING_EXISTS: You already have a pending withdrawal. Please wait for it to be processed.';
  END IF;

  -- ── 7. DEDUCT BALANCE (Funds Locked) ──────────────────────────────
  UPDATE public.users
  SET balance = balance - p_amount
  WHERE id = v_user_id;

  -- ── 8. CREATE TRANSACTION LOG ─────────────────────────────────────
  INSERT INTO public.transactions (user_id, type, amount, status)
  VALUES (v_user_id, 'withdrawal', -p_amount, 'completed')
  RETURNING id INTO v_transaction_id;

  -- ── 9. CREATE WITHDRAWAL RECORD ───────────────────────────────────
  INSERT INTO public.withdrawals (user_id, amount, status, transaction_id)
  VALUES (v_user_id, p_amount, 'pending', v_transaction_id)
  RETURNING id INTO v_withdrawal_id;

  -- ── 10. SUCCESS ───────────────────────────────────────────────────
  RETURN json_build_object(
    'success',        true,
    'withdrawal_id',  v_withdrawal_id,
    'amount',         p_amount,
    'new_balance',    v_balance - p_amount,
    'status',         'pending'
  );

EXCEPTION
  WHEN unique_violation THEN
    -- Catches the partial unique index on (user_id) WHERE status = 'pending'
    RAISE EXCEPTION 'PENDING_EXISTS: You already have a pending withdrawal.';
  WHEN check_violation THEN
    RAISE EXCEPTION 'CONSTRAINT_VIOLATION: Operation aborted by safety check.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 5. process_withdrawal — Admin-only, handles approve/reject/complete
-- ─────────────────────────────────────────────────────────────────────
-- Flow:
--   approve  → status changes to 'approved' (awaiting external payout)
--   reject   → status changes to 'rejected', funds refunded to user
--   complete → status changes to 'completed' (external payout confirmed)
--
-- This function does NOT use auth.uid() — it's called by service_role
-- through the resolveGame-style admin Edge Function.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.process_withdrawal(
  p_withdrawal_id UUID,
  p_action        TEXT,        -- 'approve', 'reject', 'complete'
  p_admin_notes   TEXT DEFAULT NULL,
  p_admin_id      TEXT DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_withdrawal      RECORD;
  v_refund_tx_id    UUID;
  v_new_balance     NUMERIC;
BEGIN
  -- ── 1. LOCK WITHDRAWAL ROW ────────────────────────────────────────
  SELECT * INTO v_withdrawal
  FROM public.withdrawals
  WHERE id = p_withdrawal_id
  FOR UPDATE;

  IF v_withdrawal.id IS NULL THEN
    RAISE EXCEPTION 'WITHDRAWAL_NOT_FOUND: Withdrawal % does not exist.', p_withdrawal_id;
  END IF;

  -- ── 2. VALIDATE ACTION ────────────────────────────────────────────
  IF p_action NOT IN ('approve', 'reject', 'complete') THEN
    RAISE EXCEPTION 'INVALID_ACTION: Action must be approve, reject, or complete.';
  END IF;

  -- ── 3. STATE MACHINE VALIDATION ───────────────────────────────────
  -- Valid transitions:
  --   pending  → approved | rejected
  --   approved → completed
  --   rejected → (terminal)
  --   completed → (terminal)

  IF v_withdrawal.status = 'pending' AND p_action = 'approve' THEN
    ------------------------------------------------------------------
    -- APPROVE: Mark as approved, awaiting external payout
    ------------------------------------------------------------------
    UPDATE public.withdrawals
    SET status       = 'approved',
        admin_notes  = COALESCE(p_admin_notes, admin_notes),
        processed_by = p_admin_id,
        processed_at = NOW()
    WHERE id = p_withdrawal_id;

    RETURN json_build_object(
      'success',        true,
      'withdrawal_id',  p_withdrawal_id,
      'action',         'approved',
      'amount',         v_withdrawal.amount
    );

  ELSIF v_withdrawal.status = 'pending' AND p_action = 'reject' THEN
    ------------------------------------------------------------------
    -- REJECT: Refund funds to user atomically
    ------------------------------------------------------------------

    -- Lock user row before touching balance
    PERFORM 1 FROM public.users
    WHERE id = v_withdrawal.user_id
    FOR UPDATE;

    -- Refund the locked amount
    UPDATE public.users
    SET balance = balance + v_withdrawal.amount
    WHERE id = v_withdrawal.user_id
    RETURNING balance INTO v_new_balance;

    -- Create refund transaction
    INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
    VALUES (v_withdrawal.user_id, 'refund', v_withdrawal.amount, 'completed', p_withdrawal_id)
    RETURNING id INTO v_refund_tx_id;

    -- Update withdrawal record
    UPDATE public.withdrawals
    SET status                = 'rejected',
        admin_notes           = COALESCE(p_admin_notes, 'Rejected by admin'),
        processed_by          = p_admin_id,
        processed_at          = NOW(),
        refund_transaction_id = v_refund_tx_id
    WHERE id = p_withdrawal_id;

    RETURN json_build_object(
      'success',        true,
      'withdrawal_id',  p_withdrawal_id,
      'action',         'rejected',
      'amount_refunded', v_withdrawal.amount,
      'new_balance',    v_new_balance,
      'refund_tx_id',   v_refund_tx_id
    );

  ELSIF v_withdrawal.status = 'approved' AND p_action = 'complete' THEN
    ------------------------------------------------------------------
    -- COMPLETE: External payout confirmed
    ------------------------------------------------------------------
    UPDATE public.withdrawals
    SET status       = 'completed',
        admin_notes  = COALESCE(p_admin_notes, admin_notes),
        processed_by = p_admin_id,
        processed_at = NOW()
    WHERE id = p_withdrawal_id;

    RETURN json_build_object(
      'success',        true,
      'withdrawal_id',  p_withdrawal_id,
      'action',         'completed',
      'amount',         v_withdrawal.amount
    );

  ELSE
    RAISE EXCEPTION 'INVALID_TRANSITION: Cannot % a withdrawal with status %.', p_action, v_withdrawal.status;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE '[process_withdrawal] Error on withdrawal %. Error: %', p_withdrawal_id, SQLERRM;
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─────────────────────────────────────────────────────────────────────
-- 6. IMMUTABILITY GUARD — Prevent edits on terminal withdrawal states
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._guard_terminal_withdrawal()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status IN ('completed', 'rejected') THEN
    RAISE EXCEPTION 'IMMUTABLE: A % withdrawal cannot be modified.', OLD.status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_guard_terminal_withdrawal ON public.withdrawals;
CREATE TRIGGER trg_guard_terminal_withdrawal
  BEFORE UPDATE ON public.withdrawals
  FOR EACH ROW
  WHEN (OLD.status IN ('completed', 'rejected'))
  EXECUTE FUNCTION public._guard_terminal_withdrawal();
