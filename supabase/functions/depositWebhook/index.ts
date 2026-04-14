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
    const webhookSecret = Deno.env.get('WEBHOOK_SECRET') // Shared secret with provider

    // 1. SIGNATURE VERIFICATION (CRITICAL)
    // In production, you would use a provider-specific check (e.g. HMAC or IP Whitelist).
    const signature = req.headers.get('X-Webhook-Signature')
    if (!signature || signature !== webhookSecret) {
       console.error('[SECURITY] Invalid webhook signature detected')
       return new Response(JSON.stringify({ error: 'Unauthorized' }), {
         headers: { ...corsHeaders, 'Content-Type': 'application/json' },
         status: 401,
       })
    }

    const payload = await req.json()
    const { external_id, amount, provider } = payload

    if (!external_id || !amount) {
      return new Response(JSON.stringify({ error: 'Missing external_id or amount' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // 2. TRIGGER SECURE RPC
    // confirm_deposit is idempotent; it won't credit the same external_id twice.
    const { data, error } = await supabase.rpc('confirm_deposit', {
      p_external_id: external_id,
      p_amount: Number(amount),
      p_provider: provider || 'unknown'
    })

    if (error) {
      console.error('[RPC_ERROR] Deposit confirmation failed:', error.message)
      // We return 200 even on 'DEPOSIT_NOT_FOUND' to acknowledge receipt to the provider,
      // but log it internally for manual adjustment.
      const status = error.message.includes('NOT_FOUND') ? 200 : 400
      return new Response(JSON.stringify({ error: error.message }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: status,
      })
    }

    console.info(`[SUCCESS] Deposit confirmed: ${external_id} for user ${data.user_id}`)

    return new Response(JSON.stringify({ success: true, message: data.message || 'Confirmed' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error: any) {
    console.error('[INTERNAL_ERROR] depositWebhook:', error.message)
    return new Response(JSON.stringify({ error: 'Internal Server Error' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
