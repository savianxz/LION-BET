-- =====================================================================
-- 📊 ADMIN MONITORING & ANALYTICS VIEWS
-- =====================================================================
-- Provides real-time visibility into platform health, financial exposure,
-- and security events. These views are intended for internal use only.
-- =====================================================================

-- ─────────────────────────────────────────────────────────────────────
-- 1. admin_platform_metrics — High-level Health
-- ─────────────────────────────────────────────────────────────────────
-- Shows total volume, GGR (Gross Gaming Revenue), and liabilities.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.admin_platform_metrics AS
SELECT
  (SELECT COUNT(*) FROM public.users) as total_users,
  (SELECT SUM(amount) FROM public.bets) as total_wagered,
  (SELECT SUM(amount) FROM public.transactions WHERE type = 'payout') as total_payouts,
  (SELECT SUM(amount) FROM public.bets) - COALESCE((SELECT ABS(SUM(amount)) FROM public.transactions WHERE type = 'payout'), 0) as net_ggr,
  (SELECT SUM(amount) FROM public.withdrawals WHERE status = 'pending') as pending_withdrawal_liability,
  (SELECT COUNT(*) FROM public.game_rounds WHERE status = 'finished') as total_rounds_completed;

-- Security: No direct access to users, admin only via service_role/RPC logic
ALTER VIEW public.admin_platform_metrics OWNER TO postgres;


-- ─────────────────────────────────────────────────────────────────────
-- 2. admin_active_exposure — Round Risk Tracking
-- ─────────────────────────────────────────────────────────────────────
-- Real-time liability for the current active round.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.admin_active_exposure AS
SELECT
  gr.id as round_id,
  gr.status,
  gr.total_bet_amount as total_wagered,
  gr.max_exposure,
  (SELECT COUNT(*) FROM public.bets WHERE round_id = gr.id) as total_bets,
  (SELECT SUM(amount) FROM public.bets WHERE round_id = gr.id AND status = 'pending') as current_liability
FROM public.game_rounds gr
WHERE gr.status IN ('created', 'in_progress');


-- ─────────────────────────────────────────────────────────────────────
-- 3. admin_abuse_dashboard — Security Monitoring
-- ─────────────────────────────────────────────────────────────────────
-- Highlights users with high suspicious flags or active suspensions.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.admin_abuse_dashboard AS
SELECT
  u.id as user_id,
  u.email,
  u.is_suspicious,
  u.suspicious_flags,
  u.suspended_until,
  (SELECT COUNT(*) FROM public.abuse_events WHERE user_id = u.id) as total_abuse_events,
  u.last_bet_at,
  u.created_at as joined_at
FROM public.users u
WHERE u.is_suspicious = true
   OR u.suspicious_flags > 0
   OR u.suspended_until > NOW()
ORDER BY u.suspicious_flags DESC, u.suspended_until DESC NULLS LAST;


-- ─────────────────────────────────────────────────────────────────────
-- 4. RLS & ACCESS CONTROL
-- ─────────────────────────────────────────────────────────────────────
-- These views should be accessed only by administrative accounts.
-- In Supabase, we can use standard RLS but views don't support RLS directly
-- until Postgres 15. For now, we rely on the fact that these are in the
-- public schema but we will not grant SELECT to 'anon' or 'authenticated' roles.

REVOKE SELECT ON public.admin_platform_metrics FROM anon, authenticated;
REVOKE SELECT ON public.admin_active_exposure FROM anon, authenticated;
REVOKE SELECT ON public.admin_abuse_dashboard FROM anon, authenticated;

-- Grants for service_role (Admin Edge Functions)
GRANT SELECT ON public.admin_platform_metrics TO service_role;
GRANT SELECT ON public.admin_active_exposure TO service_role;
GRANT SELECT ON public.admin_abuse_dashboard TO service_role;
