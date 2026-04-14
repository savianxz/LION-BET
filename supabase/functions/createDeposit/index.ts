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
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const authHeader = req.headers.get('Authorization')!

    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Authentication required' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    const { amount, provider = 'manual' } = await req.json()

    if (!amount || typeof amount !== 'number' || amount <= 0) {
      return new Response(JSON.stringify({ error: 'Invalid amount' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // Create client with user context
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    })

    // 1. GET USER ID
    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    // 2. TRIGGER RPC TO CREATE INTENT
    const { data, error } = await supabase.rpc('request_deposit', {
      p_amount: amount,
      p_provider: provider
    })

    if (error) {
      console.error('[RPC_ERROR] request_deposit:', error.message)
      return new Response(JSON.stringify({ error: 'Could not initiate deposit' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // 3. MOCK PAYMENT PROVIDER PAYLOAD
    // In a real scenario, you'd call MercadoPago/Stripe here and return the QR/Link.
    const paymentPayload = {
      deposit_id: data.deposit_id,
      payment_url: `https://mock-gateway.com/pay/${data.deposit_id}`,
      qr_code: "MOCK_QR_CODE_DATA",
      amount: amount,
      provider: provider
    }

    return new Response(JSON.stringify(paymentPayload), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error: any) {
    console.error('[INTERNAL_ERROR] createDeposit:', error.message)
    return new Response(JSON.stringify({ error: 'Internal Server Error' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
