'use client'

import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'

export default function Dashboard() {
  const [saldo, setSaldo] = useState(0)

  useEffect(() => {
    const getSaldo = async () => {
      const {
        data: { user },
      } = await supabase.auth.getUser()

      if (!user) return

      const { data } = await supabase.from('profiles').select('saldo').eq('id', user.id).single()
      if (data?.saldo !== undefined) setSaldo(data.saldo)
    }

    getSaldo()
  }, [])

  return <h1>Saldo: R$ {saldo}</h1>
}
