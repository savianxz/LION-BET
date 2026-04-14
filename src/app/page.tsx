'use client'

import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import Auth from '@/components/Auth'
import CrashGame from '@/components/CrashGame'
import { Wallet, ArrowDownToLine, ArrowUpFromLine, LogOut, X, Zap } from 'lucide-react'

type Modal = 'deposit' | 'withdraw' | null

export default function Home() {
  const [session, setSession] = useState<any>(null)
  const [balance, setBalance] = useState<number>(0)
  const [activeModal, setActiveModal] = useState<Modal>(null)
  const [modalAmount, setModalAmount] = useState('')
  const [modalLoading, setModalLoading] = useState(false)
  const [modalError, setModalError] = useState<string | null>(null)

  // Auth listener
  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session)
      if (session) fetchBalance(session.user.id)
    })

    const { data: authListener } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session)
      if (session) fetchBalance(session.user.id)
      else setBalance(0)
    })

    return () => { authListener.subscription.unsubscribe() }
  }, [])

  // Realtime balance listener
  useEffect(() => {
    if (!session?.user?.id) return

    const channel = supabase
      .channel('balance-realtime')
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'users', filter: `id=eq.${session.user.id}` },
        (payload: any) => setBalance(payload.new.balance)
      )
      .subscribe()

    return () => { supabase.removeChannel(channel) }
  }, [session])

  const fetchBalance = async (userId: string) => {
    const { data } = await supabase.from('users').select('balance').eq('id', userId).single()
    if (data) setBalance(data.balance)
  }

  const openModal = (type: Modal) => {
    setActiveModal(type)
    setModalAmount('')
    setModalError(null)
  }

  const handleDeposit = async () => {
    const amount = parseFloat(modalAmount)
    if (isNaN(amount) || amount <= 0) { setModalError('Enter a valid amount'); return }

    setModalLoading(true)
    setModalError(null)
    try {
      const res = await fetch(
        `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/createDeposit`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${session.access_token}`
          },
          body: JSON.stringify({ amount, provider: 'manual' })
        }
      )
      const data = await res.json()
      if (!res.ok) throw new Error(data.error || 'Deposit failed')
      alert(`Deposit initiated!\nPayment URL: ${data.payment_url}`)
      setActiveModal(null)
    } catch (e: any) {
      setModalError(e.message)
    } finally {
      setModalLoading(false)
    }
  }

  const handleWithdraw = async () => {
    const amount = parseFloat(modalAmount)
    if (isNaN(amount) || amount < 10) { setModalError('Minimum withdrawal is $10'); return }

    setModalLoading(true)
    setModalError(null)
    try {
      const { error } = await supabase.rpc('request_withdrawal', { p_amount: amount })
      if (error) throw new Error(error.message)
      setBalance(prev => prev - amount)
      setActiveModal(null)
      alert('Withdrawal requested successfully!')
    } catch (e: any) {
      setModalError(e.message)
    } finally {
      setModalLoading(false)
    }
  }

  if (!session) return <Auth />

  return (
    <div className="min-h-screen bg-[#09090b] text-white font-sans">

      {/* NAVBAR */}
      <header className="sticky top-0 z-50 border-b border-white/5 bg-zinc-950/80 backdrop-blur-md">
        <div className="max-w-6xl mx-auto px-4 h-16 flex items-center justify-between">
          {/* Logo */}
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 bg-yellow-500 rounded-xl flex items-center justify-center font-black text-black text-sm shadow-[0_0_16px_rgba(234,179,8,0.4)]">
              L
            </div>
            <span className="text-lg font-black tracking-tight hidden sm:block">
              LION<span className="text-yellow-500">.BET</span>
            </span>
          </div>

          {/* Right: Balance + Actions + Signout */}
          <div className="flex items-center gap-3">
            {/* Balance chip */}
            <div className="flex items-center gap-2 bg-zinc-900 border border-white/10 rounded-full px-4 py-2">
              <Wallet className="w-3.5 h-3.5 text-yellow-500" />
              <span className="font-mono font-bold text-sm text-white tabular-nums">
                ${balance.toFixed(2)}
              </span>
            </div>

            {/* Deposit */}
            <button
              onClick={() => openModal('deposit')}
              className="flex items-center gap-1.5 bg-yellow-500 hover:bg-yellow-400 text-black font-bold px-4 py-2 rounded-full text-sm transition-all active:scale-95 shadow-[0_0_16px_rgba(234,179,8,0.25)]"
            >
              <ArrowDownToLine className="w-3.5 h-3.5" />
              <span className="hidden sm:inline">Deposit</span>
            </button>

            {/* Withdraw */}
            <button
              onClick={() => openModal('withdraw')}
              className="flex items-center gap-1.5 bg-white/5 hover:bg-white/10 border border-white/10 text-white font-bold px-4 py-2 rounded-full text-sm transition-all active:scale-95"
            >
              <ArrowUpFromLine className="w-3.5 h-3.5" />
              <span className="hidden sm:inline">Withdraw</span>
            </button>

            {/* Logout */}
            <button
              onClick={() => supabase.auth.signOut()}
              className="p-2 text-zinc-600 hover:text-red-400 transition-colors rounded-xl hover:bg-white/5"
              title="Sign out"
            >
              <LogOut className="w-4 h-4" />
            </button>
          </div>
        </div>
      </header>

      {/* MAIN */}
      <main className="max-w-6xl mx-auto px-4 py-6">
        {/* Page title */}
        <div className="flex items-center gap-3 mb-6">
          <div className="flex items-center gap-2">
            <Zap className="w-5 h-5 text-yellow-500" />
            <h1 className="text-xl font-black text-white tracking-tight">Crash</h1>
          </div>
          <div className="text-xs text-zinc-500 bg-zinc-900 border border-white/5 px-2.5 py-1 rounded-full font-medium">
            Provably Fair
          </div>
        </div>

        <CrashGame session={session} />
      </main>

      {/* MODAL */}
      {activeModal && (
        <div
          className="fixed inset-0 z-[100] flex items-end sm:items-center justify-center bg-black/70 backdrop-blur-sm p-4"
          onClick={e => { if (e.target === e.currentTarget) setActiveModal(null) }}
        >
          <div className="w-full max-w-sm bg-zinc-900 border border-white/10 rounded-3xl p-6 shadow-2xl">
            <div className="flex justify-between items-center mb-5">
              <h2 className="text-lg font-black text-white">
                {activeModal === 'deposit' ? 'Deposit Funds' : 'Withdraw Funds'}
              </h2>
              <button onClick={() => setActiveModal(null)} className="text-zinc-400 hover:text-white transition-colors">
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="space-y-4">
              <div>
                <label className="text-xs text-zinc-500 font-medium block mb-1.5 uppercase">
                  Amount (USD)
                </label>
                <div className="relative">
                  <span className="absolute left-4 top-1/2 -translate-y-1/2 text-zinc-400 font-bold">$</span>
                  <input
                    type="number"
                    value={modalAmount}
                    onChange={e => setModalAmount(e.target.value)}
                    placeholder="0.00"
                    min={activeModal === 'withdraw' ? 10 : 1}
                    className="w-full bg-zinc-800 border border-white/10 rounded-xl pl-8 pr-4 py-3 text-white font-bold text-lg focus:outline-none focus:ring-2 focus:ring-yellow-500/50 focus:border-yellow-500/50"
                    autoFocus
                  />
                </div>
                {activeModal === 'withdraw' && (
                  <p className="text-xs text-zinc-600 mt-1.5">
                    Available: ${balance.toFixed(2)} · Min $10
                  </p>
                )}
              </div>

              {/* Quick amounts */}
              <div className="flex gap-2">
                {(activeModal === 'deposit' ? [50, 100, 250, 500] : [10, 20, 50, 100]).map(v => (
                  <button
                    key={v}
                    onClick={() => setModalAmount(String(v))}
                    className="flex-1 py-2 bg-zinc-800 hover:bg-zinc-700 border border-white/5 rounded-xl text-xs font-bold text-zinc-300 transition-colors"
                  >
                    ${v}
                  </button>
                ))}
              </div>

              {modalError && (
                <div className="text-red-400 text-sm bg-red-500/10 border border-red-500/20 rounded-xl px-4 py-2.5">
                  {modalError}
                </div>
              )}

              <button
                onClick={activeModal === 'deposit' ? handleDeposit : handleWithdraw}
                disabled={modalLoading}
                className={`w-full py-3.5 rounded-xl font-black text-sm transition-all active:scale-[0.98] disabled:opacity-60 ${
                  activeModal === 'deposit'
                    ? 'bg-yellow-500 hover:bg-yellow-400 text-black shadow-[0_0_20px_rgba(234,179,8,0.25)]'
                    : 'bg-white text-black hover:bg-zinc-100'
                }`}
              >
                {modalLoading ? 'Processing...' : activeModal === 'deposit' ? 'Deposit' : 'Withdraw'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
