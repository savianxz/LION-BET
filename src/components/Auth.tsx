'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'

export default function Auth() {
  const router = useRouter()
  const [mode, setMode] = useState<'login' | 'register'>('login')
  const [loading, setLoading] = useState(false)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [message, setMessage] = useState<{ type: 'error' | 'success'; text: string } | null>(null)

  const handleRegister = async () => {
    const { error } = await supabase.auth.signUp({ email, password })

    if (error) {
      setMessage({ type: 'error', text: error.message })
    } else {
      setMessage({ type: 'success', text: 'Usuário criado. Confira seu e-mail ou faça login.' })
      setMode('login')
    }
  }

  const handleLogin = async () => {
    const { error } = await supabase.auth.signInWithPassword({ email, password })

    if (error) {
      setMessage({ type: 'error', text: error.message })
    } else {
      router.push('/dashboard')
    }
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    setMessage(null)

    if (mode === 'login') await handleLogin()
    else await handleRegister()

    setLoading(false)
  }

  return (
    <div className="flex justify-center items-center min-h-screen bg-[#09090b] px-4">
      <div className="w-full max-w-sm">

        {/* Logo */}
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-yellow-500 rounded-2xl text-3xl font-black text-black mb-4 shadow-[0_0_40px_rgba(234,179,8,0.4)]">
            L
          </div>
          <h1 className="text-4xl font-black text-white tracking-tight">
            LION<span className="text-yellow-500">.BET</span>
          </h1>
          <p className="text-zinc-500 mt-2 text-sm">Provably fair crash gaming</p>
        </div>

        {/* Card */}
        <div className="bg-zinc-900 border border-white/5 rounded-3xl p-8 shadow-2xl">

          {/* Tabs */}
          <div className="flex mb-6 bg-zinc-800 rounded-xl p-1">
            {(['login', 'register'] as const).map(tab => (
              <button
                key={tab}
                onClick={() => { setMode(tab); setMessage(null) }}
                className={`flex-1 py-2 rounded-lg text-sm font-semibold transition-all ${
                  mode === tab
                    ? 'bg-zinc-700 text-white shadow-md'
                    : 'text-zinc-400 hover:text-white'
                }`}
              >
                {tab === 'login' ? 'Sign In' : 'Register'}
              </button>
            ))}
          </div>

          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className="block text-xs font-medium text-zinc-400 mb-1.5 uppercase tracking-wider">
                Email
              </label>
              <input
                type="email"
                value={email}
                onChange={e => setEmail(e.target.value)}
                required
                placeholder="name@email.com"
                className="w-full bg-zinc-800 border border-white/10 rounded-xl px-4 py-3 text-white placeholder-zinc-600 focus:outline-none focus:ring-2 focus:ring-yellow-500/50 focus:border-yellow-500/50 transition-shadow text-sm"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-zinc-400 mb-1.5 uppercase tracking-wider">
                Password
              </label>
              <input
                type="password"
                value={password}
                onChange={e => setPassword(e.target.value)}
                required
                placeholder="••••••••"
                minLength={6}
                className="w-full bg-zinc-800 border border-white/10 rounded-xl px-4 py-3 text-white placeholder-zinc-600 focus:outline-none focus:ring-2 focus:ring-yellow-500/50 focus:border-yellow-500/50 transition-shadow text-sm"
              />
            </div>

            {message && (
              <div className={`p-3 rounded-xl text-sm border ${
                message.type === 'error'
                  ? 'bg-red-500/10 border-red-500/20 text-red-400'
                  : 'bg-green-500/10 border-green-500/20 text-green-400'
              }`}>
                {message.text}
              </div>
            )}

            <button
              type="submit"
              disabled={loading}
              className="w-full bg-yellow-500 hover:bg-yellow-400 text-black font-black py-3.5 rounded-xl transition-all active:scale-[0.98] disabled:opacity-60 mt-2 text-sm"
            >
              {loading ? 'Processing...' : mode === 'login' ? 'Sign In' : 'Create Account'}
            </button>
          </form>
        </div>

        <p className="text-center text-zinc-600 text-xs mt-6">
          By continuing, you agree to our Terms of Service.
        </p>
      </div>
    </div>
  )
}
