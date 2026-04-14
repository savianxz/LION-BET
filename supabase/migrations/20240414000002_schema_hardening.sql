-- ==========================================
-- 🛡️ SCHEMA HARDENING: FINANCIAL-GRADE INTEGRITY
-- ==========================================
-- This migration upgrades the platform schema to production standards.
-- 1. Introduces Enums for strict state control.
-- 2. Hardens financial columns and constraints.
-- 3. Optimizes indexing for high-concurrency betting.
-- 4. Refines RLS for absolute multi-tenant user isolation.

-- 1. STATUS & TYPE ENUMS
-- Using Enums prevents invalid strings from corrupting the application state.
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'game_round_status') THEN
        CREATE TYPE public.game_round_status AS ENUM ('created', 'started', 'finished', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'bet_status') THEN
        CREATE TYPE public.bet_status AS ENUM ('pending', 'won', 'lost', 'voided');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'transaction_type') THEN
        CREATE TYPE public.transaction_type AS ENUM ('deposit', 'withdrawal', 'bet', 'win', 'refund');
    END IF;
END $$;

-- 2. HARDEN USERS TABLE
-- Ensuring maximum precision and ironclad balance checks.
ALTER TABLE public.users 
  ALTER COLUMN balance TYPE NUMERIC(20, 8),
  ALTER COLUMN balance SET DEFAULT 0.00000000;

-- Redundant but critical safety check
DO $$ 
BEGIN
    ALTER TABLE public.users ADD CONSTRAINT users_balance_non_negative CHECK (balance >= 0);
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 3. HARDEN GAME_ROUNDS TABLE
-- We convert the status column to use our new Enum.
-- Using a subquery for casting to ensure compatibility.
ALTER TABLE public.game_rounds 
  ALTER COLUMN status TYPE public.game_round_status USING status::public.game_round_status;

CREATE INDEX IF NOT EXISTS idx_game_rounds_active_lookup 
  ON public.game_rounds (game_id, status) 
  WHERE status != 'finished';

-- 4. HARDEN BETS TABLE
ALTER TABLE public.bets 
  ALTER COLUMN status TYPE public.bet_status USING status::public.bet_status,
  ALTER COLUMN amount TYPE NUMERIC(20, 8),
  ALTER COLUMN payout TYPE NUMERIC(20, 8);

-- Index for efficient user history tracking
CREATE INDEX IF NOT EXISTS idx_bets_user_round_lookup 
  ON public.bets (user_id, round_id);

-- 5. HARDEN TRANSACTIONS TABLE
ALTER TABLE public.transactions 
  ALTER COLUMN type TYPE public.transaction_type USING type::public.transaction_type;

-- Add metadata column for traceability (IP, User Agent, etc.)
ALTER TABLE public.transactions 
  ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_transactions_user_type_created 
  ON public.transactions (user_id, type, created_at DESC);

-- 6. REFINED ROW LEVEL SECURITY (RLS)
-- Ensuring users can only see what belongs to them.

-- USERS
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can read own data" ON public.users;
CREATE POLICY "Users can read own data" ON public.users
  FOR SELECT USING (auth.uid() = id);

-- BETS
ALTER TABLE public.bets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can read own bets" ON public.bets;
CREATE POLICY "Users can read own bets" ON public.bets
  FOR SELECT USING (auth.uid() = user_id);
-- No manual updates allowed for users; only via RPC/System
CREATE POLICY "Users cannot update bets" ON public.bets
  FOR UPDATE USING (false);

-- TRANSACTIONS
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can read own transactions" ON public.transactions;
CREATE POLICY "Users can read own transactions" ON public.transactions
  FOR SELECT USING (auth.uid() = user_id);
-- Static history: no one (not even admin in many cases) should edit a transaction
CREATE POLICY "Transactions are immutable" ON public.transactions
  FOR UPDATE USING (false);

-- 7. AUDIT TRIGGER
-- Standard trigger to update 'updated_at' if it exists.
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  IF (NEW IS DISTINCT FROM OLD) THEN
    NEW.updated_at = NOW();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all relevant tables
DO $$ 
DECLARE
    t text;
BEGIN
    FOR t IN SELECT table_name FROM information_schema.columns WHERE column_name = 'updated_at' AND table_schema = 'public'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_handle_updated_at ON public.%I', t);
        EXECUTE format('CREATE TRIGGER trg_handle_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE PROCEDURE public.handle_updated_at()', t);
    END LOOP;
END $$;
