CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. Create a logic to place a bet safely
CREATE OR REPLACE FUNCTION public.place_bet(
  p_game_id UUID,
  p_round_id UUID,
  p_amount NUMERIC,
  p_multiplier NUMERIC
)
RETURNS JSON AS $$
DECLARE
  v_user_id UUID;
  v_balance NUMERIC;
  v_bet_id UUID;
  v_round_status TEXT;
BEGIN
  -- 1. Get user id from auth context
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- 2. Check if the round is accepting bets (status = 'created' or 'started')
  -- We assume 'created' is betting phase
  SELECT status INTO v_round_status FROM public.game_rounds WHERE id = p_round_id;
  IF v_round_status != 'created' THEN
    RAISE EXCEPTION 'Round is closed for betting';
  END IF;

  -- 3. Lock user row and check balance
  SELECT balance INTO v_balance FROM public.users WHERE id = v_user_id FOR UPDATE;
  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  -- 4. Deduct balance
  UPDATE public.users SET balance = balance - p_amount WHERE id = v_user_id;

  -- 5. Insert Bet
  INSERT INTO public.bets (user_id, game_id, round_id, amount, multiplier, status)
  VALUES (v_user_id, p_game_id, p_round_id, p_amount, p_multiplier, 'pending')
  RETURNING id INTO v_bet_id;

  -- 6. Insert transaction
  INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
  VALUES (v_user_id, 'bet', -p_amount, 'completed', v_bet_id);

  RETURN json_build_object('success', true, 'bet_id', v_bet_id, 'new_balance', v_balance - p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 2. Create the next game round logic (Provably Fair)
CREATE OR REPLACE FUNCTION public.create_game_round(p_game_id UUID)
RETURNS UUID AS $$
DECLARE
  v_round_id UUID;
  v_secret TEXT;
  v_hash TEXT;
BEGIN
  -- Generate a secure random server_seed
  v_secret := encode(gen_random_bytes(32), 'hex');
  v_hash := encode(digest(v_secret, 'sha256'), 'hex');
  
  INSERT INTO public.game_rounds (game_id, server_seed, server_seed_hash, status)
  VALUES (p_game_id, v_secret, v_hash, 'created')
  RETURNING id INTO v_round_id;
  
  RETURN v_round_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 3. Resolve a round (calculating result and paying winners)
CREATE OR REPLACE FUNCTION public.resolve_game(
  p_round_id UUID,
  p_result NUMERIC
)
RETURNS JSON AS $$
DECLARE
  v_bet RECORD;
  v_payout NUMERIC;
BEGIN
  -- Note: This function should only be called by an authenticated admin/service role
  
  -- Update round
  UPDATE public.game_rounds 
  SET result = p_result, status = 'finished' 
  WHERE id = p_round_id AND status != 'finished';
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Round already resolved or not found';
  END IF;

  -- Resolve bets
  FOR v_bet IN 
    SELECT * FROM public.bets WHERE round_id = p_round_id AND status = 'pending' FOR UPDATE
  LOOP
    IF p_result >= v_bet.multiplier THEN
      -- Win
      v_payout := TRUNC(v_bet.amount * v_bet.multiplier, 2);
      
      UPDATE public.bets SET status = 'win', payout = v_payout WHERE id = v_bet.id;
      UPDATE public.users SET balance = balance + v_payout WHERE id = v_bet.user_id;
      
      INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
      VALUES (v_bet.user_id, 'win', v_payout, 'completed', v_bet.id);
    ELSE
      -- Loss
      UPDATE public.bets SET status = 'loss' WHERE id = v_bet.id;
    END IF;
  END LOOP;
  
  RETURN json_build_object('success', true, 'round_id', p_round_id, 'result', p_result);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
