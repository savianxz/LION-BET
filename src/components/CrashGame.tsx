'use client'

import { useEffect, useState, useRef, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import { TrendingUp, Zap, History, AlertTriangle } from 'lucide-react'

interface BetHistoryEntry {
  roundId: string
  amount: number
  result: number | null
  status: 'won' | 'lost' | 'pending'
  multiplierAtCashout?: number
  payout?: number
}

interface RoundData {
  id: string
  game_id: string
  status: 'created' | 'started' | 'finished' | 'cancelled'
  result?: number
  server_seed_hash?: string
}

export default function CrashGame({ session }: { session: any }) {
  const [round, setRound] = useState<RoundData | null>(null)
  const [multiplier, setMultiplier] = useState(1.00)
  const [isCrashed, setIsCrashed] = useState(false)

  const [betAmount, setBetAmount] = useState<string>('10')
  const [autoCashout, setAutoCashout] = useState<string>('2.00')
  const [isPlacingBet, setIsPlacingBet] = useState(false)
  const [hasBetThisRound, setHasBetThisRound] = useState(false)
  const [betError, setBetError] = useState<string | null>(null)

  const [history, setHistory] = useState<BetHistoryEntry[]>([])
  const [lastCrashes, setLastCrashes] = useState<number[]>([])

  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const startTimeRef = useRef<number>(0)

  const stopTimer = useCallback(() => {
    if (timerRef.current) {
      clearInterval(timerRef.current)
      timerRef.current = null
    }
  }, [])

  const handleRoundChange = useCallback((roundData: RoundData) => {
    setRound(roundData)

    if (roundData.status === 'created') {
      stopTimer()
      setMultiplier(1.00)
      setIsCrashed(false)
      setHasBetThisRound(false)
      setBetError(null)
    } else if (roundData.status === 'started') {
      stopTimer()
      setIsCrashed(false)
      startTimeRef.current = Date.now()
      timerRef.current = setInterval(() => {
        // Exponential growth formula matching typical crash game feel
        const elapsed = (Date.now() - startTimeRef.current) / 1000
        const current = Math.pow(Math.E, 0.08 * elapsed)
        setMultiplier(Math.max(1.00, parseFloat(current.toFixed(2))))
      }, 50)
    } else if (roundData.status === 'finished') {
      stopTimer()
      const crashAt = roundData.result ?? 1.00
      setMultiplier(crashAt)
      setIsCrashed(true)
      setLastCrashes(prev => [crashAt, ...prev.slice(0, 9)])
    }
  }, [stopTimer])

  const fetchGameState = useCallback(async () => {
    try {
      const res = await fetch(
        `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/getGameState`,
        { headers: { Authorization: `Bearer ${session.access_token}` } }
      )
      const data = await res.json()
      if (data.round) handleRoundChange(data.round as RoundData)
    } catch (e) {
      console.error('[getGameState] Error:', e)
    }
  }, [session.access_token, handleRoundChange])

  useEffect(() => {
    fetchGameState()

    const channel = supabase
      .channel('crash-rounds')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'game_rounds' },
        (payload: any) => handleRoundChange(payload.new as RoundData)
      )
      .subscribe()

    return () => {
      stopTimer()
      supabase.removeChannel(channel)
    }
  }, [fetchGameState, handleRoundChange, stopTimer])

  const placeBet = async () => {
    if (!round || round.status !== 'created' || hasBetThisRound) return
    const amount = parseFloat(betAmount)
    const cashout = parseFloat(autoCashout)
    if (isNaN(amount) || amount <= 0) { setBetError('Enter a valid amount'); return }
    if (isNaN(cashout) || cashout < 1.01) { setBetError('Cashout must be ≥ 1.01x'); return }

    setIsPlacingBet(true)
    setBetError(null)

    try {
      const res = await fetch(
        `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/placeBet`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${session.access_token}`
          },
          body: JSON.stringify({
            game_id: round.game_id,
            round_id: round.id,
            amount
          })
        }
      )
      const data = await res.json()
      if (!res.ok || data.error) throw new Error(data.error || 'Bet failed')

      setHasBetThisRound(true)
      setHistory(prev => [{
        roundId: round.id,
        amount,
        result: null,
        status: 'pending',
      }, ...prev.slice(0, 19)])
    } catch (e: any) {
      setBetError(e.message)
    } finally {
      setIsPlacingBet(false)
    }
  }

  // Multiplier color based on value
  const multiplierColor = isCrashed
    ? 'text-red-500'
    : multiplier < 1.5
    ? 'text-white'
    : multiplier < 2.5
    ? 'text-yellow-400'
    : multiplier < 5
    ? 'text-orange-400'
    : 'text-green-400'

  const glowColor = isCrashed
    ? 'shadow-[0_0_80px_rgba(239,68,68,0.25)]'
    : multiplier >= 5
    ? 'shadow-[0_0_80px_rgba(74,222,128,0.2)]'
    : multiplier >= 2
    ? 'shadow-[0_0_60px_rgba(250,204,21,0.15)]'
    : ''

  const crashBadgeColor = (val: number) =>
    val < 1.5 ? 'bg-red-500/20 text-red-400 border-red-500/30'
    : val < 2 ? 'bg-zinc-700 text-zinc-300 border-zinc-600'
    : val < 5 ? 'bg-yellow-500/20 text-yellow-400 border-yellow-500/30'
    : 'bg-green-500/20 text-green-400 border-green-500/30'

  const canBet = round?.status === 'created' && !hasBetThisRound
  const isRunning = round?.status === 'started'

  return (
    <div className="flex flex-col gap-4">

      {/* Last Crashes Strip */}
      <div className="flex items-center gap-2 overflow-x-auto pb-1">
        <History className="w-3.5 h-3.5 text-zinc-500 shrink-0" />
        <span className="text-xs text-zinc-500 shrink-0 mr-1">Previous:</span>
        {lastCrashes.length === 0 ? (
          <span className="text-xs text-zinc-600 italic">No crashes yet this session</span>
        ) : (
          lastCrashes.map((val, i) => (
            <span key={i} className={`shrink-0 text-xs font-bold px-2 py-0.5 rounded-full border ${crashBadgeColor(val)}`}>
              {val.toFixed(2)}x
            </span>
          ))
        )}
      </div>

      <div className="flex flex-col lg:flex-row gap-4">

        {/* === GAME AREA === */}
        <div className={`flex-1 relative bg-zinc-900 border border-white/5 rounded-2xl overflow-hidden min-h-[360px] flex flex-col items-center justify-center ${glowColor} transition-shadow duration-1000`}>

          {/* Status Badge */}
          {round && (
            <div className="absolute top-4 right-4">
              <div className={`text-xs px-3 py-1 rounded-full font-bold tracking-widest border ${
                round.status === 'created' ? 'bg-green-500/10 text-green-400 border-green-500/20 animate-pulse'
                : round.status === 'started' ? 'bg-blue-500/10 text-blue-400 border-blue-500/20'
                : 'bg-red-500/10 text-red-400 border-red-500/20'
              }`}>
                {round.status === 'created' ? 'BETTING OPEN'
                  : round.status === 'started' ? 'LIVE'
                  : 'CRASHED'}
              </div>
            </div>
          )}

          {/* Hash display */}
          {round?.server_seed_hash && (
            <div className="absolute top-4 left-4 text-xs font-mono text-zinc-600 max-w-[150px] truncate">
              {round.server_seed_hash.slice(0, 12)}…
            </div>
          )}

          {/* SVG Graph */}
          <div className="absolute inset-0 pointer-events-none">
            <svg viewBox="0 0 400 200" className="w-full h-full" preserveAspectRatio="none">
              <defs>
                <linearGradient id="crash-gradient" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={isCrashed ? "#ef4444" : multiplier >= 5 ? "#4ade80" : "#eab308"} stopOpacity="0.3" />
                  <stop offset="100%" stopColor="transparent" stopOpacity="0" />
                </linearGradient>
              </defs>
              {!isCrashed && (
                <path
                  d={`M0 200 Q ${Math.min(multiplier * 40, 380)} ${Math.max(200 - multiplier * 20, 10)}, 400 ${Math.max(200 - multiplier * 25, 5)} L 400 200 Z`}
                  fill="url(#crash-gradient)"
                  className="transition-all duration-100"
                />
              )}
            </svg>
          </div>

          {/* Multiplier */}
          <div className="relative z-10 text-center select-none">
            <div className={`text-7xl md:text-8xl font-black tracking-tighter tabular-nums transition-colors duration-300 ${multiplierColor}`}>
              {multiplier.toFixed(2)}<span className="text-4xl md:text-5xl">×</span>
            </div>
            {isCrashed && (
              <div className="mt-4 flex items-center justify-center gap-2 text-red-400 font-bold uppercase tracking-widest text-sm">
                <AlertTriangle className="w-4 h-4" />
                Crashed at {multiplier.toFixed(2)}×
              </div>
            )}
            {round?.status === 'created' && !isCrashed && (
              <p className="text-zinc-400 mt-3 text-sm animate-pulse">
                Waiting for next round…
              </p>
            )}
            {isRunning && hasBetThisRound && (
              <div className="mt-4 flex items-center gap-2 justify-center text-yellow-400 text-sm font-semibold">
                <Zap className="w-4 h-4 animate-bounce" />
                Your bet is live!
              </div>
            )}
          </div>
        </div>

        {/* === CONTROLS === */}
        <div className="w-full lg:w-72 shrink-0 flex flex-col gap-4">
          <div className="bg-zinc-900 border border-white/5 rounded-2xl p-5">
            <div className="flex items-center gap-2 mb-5">
              <TrendingUp className="w-4 h-4 text-yellow-500" />
              <h2 className="text-sm font-bold text-white uppercase tracking-wider">Place Bet</h2>
            </div>

            <div className="space-y-3">
              {/* Amount */}
              <div>
                <label className="text-xs text-zinc-500 font-medium mb-1 block">Bet Amount</label>
                <div className="flex gap-1">
                  <div className="relative flex-1">
                    <span className="absolute left-3 top-1/2 -translate-y-1/2 text-zinc-400 font-bold text-sm">$</span>
                    <input
                      type="number"
                      value={betAmount}
                      onChange={e => setBetAmount(e.target.value)}
                      min="1"
                      step="1"
                      disabled={!canBet}
                      className="w-full bg-zinc-800 border border-white/10 rounded-xl pl-7 pr-3 py-2.5 text-white font-bold text-sm focus:outline-none focus:ring-1 focus:ring-yellow-500/50 disabled:opacity-50"
                    />
                  </div>
                  <button
                    onClick={() => setBetAmount(v => String(parseFloat(v || '0') * 2))}
                    disabled={!canBet}
                    className="px-3 bg-zinc-800 border border-white/10 rounded-xl text-zinc-400 hover:text-white text-xs font-bold disabled:opacity-40 transition-colors"
                  >
                    2×
                  </button>
                  <button
                    onClick={() => setBetAmount(v => String(Math.max(1, parseFloat(v || '0') / 2)))}
                    disabled={!canBet}
                    className="px-3 bg-zinc-800 border border-white/10 rounded-xl text-zinc-400 hover:text-white text-xs font-bold disabled:opacity-40 transition-colors"
                  >
                    ½
                  </button>
                </div>
                {/* Quick amounts */}
                <div className="flex gap-1 mt-1.5">
                  {[10, 25, 50, 100].map(v => (
                    <button
                      key={v}
                      onClick={() => setBetAmount(String(v))}
                      disabled={!canBet}
                      className="flex-1 text-xs py-1 bg-zinc-800 hover:bg-zinc-700 rounded-lg text-zinc-400 hover:text-white border border-white/5 disabled:opacity-40 transition-colors font-medium"
                    >
                      ${v}
                    </button>
                  ))}
                </div>
              </div>

              {/* Auto Cashout */}
              <div>
                <label className="text-xs text-zinc-500 font-medium mb-1 block">Auto Cashout</label>
                <div className="relative">
                  <input
                    type="number"
                    value={autoCashout}
                    onChange={e => setAutoCashout(e.target.value)}
                    min="1.01"
                    step="0.01"
                    disabled={!canBet}
                    className="w-full bg-zinc-800 border border-white/10 rounded-xl px-3 pr-8 py-2.5 text-white font-bold text-sm focus:outline-none focus:ring-1 focus:ring-yellow-500/50 disabled:opacity-50"
                  />
                  <span className="absolute right-3 top-1/2 -translate-y-1/2 text-zinc-500 font-black text-sm">×</span>
                </div>
              </div>

              {betError && (
                <div className="text-red-400 text-xs bg-red-500/10 border border-red-500/20 px-3 py-2 rounded-xl">
                  {betError}
                </div>
              )}

              <button
                onClick={placeBet}
                disabled={!canBet || isPlacingBet}
                className={`w-full py-3.5 rounded-xl font-black text-sm transition-all active:scale-[0.98] ${
                  hasBetThisRound
                    ? 'bg-green-500/20 border border-green-500/30 text-green-400 cursor-default'
                    : canBet
                    ? 'bg-yellow-500 hover:bg-yellow-400 text-black shadow-[0_0_20px_rgba(234,179,8,0.3)]'
                    : 'bg-zinc-800 text-zinc-500 cursor-not-allowed border border-white/5'
                }`}
              >
                {hasBetThisRound
                  ? '✓ Bet Placed'
                  : isPlacingBet
                  ? 'Placing...'
                  : canBet
                  ? 'Place Bet'
                  : round?.status === 'started'
                  ? 'Round in Progress'
                  : 'Next Round Soon…'}
              </button>
            </div>
          </div>

          {/* Potential Payout */}
          {hasBetThisRound && isRunning && (
            <div className="bg-zinc-900 border border-yellow-500/20 rounded-2xl p-4">
              <p className="text-xs text-zinc-500 mb-1 uppercase tracking-wider font-medium">Current Potential Payout</p>
              <p className="text-2xl font-black text-yellow-400">
                ${(parseFloat(betAmount || '0') * multiplier).toFixed(2)}
              </p>
            </div>
          )}
        </div>
      </div>

      {/* === BET HISTORY === */}
      {history.length > 0 && (
        <div className="bg-zinc-900 border border-white/5 rounded-2xl p-5">
          <h3 className="text-sm font-bold text-zinc-400 uppercase tracking-wider mb-4 flex items-center gap-2">
            <History className="w-3.5 h-3.5" />
            Bet History
          </h3>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-xs text-zinc-600 uppercase tracking-wider">
                  <th className="text-left pb-3 font-medium">Round</th>
                  <th className="text-right pb-3 font-medium">Amount</th>
                  <th className="text-right pb-3 font-medium">Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-white/5">
                {history.map((h, i) => (
                  <tr key={i}>
                    <td className="py-2.5 font-mono text-xs text-zinc-500">{h.roundId.slice(0, 8)}…</td>
                    <td className="py-2.5 text-right font-bold text-white">${h.amount.toFixed(2)}</td>
                    <td className="py-2.5 text-right">
                      <span className={`inline-block text-xs px-2 py-0.5 rounded-full font-semibold border ${
                        h.status === 'won' ? 'bg-green-500/15 text-green-400 border-green-500/30'
                        : h.status === 'lost' ? 'bg-red-500/15 text-red-400 border-red-500/30'
                        : 'bg-zinc-700 text-zinc-300 border-zinc-600'
                      }`}>
                        {h.status === 'pending' ? 'Live' : h.status === 'won' ? `+$${h.payout?.toFixed(2)}` : 'Lost'}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  )
}
