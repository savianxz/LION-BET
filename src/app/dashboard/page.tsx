'use client'

import React, { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabaseClient'
import { Navbar } from '@/components/Navbar'
import { ArrowDownToLine, ArrowUpFromLine, PlayCircle } from 'lucide-react'

export default function Dashboard() {
  const router = useRouter()
  const [loading, setLoading] = useState(false)
  const [balance, setBalance] = useState<number | null>(null)
  
  // Auth check & load data
  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session) {
        router.replace('/login')
      } else {
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

  // Simplified handler for Deposit (Phase 6 Integration)
  const handleDeposit = async () => {
    setLoading(true)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      if (!session) return

      // Example amount. In a real scenario, this would come from an input modal.
      const amount = 100

      const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/createDeposit`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${session.access_token}`
        },
        body: JSON.stringify({ amount, provider: 'manual' })
      })
      
      const payload = await res.json()
      if (res.ok) {
        alert(`Deposit Intent Created. Payment URL: ${payload.payment_url}`)
      } else {
        alert(`Error: ${payload.error}`)
      }
    } catch (error) {
      console.error(error)
    } finally {
      setLoading(false)
    }
  }

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
              disabled={loading}
              className="flex-1 md:flex-none flex items-center justify-center gap-2 bg-brand-500 hover:bg-brand-600 text-black font-bold px-8 py-4 rounded-xl transition-transform active:scale-95 disabled:opacity-50"
            >
              <ArrowDownToLine className="w-5 h-5" />
              Deposit
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
