import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { corsHeaders } from "../_shared/cors.ts";

/**
 * 🔄 GAME LOOP EDGE FUNCTION
 * 
 * This function handles the automated state machine transitions for the Crash game.
 * In production, this should be triggered every 1-2 seconds by:
 *   1. A GitHub Action / Cron job
 *   2. A specialized scheduler (like Inngest or Upstash)
 *   3. A long-running loop with a sleep interval
 */

Deno.serve(async (req) => {
  // 1. Handle CORS Preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    const adminSecret = Deno.env.get("ADMIN_SECRET");

    // 2. Security: Verify Admin Secret
    // We use a simple secret check for internal system-to-system calls.
    if (!adminSecret || authHeader !== `Bearer ${adminSecret}`) {
      console.warn("[GAME_LOOP] Unauthorized access attempt.");
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { game_id } = await req.json();
    if (!game_id) {
      return new Response(JSON.stringify({ error: "game_id is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // 3. FETCH CURRENT ACTIVE ROUND
    const { data: activeRound, error: fetchError } = await supabase
      .from("game_rounds")
      .select("*")
      .eq("game_id", game_id)
      .in("status", ["created", "in_progress"])
      .order("created_at", { ascending: false })
      .limit(1)
      .single();

    // 4. STATE MACHINE TRANSITIONS
    
    // CASE A: NO ACTIVE ROUND -> START NEW ONE
    if (!activeRound || fetchError) {
      console.log(`[GAME_LOOP] No active round for game ${game_id}. Starting new one...`);
      const { data, error } = await supabase.rpc("start_new_round", {
        p_game_id: game_id,
        p_max_exposure: 50000.00 // Default exposure limit
      });
      
      if (error) throw error;
      return new Response(JSON.stringify({ status: "STARTED_NEW_ROUND", data }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const now = new Date();
    const createdAt = new Date(activeRound.created_at);
    const updatedAt = new Date(activeRound.updated_at || activeRound.created_at);
    const elapsedSinceCreation = (now.getTime() - createdAt.getTime()) / 1000;
    const elapsedSinceStateChange = (now.getTime() - updatedAt.getTime()) / 1000;

    // CASE B: ROUND IS 'created' -> WAIT OR CLOSE BETTING
    if (activeRound.status === "created") {
      const BETTING_DURATION = 10; // seconds
      
      if (elapsedSinceCreation >= BETTING_DURATION) {
        console.log(`[GAME_LOOP] Betting period over for round ${activeRound.id}. Closing...`);
        const { data, error } = await supabase.rpc("close_round_betting", {
          p_round_id: activeRound.id
        });
        if (error) throw error;
        return new Response(JSON.stringify({ status: "CLOSED_BETTING", data }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      
      return new Response(JSON.stringify({ 
        status: "WAITING_FOR_BETS", 
        seconds_remaining: Math.max(0, BETTING_DURATION - elapsedSinceCreation) 
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // CASE C: ROUND IS 'in_progress' -> WAIT OR RESOLVE
    // In a real Crash game, we'd simulate the multiplier climb here.
    // For the MVP, we resolve after a fixed delay.
    if (activeRound.status === "in_progress") {
      const GAME_ANIMATION_DELAY = 5; // seconds (simulated duration)
      
      if (elapsedSinceStateChange >= GAME_ANIMATION_DELAY) {
        console.log(`[GAME_LOOP] Game animation finished for round ${activeRound.id}. Resolving...`);
        const { data, error } = await supabase.rpc("resolve_game_round", {
          p_round_id: activeRound.id
        });
        if (error) throw error;
        return new Response(JSON.stringify({ status: "RESOLVED", data }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      
      return new Response(JSON.stringify({ 
        status: "GAME_RUNNING", 
        seconds_to_resolution: Math.max(0, GAME_ANIMATION_DELAY - elapsedSinceStateChange) 
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ status: "IDLE", current_state: activeRound.status }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error) {
    console.error("[GAME_LOOP_ERROR]", error.message);
    return new Response(JSON.stringify({ error: "Internal Server Error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
