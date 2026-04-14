import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const supabaseServiceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY

export async function POST(request: Request) {
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return NextResponse.json(
      { error: 'Server is not configured for registration.' },
      { status: 500 },
    )
  }

  let body: { id?: string; email?: string }

  try {
    body = (await request.json()) as { id?: string; email?: string }
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body.' }, { status: 400 })
  }

  const userId = body.id?.trim()
  const userEmail = body.email?.trim().toLowerCase()

  if (!userId || !userEmail) {
    return NextResponse.json({ error: 'Missing required fields: id and email.' }, { status: 400 })
  }

  const supabaseAdmin = createClient(supabaseUrl, supabaseServiceRoleKey)

  const { error } = await supabaseAdmin
    .from('users')
    .insert({
      id: userId,
      email: userEmail,
      balance: 0,
      created_at: new Date().toISOString(),
    })

  if (error) {
    if (error.code === '23505') {
      return NextResponse.json({ success: true })
    }

    return NextResponse.json(
      { error: 'Could not create user profile. Please try again.' },
      { status: 500 },
    )
  }

  return NextResponse.json({ success: true })
}
