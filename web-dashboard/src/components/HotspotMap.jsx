import { useEffect, useRef } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { fmtCount, fmtDate } from '../lib.js';
import { LEVEL_COLOR } from './ui.jsx';

const NO_LEVEL = '#8E9E90';
export const TILE_URL = 'https://tile.opentopomap.org/{z}/{x}/{y}.png';
export const TILE_ATTRIBUTION = '© OpenStreetMap contributors, SRTM | © OpenTopoMap';

// Tooltip HTML includes farmer-entered text (barangay names), so escape it.
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);

/** Barangay circle radius in pixels (visible at province zoom): grows with the number of records. */
const radius = (records) => Math.min(12 + Math.sqrt(records) * 4, 30);

export default function HotspotMap({ points = [], hotspots = [], onSelect, focus, className = 'h-[460px]' }) {
  const mapRef = useRef(null);
  const mapObj = useRef(null);
  const layerRef = useRef(null);
  const selectRef = useRef(onSelect);
  selectRef.current = onSelect;

  useEffect(() => {
    if (mapObj.current) return undefined;
    // Centered on Antique.
    const map = L.map(mapRef.current, { scrollWheelZoom: false }).setView([11.2, 122.05], 9);
    L.tileLayer(TILE_URL, { maxZoom: 17, attribution: TILE_ATTRIBUTION }).addTo(map);
    layerRef.current = L.layerGroup().addTo(map);
    mapObj.current = map;
    const ro = new ResizeObserver(() => map.invalidateSize());
    ro.observe(mapRef.current);
    return () => {
      ro.disconnect();
      map.remove();
      mapObj.current = null;
      layerRef.current = null;
    };
  }, []);

  useEffect(() => {
    const layer = layerRef.current;
    const map = mapObj.current;
    if (!layer || !map) return;
    layer.clearLayers();

    for (const h of hotspots) {
      const color = LEVEL_COLOR[h.level] || NO_LEVEL;
      L.circleMarker([h.lat, h.lng], {
        radius: radius(h.records),
        color,
        fillColor: color,
        fillOpacity: 0.18,
        weight: 2,
        dashArray: '5 4',
      })
        .bindTooltip(
          `<b>${esc(h.barangay)}</b>, ${esc(h.municipality)}<br/>` +
            `Highest level: <b>${esc(h.level)}</b> · ${esc(h.records)} record${h.records === 1 ? '' : 's'}<br/>` +
            `${esc(h.pests.join(', '))}<br/>Latest: ${esc(fmtDate(h.latest))}`,
          { sticky: true },
        )
        .addTo(layer);
    }

    for (const p of points) {
      const color = LEVEL_COLOR[p.level] || NO_LEVEL;
      const count = p.is_disease ? '' : ` · ${esc(fmtCount(p.count))}`;
      const marker = L.circleMarker([p.lat, p.lng], {
        radius: 6,
        color: '#ffffff',
        fillColor: color,
        fillOpacity: 0.95,
        weight: 2,
      }).bindTooltip(
        `<b>#${esc(p.id)} ${esc(p.pest)}</b> · ${esc(p.level || 'no level')}${count}<br/>` +
          `${esc(p.barangay || '—')}, ${esc(p.municipality)} · ${esc(fmtDate(p.created_at))}`,
      );
      marker.on('click', () => selectRef.current?.(p));
      marker.addTo(layer);
    }

    const coords = [...points.map((p) => [p.lat, p.lng]), ...hotspots.map((h) => [h.lat, h.lng])];
    if (coords.length) map.fitBounds(L.latLngBounds(coords).pad(0.25), { maxZoom: 14 });
  }, [points, hotspots]);

  useEffect(() => {
    if (focus && mapObj.current) mapObj.current.setView([focus.lat, focus.lng], 14);
  }, [focus]);

  return (
    <div>
      {/* isolate keeps Leaflet's z-indexes below drawers and menus */}
      <div ref={mapRef} className={`isolate w-full rounded-xl border border-line ${className}`} />
      <div className="mt-3 flex flex-wrap items-center gap-2.5 text-sm text-ink2">
        {Object.entries(LEVEL_COLOR).map(([k, v]) => (
          <span key={k} className="flex items-center gap-2 rounded-full border border-line bg-white px-3 py-1.5 font-bold text-ink shadow-sm">
            <span className="inline-block h-5 w-5 rounded-full ring-2 ring-white" style={{ background: v, boxShadow: `0 0 0 1px ${v}` }} />
            {k}
          </span>
        ))}
        <span className="flex items-center gap-2 rounded-full border border-line bg-white px-3 py-1.5 shadow-sm">
          <span className="inline-block h-5 w-5 rounded-full" style={{ background: NO_LEVEL }} />
          Disease report (no level)
        </span>
        <span className="flex items-center gap-2 rounded-full border border-line bg-white px-3 py-1.5 shadow-sm">
          <span className="inline-block h-5 w-5 rounded-full border-2 border-dashed border-ink2" />
          Barangay hotspot, coloured by its highest confirmed level
        </span>
        {onSelect && <span className="text-muted">Click a point to open the record.</span>}
      </div>
    </div>
  );
}
