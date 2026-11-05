import { useState } from 'react';
import { api } from '../api.js';
import HotspotMap from '../components/HotspotMap.jsx';
import RecordDrawer from '../components/RecordDrawer.jsx';
import { Button, Empty, ErrorNote, Field, LEVEL_COLOR, LevelBadge, Loading, Panel, PageHeader, Select, Stat, Table } from '../components/ui.jsx';
import { CROP_STAGES, fmtDate, fmtNum, LEVELS, useAsync } from '../lib.js';

const NO_FILTERS = { start: '', end: '', pest: '', crop_stage: '', level: '', municipality: '' };

/** Active hotspots by highest level, e.g. on the home summary row. */
export function HotspotStat({ counts, days }) {
  return (
    <div className="rounded-2xl border border-line bg-white p-4 shadow-sm">
      <div className="text-xs font-semibold uppercase tracking-wide text-ink2">Active hotspots</div>
      <div className="mt-1 flex items-end gap-4">
        {LEVELS.map((lv) => (
          <div key={lv}>
            <div className="text-2xl font-bold tabular-nums" style={{ color: LEVEL_COLOR[lv] }}>
              {fmtNum(counts[lv])}
            </div>
            <div className="text-[11px] font-semibold text-ink2">{lv}</div>
          </div>
        ))}
      </div>
      <div className="mt-1 text-xs text-muted">Barangays with validated records, last {days} days</div>
    </div>
  );
}

/** Filters + map + hotspot list. Validated observations only. */
export function HotspotExplorer({ viewer, mapClassName }) {
  const isAgri = viewer.role === 'agriculturist';
  const [filters, setFilters] = useState(NO_FILTERS);
  const [openId, setOpenId] = useState(null);
  const [focus, setFocus] = useState(null);
  const res = useAsync(() => api.hotspots(filters), [JSON.stringify(filters)]);
  const set = (key) => (value) => setFilters((f) => ({ ...f, [key]: value }));
  const d = res.data;
  const filtered = Object.values(filters).some(Boolean);

  return (
    <>
      <Panel
        title="Hotspot map"
        subtitle={
          d
            ? `Validated observations only · ${fmtNum(d.points.length)} with GPS${filtered ? ' match the filters' : ''} · ${fmtNum(d.hotspots.length)} barangay hotspot${d.hotspots.length === 1 ? '' : 's'}`
            : 'Validated observations only'
        }
        actions={
          filtered && (
            <Button variant="ghost" size="sm" onClick={() => setFilters(NO_FILTERS)}>
              Clear filters
            </Button>
          )
        }
      >
        <div className={`mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3 ${isAgri ? 'xl:grid-cols-6' : 'xl:grid-cols-5'}`}>
          <Field label="Pest type">
            <Select value={filters.pest} onChange={set('pest')} placeholder="All" options={d?.facets.pests || []} />
          </Field>
          <Field label="From">
            <input type="date" className="input" value={filters.start} onChange={(e) => set('start')(e.target.value)} />
          </Field>
          <Field label="To">
            <input type="date" className="input" value={filters.end} onChange={(e) => set('end')(e.target.value)} />
          </Field>
          <Field label="Crop stage">
            <Select value={filters.crop_stage} onChange={set('crop_stage')} placeholder="All stages" options={CROP_STAGES} />
          </Field>
          <Field label="Infestation level">
            <Select value={filters.level} onChange={set('level')} placeholder="All levels" options={LEVELS} />
          </Field>
          {isAgri && (
            <Field label="Municipality">
              <Select value={filters.municipality} onChange={set('municipality')} placeholder="All" options={d?.facets.municipalities || []} />
            </Field>
          )}
        </div>
        <ErrorNote message={res.error} onRetry={res.reload} />
        {!d && res.loading ? (
          <Loading label="Loading map…" />
        ) : (
          d && <HotspotMap points={d.points} hotspots={d.hotspots} focus={focus} onSelect={(p) => setOpenId(p.id)} className={mapClassName} />
        )}
      </Panel>

      {d && (
        <Panel className="mt-6" title="Barangay hotspots" subtitle="Highest confirmed level first. Click a row to zoom the map to it." bodyClassName="">
          <Table
            rowKey="key"
            rows={d.hotspots.map((h) => ({ ...h, key: `${h.municipality}|${h.barangay}` }))}
            onRowClick={(h) => setFocus({ lat: h.lat, lng: h.lng, at: Date.now() })}
            empty={<Empty title="No hotspots">No validated pest observations with a location match these filters.</Empty>}
            columns={[
              { key: 'barangay', label: 'Barangay', className: 'font-medium' },
              { key: 'municipality', label: 'Municipality' },
              { key: 'level', label: 'Highest level', render: (h) => <LevelBadge level={h.level} /> },
              { key: 'records', label: 'Records', align: 'right', render: (h) => fmtNum(h.records) },
              { key: 'pests', label: 'Pests', render: (h) => <span className="text-ink2">{h.pests.join(', ')}</span> },
              { key: 'latest', label: 'Latest', render: (h) => fmtDate(h.latest) },
            ]}
          />
        </Panel>
      )}

      {openId && <RecordDrawer scanId={openId} viewer={viewer} onClose={() => setOpenId(null)} onChanged={res.reload} />}
    </>
  );
}

export default function MapPage({ viewer }) {
  const isAgri = viewer.role === 'agriculturist';
  const overview = useAsync(() => (isAgri ? Promise.resolve(null) : api.overview()), [isAgri]);
  const o = overview.data;
  return (
    <div>
      <PageHeader
        title="Hotspot map"
        description={
          isAgri
            ? 'The whole province. Only validated observations appear; hotspots are barangays coloured by the highest infestation level a reviewer confirmed.'
            : 'Your coverage area. Only validated observations appear; hotspots are barangays coloured by the highest infestation level a reviewer confirmed.'
        }
        area={isAgri ? undefined : viewer.area_label}
      />
      {o && (
        <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Stat label="For validation" value={fmtNum(o.pending)} tone={o.pending ? 'orange' : 'muted'} hint="In your queue" />
          <Stat label="Validated this month" value={fmtNum(o.validated_this_month)} tone="brand" />
          <HotspotStat counts={o.hotspots} days={o.hotspot_days} />
          <Stat label="Escalated" value={fmtNum(o.escalated)} tone={o.escalated ? 'red' : 'muted'} hint="Waiting for an agriculturist" />
        </div>
      )}
      <HotspotExplorer viewer={viewer} />
    </div>
  );
}
