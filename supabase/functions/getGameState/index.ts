import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { corsHeaders } from "../_shared/cors.ts"

serve(async (req) => {
  // CORS Preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // Use service role to read game state (base game_rounds table is locked by RLS)
    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // 1. FETCH ACTIVE GAME
    const { data: game, error: gameError } = await supabase
      .from('games')
      .select('id, name')
      .eq('name', 'CRASH')
      .single()

    if (gameError || !game) {
      return new Response(JSON.stringify({ error: 'Game not available' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 404,
      })
    }

    // 2. FETCH LATEST NON-FINISHED ROUND
    // We use the masking view to ensure server_seed is never exposed
    const { data: round, error: roundError } = await supabase
      .from('game_rounds_public')
      .select('id, server_seed_hash, status, created_at, nonce')
      .eq('game_id', game.id)
      .neq('status', 'finished')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle()

    if (roundError) throw roundError

    // 3. FETCH AGGREGATED BET STATS (VULN-007: No user_id exposure)
    // Instead of leaking individual bets with user IDs, return anonymous aggregates.
    let betStats = { total_bets: 0, total_amount: 0 }
    if (round) {
      const { data: stats } = await supabase
        .rpc('get_round_bet_stats', { p_round_id: round.id })

      if (stats) {
        betStats = stats
      }
    }

    return new Response(JSON.stringify({
      game: { name: game.name },
      round: round || null,
      stats: betStats,
      timestamp: new Date().toISOString()
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error: any) {
    // VULN-013: Never leak internal errors
    console.error('[INTERNAL_ERROR] getGameState:', error.message)
    return new Response(JSON.stringify({ error: 'Unable to fetch game state.' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
