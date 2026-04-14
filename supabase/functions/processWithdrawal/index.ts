import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { corsHeaders } from "../_shared/cors.ts"

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const adminSecret = Deno.env.get('ADMIN_SECRET')

    // ── ADMIN AUTHENTICATION (same pattern as resolveGame) ────────
    const providedSecret = req.headers.get('X-Admin-Secret')

    if (!adminSecret || !providedSecret) {
      console.error('[SECURITY] Missing admin credentials in withdrawal process attempt')
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    // Timing-safe comparison
    const encoder = new TextEncoder()
    const a = encoder.encode(adminSecret)
    const b = encoder.encode(providedSecret)

    if (a.length !== b.length) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    const keyA = await crypto.subtle.importKey('raw', a, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
    const keyB = await crypto.subtle.importKey('raw', b, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
    const sigA = await crypto.subtle.sign('HMAC', keyA, encoder.encode('verify'))
    const sigB = await crypto.subtle.sign('HMAC', keyB, encoder.encode('verify'))
    const match = new Uint8Array(sigA).every((val, i) => val === new Uint8Array(sigB)[i])

    if (!match) {
      console.error('[SECURITY] Invalid admin secret in withdrawal process')
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    // ── PARSE REQUEST ─────────────────────────────────────────────
    const { withdrawal_id, action, admin_notes } = await req.json()

    if (!withdrawal_id || !action) {
      return new Response(JSON.stringify({ error: 'withdrawal_id and action are required' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    if (!['approve', 'reject', 'complete'].includes(action)) {
      return new Response(JSON.stringify({ error: 'Action must be: approve, reject, or complete' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // ── CALL SECURE RPC ───────────────────────────────────────────
    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    const { data, error } = await supabase.rpc('process_withdrawal', {
      p_withdrawal_id: withdrawal_id,
      p_action: action,
      p_admin_notes: admin_notes || null,
      p_admin_id: 'admin_api' // Can be enriched with actual admin identity
    })

    if (error) {
      console.error('[RPC_ERROR] process_withdrawal:', error.message)
      const safeMessage = error.message.includes('WITHDRAWAL_NOT_FOUND') ? 'Withdrawal not found.'
        : error.message.includes('INVALID_TRANSITION') ? 'Invalid status transition.'
        : error.message.includes('IMMUTABLE') ? 'This withdrawal cannot be modified.'
        : 'Processing failed.'
      return new Response(JSON.stringify({ error: safeMessage }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error: any) {
    console.error('[INTERNAL_ERROR] processWithdrawal:', error.message)
    return new Response(JSON.stringify({ error: 'An unexpected error occurred.' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
