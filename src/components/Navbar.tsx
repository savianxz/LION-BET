'use client'

import React, { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabaseClient'
import { User, LogOut, Wallet } from 'lucide-react'
import { useRouter } from 'next/navigation'

export function Navbar() {
  const [balance, setBalance] = useState<number | null>(null)
  const [email, setEmail] = useState<string | null>(null)
  const router = useRouter()

  const fetchUser = async () => {
    const { data: { user } } = await supabase.auth.getUser()
    if (user) {
      setEmail(user.email ?? null)
      // Fetch balance from DB
      const { data, error } = await supabase
        .from('users')
        .select('balance')
        .eq('id', user.id)
        .single()
      
      if (!error && data) {
        setBalance(data.balance)
      }

      // Optional: Set up realtime listener for balance changes
      const channel = supabase.channel('schema-db-changes')
        .on(
          'postgres_changes',
          {
            event: 'UPDATE',
            schema: 'public',
            table: 'users',
            filter: `id=eq.${user.id}`,
          },
          (payload) => {
            setBalance(payload.new.balance)
          }
        )
        .subscribe()

      return () => {
        supabase.removeChannel(channel)
      }
    }
  }

  useEffect(() => {
    const cleanup = fetchUser()
    return () => {
      cleanup.then(fn => fn && fn())
    }
  }, [])

  const handleLogout = async () => {
    await supabase.auth.signOut()
    router.push('/login')
  }

  return (
    <nav className="glass-panel sticky top-0 z-50 w-full px-4 border-b border-white/5 h-16 flex items-center justify-between">
      <div className="flex items-center gap-2 cursor-pointer" onClick={() => router.push('/dashboard')}>
        <div className="w-8 h-8 bg-brand-500 rounded-lg flex items-center justify-center font-bold text-black border border-brand-400">
          L
        </div>
        <span className="text-xl font-bold tracking-tight text-white hidden sm:block">
          LION<span className="text-brand-500">.BET</span>
        </span>
      </div>

      <div className="flex items-center gap-4">
        {balance !== null ? (
          <div className="flex items-center bg-bg-input border border-white/10 rounded-full px-4 py-1.5 shadow-inner">
            <Wallet className="w-4 h-4 text-brand-500 mr-2" />
            <span className="font-mono font-medium text-white">
              ${Number(balance).toFixed(2)}
            </span>
          </div>
        ) : (
          <div className="w-24 h-8 bg-white/5 animate-pulse rounded-full" />
        )}

        <div className="flex items-center gap-3 border-l border-white/10 pl-4">
          <div className="flex items-center gap-2 text-sm text-gray-400">
            <User className="w-4 h-4" />
            <span className="hidden sm:inline">{email?.split('@')[0]}</span>
          </div>
          <button 
            onClick={handleLogout}
            className="p-1.5 text-gray-500 hover:text-red-400 transition-colors rounded-lg hover:bg-white/5"
            title="Log out"
          >
            <LogOut className="w-4 h-4" />
          </button>
        </div>
      </div>
    </nav>
  )
}
