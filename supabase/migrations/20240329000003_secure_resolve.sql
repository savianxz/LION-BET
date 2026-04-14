-- ==========================================
-- 🛡️ REFACTOR: SECURE GAME RESOLUTION
-- ==========================================
-- Função 100% segura e atômica para encerrar rodadas.
-- 1. Impede dupla execução e race conditions (FOR UPDATE em game_rounds)
-- 2. Atualiza saldo dos vencedores de forma segura (FOR UPDATE em users)
-- 3. Transacional: tudo ocorre em um único bloco de commit.

-- Adicionando colunas de salvaguarda caso não existam
DO $$ 
BEGIN
  ALTER TABLE public.game_rounds ADD COLUMN result NUMERIC;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

DO $$ 
BEGIN
  ALTER TABLE public.bets ADD COLUMN payout NUMERIC DEFAULT 0;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

-- Criação da Procedure Robusta
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
  v_total_payout NUMERIC := 0;
  v_bets_processed INT := 0;
BEGIN
  -- 1. LOCK EXCLUSIVO NA RODADA MÃE (FOR UPDATE)
  -- Garante que nenhum outro processo ou servidor encerre esta mesma rodada.
  SELECT * INTO v_round
  FROM public.game_rounds
  WHERE id = p_round_id
  FOR UPDATE;

  -- 2. VERIFICAÇÃO DE ESTADO
  IF v_round.id IS NULL THEN
    RAISE EXCEPTION 'ROUND_NOT_FOUND: Rodada inexistente.';
  END IF;

  -- Se já estiver finalizada, abortamos imediatamente. Nunca pagar 2 vezes!
  IF v_round.status = 'finished' THEN
    RAISE EXCEPTION 'ALREADY_RESOLVED: A rodada já foi encerrada e contabilizada.';
  END IF;

  -- 3. GERAR O RESULTADO DO JOGO (CRASH MULTIPLIER)
  -- Caso o backend não passe o resultado, a DB gera um valor seguro por fallback
  IF p_crash_multiplier IS NULL THEN
    p_crash_multiplier := ROUND((random() * 9.0 + 1.0)::numeric, 2);
  END IF;

  -- 4. ATUALIZAR STATUS DA RODADA
  UPDATE public.game_rounds
  SET status = 'finished',
      result = p_crash_multiplier,
      updated_at = NOW()
  WHERE id = p_round_id;

  -- 5. PROCESSAMENTO SEQUENCIAL DAS APOSTAS PENDENTES
  FOR v_bet IN 
    SELECT * FROM public.bets 
    WHERE round_id = p_round_id AND status = 'pending'
  LOOP
    v_bets_processed := v_bets_processed + 1;

    -- 6. CALCULAR GANHO (WIN/LOSS)
    -- O jogador ganha se definiu um cashout (`multiplier`) menor ou igual ao ponto de crash.
    IF v_bet.multiplier IS NOT NULL AND v_bet.multiplier <= p_crash_multiplier THEN
      
      v_payout := v_bet.amount * v_bet.multiplier;
      
      -- Atualiza o bilhete da aposta com lucro exato
      UPDATE public.bets
      SET status = 'won',
          payout = v_payout
      WHERE id = v_bet.id;

      -- ATUALIZAÇÃO SEGURA DO SALDO DO JOGADOR (Lock na linha do usuário)
      SELECT balance INTO v_user_balance
      FROM public.users
      WHERE id = v_bet.user_id
      FOR UPDATE;

      UPDATE public.users
      SET balance = balance + v_payout
      WHERE id = v_bet.user_id;

      -- INSERIR COMPROVANTE BANCÁRIO (TRANSACTIONS)
      INSERT INTO public.transactions (user_id, type, amount, status, reference_id)
      VALUES (v_bet.user_id, 'win', v_payout, 'completed', v_bet.id);

      v_total_payout := v_total_payout + v_payout;

    ELSE
      -- Jogador PERDEU. Seu auto cashout foi maior que o crash (ou ele não retirou).
      UPDATE public.bets
      SET status = 'lost',
          payout = 0
      WHERE id = v_bet.id;

    END IF;
  END LOOP;

  -- 7. RESPOSTA DE SUCESSO E AUDITORIA
  RETURN json_build_object(
    'success', true,
    'round_id', p_round_id,
    'crash_multiplier', p_crash_multiplier,
    'bets_processed', v_bets_processed,
    'total_paid', v_total_payout
  );

EXCEPTION
  WHEN OTHERS THEN
    -- Propaga qualquer erro do lock ou falha estrutural para abortar a transação
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
