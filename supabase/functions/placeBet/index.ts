import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { corsHeaders } from "../_shared/cors.ts"

serve(async (req) => {
  // CORS Preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const authHeader = req.headers.get('Authorization')!

  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Authentication required' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 401,
    })
  }

  // Create client with authenticated user's context
  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } }
  })

  try {
    const { game_id, round_id, amount } = await req.json()

    // 1. INPUT VALIDATION (Never trust frontend)
    // We strictly DO NOT accept multiplier/auto_cashout from user.
    if (!game_id || !round_id || !amount || typeof amount !== 'number' || amount <= 0) {
      console.warn('[SECURITY] Invalid bet parameters received')
      return new Response(JSON.stringify({ error: 'Invalid bet parameters' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // VULN-006: Edge-level max bet guard (defense in depth — SQL also enforces)
    if (amount > 10000) {
      console.warn('[SECURITY] Max bet exceeded attempt')
      return new Response(JSON.stringify({ error: 'Bet exceeds maximum allowed' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // 2. GET USER ID
    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Authentication required' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    // 3. CALL SECURE RPC
    // Rate limiting is now enforced INSIDE the SQL function (VULN-009 fix).
    // p_auto_cashout is null because we don't accept multiplier from user.
    const userIP = req.headers.get('x-forwarded-for')?.split(',')[0].trim() || null
    const userUA = req.headers.get('user-agent') || null

    const { data, error } = await supabase.rpc('place_bet', {
      p_game_id: game_id,
      p_round_id: round_id,
      p_amount: amount,
      p_auto_cashout: null,
      p_ip: userIP,
      p_ua: userUA
    })

    if (error) {
      console.error('[RPC_ERROR]', error.message)
      // Sanitized error mapping (security + risk + anti-abuse)
      const safeMessage = error.message.includes('ACCOUNT_SUSPENDED') ? 'Your account is temporarily suspended.'
        : error.message.includes('RATE_LIMITED') ? 'Too many requests. Please wait.'
        : error.message.includes('MINUTE_CAP_EXCEEDED') ? 'Too many bets. Please slow down.'
        : error.message.includes('INSUFFICIENT_FUNDS') ? 'Insufficient balance.'
        : error.message.includes('ROUND_CLOSED') ? 'Round is closed for betting.'
        : error.message.includes('ALREADY_BET') ? 'You already bet this round.'
        : error.message.includes('BET_EXCEEDS_MAXIMUM') ? 'Bet exceeds maximum allowed.'
        : error.message.includes('BELOW_MINIMUM') ? 'Bet is below the minimum.'
        : error.message.includes('DAILY_LIMIT_EXCEEDED') ? 'You have reached your daily betting limit.'
        : error.message.includes('ROUND_LIMIT_EXCEEDED') ? 'This round has reached maximum capacity.'
        : 'Bet could not be placed.'

      const status = error.message.includes('ACCOUNT_SUSPENDED') ? 403
        : error.message.includes('RATE_LIMITED') || error.message.includes('MINUTE_CAP') ? 429
        : 400
      return new Response(JSON.stringify({ error: safeMessage }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status,
      })
    }

    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error: any) {
    // VULN-013: Never leak internal errors to client
    console.error('[INTERNAL_ERROR] placeBet:', error.message)
    return new Response(JSON.stringify({ error: 'An unexpected error occurred.' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
