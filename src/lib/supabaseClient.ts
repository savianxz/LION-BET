import { createClient } from '@supabase/supabase-js'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || ''
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || 'sb_publishable_g0Tb5RGlS6y8mHthMHEhYg_C40dLWK0'

export const supabase = createClient(supabaseUrl, supabaseAnonKey)
