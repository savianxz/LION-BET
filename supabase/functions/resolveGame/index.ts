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
    const adminSecret = Deno.env.get('ADMIN_SECRET')

    // 1. ADMIN AUTHENTICATION
    // VULN-008: Note — the admin secret is passed in a header.
    // In production, consider using a short-lived signed JWT instead.
    // This header MUST NOT be logged by any upstream proxy/CDN.
    const providedSecret = req.headers.get('X-Admin-Secret')

    if (!adminSecret || !providedSecret) {
      console.error('[SECURITY] Missing admin credentials in resolve attempt')
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    // Timing-safe comparison to prevent timing attacks
    const encoder = new TextEncoder()
    const a = encoder.encode(adminSecret)
    const b = encoder.encode(providedSecret)
    
    if (a.length !== b.length) {
      console.error('[SECURITY] Admin secret length mismatch — possible brute force')
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    // Use crypto.subtle for constant-time comparison
    const keyA = await crypto.subtle.importKey('raw', a, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
    const keyB = await crypto.subtle.importKey('raw', b, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
    const sigA = await crypto.subtle.sign('HMAC', keyA, encoder.encode('verify'))
    const sigB = await crypto.subtle.sign('HMAC', keyB, encoder.encode('verify'))
    
    const match = new Uint8Array(sigA).every((val, i) => val === new Uint8Array(sigB)[i])
    
    if (!match) {
      console.error('[SECURITY] Invalid admin secret provided')
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    const { round_id } = await req.json()

    if (!round_id) {
      return new Response(JSON.stringify({ error: 'Missing round_id' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // 2. TRIGGER SECURE RPC (deterministic result from provably fair algorithm)
    const { data, error } = await supabase.rpc('resolve_game_round', {
      p_round_id: round_id
    })

    if (error) {
      console.error('[RPC_ERROR] Resolution failed:', error.message)
      // VULN-013: Sanitize
      const safeMessage = error.message.includes('ALREADY_RESOLVED') ? 'Round already resolved.'
        : error.message.includes('ROUND_NOT_FOUND') ? 'Round not found.'
        : 'Resolution failed.'
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
    // VULN-013: Never leak internal errors
    console.error('[INTERNAL_ERROR] resolveGame:', error.message)
    return new Response(JSON.stringify({ error: 'An unexpected error occurred.' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
