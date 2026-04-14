'use client'

import React, { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabaseClient'
import { Navbar } from '@/components/Navbar'
import { ArrowDownToLine, ArrowUpFromLine, Copy, PlayCircle } from 'lucide-react'

type DepositStatus = 'pending' | 'confirmed' | 'failed'

type DepositIntent = {
  depositId: string
  qrCode: string
  pixCode: string
  amount: number
  status: DepositStatus
}

export default function Dashboard() {
  const router = useRouter()
  const [loading, setLoading] = useState(false)
  const [balance, setBalance] = useState<number | null>(null)
  const [sessionToken, setSessionToken] = useState<string | null>(null)
  const [depositAmount, setDepositAmount] = useState('100')
  const [depositLoading, setDepositLoading] = useState(false)
  const [depositError, setDepositError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [depositIntent, setDepositIntent] = useState<DepositIntent | null>(null)
  
  // Auth check & load data
  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session) {
        router.replace('/login')
      } else {
        setSessionToken(session.access_token)
        fetchBalance(session.user.id)
      }
    })
  }, [router])

  const fetchBalance = async (userId: string) => {
    const { data, error } = await supabase
      .from('users')
      .select('balance')
      .eq('id', userId)
      .single()
    if (!error && data) setBalance(data.balance)
  }

  const fetchDepositStatus = async (depositId: string) => {
    const { data, error } = await supabase
      .from('deposits')
      .select('status')
      .eq('id', depositId)
      .single()

    if (error || !data) return

    const status = data.status as DepositStatus
    setDepositIntent(prev => (prev ? { ...prev, status } : prev))
  }

  // Deposit creation flow
  const handleDeposit = async () => {
    const amount = Number.parseFloat(depositAmount)
    if (!Number.isFinite(amount) || amount <= 0) {
      setDepositError('Enter a valid deposit amount greater than 0.')
      return
    }

    if (!sessionToken) {
      setDepositError('Your session expired. Please sign in again.')
      return
    }

    setDepositLoading(true)
    setDepositError(null)
    setCopied(false)
    try {
      const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/createDeposit`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${sessionToken}`
        },
        body: JSON.stringify({ amount, provider: 'pix' })
      })
      
      const payload = (await res.json()) as {
        error?: string
        deposit_id?: string
        qr_code?: string
        amount?: number
      }

      if (res.ok) {
        if (!payload.deposit_id || !payload.qr_code || !payload.amount) {
          setDepositError('Deposit created, but payment details are incomplete. Try again.')
          return
        }

        setDepositIntent({
          depositId: payload.deposit_id,
          qrCode: payload.qr_code,
          pixCode: payload.qr_code,
          amount: payload.amount,
          status: 'pending',
        })
      } else {
        setDepositError(payload.error || 'Could not create deposit. Please try again.')
      }
    } catch (error) {
      console.error(error)
      setDepositError('Unexpected error while creating deposit.')
    } finally {
      setDepositLoading(false)
    }
  }

  const handleCopyPixCode = async () => {
    if (!depositIntent?.pixCode) return

    try {
      await navigator.clipboard.writeText(depositIntent.pixCode)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      setDepositError('Unable to copy PIX code. Copy it manually below.')
    }
  }

  useEffect(() => {
    if (!depositIntent?.depositId) return

    const channel = supabase
      .channel(`deposit-status-${depositIntent.depositId}`)
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'public',
          table: 'deposits',
          filter: `id=eq.${depositIntent.depositId}`,
        },
        payload => {
          const nextStatus = payload.new.status as DepositStatus
          setDepositIntent(prev => (prev ? { ...prev, status: nextStatus } : prev))
        },
      )
      .subscribe()

    const poller = setInterval(() => {
      void fetchDepositStatus(depositIntent.depositId)
    }, 5000)

    return () => {
      clearInterval(poller)
      void supabase.removeChannel(channel)
    }
  }, [depositIntent?.depositId])

  // Simplified handler for Withdrawal
  const handleWithdrawal = async () => {
    const amount = prompt("Enter amount to withdraw (Min 10):", "50")
    if (!amount || isNaN(Number(amount))) return

    setLoading(true)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      if (!session) return

      const { data, error } = await supabase.rpc('request_withdrawal', {
        p_amount: Number(amount)
      })

      if (error) {
        alert(`Withdrawal failed: ${error.message}`)
      } else {
        alert('Withdrawal requested successfully!')
        // Optimistic update
        if (balance !== null) setBalance(balance - Number(amount))
      }
    } catch (error) {
      console.error(error)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="flex flex-col min-h-screen">
      <Navbar />
      
      <main className="flex-1 p-6 md:p-12 max-w-5xl mx-auto w-full flex flex-col gap-8">
        
        {/* HERO BALANCE SECTION */}
        <div className="glass-panel rounded-2xl p-8 flex flex-col md:flex-row items-center justify-between gap-6 transform transition-all">
          <div className="flex flex-col items-center md:items-start">
            <p className="text-gray-400 text-sm tracking-wide uppercase font-semibold mb-1">Total Balance</p>
            {balance !== null ? (
              <h1 className="text-5xl md:text-6xl font-bold tracking-tighter text-white">
                <span className="text-brand-500 mr-2">$</span>
                {balance.toFixed(2)}
              </h1>
            ) : (
              <div className="h-14 w-48 bg-white/5 animate-pulse rounded-lg" />
            )}
          </div>
          
          <div className="flex w-full md:w-auto gap-4">
            <button 
              onClick={handleDeposit}
              disabled={depositLoading}
              className="flex-1 md:flex-none flex items-center justify-center gap-2 bg-brand-500 hover:bg-brand-600 text-black font-bold px-8 py-4 rounded-xl transition-transform active:scale-95 disabled:opacity-50"
            >
              <ArrowDownToLine className="w-5 h-5" />
              {depositLoading ? 'Generating...' : 'Generate PIX'}
            </button>
            <button 
              onClick={handleWithdrawal}
              disabled={loading}
              className="flex-1 md:flex-none flex items-center justify-center gap-2 bg-white/5 hover:bg-white/10 border border-white/10 text-white font-bold px-8 py-4 rounded-xl transition-all active:scale-95 disabled:opacity-50"
            >
              <ArrowUpFromLine className="w-5 h-5" />
              Withdraw
            </button>
          </div>
        </div>

        {/* PIX DEPOSIT FLOW */}
        <div className="glass-panel rounded-2xl p-6 md:p-8 border border-white/10">
          <h2 className="text-2xl font-bold text-white mb-2">Deposit via PIX</h2>
          <p className="text-gray-400 text-sm mb-6">
            Enter an amount, generate your PIX, then pay with your banking app. Your balance updates automatically after confirmation.
          </p>

          <div className="grid gap-4 md:grid-cols-[1fr_auto]">
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-gray-400 mb-2">
                Amount
              </label>
              <input
                type="number"
                min={1}
                step="0.01"
                value={depositAmount}
                onChange={event => setDepositAmount(event.target.value)}
                className="w-full bg-zinc-800 border border-white/10 rounded-xl px-4 py-3 text-white text-lg font-semibold focus:outline-none focus:ring-2 focus:ring-brand-500"
                placeholder="100.00"
              />
            </div>
            <button
              onClick={handleDeposit}
              disabled={depositLoading}
              className="md:self-end bg-brand-500 hover:bg-brand-600 text-black font-bold px-6 py-3 rounded-xl disabled:opacity-60 transition-all"
            >
              {depositLoading ? 'Generating PIX...' : 'Generate PIX'}
            </button>
          </div>

          {depositError && (
            <p className="mt-4 rounded-xl border border-red-500/30 bg-red-500/10 text-red-300 px-4 py-2 text-sm">
              {depositError}
            </p>
          )}

          {depositIntent && (
            <div className="mt-6 rounded-2xl border border-white/10 bg-zinc-900/70 p-5">
              <div className="flex flex-wrap items-center gap-2 mb-4">
                <span className="text-xs font-semibold uppercase text-gray-400">Status</span>
                <span
                  className={`text-xs font-bold uppercase px-2.5 py-1 rounded-full ${
                    depositIntent.status === 'confirmed'
                      ? 'bg-green-500/20 text-green-300'
                      : 'bg-yellow-500/20 text-yellow-300'
                  }`}
                >
                  {depositIntent.status}
                </span>
                <span className="text-sm text-gray-300 ml-auto">
                  Amount: <strong className="text-white">${depositIntent.amount.toFixed(2)}</strong>
                </span>
              </div>

              <div className="grid md:grid-cols-[220px_1fr] gap-5 items-start">
                <img
                  src={`https://api.qrserver.com/v1/create-qr-code/?size=220x220&data=${encodeURIComponent(depositIntent.qrCode)}`}
                  alt="PIX payment QR code"
                  className="w-[220px] h-[220px] rounded-xl border border-white/10 bg-white p-2"
                />

                <div>
                  <p className="text-sm text-gray-300 mb-2">Copy and paste code</p>
                  <div className="bg-zinc-950 border border-white/10 rounded-xl p-3 font-mono text-xs break-all text-gray-200">
                    {depositIntent.pixCode}
                  </div>
                  <button
                    onClick={handleCopyPixCode}
                    className="mt-3 inline-flex items-center gap-2 bg-white/5 hover:bg-white/10 text-white text-sm font-semibold px-4 py-2 rounded-lg border border-white/10"
                  >
                    <Copy className="w-4 h-4" />
                    {copied ? 'Copied!' : 'Copy PIX code'}
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* QUICK ACTIONS */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <button 
            onClick={() => router.push('/game')}
            className="group relative overflow-hidden glass-panel rounded-2xl p-8 text-left hover:border-brand-500/50 transition-colors"
          >
            <div className="absolute top-0 right-0 p-6 opacity-10 group-hover:opacity-20 transition-opacity">
              <PlayCircle className="w-32 h-32 text-brand-500" />
            </div>
            <div className="relative z-10">
              <h2 className="text-2xl font-bold text-white mb-2">Play Crash</h2>
              <p className="text-gray-400 max-w-xs">Experience the ultimate provably fair betting game with instant multipliers.</p>
              
              <div className="mt-6 flex items-center text-brand-500 font-semibold group-hover:translate-x-2 transition-transform">
                Enter Game &rarr;
              </div>
            </div>
          </button>

          <div className="glass-panel rounded-2xl p-8">
            <h2 className="text-xl font-bold text-white mb-4">Recent Activity</h2>
            <div className="flex flex-col items-center justify-center h-32 text-gray-500 border border-dashed border-white/10 rounded-xl">
              No recent activity found.
            </div>
          </div>
        </div>
      </main>
    </div>
  )
}
