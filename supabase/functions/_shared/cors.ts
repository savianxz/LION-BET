// VULN-005 FIX: Lock down CORS to specific origin.
// Replace 'https://lion.bet' with your actual production domain.
// For local development, add your dev URL conditionally.
const ALLOWED_ORIGIN = Deno.env.get('ALLOWED_ORIGIN') || 'https://lion.bet';

export const corsHeaders = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-admin-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
