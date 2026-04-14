---------- USERS ----------
CREATE TABLE public.users (
  id UUID REFERENCES auth.users(id) PRIMARY KEY,
  email TEXT NOT NULL,
  balance NUMERIC NOT NULL DEFAULT 0.0 CHECK (balance >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS: Only the user can read their own data.
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own data" ON public.users
  FOR SELECT USING (auth.uid() = id);

-- Handle new user creation (trigger)
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.users (id, email, balance)
  VALUES (new.id, new.email, 0.0);
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();


---------- GAMES ----------
CREATE TABLE public.games (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  house_edge NUMERIC NOT NULL DEFAULT 5.0,
  is_active BOOLEAN NOT NULL DEFAULT true
);

-- Insert the default 'CRASH' game
INSERT INTO public.games (name, house_edge) VALUES ('CRASH', 5.0);

-- RLS: Anyone can read games
ALTER TABLE public.games ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read active games" ON public.games
  FOR SELECT USING (is_active = true);


---------- GAME ROUNDS ----------
-- status: 'created', 'started', 'finished'
CREATE TABLE public.game_rounds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id UUID REFERENCES public.games(id) NOT NULL,
  server_seed TEXT NOT NULL,       -- Secret until round ends
  server_seed_hash TEXT NOT NULL,  -- Publicly verifiable
  client_seed TEXT,
  nonce BIGINT NOT NULL DEFAULT 0,
  result NUMERIC,                  -- The crash multiplier (e.g. 1.5)
  status TEXT NOT NULL DEFAULT 'created', 
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS: Anyone can read rounds
ALTER TABLE public.game_rounds ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read game rounds" ON public.game_rounds
  FOR SELECT USING (true);


---------- BETS ----------
-- status: 'pending', 'win', 'loss'
CREATE TABLE public.bets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES public.users(id) NOT NULL,
  game_id UUID REFERENCES public.games(id) NOT NULL,
  round_id UUID REFERENCES public.game_rounds(id) NOT NULL,
  amount NUMERIC NOT NULL CHECK (amount > 0),
  multiplier NUMERIC NOT NULL CHECK (multiplier > 1), -- The auto-cashout multiplier
  payout NUMERIC NOT NULL DEFAULT 0.0,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS: User can read own bets
ALTER TABLE public.bets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own bets" ON public.bets
  FOR SELECT USING (auth.uid() = user_id);


---------- TRANSACTIONS ----------
-- type: 'deposit', 'withdrawal', 'bet', 'win'
-- status: 'completed', 'pending'
CREATE TABLE public.transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES public.users(id) NOT NULL,
  type TEXT NOT NULL, 
  amount NUMERIC NOT NULL,
  status TEXT NOT NULL DEFAULT 'completed',
  reference_id UUID, -- Optional linking to bet_id or outside trans id
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS: User can read own transactions
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own transactions" ON public.transactions
  FOR SELECT USING (auth.uid() = user_id);
