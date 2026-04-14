-- ==========================================
-- 🛡️ REFACTOR: SECURITY & ACID COMPLIANCE
-- ==========================================
-- Este script corrige vulnerabilidades críticas:
-- 1. Impede multiplicador malicioso vindo do cliente
-- 2. Previne deduções paralelas / race conditions (Lock FOR UPDATE)
-- 3. Garante que o saldo nunca fique negativo (CHECK constraints)
-- 4. Impede que apostas ocorram fora da janela `created`

-- 1. Adicionar Constraints Fortes nas Tabelas
DO $$ 
BEGIN
  -- users: Garante a nível de engine DB que saldo nunca seja menor que ZERO
  ALTER TABLE public.users ADD CONSTRAINT users_balance_check CHECK (balance >= 0);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$ 
BEGIN
  -- bets: O valor da aposta DEVE ser maior que 0. Cashout tem de ser NULL ou > 1.
  ALTER TABLE public.bets ADD CONSTRAINT bet_amount_check CHECK (amount > 0);
  ALTER TABLE public.bets ADD CONSTRAINT bet_multiplier_check CHECK (multiplier IS NULL OR multiplier > 1.0);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$ 
BEGIN
  -- Evitar que a mesma pessoa aposte 2 vezes no mesmo round usando UNIQUE constraint
  ALTER TABLE public.bets ADD CONSTRAINT unique_user_round_bet UNIQUE (user_id, round_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- Índices essenciais de performance
CREATE INDEX IF NOT EXISTS idx_bets_round_id on public.bets(round_id);
CREATE INDEX IF NOT EXISTS idx_bets_user_id on public.bets(user_id);


-- 2. Refatorando a Função de Aposta (Segurança Total & Atômica)
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
BEGIN
  -- 1. SEGURANÇA: PEGAR ID DO USUÁRIO VIA TOKEN AUTENTICADO
  -- NUNCA confie em IDs enviados via JSON do Frontend!
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Usuário precisa estar logado para apostar.';
  END IF;

  -- 2. VALIDAÇÃO DE INPUT
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Valor da aposta deve ser maior que zero.';
  END IF;

  IF p_auto_cashout IS NOT NULL AND p_auto_cashout <= 1.0 THEN
    RAISE EXCEPTION 'INVALID_CASHOUT: O multiplicador alvo (auto cashout) não pode ser <= 1.0.';
  END IF;

  -- 3. LOCK TRANSACIONAL ANTI RACE CONDITION (FOR UPDATE)
  -- Bloqueia SOMENTE a linha do usuário até a transação terminar (commit/rollback)
  SELECT balance INTO v_balance 
  FROM public.users 
  WHERE id = v_user_id 
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND: Registro do usuário não encontrado na base.';
  END IF;

  -- 4. CHECK DE SALDO
  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Saldo insuficiente. Atual: %. Necessário: %', v_balance, p_amount;
  END IF;

  -- 5. VALIDAÇÃO DE ESTADO DO JOGO (Round Ativa)
  SELECT status INTO v_round_status 
  FROM public.game_rounds 
  WHERE id = p_round_id;

  IF v_round_status IS NULL THEN
    RAISE EXCEPTION 'ROUND_NOT_FOUND: Rodada inexistente.';
  END IF;

  -- O jogo SÓ pode receber apostas no status inicial.
  IF v_round_status != 'created' THEN
    RAISE EXCEPTION 'ROUND_CLOSED: A rodada já foi encerrada ou iniciada (Status atual: %).', v_round_status;
  END IF;

  -- 6. EXECUÇÃO ATÔMICA
  -- 6.1 Debitar do Saldo
  UPDATE public.users 
  SET balance = balance - p_amount 
  WHERE id = v_user_id;

  -- 6.2 Criar Aposta (Note que p_auto_cashout está indo para a coluna multiplier do usuário)
  INSERT INTO public.bets (user_id, game_id, round_id, amount, multiplier, status)
  VALUES (v_user_id, p_game_id, p_round_id, p_amount, p_auto_cashout, 'pending')
  RETURNING id INTO v_bet_id;

  -- 6.3 Criar Extrato/Histórico (Transação)
  INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
  VALUES (v_user_id, 'bet', -p_amount, 'completed', v_bet_id);

  -- 7. RESPOSTA DE SUCESSO
  RETURN json_build_object(
    'success', true, 
    'bet_id', v_bet_id, 
    'new_balance', v_balance - p_amount,
    'amount', p_amount,
    'auto_cashout', p_auto_cashout
  );

EXCEPTION
  WHEN unique_violation THEN
    -- Isso dispara se o usuário tentar burlar fazendo spam simultâneo na mesma rodada (Constraint UNIQUE da tabela)
    RAISE EXCEPTION 'ALREADY_BETTED: Você já realizou uma aposta nesta rodada.';
  WHEN check_violation THEN
    -- Dispara se, por um bug bizarro, a matemática jogar o número pra negativo (CHECK balance >= 0)
    RAISE EXCEPTION 'CONSTRAINT_VIOLATION: Operação abortada por segurança matemática no banco.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
