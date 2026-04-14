import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { corsHeaders } from "../_shared/cors.ts"

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const authHeader = req.headers.get('Authorization')

  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Authentication required' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 401,
    })
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } }
  })

  try {
    const { amount } = await req.json()

    // Input validation (defense in depth — SQL also validates)
    if (!amount || typeof amount !== 'number' || amount <= 0) {
      return new Response(JSON.stringify({ error: 'Invalid withdrawal amount' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // Verify user is authenticated
    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Authentication required' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    // Call the atomic SQL function
    const { data, error } = await supabase.rpc('request_withdrawal', {
      p_amount: amount,
    })

    if (error) {
      console.error('[RPC_ERROR] request_withdrawal:', error.message)
      // Sanitized errors (VULN-013 pattern)
      const safeMessage = error.message.includes('INSUFFICIENT_FUNDS') ? 'Insufficient balance.'
        : error.message.includes('BELOW_MINIMUM') ? 'Amount is below the minimum withdrawal.'
        : error.message.includes('ABOVE_MAXIMUM') ? 'Amount exceeds the maximum withdrawal.'
        : error.message.includes('RATE_LIMITED') ? 'Please wait before requesting another withdrawal.'
        : error.message.includes('PENDING_EXISTS') ? 'You already have a pending withdrawal.'
        : 'Withdrawal request failed.'

      const status = error.message.includes('RATE_LIMITED') ? 429 : 400
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
    console.error('[INTERNAL_ERROR] requestWithdrawal:', error.message)
    return new Response(JSON.stringify({ error: 'An unexpected error occurred.' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
