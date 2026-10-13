import React, { useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { fetchLeadershipChart } from '@/lib/publicData';
import LeadershipChart from '@/components/leadership/LeadershipChart';

// Public section: reads leadership_chart_current (anon-readable view).
export default function LeadershipSection() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let active = true;
    fetchLeadershipChart().then(({ data, error }) => {
      if (!active) return;
      setRows(data);
      setFailed(!!error);
      setLoading(false);
    });
    return () => { active = false; };
  }, []);

  return (
    <section id="leadership" className="py-10">
      <h2 className="text-2xl font-heading mb-4">Leadership</h2>
      {loading ? (
        <div className="flex justify-center py-8"><Loader2 className="w-6 h-6 animate-spin text-muted-foreground" /></div>
      ) : failed ? (
        <p className="text-center text-muted-foreground py-8">Leadership chart is unavailable right now.</p>
      ) : (
        <LeadershipChart rows={rows} />
      )}
    </section>
  );
}
