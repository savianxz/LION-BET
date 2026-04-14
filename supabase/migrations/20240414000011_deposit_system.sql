-- =====================================================================
-- 💳 SECURE DEPOSIT SYSTEM — Webhook-Based Flow
-- =====================================================================
-- Covers:
--   1. deposit_status enum
--   2. deposits table for tracking and idempotency
--   3. request_deposit — creates pending intent
--   4. confirm_deposit — atomic, idempotent balance crediting
-- =====================================================================

-- 1. DEPOSIT STATUS ENUM
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'deposit_status') THEN
    CREATE TYPE public.deposit_status AS ENUM (
      'pending',    -- User initiated, waiting for payment
      'confirmed',  -- Webhook received, funds credited
      'failed'      -- Payment failed or cancelled
    );
  END IF;
END $$;

-- 2. DEPOSITS TABLE
CREATE TABLE IF NOT EXISTS public.deposits (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.users(id),
  amount          NUMERIC(20, 8) NOT NULL CHECK (amount > 0),
  status          public.deposit_status NOT NULL DEFAULT 'pending',
  external_id     TEXT UNIQUE,                   -- ID from payment provider (PIX ID, etc.)
  provider        TEXT,                          -- e.g., 'mercadopago', 'stripe'
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),
  confirmed_at    TIMESTAMPTZ
);

-- Index for operational tracing
CREATE INDEX IF NOT EXISTS idx_deposits_user_status ON public.deposits (user_id, status);
CREATE INDEX IF NOT EXISTS idx_deposits_external_id ON public.deposits (external_id);

-- Updated_at trigger
DROP TRIGGER IF EXISTS trg_handle_updated_at ON public.deposits;
CREATE TRIGGER trg_handle_updated_at
  BEFORE UPDATE ON public.deposits
  FOR EACH ROW EXECUTE PROCEDURE public.handle_updated_at();

-- RLS
ALTER TABLE public.deposits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own deposits" ON public.deposits
  FOR SELECT USING (auth.uid() = user_id);

-- No direct client writes
CREATE POLICY "No direct client writes on deposits" ON public.deposits
  FOR ALL USING (false);

-- 3. request_deposit RPC
-- Initiates a deposit intent.
CREATE OR REPLACE FUNCTION public.request_deposit(
  p_amount NUMERIC,
  p_provider TEXT DEFAULT 'manual'
)
RETURNS JSON AS $$
DECLARE
  v_user_id UUID;
  v_deposit_id UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Must be logged in.';
  END IF;

  INSERT INTO public.deposits (user_id, amount, provider, status)
  VALUES (v_user_id, p_amount, p_provider, 'pending')
  RETURNING id INTO v_deposit_id;

  RETURN json_build_object(
    'success', true,
    'deposit_id', v_deposit_id,
    'status', 'pending'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. confirm_deposit RPC
-- CRITICAL HUB: Credits user balance upon webhook confirmation.
-- This function is IDEMPOTENT via external_id.
CREATE OR REPLACE FUNCTION public.confirm_deposit(
  p_external_id TEXT,
  p_amount      NUMERIC,
  p_provider    TEXT DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_deposit RECORD;
  v_user_id UUID;
  v_new_balance NUMERIC;
BEGIN
  -- 1. [LOCK] Lock the deposit by external_id to prevent races.
  SELECT * INTO v_deposit
  FROM public.deposits
  WHERE external_id = p_external_id
  FOR UPDATE;

  -- 2. [IDEMPOTENCY] If it doesn't exist, we create it (auto-funding/late-hook).
  -- If it DOES exist and is already confirmed, we exit early (success).
  IF v_deposit.id IS NOT NULL THEN
    IF v_deposit.status = 'confirmed' THEN
      RETURN json_build_object('success', true, 'message', 'ALREADY_PROCESSED');
    END IF;
  ELSE
    -- Optional: If external_id wasn't pre-recorded, we should have a fallback user_id.
    -- For this implementation, we assume the webhook provides context to link it if not found.
    -- However, standard flow is record pendant -> confirm.
    -- If not found, it's likely an error or a direct deposit without intent.
    RAISE EXCEPTION 'DEPOSIT_NOT_FOUND: External ID % not recognized.', p_external_id;
  END IF;

  -- 3. [VALIDATE] Ensure amount matches expected intent if applicable.
  -- Some providers allow partials, but usually we match exact.
  IF v_deposit.amount != p_amount THEN
    RAISE EXCEPTION 'AMOUNT_MISMATCH: Expected %, received %.', v_deposit.amount, p_amount;
  END IF;

  -- 4. [LOCK] Lock user balance
  SELECT balance INTO v_new_balance
  FROM public.users
  WHERE id = v_deposit.user_id
  FOR UPDATE;

  -- 5. [CREDIT] Update balance
  UPDATE public.users
  SET balance = balance + p_amount
  WHERE id = v_deposit.user_id
  RETURNING balance INTO v_new_balance;

  -- 6. [UPDATE] Mark deposit as confirmed
  UPDATE public.deposits
  SET status = 'confirmed',
      confirmed_at = NOW(),
      updated_at = NOW()
  WHERE id = v_deposit.id;

  -- 7. [LOG] Create transaction
  INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
  VALUES (v_deposit.user_id, 'deposit', p_amount, 'completed', v_deposit.id);

  RETURN json_build_object(
    'success', true,
    'deposit_id', v_deposit.id,
    'new_balance', v_new_balance
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'confirm_deposit failed for external_id %. Error: %', p_external_id, SQLERRM;
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
