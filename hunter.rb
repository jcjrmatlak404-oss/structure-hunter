#!/usr/bin/env ruby
# ============================================================================
# hunter_app.rb — local web interface for the structure-hunting toolkit
# BUILD: v47-roof-shape (live picture controls · cache panel · relief render)
#
# Run:     ruby hunter_app.rb          (then open http://localhost:8080)
# Stop:    Ctrl+C
#
# One file, stdlib only (socket, json, csv, uri). It serves a form where
# you supply data file paths, an optional bounding box for the area to
# scan, and plain-language tuning knobs. Submit -> the vector pipeline
# runs -> ranked results render as a table with map links (and are also
# written to candidates.csv / candidates.geojson). An optional LiDAR
# section refines further if you supply an ndsm.asc grid.
#
# Everything runs locally; the server binds to 127.0.0.1 only.
# ============================================================================

require 'socket'
require 'json'
require 'csv'
require 'uri'
require 'net/http'
require 'digest'

PORT = 8080
NOOP_LOG = ->(_msg) {}   # default logger: silence

# ============================================================================
# GEOMETRY CORE (same math as the CLI hunters — see those files for the
# full line-by-line commentary; kept compact here)
# ============================================================================
M_LAT = 111_320.0
def m_lon(lat) = M_LAT * Math.cos(lat * Math::PI / 180.0)

def dist_sq(lng1, lat1, lng2, lat2, mlon)
  dx = (lng2 - lng1) * mlon
  dy = (lat2 - lat1) * M_LAT
  dx * dx + dy * dy
end

def ring_area_centroid(ring, mlon)
  ox, oy = ring[0]
  pts = ring.map { |g, t| [(g - ox) * mlon, (t - oy) * M_LAT] }
  a = cx = cy = 0.0
  pts.each_cons(2) do |(x1, y1), (x2, y2)|
    cr = x1 * y2 - x2 * y1
    a += cr; cx += (x1 + x2) * cr; cy += (y1 + y2) * cr
  end
  sa = a / 2.0
  return [0.0, ox, oy] if sa.abs < 1e-9
  [sa.abs, ox + (cx / (6 * sa)) / mlon, oy + (cy / (6 * sa)) / M_LAT]
end

# --- Shape analysis: tell a lone circular tank from a building -------------
# Andrew's monotone-chain convex hull over [x,y] points (meters).
def convex_hull(points)
  pts = points.uniq.sort
  return pts if pts.size < 3
  cross = ->(o, a, b) { (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]) }
  lower = []
  pts.each do |p|
    lower.pop while lower.size >= 2 && cross.call(lower[-2], lower[-1], p) <= 0
    lower << p
  end
  upper = []
  pts.reverse_each do |p|
    upper.pop while upper.size >= 2 && cross.call(upper[-2], upper[-1], p) <= 0
    upper << p
  end
  lower[0...-1] + upper[0...-1]
end

def polygon_area(poly)
  a = 0.0
  poly.each_index { |i| j = (i + 1) % poly.size; a += poly[i][0] * poly[j][1] - poly[j][0] * poly[i][1] }
  a.abs / 2.0
end

# Given boundary points (meters) and the true area, return shape descriptors.
def shape_descriptors(points, area, perimeter)
  return nil if points.size < 3 || area <= 0 || perimeter <= 0
  hull = convex_hull(points)
  hull_area = polygon_area(hull)
  xs = points.map { |p| p[0] }; ys = points.map { |p| p[1] }
  bw = (xs.max - xs.min); bh = (ys.max - ys.min)
  {
    circularity: (4 * Math::PI * area) / (perimeter * perimeter),  # 1.0 = circle
    solidity:    hull_area > 0 ? area / hull_area : 1.0,           # 1.0 = no notches
    aspect:      bh > 0 ? bw / bh : 1.0,                            # ~1 = square box
    extent:      (bw * bh) > 0 ? area / (bw * bh) : 1.0            # ~0.785 = circle in box
  }
end

# A "lone circle" (tank/silo) is circular AND solid AND square-ish AND fills
# its box like a circle. If anything is attached, solidity/aspect/extent break
# and it is NOT flagged — exactly "circle plus an addition still passes".
def lone_circle?(d)
  return false unless d
  d[:circularity] > 0.88 && d[:solidity] > 0.92 &&
    d[:aspect] >= 0.8 && d[:aspect] <= 1.25 &&
    d[:extent] >= 0.74 && d[:extent] <= 0.84
end

# Minimum-area oriented bounding rectangle of a point set (meters), via rotating
# the hull to each edge's angle and taking the tightest box. Returns the box's
# long side, short side, fill ratio (area / box area), and orientation in degrees.
# Unlike an axis-aligned box, this gives the TRUE length/width even for a
# structure sitting at an angle — essential for telling "long thin barn" from
# "square house" regardless of how it's oriented on the map.
def min_area_rect(points, area)
  hull = convex_hull(points)
  return nil if hull.size < 3
  best = nil
  n = hull.size
  n.times do |i|
    ax, ay = hull[i]
    bx, by = hull[(i + 1) % n]
    ex = bx - ax; ey = by - ay
    len = Math.hypot(ex, ey)
    next if len < 1e-9
    ux = ex / len; uy = ey / len      # edge direction (unit)
    px = -uy; py = ux                 # perpendicular (unit)
    min_u = min_v = Float::INFINITY
    max_u = max_v = -Float::INFINITY
    hull.each do |hx, hy|
      du = hx * ux + hy * uy
      dv = hx * px + hy * py
      min_u = du if du < min_u; max_u = du if du > max_u
      min_v = dv if dv < min_v; max_v = dv if dv > max_v
    end
    w = max_u - min_u; h = max_v - min_v
    a = w * h
    if best.nil? || a < best[:box_area]
      ang = Math.atan2(uy, ux) * 180 / Math::PI
      best = { box_area: a, long: [w, h].max, short: [w, h].min, angle: ang }
    end
  end
  return nil unless best
  best[:fill] = best[:box_area] > 0 ? area / best[:box_area] : 1.0  # 1=perfect rectangle
  best[:elong] = best[:short] > 0 ? best[:long] / best[:short] : 1.0
  best
end

# Classify a footprint into a shape family and a likely structure type, from its
# geometric descriptors and real area. Returns { shape:, type:, long:, short: }.
# Everything is a LIKELIHOOD, not a certainty — the footprint is the roof-down
# outline, so size + shape narrow the options but can't prove use.
def classify_footprint(points, area, perimeter)
  d = shape_descriptors(points, area, perimeter)
  return { shape: 'unknown', type: '', long: nil, short: nil } unless d
  rect = min_area_rect(points, area)
  long  = rect ? rect[:long] : nil
  short = rect ? rect[:short] : nil
  elong = rect ? rect[:elong] : d[:aspect]
  fill  = rect ? rect[:fill] : d[:extent]
  sol   = d[:solidity]
  circ  = d[:circularity]

  # ---- shape family ----
  shape =
    if circ > 0.85 && elong < 1.3 && fill.between?(0.74, 0.86)
      'circular'
    elsif fill >= 0.90 && sol >= 0.90
      elong >= 3.0 ? 'long rectangle' : (elong <= 1.2 ? 'square' : 'rectangle')
    elsif sol >= 0.78 && fill >= 0.62
      # fills a good part of its hull but not its box -> a rectangle with a bite:
      # L / T / U shapes (very common for houses with wings/additions)
      'L / T-shaped'
    elsif elong >= 3.5
      'elongated'
    elsif sol < 0.7
      'irregular'
    else
      elong >= 1.8 ? 'rectangle' : 'blocky'
    end

  # ---- likely type, from shape + size (m^2) ----
  type =
    if shape == 'circular'
      area < 60 ? 'tank / bin' : 'tank / silo'
    elsif shape == 'elongated' || shape == 'long rectangle'
      if area < 120 then 'mobile home / trailer-like'
      elsif area < 400 then 'barn / stable / long building'
      else 'large agricultural / warehouse' end
    elsif shape == 'irregular'
      area > 500 ? 'large complex / multi-building' : 'irregular structure'
    else  # square, rectangle, blocky, L/T
      if area < 25 then 'small shed / outbuilding'
      elsif area < 70 then 'shed / garage / cabin'
      elsif area < 350 then (shape == 'L / T-shaped' ? 'likely dwelling (with wing)' : 'possible dwelling')
      elsif area < 1200 then 'large building / commercial'
      else 'warehouse / industrial' end
    end

  { shape: shape, type: type, long: long, short: short }
end

# From a LiDAR blob's height statistics, infer the roof form. `rough` is the
# standard deviation of height-above-ground across the blob (flat roofs vary
# little; pitched roofs vary moderately and structurally; very steep/complex
# roofs vary a lot). `mean` is the mean height. Returns a short label.
def roof_shape(mean, rough)
  return '' unless mean && rough
  if rough < 0.45 then 'flat roof'
  elsif rough < 1.3 then 'pitched roof'
  elsif rough < 2.5 then 'steep / complex roof'
  else 'very tall / irregular'
  end
end

# Refine a footprint type guess using the roof form, for LiDAR candidates where
# we have height data. A pitched roof on a house-sized rectangle strengthens
# "dwelling"; a flat roof on the same shape leans commercial/shed/mobile. Domed
# circular = silo vs flat circular = tank. Returns a possibly-updated type, and
# the roof label, so the UI can show both.
def refine_type_with_roof(cls, area, mean, rough)
  roof = roof_shape(mean, rough)
  type = cls[:type].to_s
  shape = cls[:shape].to_s
  return [type, roof] if roof.empty?

  square_ish = %w[square rectangle blocky].include?(shape) || shape == 'L / T-shaped'
  if square_ish && area >= 60 && area < 400
    type =
      case roof
      when 'pitched roof'        then 'likely dwelling (pitched roof)'
      when 'flat roof'           then 'flat-roof building (shed / commercial / mobile)'
      when 'steep / complex roof' then 'likely dwelling (complex roof)'
      else type
      end
  elsif shape == 'circular'
    type = roof == 'flat roof' ? 'tank (flat top)' : 'silo / bin (domed)'
  elsif (shape == 'long rectangle' || shape == 'elongated') && roof == 'pitched roof' && area < 400
    type = 'barn / gabled long building'
  end
  [type, roof]
end

# Draw a tiny SVG glyph of the actual footprint outline, scaled so that its
# on-glyph size reflects the REAL structure size: a small shed fills only a
# little of the box, a warehouse nearly fills it. A faint reference square marks
# a fixed real-world size (~25 m) so the eye reads absolute scale, not just shape.
# `points` are boundary coords in meters; pass the long/short for the label.
def shape_glyph_svg(points, long_m, short_m)
  return '' if points.nil? || points.size < 3
  xs = points.map { |p| p[0] }; ys = points.map { |p| p[1] }
  cx = (xs.min + xs.max) / 2.0; cy = (ys.min + ys.max) / 2.0
  # real extent of the structure (meters), with a floor so dots aren't invisible
  real_w = [xs.max - xs.min, 1.0].max
  real_h = [ys.max - ys.min, 1.0].max
  real_span = [real_w, real_h].max

  box = 46            # glyph viewport (px)
  pad = 5
  # Scale: a REFERENCE_M structure fills the drawable area. Bigger real
  # structures are clamped to fit but still read as "large" (near-full box).
  ref_m = 40.0
  draw = box - pad * 2
  scale = draw / [real_span, ref_m].max     # px per meter (shared x & y -> true proportions)

  pts = points.map do |x, y|
    px = box / 2.0 + (x - cx) * scale
    py = box / 2.0 - (y - cy) * scale       # flip y for screen coords
    "#{px.round(1)},#{py.round(1)}"
  end.join(' ')

  # reference square = 25 m, drawn faint so size is judgeable at a glance
  refpx = 25.0 * scale
  rx = box - pad - refpx
  ry = box - pad - refpx
  ref = refpx.between?(4, box) ?
    %(<rect x="#{rx.round(1)}" y="#{ry.round(1)}" width="#{refpx.round(1)}" height="#{refpx.round(1)}" fill="none" stroke="#46d39a" stroke-opacity="0.35" stroke-dasharray="2 2"/>) : ''

  %(<svg class="glyph" viewBox="0 0 #{box} #{box}" width="#{box}" height="#{box}" xmlns="http://www.w3.org/2000/svg">) +
    ref +
    %(<polygon points="#{pts}" fill="#f0a830" fill-opacity="0.22" stroke="#f0a830" stroke-width="1.3" stroke-linejoin="round"/>) +
    %(</svg>)
end

def point_in_ring?(lng, lat, ring)
  inside = false
  j = ring.size - 1
  ring.each_with_index do |(xi, yi), i|
    xj, yj = ring[j]
    if ((yi > lat) != (yj > lat)) &&
       (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)
      inside = !inside
    end
    j = i
  end
  inside
end

class GridIndex
  def initialize(cell_m, mlon)
    @clat = cell_m / M_LAT
    @clng = cell_m / mlon
    @cells = Hash.new { |h, k| h[k] = [] }
  end
  def key(lng, lat) = [(lng / @clng).floor, (lat / @clat).floor]
  def insert(lng, lat) = @cells[key(lng, lat)] << [lng, lat]
  def each_near(lng, lat, r = 1)
    cx, cy = key(lng, lat)
    (-r..r).each do |dx|
      (-r..r).each do |dy|
        c = @cells.fetch([cx + dx, cy + dy], nil)
        c&.each { |pt| yield pt }
      end
    end
  end
end

class ParcelIndex
  def initialize(cell_m, mlon)
    @clat = cell_m / M_LAT
    @clng = cell_m / mlon
    @cells = Hash.new { |h, k| h[k] = [] }
  end
  def insert(rings, improvement)
    lngs = rings.flat_map { |r| r.map(&:first) }
    lats = rings.flat_map { |r| r.map(&:last) }
    p = [rings, improvement]
    ((lngs.min / @clng).floor..(lngs.max / @clng).floor).each do |cx|
      ((lats.min / @clat).floor..(lats.max / @clat).floor).each do |cy|
        @cells[[cx, cy]] << p
      end
    end
  end
  def lookup(lng, lat)
    @cells.fetch([(lng / @clng).floor, (lat / @clat).floor], []).each do |rings, imp|
      rings.each { |r| return [:hit, imp] if point_in_ring?(lng, lat, r) }
    end
    nil
  end
end

# ============================================================================
# LOADERS (with optional bounding-box filtering — replaces ogr2ogr clipping)
# ============================================================================
def in_box?(lng, lat, box)
  return true unless box
  lng >= box[0] && lng <= box[2] && lat >= box[1] && lat <= box[3]
end

def load_addresses(path, box)
  pts = []
  JSON.parse(File.read(path))['features'].each do |f|
    g = f['geometry'] or next
    coords = g['type'] == 'Point' ? [g['coordinates']] :
             g['type'] == 'MultiPoint' ? g['coordinates'] : []
    coords.each { |c| pts << c[0, 2] if in_box?(c[0], c[1], box) }
  end
  pts
end

def load_footprints(path, box, mlon)
  rings = []
  JSON.parse(File.read(path))['features'].each do |f|
    g = f['geometry'] or next
    ring =
      case g['type']
      when 'Polygon'      then g['coordinates'][0]
      when 'MultiPolygon' then g['coordinates'].max_by { |p| ring_area_centroid(p[0], mlon)[0] }[0]
      else next
      end
    rings << ring if in_box?(ring[0][0], ring[0][1], box)
  end
  rings
end

def load_parcels(path, field, box)
  out = []
  JSON.parse(File.read(path))['features'].each do |f|
    g = f['geometry'] or next
    rings =
      case g['type']
      when 'Polygon'      then [g['coordinates'][0]]
      when 'MultiPolygon' then g['coordinates'].map { |p| p[0] }
      else next
      end
    next unless in_box?(rings[0][0][0], rings[0][0][1], box)
    props = f['properties'] || {}
    raw = props[field]
    # Rich context for accuracy judgement (NC OneMap field names; nil-safe so
    # other parcel sources that lack these simply carry blanks).
    ctx = {
      imp: raw.nil? ? nil : raw.to_f,
      use_code: (props['parusecode'] || props['PARUSECODE']).to_s.strip,
      use_desc: (props['parusedesc'] || props['PARUSEDESC']).to_s.strip,
      use_desc2: (props['parusedsc2'] || props['PARUSEDSC2']).to_s.strip,
      owner_type: (props['owntype'] || props['OWNTYPE']).to_s.strip,
      owner: (props['ownname'] || props['OWNNAME']).to_s.strip,
      acres: (props['gisacres'] || props['GISACRES']),
      site_addr: (props['siteadd'] || props['SITEADD']).to_s.strip,
      has_struct: (props['struct'] || props['STRUCT']).to_s.strip
    }
    out << [rings, ctx]
  end
  out
end

# Decide if a parcel's use looks NON-residential (commercial / industrial /
# rail / utility / agricultural-operation) from its use description text.
# Works across counties by matching words rather than county-specific codes.
NONRES_WORDS = %w[COMMERC INDUST RAIL WAREHOUS MANUF UTILIT SUBSTAT
                  STORAGE PLANT FACTOR TERMINAL DEPOT FREIGHT QUARRY MINE
                  REFINER YARD PORT AIRPORT HANGAR].freeze
def parcel_use_flag(ctx)
  return nil unless ctx.is_a?(Hash)
  d = "#{ctx[:use_desc]} #{ctx[:use_desc2]}".upcase
  return nil if d.strip.empty?
  hit = NONRES_WORDS.find { |w| d.include?(w) }
  hit ? ctx[:use_desc] : nil
end

# ============================================================================
# AUTO-FETCH FROM OPENSTREETMAP (with on-disk caching)
#
# Given a bounding box, pulls building outlines and address points from
# the free Overpass API and writes them as GeoJSON into ./cache/, named
# by a hash of the box. Subsequent runs with the same box hit the cache
# instead of the network — fetch once, tune forever.
#
# Address points come from two OSM shapes: standalone addr nodes, and
# buildings that carry their own address tags (we take their centers).
# Coverage caveat: OSM address data is excellent in cities, sparse in
# rural areas — for serious rural hunts, a county address file via the
# manual fields is higher quality.
# ============================================================================
CACHE_DIR = File.join(__dir__, 'cache')
DISMISS_FILE = File.join(CACHE_DIR, 'dismissed.json')
EXAMINED_FILE = File.join(CACHE_DIR, 'examined.json')

# Centers of LiDAR windows already examined, so "focus next unexamined" can
# sweep forward through the candidate list across runs instead of repeating
# the same #1 window every time. Matched by proximity to the window's snapped
# center. Like dismissals, this persists and survives a cache clear.
EXAMINED_RADIUS_M = 900.0   # within ~0.9 km counts as "same window already seen"

def load_examined
  return [] unless File.exist?(EXAMINED_FILE)
  JSON.parse(File.read(EXAMINED_FILE), symbolize_names: true)
rescue
  []
end

def mark_examined(lat, lng)
  list = load_examined
  return if list.any? { |e| haversine_m(lat, lng, e[:lat], e[:lng]) <= EXAMINED_RADIUS_M }
  list << { lat: lat.round(6), lng: lng.round(6), at: Time.now.strftime('%Y-%m-%d') }
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  File.write(EXAMINED_FILE, JSON.generate(list))
end

def examined?(examined, lat, lng)
  examined.any? { |e| haversine_m(lat, lng, e[:lat], e[:lng]) <= EXAMINED_RADIUS_M }
end

# Locations the user has marked "not interesting" so future scans skip them.
# Keyed to physical coordinates and matched by proximity, so dismissals persist
# across runs and survive small coordinate wobble between data updates.
DISMISS_RADIUS_M = 20.0

def load_dismissed
  return [] unless File.exist?(DISMISS_FILE)
  JSON.parse(File.read(DISMISS_FILE), symbolize_names: true)
rescue
  []
end

def save_dismissed(list)
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  File.write(DISMISS_FILE, JSON.generate(list))
end

def add_dismissed(lat, lng, reason)
  list = load_dismissed
  # de-dupe: if one already sits within the match radius, just update it
  list.reject! { |d| haversine_m(lat, lng, d[:lat], d[:lng]) <= DISMISS_RADIUS_M }
  list << { lat: lat.round(6), lng: lng.round(6),
            reason: reason.to_s.strip[0, 80],
            at: Time.now.strftime('%Y-%m-%d') }
  save_dismissed(list)
  list.size
end

def remove_dismissed(lat, lng)
  list = load_dismissed
  list.reject! { |d| haversine_m(lat, lng, d[:lat], d[:lng]) <= DISMISS_RADIUS_M }
  save_dismissed(list)
  list.size
end

# Is this candidate location within the match radius of any dismissed point?
# Returns the dismissed record (with its reason) or nil.
def dismissed_match(dismissed, lat, lng)
  dismissed.find { |d| haversine_m(lat, lng, d[:lat], d[:lng]) <= DISMISS_RADIUS_M }
end

# Small-distance great-circle metres (good enough at candidate scale).
def haversine_m(lat1, lon1, lat2, lon2)
  rad = Math::PI / 180
  dlat = (lat2 - lat1) * rad
  dlon = (lon2 - lon1) * rad
  a = Math.sin(dlat / 2)**2 +
      Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2)**2
  6_371_000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
end

def cache_stats
  return { count: 0, bytes: 0, laz_count: 0, laz_bytes: 0, groups: {} } unless Dir.exist?(CACHE_DIR)
  files = Dir.glob(File.join(CACHE_DIR, '*')).select { |f| File.file?(f) }
  laz = files.select { |f| f.end_with?('.laz') }
  group = Hash.new { |h, k| h[k] = { count: 0, bytes: 0 } }
  files.each do |f|
    ext = File.extname(f).downcase
    kind = case ext
           when '.laz' then 'LiDAR point clouds (.laz)'
           when '.asc' then 'Height grids (.asc)'
           when '.png' then 'Rendered images (.png)'
           when '.geojson' then 'Map data (.geojson)'
           else 'Other'
           end
    group[kind][:count] += 1
    group[kind][:bytes] += File.size(f)
  end
  {
    count: files.size,
    bytes: files.sum { |f| File.size(f) },
    laz_count: laz.size,
    laz_bytes: laz.sum { |f| File.size(f) },
    groups: group
  }
end

def human_size(bytes)
  return "#{bytes} B" if bytes < 1024
  units = %w[KB MB GB TB]
  v = bytes.to_f
  units.each do |u|
    v /= 1024.0
    return format('%.1f %s', v, u) if v < 1024 || u == 'TB'
  end
end

def clear_cache(which)
  return 0 unless Dir.exist?(CACHE_DIR)
  files = Dir.glob(File.join(CACHE_DIR, '*')).select { |f| File.file?(f) }
  # never delete the user's decisions — dismissals and examined-window history
  files.reject! { |f| %w[dismissed.json examined.json].include?(File.basename(f)) }
  files = files.select { |f| f.end_with?('.laz') } if which == 'laz'
  freed = files.sum { |f| File.size(f) }
  files.each { |f| File.delete(f) }
  freed
end

def overpass(query)
  res = Net::HTTP.post_form(URI('https://overpass-api.de/api/interpreter'),
                            'data' => query)
  unless res.code == '200'
    raise "Overpass API returned #{res.code} — server busy or rate-limited. " \
          'Wait a minute and run again (results cache once fetched).'
  end
  JSON.parse(res.body)['elements']
end

def box_key(box)
  Digest::SHA1.hexdigest(box.map { |v| v.round(5) }.join(','))[0, 12]
end

def osm_fetch_buildings(box, key, log = NOOP_LOG)
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  fp_file = File.join(CACHE_DIR, "osm_buildings_#{key}.geojson")
  if File.exist?(fp_file)
    log.('Building outlines: using cache')
    return [fp_file, true]
  end
  log.('Fetching building outlines from OpenStreetMap...')
  bbox = "#{box[1]},#{box[0]},#{box[3]},#{box[2]}"
  buildings = overpass(
    %{[out:json][timeout:120];(way["building"](#{bbox}););out geom;})
  feats = buildings.filter_map do |el|
    g = el['geometry'] or next
    ring = g.map { |pt| [pt['lon'], pt['lat']] }
    ring << ring.first unless ring.first == ring.last
    next if ring.size < 4
    { 'type' => 'Feature', 'properties' => {},
      'geometry' => { 'type' => 'Polygon', 'coordinates' => [ring] } }
  end
  File.write(fp_file, JSON.generate(
    { 'type' => 'FeatureCollection', 'features' => feats }))
  log.("Buildings fetched: #{feats.size}")
  [fp_file, false]
end

# Fetch OSM industrial / railway land-use polygons and rail lines for a box.
# Used to recognize when a candidate sits inside an industrial area or rail
# yard — context the per-structure scan can't see on its own. Cached like the
# building data. Returns a structure of zones for fast point-in-zone testing.
def osm_fetch_zones(box, key, log = NOOP_LOG)
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  zf = File.join(CACHE_DIR, "osm_zones_#{key}.json")
  if File.exist?(zf)
    log.('Industrial/railway zones: using cache')
    return JSON.parse(File.read(zf), symbolize_names: true)
  end
  log.('Fetching industrial & railway zones from OpenStreetMap...')
  bbox = "#{box[1]},#{box[0]},#{box[3]},#{box[2]}"
  q = %{[out:json][timeout:180];(} +
      %{way["landuse"="industrial"](#{bbox});} +
      %{way["landuse"="railway"](#{bbox});} +
      %{way["landuse"="commercial"](#{bbox});} +
      %{way["landuse"="quarry"](#{bbox});} +
      %{way["man_made"="works"](#{bbox});} +
      %{way["railway"="yard"](#{bbox});} +
      %{way["aeroway"="aerodrome"](#{bbox});} +
      %{way["railway"="rail"](#{bbox});} +
      %{);out geom;}
  els = overpass(q)
  polys = []   # [label, [ [lng,lat],... ]]
  rails = []   # [ [lng,lat],... ]  (rail centerlines, buffered at test time)
  els.each do |el|
    g = el['geometry'] or next
    pts = g.map { |pt| [pt['lon'], pt['lat']] }
    tags = el['tags'] || {}
    if tags['railway'] == 'rail' && tags['landuse'].nil?
      rails << pts if pts.size >= 2
    else
      next if pts.size < 4
      pts << pts.first unless pts.first == pts.last
      label =
        if tags['landuse'] == 'railway' || tags['railway'] == 'yard' then 'rail yard'
        elsif tags['landuse'] == 'industrial' || tags['man_made'] == 'works' then 'industrial zone'
        elsif tags['landuse'] == 'quarry' then 'quarry'
        elsif tags['aeroway'] then 'airport'
        elsif tags['landuse'] == 'commercial' then 'commercial zone'
        else 'industrial zone' end
      polys << [label, pts]
    end
  end
  data = { polys: polys, rails: rails }
  File.write(zf, JSON.generate(data))
  log.("Zones fetched: #{polys.size} areas, #{rails.size} rail lines")
  JSON.parse(JSON.generate(data), symbolize_names: true)
end

# Is (lng,lat) inside any industrial/railway polygon, or within ~60 m of a rail
# line? Returns the zone label (e.g. "rail yard") or nil.
def zone_hit(zones, lng, lat)
  return nil unless zones
  (zones[:polys] || []).each do |label, ring|
    return label if point_in_ring?(lng, lat, ring)
  end
  # near a rail line? cheap check: distance to any rail vertex under ~60 m
  rail_tol = (60.0 / 111_320.0)  # ~60 m in degrees lat (approx; longitude close enough at test latitudes)
  (zones[:rails] || []).each do |line|
    line.each do |x, y|
      return 'near rail line' if (x - lng).abs < rail_tol && (y - lat).abs < rail_tol
    end
  end
  nil
end

def osm_fetch(box, log = NOOP_LOG)
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  key = box_key(box)
  fp_file, fp_cached = osm_fetch_buildings(box, key, log)
  ad_file = File.join(CACHE_DIR, "osm_addresses_#{key}.geojson")
  cached = fp_cached && File.exist?(ad_file)
  if File.exist?(ad_file)
    log.('Address points: using cache')
  end
  unless File.exist?(ad_file)
    log.('Fetching address points from OpenStreetMap...')
    bbox = "#{box[1]},#{box[0]},#{box[3]},#{box[2]}"
    addr = overpass(
      %{[out:json][timeout:90];(node["addr:housenumber"](#{bbox});} +
      %{way["addr:housenumber"](#{bbox}););out center;})
    afeats = addr.filter_map do |el|
      lat = el['lat'] || el.dig('center', 'lat')
      lon = el['lon'] || el.dig('center', 'lon')
      next unless lat && lon
      { 'type' => 'Feature', 'properties' => {},
        'geometry' => { 'type' => 'Point', 'coordinates' => [lon, lat] } }
    end
    File.write(ad_file, JSON.generate(
      { 'type' => 'FeatureCollection', 'features' => afeats }))
    log.("Addresses fetched: #{afeats.size}")
  end
  [fp_file, ad_file, cached]
end

# ----------------------------------------------------------------------------
# GENERIC HTTPS JSON GET (Nominatim, ArcGIS)
# ----------------------------------------------------------------------------
def http_get_json(url, tries = 3)
  uri = URI(url)
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |h|
    h.read_timeout = 180
    h.get(uri.request_uri, { 'User-Agent' => 'structure-hunter/1.0 (educational)' })
  end
  raise "#{uri.host} returned HTTP #{res.code}" unless res.code == '200'
  JSON.parse(res.body)
rescue => e
  raise "#{uri.host}: #{e.message}" if tries <= 1
  sleep 2
  http_get_json(url, tries - 1)
end

# ----------------------------------------------------------------------------
# COUNTY NAME -> BOUNDING BOX (Nominatim, the OSM geocoder)
# ----------------------------------------------------------------------------
def nominatim_box(county, state)
  county = county.sub(/\s+county\z/i, '')   # tolerate "Union County"
  q = URI.encode_www_form_component("#{county} County, #{state}, USA")
  d = http_get_json(
    "https://nominatim.openstreetmap.org/search?q=#{q}&format=json&limit=1")
  raise "Could not locate '#{county} County, #{state}' — check the spelling." if d.empty?
  s, n, w, e = d.first['boundingbox'].map(&:to_f)
  [w, s, e, n]   # our order: W, S, E, N
end

# ----------------------------------------------------------------------------
# ARCGIS REST LAYER FETCH (paged — services cap each response, so we walk
# through with resultOffset until a short page signals the end)
# ----------------------------------------------------------------------------
def arcgis_fetch(layer_url, box, log = NOOP_LOG, page = 2000)
  env = box.join(',')
  feats = []
  offset = 0
  loop do
    q = "geometry=#{env}&geometryType=esriGeometryEnvelope&inSR=4326&outSR=4326" \
        "&spatialRel=esriSpatialRelIntersects&where=1%3D1&outFields=*&f=geojson" \
        "&resultRecordCount=#{page}&resultOffset=#{offset}"
    d = http_get_json("#{layer_url}/query?#{q}")
    raise "ArcGIS service error: #{d['error']}" if d['error']
    batch = d['features'] || []
    feats.concat(batch)
    log.("  ...#{feats.size} features so far") if offset.positive?
    break if batch.size < page
    offset += page
  end
  feats
end

# ----------------------------------------------------------------------------
# NC ONEMAP (North Carolina only): statewide 911-grade address points and
# parcels with assessed values, via the state's public ArcGIS services.
# ----------------------------------------------------------------------------
NCOM_ADDR_LAYER   = 'https://services.nconemap.gov/secure/rest/services/AddressNC/NC1Map_Addresses/MapServer/0'
NCOM_PARCEL_LAYER = 'https://services.nconemap.gov/secure/rest/services/NC1Map_Parcels/MapServer/1'

def ncom_fetch(box, key, log = NOOP_LOG)
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  ad_file = File.join(CACHE_DIR, "ncom_addresses_#{key}.geojson")
  pc_file = File.join(CACHE_DIR, "ncom_parcels_#{key}.geojson")
  cached = File.exist?(ad_file) && File.exist?(pc_file)

  log.('NC OneMap data: using cache') if cached
  unless cached
    log.('Fetching NC OneMap address points (911-grade)...')
    addr = arcgis_fetch(NCOM_ADDR_LAYER, box, log)
    afeats = addr.filter_map do |f|
      g = f['geometry']
      next unless g && g['type'] == 'Point'
      { 'type' => 'Feature', 'properties' => {}, 'geometry' => g }
    end
    File.write(ad_file, JSON.generate(
      { 'type' => 'FeatureCollection', 'features' => afeats }))

    log.("Addresses fetched: #{afeats.size}")
    log.('Fetching NC OneMap parcels with assessed values...')
    parcels = arcgis_fetch(NCOM_PARCEL_LAYER, box, log)
    pfeats = parcels.filter_map do |f|
      g = f['geometry']
      next unless g && %w[Polygon MultiPolygon].include?(g['type'])
      pr = f['properties'] || {}
      improv = pr['improvval']
      # Data-quality guard: some NC counties publish only a TOTAL parcel
      # value (parval) and leave improvval/landval at 0. There, a zero
      # means "not split", NOT "no building" — treat as unknown (nil)
      # so the scorer reads it as 0.5 instead of a false 1.0.
      improv = nil if improv.to_f == 0 && pr['landval'].to_f == 0 &&
                      pr['parval'].to_f > 0
      { 'type' => 'Feature',
        'properties' => {
          'IMPROVVAL'  => improv,
          'parusecode' => pr['parusecode'], 'parusedesc' => pr['parusedesc'],
          'parusedsc2' => pr['parusedsc2'],
          'owntype'    => pr['owntype'],    'ownname'    => pr['ownname'],
          'gisacres'   => pr['gisacres'],   'siteadd'    => pr['siteadd'],
          'struct'     => pr['struct']
        },
        'geometry' => g }
    end
    File.write(pc_file, JSON.generate(
      { 'type' => 'FeatureCollection', 'features' => pfeats }))
    log.("Parcels fetched: #{pfeats.size}")
  end
  [ad_file, pc_file, cached]
end

# ----------------------------------------------------------------------------
# NATIONAL ADDRESS DATABASE (US DOT) — address points for most US states,
# hosted as a public ArcGIS service. Coverage: the large majority of states
# participate; a few have gaps. If a known-populated area returns zero,
# that state may not be a NAD partner — fall back to OSM mode or files.
# ----------------------------------------------------------------------------
NAD_LAYER = 'https://services.arcgis.com/xOi1kZaI0eWDREZv/arcgis/rest/services/Address_Points_from_National_Address_Database_view/FeatureServer/0'

def nad_fetch(box, key, log = NOOP_LOG)
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  ad_file = File.join(CACHE_DIR, "nad_addresses_#{key}.geojson")
  if File.exist?(ad_file)
    log.('NAD addresses: using cache')
    return [ad_file, true]
  end
  log.('Fetching National Address Database points...')
  addr = arcgis_fetch(NAD_LAYER, box, log)
  afeats = addr.filter_map do |f|
    g = f['geometry']
    next unless g && g['type'] == 'Point'
    { 'type' => 'Feature', 'properties' => {}, 'geometry' => g }
  end
  File.write(ad_file, JSON.generate(
    { 'type' => 'FeatureCollection', 'features' => afeats }))
  log.("Addresses fetched: #{afeats.size}")
  [ad_file, false]
end

# ----------------------------------------------------------------------------
# GENERIC COUNTY PARCELS from ANY pasted ArcGIS layer URL, with automatic
# improvement-field detection. County schemas differ wildly, so we inspect
# the first page of real data and look for a field whose name suggests
# "building/improvement value", then normalize everything to IMPROVVAL so
# the existing pipeline reads it unchanged.
# ----------------------------------------------------------------------------
def generic_parcels_fetch(layer_url, box, key, log = NOOP_LOG)
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  url_key = Digest::SHA1.hexdigest(layer_url)[0, 8]
  pc_file = File.join(CACHE_DIR, "parcels_#{url_key}_#{key}.geojson")
  if File.exist?(pc_file)
    log.('County parcels: using cache')
    return [pc_file, true]
  end
  log.('Fetching county parcels from the pasted ArcGIS service...')

  layer_url = layer_url.sub(%r{/query.*\z}, '').sub(%r{/\z}, '')
  feats = arcgis_fetch(layer_url, box, log)
  raise 'Parcel service returned no features for this area.' if feats.empty?

  keys = (feats.first['properties'] || {}).keys
  log.("Parcels fetched: #{feats.size} — detecting improvement field...")
  improv_field = keys.find { |k| k =~ /improv/i } ||
                 keys.find { |k| k =~ /(bldg|build).*(val|value)/i } ||
                 keys.find { |k| k =~ /\bimp.?val/i }
  log.(improv_field ? "Detected field: #{improv_field}" : 'No improvement field found — parcel layer scores neutral')
  land_field  = keys.find { |k| k =~ /land.?val/i }
  total_field = keys.find { |k| k =~ /(par|total|assessed).*(val|value)/i }

  pfeats = feats.filter_map do |f|
    g = f['geometry']
    next unless g && %w[Polygon MultiPolygon].include?(g['type'])
    pr = f['properties'] || {}
    improv = improv_field ? pr[improv_field] : nil
    # Unsplit-value guard, generalized: improvement 0 + land 0 + total > 0
    # means the county did not split values — unknown, not "no building".
    if improv.to_f == 0 && land_field && total_field &&
       pr[land_field].to_f == 0 && pr[total_field].to_f > 0
      improv = nil
    end
    { 'type' => 'Feature', 'properties' => { 'IMPROVVAL' => improv },
      'geometry' => g }
  end
  File.write(pc_file, JSON.generate(
    { 'type' => 'FeatureCollection', 'features' => pfeats }))
  [pc_file, false]
end

# ----------------------------------------------------------------------------
# USGS LIDAR FINDER — queries The National Map for LiDAR-derived elevation
# products covering the box and returns direct download links. National.
# ----------------------------------------------------------------------------
def tnm_lidar_products(box)
  bbox = box.join(',')
  out = []
  [['Digital Elevation Model (DEM) 1 meter', 'Bare-earth DEM (the DTM half of the nDSM)'],
   ['Lidar Point Cloud (LPC)', 'Raw point cloud (auto-LiDAR processes these itself)']].each do |ds, note|
    d = http_get_json("https://tnmaccess.nationalmap.gov/api/v1/products?bbox=#{bbox}"                       "&datasets=#{URI.encode_www_form_component(ds)}&max=6")
    (d['items'] || []).each do |i|
      out << { dataset: note, title: i['title'], url: i['downloadURL'] }
    end
  rescue => e
    out << { dataset: ds, title: "lookup failed: #{e.message}", url: nil }
  end
  out
end

# ----------------------------------------------------------------------------
# FULLY AUTOMATED LIDAR: box -> find USGS point-cloud tiles -> download ->
# grid into an nDSM (embedded Python/laspy script) -> feed the blob hunter.
# Needs: python3 with `pip install laspy lazrs numpy pyproj` (checked, with
# the exact command surfaced if missing). Small areas only — tiles are
# ~100 MB each, so we cap the tile count.
# ----------------------------------------------------------------------------
PY_GRIDDER = <<~'PYSRC'
#!/usr/bin/env python3
"""
laz_to_ndsm.py — turn raw USGS LiDAR point-cloud tiles into the ndsm.asc
height-above-ground grid that lidar_hunter consumes.

Usage: python3 laz_to_ndsm.py OUT.asc W S E N RES_M tile1.laz [tile2.laz ...]

How it works (all numpy, no GDAL/PDAL):
  DSM  = highest point in each grid cell (any return: rooftops, treetops)
  DTM  = mean of ground-classified points (class 2) per cell, holes filled
         by iterative neighbor averaging (under buildings there are no
         ground returns, so we interpolate the terrain beneath them)
  nDSM = DSM - DTM  (height above ground, meters)
Units are auto-detected from the tile's CRS (NC tiles are in US survey
FEET — both coordinates and heights — and are converted to meters).
"""
import warnings
warnings.filterwarnings('ignore')
import sys
import os
import zlib
import struct
import numpy as np


def shade_dtm(dtm_m, res_m):
    """Render a bare-earth terrain array to a 0..1 relief image.
    Reads REND_AZ, REND_Z, REND_MODE, REND_STRETCH from the environment so
    the same cached terrain can be re-lit without recomputing it."""
    import os
    az_deg = float(os.environ.get('REND_AZ', '315'))
    z = float(os.environ.get('REND_Z', '1'))
    mode = os.environ.get('REND_MODE', 'hillshade')
    stretch = os.environ.get('REND_STRETCH', '0') == '1'

    gy, gx = np.gradient(dtm_m, res_m)
    slope = np.arctan(z * np.hypot(gx, gy))
    aspect = np.arctan2(-gx, gy)
    alt = np.deg2rad(45.0)

    def one(az_d):
        a = np.deg2rad(az_d)
        return np.sin(alt) * np.cos(slope) + np.cos(alt) * np.sin(slope) * np.cos(a - aspect)

    if mode == 'svf':
        acc = np.zeros_like(slope)
        for ad in range(0, 360, 30):
            acc += np.clip(one(ad), 0, 1)
        img = acc / 12.0
    elif mode == 'multi':
        img = np.zeros_like(slope)
        for ad in (az_deg, az_deg + 90, az_deg + 180, az_deg + 270):
            img = np.maximum(img, np.clip(one(ad), 0, 1))
    else:
        img = np.clip(one(az_deg), 0, 1)

    if stretch:
        finite = img[np.isfinite(img)]
        if finite.size:
            lo, hi = np.percentile(finite, 2), np.percentile(finite, 98)
            if hi > lo:
                img = np.clip((img - lo) / (hi - lo), 0, 1)
    return img
import laspy
from pyproj import Transformer

def main():
    out_path = sys.argv[1]
    w, s, e, n = map(float, sys.argv[2:6])
    res_m = float(sys.argv[6])
    laz_paths = sys.argv[7:]

    # ---- global extent from HEADERS only (no point data loaded yet) -------
    crs = None
    xmin = ymin = float('inf')
    xmax = ymax = float('-inf')
    valid_paths = []
    for p in laz_paths:
        try:
            with laspy.open(p) as f:
                h = f.header
                if crs is None:
                    crs = h.parse_crs()
                xmin = min(xmin, h.x_min); ymin = min(ymin, h.y_min)
                xmax = max(xmax, h.x_max); ymax = max(ymax, h.y_max)
            valid_paths.append(p)
        except Exception as ex:
            print(f"  WARNING: skipping unreadable tile {p.split('/')[-1]}: {ex}", flush=True)
            try:
                os.remove(p)   # drop the corrupt cache file so it re-downloads next run
                print(f"  (removed corrupt cache file; it will re-download next run)", flush=True)
            except Exception:
                pass
    if not valid_paths:
        print("ERROR: no readable LiDAR tiles (all were corrupt or unreadable). "
              "Re-run to download fresh copies.", file=sys.stderr, flush=True)
        sys.exit(2)
    laz_paths = valid_paths

    unit = 1.0
    if crs is not None and crs.axis_info:
        unit = crs.axis_info[0].unit_conversion_factor
    print(f"  CRS: {crs.name if crs else 'unknown'} | native unit = {unit:.6f} m", flush=True)

    cell_native = res_m / unit
    nx = int((xmax - xmin) / cell_native) + 2
    ny = int((ymax - ymin) / cell_native) + 2
    print(f"  native grid: {nx} x {ny} cells at {res_m} m", flush=True)

    NEG = -1e9
    dsm = np.full(nx * ny, NEG)
    gsum = np.zeros(nx * ny)
    gcnt = np.zeros(nx * ny)

    # ---- accumulate ONE tile at a time --------------------------------------
    # Loading all tiles at once would need several GB; streaming bounds
    # memory to a single tile's points regardless of how many tiles.
    for p in laz_paths:
        try:
            las = laspy.read(p)
        except Exception as ex:
            print(f"  WARNING: skipping tile that failed to read fully "
                  f"{p.split('/')[-1]}: {ex}", flush=True)
            try:
                os.remove(p)
                print("  (removed corrupt cache file; it will re-download next run)", flush=True)
            except Exception:
                pass
            continue
        x = np.asarray(las.x); y = np.asarray(las.y)
        z = np.asarray(las.z); c = np.asarray(las.classification)
        print(f"  gridded {p.split('/')[-1]}: {len(z):,} points", flush=True)
        flat = ((y - ymin) / cell_native).astype(np.int64) * nx + \
               ((x - xmin) / cell_native).astype(np.int64)
        np.maximum.at(dsm, flat, z)          # highest return per cell
        gr = c == 2                          # ground-classified points
        np.add.at(gsum, flat[gr], z[gr])
        np.add.at(gcnt, flat[gr], 1)
        del las, x, y, z, c, flat, gr

    dsm[dsm == NEG] = np.nan
    dsm = dsm.reshape(ny, nx)
    with np.errstate(invalid='ignore'):
        dtm = (gsum / gcnt).reshape(ny, nx)  # nan where no ground points
    del gsum, gcnt

    # ---- fill DTM holes (terrain under buildings/dense canopy) ------------
    # iterative neighbor-mean fill: each pass, empty cells take the average
    # of their filled 4-neighbors. Terrain is smooth, so this is accurate
    # over building-sized gaps.
    for _ in range(60):
        nanmask = np.isnan(dtm)
        if not nanmask.any():
            break
        up    = np.vstack([dtm[1:, :], np.full((1, nx), np.nan)])
        down  = np.vstack([np.full((1, nx), np.nan), dtm[:-1, :]])
        left  = np.hstack([dtm[:, 1:], np.full((ny, 1), np.nan)])
        right = np.hstack([np.full((ny, 1), np.nan), dtm[:, :-1]])
        stack = np.stack([up, down, left, right])
        with np.errstate(all='ignore'):
            neigh = np.nanmean(stack, axis=0)
        dtm[nanmask] = neigh[nanmask]

    # ---- bare-earth hillshade (the "ghost structure" view) ----------------
    # Render settings come from environment variables so the SAME cached
    # terrain can be re-lit instantly without re-reading the point cloud:
    #   REND_AZ    sun direction in degrees (315 = NW default)
    #   REND_Z     vertical exaggeration (1-6)
    #   REND_MODE  'hillshade' | 'multi' (blend 4 directions) | 'svf' (sky-view)
    #   REND_STRETCH '1' to stretch contrast to full black-white range
    dtm_m = dtm * unit
    hill = shade_dtm(dtm_m, res_m)

    ndsm_native = (dsm - dtm) * unit            # heights now in METERS
    print(f"  nDSM built. height range: {np.nanmin(ndsm_native):.1f}"
          f" .. {np.nanmax(ndsm_native):.1f} m", flush=True)

    # ---- resample onto a lat/lng target grid covering the box -------------
    dlat = res_m / 111320.0
    cols = int(round((e - w) / dlat)); rows = int(round((n - s) / dlat))
    lon_c = w + (np.arange(cols) + 0.5) * dlat
    lat_c = n - (np.arange(rows) + 0.5) * dlat  # row 0 = north
    LON, LAT = np.meshgrid(lon_c, lat_c)

    # A compound CRS (horizontal + vertical datum, common in NC tiles) breaks
    # the 2D transform — every point lands outside the grid. Use only the
    # horizontal sub-CRS for the lat/lng -> native reprojection.
    crs_h = crs.sub_crs_list[0] if getattr(crs, 'is_compound', False) else crs
    tr = Transformer.from_crs("EPSG:4326", crs_h, always_xy=True)
    X, Y = tr.transform(LON, LAT)               # native coords of each cell
    jx = ((X - xmin) / cell_native).astype(np.int64)
    jy = ((Y - ymin) / cell_native).astype(np.int64)
    inside = (jx >= 0) & (jx < nx) & (jy >= 0) & (jy < ny)

    out = np.full((rows, cols), -9999.0)
    vals = ndsm_native[jy[inside], jx[inside]]
    tmp = out[inside]
    tmp[~np.isnan(vals)] = vals[~np.isnan(vals)]
    out[inside] = tmp

    with open(out_path, 'w') as f:
        f.write(f"ncols {cols}\nnrows {rows}\n")
        f.write(f"xllcorner {w}\nyllcorner {s}\n")
        f.write(f"cellsize {dlat}\nNODATA_value -9999\n")
        np.savetxt(f, out, fmt='%.2f')
    print(f"  wrote {out_path}: {cols} x {rows} cells", flush=True)

    # ---- render a PNG so humans can SEE the height field ------------------
    # bright = ground, darkening gray = taller (trees go dark),
    # orange tint = the 2.5-15 m building band the hunter searches.
    img = np.zeros((rows, cols, 3), np.uint8)
    nod = out <= -9000
    shade = (235 - np.clip(out, 0, 22) / 22.0 * 165).astype(np.uint8)
    img[..., 0] = shade
    img[..., 1] = shade
    img[..., 2] = shade
    band = (out >= 2.5) & (out <= 15) & ~nod
    img[..., 0][band] = 225
    img[..., 1][band] = (165 - np.clip(out[band] - 2.5, 0, 12.5) / 12.5 * 95
                         ).astype(np.uint8)
    img[..., 2][band] = 45
    img[nod] = (255, 255, 255)

    raw = b''.join(b'\x00' + img[i].tobytes() for i in range(rows))
    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c))
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', cols, rows, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 6))
           + chunk(b'IEND', b''))
    png_path = out_path[:-4] + '.png'
    with open(png_path, 'wb') as f:
        f.write(png)
    print(f"  wrote {png_path}", flush=True)

    # ---- second PNG: the bare-earth hillshade, resampled to the same grid --
    ground = np.full((rows, cols), 0.78)
    hvals = hill[jy[inside], jx[inside]]
    tmp2 = ground[inside]
    ok = ~np.isnan(hvals)
    tmp2[ok] = hvals[ok]
    ground[inside] = tmp2
    gimg = np.zeros((rows, cols, 3), np.uint8)
    gray = (40 + ground * 205).astype(np.uint8)
    gimg[..., 0] = gray
    gimg[..., 1] = gray
    gimg[..., 2] = gray
    raw2 = b''.join(b'\x00' + gimg[i].tobytes() for i in range(rows))
    png2 = (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', cols, rows, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw2, 6))
            + chunk(b'IEND', b''))
    ground_path = out_path[:-4] + '_ground.png'
    with open(ground_path, 'wb') as f:
        f.write(png2)
    print(f"  wrote {ground_path}", flush=True)

    # elevation PNG (bare-earth height, 8-bit) + scale meta, for LIVE
    # in-browser hillshading as the sliders move
    elev = np.full((rows, cols), np.nan)
    ev = dtm_m[jy[inside], jx[inside]]
    te = elev[inside]; ok2 = ~np.isnan(ev); te[ok2] = ev[ok2]; elev[inside] = te
    fin = elev[np.isfinite(elev)]
    if fin.size:
        elo, ehi = float(np.percentile(fin, 0.5)), float(np.percentile(fin, 99.5))
        if ehi <= elo: ehi = elo + 1.0
        q = np.where(np.isfinite(elev), np.clip((elev-elo)/(ehi-elo)*255,0,255), 0).astype(np.uint8)
        eimg = np.stack([q,q,q], axis=-1)
        rawe = b''.join(b'\x00' + eimg[i].tobytes() for i in range(rows))
        epng = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', cols, rows, 8,2,0,0,0))
                + chunk(b'IDAT', zlib.compress(rawe, 6)) + chunk(b'IEND', b''))
        with open(out_path[:-4] + '_elev.png', 'wb') as f: f.write(epng)
        with open(out_path[:-4] + '_elev.json', 'w') as f:
            f.write('{"m_per_level": %.6f, "cell_m": %.4f}' % ((ehi-elo)/255.0, res_m))
        print(f"  wrote {out_path[:-4]}_elev.png", flush=True)
    else:
        print("  ELEV SKIPPED: no finite ground-elevation values", flush=True)

if __name__ == '__main__':
    main()
PYSRC

PY_DEM = <<~'PYSRC2'
#!/usr/bin/env python3
"""
dem_window_hillshade.py OUT.png W S E N TIF_URL
Remote-windowed read of a USGS Cloud-Optimized GeoTIFF DEM (only the bytes
covering the box travel over the network), hillshaded to a PNG.
"""
import warnings; warnings.filterwarnings('ignore')
import os, sys, zlib, struct
os.environ.setdefault('CURL_CA_BUNDLE', '/etc/ssl/certs/ca-certificates.crt')
import numpy as np
import rasterio
from rasterio.windows import from_bounds, Window
from pyproj import Transformer

out_path = sys.argv[1]
w, s, e, n = map(float, sys.argv[2:6])
url = sys.argv[6]

with rasterio.open(url) as ds:
    print(f"  remote DEM: {ds.width} x {ds.height} cells, CRS {ds.crs}", flush=True)
    _c = ds.crs
    try:
        from pyproj import CRS as _PC
        _pc = _PC.from_user_input(_c)
        if getattr(_pc, 'is_compound', False):
            _c = _pc.sub_crs_list[0]
    except Exception:
        pass
    tr = Transformer.from_crs('EPSG:4326', _c, always_xy=True)
    xs, ys = tr.transform([w, e], [s, n])
    win = from_bounds(min(xs), min(ys), max(xs), max(ys), ds.transform)
    # clamp window to the dataset
    c0 = max(0, int(win.col_off)); r0 = max(0, int(win.row_off))
    c1 = min(ds.width, int(win.col_off + win.width))
    r1 = min(ds.height, int(win.row_off + win.height))
    if c1 - c0 < 10 or r1 - r0 < 10:
        sys.exit('box barely overlaps this DEM tile')
    dem = ds.read(1, window=Window(c0, r0, c1 - c0, r1 - r0)).astype('float64')
    res = ds.res[0]
print(f"  window: {dem.shape[1]} x {dem.shape[0]} cells at {res} m", flush=True)

import os
az_deg = float(os.environ.get('REND_AZ', '315'))
zf = float(os.environ.get('REND_Z', '1'))
mode = os.environ.get('REND_MODE', 'hillshade')
stretch = os.environ.get('REND_STRETCH', '0') == '1'
gy, gx = np.gradient(dem, res)
slope = np.arctan(zf * np.hypot(gx, gy))
aspect = np.arctan2(-gx, gy)
alt = np.deg2rad(45.0)
def _one(ad):
    a = np.deg2rad(ad)
    return np.sin(alt)*np.cos(slope) + np.cos(alt)*np.sin(slope)*np.cos(a-aspect)
if mode == 'svf':
    acc = np.zeros_like(slope)
    for ad in range(0, 360, 30):
        acc += np.clip(_one(ad), 0, 1)
    hill = acc / 12.0
elif mode == 'multi':
    hill = np.zeros_like(slope)
    for ad in (az_deg, az_deg+90, az_deg+180, az_deg+270):
        hill = np.maximum(hill, np.clip(_one(ad), 0, 1))
else:
    hill = np.clip(_one(az_deg), 0, 1)
if stretch:
    f = hill[np.isfinite(hill)]
    if f.size:
        lo, hi = np.percentile(f, 2), np.percentile(f, 98)
        if hi > lo:
            hill = np.clip((hill - lo) / (hi - lo), 0, 1)
gray = (40 + hill * 205).astype(np.uint8)
img = np.stack([gray]*3, axis=-1)
rows, cols = img.shape[:2]
raw = b''.join(b'\x00' + img[i].tobytes() for i in range(rows))
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', cols, rows, 8,2,0,0,0))
       + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
with open(out_path, 'wb') as f:
    f.write(png)
print(f"  wrote {out_path}", flush=True)

# elevation PNG + meta for live in-browser hillshading
efin = dem[np.isfinite(dem)]
if efin.size:
    elo, ehi = float(np.percentile(efin, 0.5)), float(np.percentile(efin, 99.5))
    if ehi <= elo: ehi = elo + 1.0
    q = np.clip((dem - elo) / (ehi - elo) * 255, 0, 255).astype(np.uint8)
    eimg = np.stack([q, q, q], axis=-1)
    rawe = b''.join(b'\x00' + eimg[i].tobytes() for i in range(eimg.shape[0]))
    epng = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', cols, rows, 8,2,0,0,0))
            + chunk(b'IDAT', zlib.compress(rawe, 6)) + chunk(b'IEND', b''))
    ep = out_path[:-4] + '_elev.png' if out_path.endswith('.png') else out_path + '_elev.png'
    with open(ep, 'wb') as f: f.write(epng)
    with open((out_path[:-4] if out_path.endswith('.png') else out_path) + '_elev.json', 'w') as f:
        f.write('{"m_per_level": %.6f, "cell_m": %.4f}' % ((ehi-elo)/255.0, res))
    print(f"  wrote {ep}", flush=True)
PYSRC2

DEM_GROUND_CAPTION = 'Bare-earth hillshade (from the modern USGS DEM — point clouds ' \
  'not yet published here, so no height map): vegetation and buildings stripped — ' \
  'look for rectangular pads, sharp depressions, and straight lines ' \
  '(foundations, leveled homesites, old roadbeds)'

def python_dem_ready?
  system('python3 -c "import rasterio, numpy, pyproj" 2>/dev/null')
end

def dem_ground_fallback(box, key, log)
  png = File.join(CACHE_DIR, "ndsm_#{key}_ground.png")
  epng = png.sub(/\.png\z/, '_elev.png')
  if File.exist?(png) && File.exist?(epng)
    log.('Bare-earth view: using cache')
    return png
  end
  unless python_dem_ready?
    raise 'DEM fallback needs one more package: pip install rasterio  (then run again)'
  end
  d = http_get_json('https://tnmaccess.nationalmap.gov/api/v1/products' \
                    "?bbox=#{box.join(',')}" \
                    "&datasets=#{URI.encode_www_form_component('Digital Elevation Model (DEM) 1 meter')}&max=10")
  items = (d['items'] || []).reject { |i| i['downloadURL'].to_s.include?('/legacy/') }
  items = items.select do |i|
    bb = i['boundingBox']
    bb && bb['minX'] < box[2] && bb['maxX'] > box[0] &&
      bb['minY'] < box[3] && bb['maxY'] > box[1]
  end
  raise 'No modern elevation data of any kind covers this box.' if items.empty?
  cx = (box[0] + box[2]) / 2.0
  cy = (box[1] + box[3]) / 2.0
  item = items.find { |i|
    bb = i['boundingBox']
    bb['minX'] <= cx && bb['maxX'] >= cx && bb['minY'] <= cy && bb['maxY'] >= cy
  } || items.first
  log.("Reading just the box's window from #{item['title']} remotely (no full download)...")
  script = File.join(CACHE_DIR, 'dem_window_hillshade.py')
  File.write(script, PY_DEM)
  IO.popen(['python3', script, png,
            box[0].to_s, box[1].to_s, box[2].to_s, box[3].to_s,
            item['downloadURL']], err: [:child, :out]) do |io|
    io.each_line { |line| log.(line.strip) unless line.strip.empty? }
  end
  raise 'DEM hillshade failed — see log lines above.' unless $?.success? && File.exist?(png)
  png
end

MAX_LIDAR_TILES = 6
LIDAR_RES_M = 1.0

def python_lidar_ready?
  system('python3 -c "import laspy, numpy, pyproj" 2>/dev/null')
end

def download_file(url, dest, log)
  return if File.exist?(dest)
  attempts = 3
  last_err = nil
  attempts.times do |attempt|
    uri = URI(url)
    tmp = "#{dest}.part"
    begin
      redirects = 0
      loop do
        done_ok = false
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |h|
          h.read_timeout = 600
          h.open_timeout = 60
          h.request(Net::HTTP::Get.new(uri)) do |res|
            if %w[301 302 303 307 308].include?(res.code)
              uri = URI(res['location']); redirects += 1
              raise 'too many redirects' if redirects > 5
              next  # re-request the new location
            end
            raise "HTTP #{res.code}" unless res.code == '200'
            total = res['content-length'].to_i   # 0 if server didn't say
            done = 0; last = 0
            File.open(tmp, 'wb') do |f|
              res.read_body do |chunk|
                f.write(chunk); done += chunk.bytesize
                if done - last > 20_000_000
                  log.("    ...#{(done / 1e6).round}#{total > 0 ? " / #{(total / 1e6).round}" : ''} MB")
                  last = done
                end
              end
            end
            # Verify completeness: if the server told us the size, the file on
            # disk must match it. A short file means the stream was cut off —
            # exactly what causes "failed to fill whole buffer" later.
            actual = File.size(tmp)
            if total > 0 && actual < total
              raise "incomplete download (#{actual} of #{total} bytes)"
            end
            if actual < 1024
              raise "download too small (#{actual} bytes) — likely an error page"
            end
            done_ok = true
          end
        end
        if done_ok
          File.rename(tmp, dest)   # atomic: only now is it a "good" cached tile
          return
        end
      end
    rescue => e
      last_err = e
      File.delete(tmp) if File.exist?(tmp)   # never leave a partial file behind
      if attempt < attempts - 1
        wait = 2 * (attempt + 1)
        log.("    download attempt #{attempt + 1} failed (#{e.message}); retrying in #{wait}s...")
        sleep wait
      end
    end
  end
  raise "download failed after #{attempts} attempts: #{last_err&.message}"
end

def auto_lidar(box, key, log)
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
  asc = File.join(CACHE_DIR, "ndsm_#{key}.asc")
  if File.exist?(asc) && File.exist?(asc.sub(/\.asc\z/, '_elev.png'))
    log.('LiDAR grid: using cache')
    return [asc, []]
  end

  unless python_lidar_ready?
    raise 'Auto-LiDAR needs Python packages. One-time setup: '           'pip install laspy lazrs numpy pyproj  (then run again)'
  end

  log.('Searching USGS for point-cloud tiles covering the box...')
  d = http_get_json('https://tnmaccess.nationalmap.gov/api/v1/products'                     "?bbox=#{box.join(',')}"                     "&datasets=#{URI.encode_www_form_component('Lidar Point Cloud (LPC)')}&max=40")
  all_items = d['items'] || []
  items = all_items.reject { |i| i['downloadURL'].to_s.include?('/legacy/') }
  legacy_only = items.empty? && !all_items.empty?
  items = items.select do |i|
    bb = i['boundingBox']
    bb && bb['minX'] < box[2] && bb['maxX'] > box[0] &&
      bb['minY'] < box[3] && bb['maxY'] > box[1]
  end.uniq { |i| i['downloadURL'] }
  if items.empty?
    log.(legacy_only ?
      'Only legacy (pre-2010) point clouds here — too coarse for building detection.' :
      'No point-cloud coverage found for this box.')
    png = dem_ground_fallback(box, key, log)
    return [nil, [[File.basename(png), DEM_GROUND_CAPTION]]]
  end
  # Several flight projects can overlap the same ground (states get re-flown).
  # Mixing projects in one grid is wrong — different vintages and sometimes
  # different coordinate systems — so keep the single best-covering project,
  # preferring the most tiles, then the newest year in the name.
  by_proj = items.group_by { |i| i['downloadURL'][%r{/Projects/([^/]+)/}, 1].to_s }
  if by_proj.size > 1
    proj, items = by_proj.max_by { |name, tiles| [tiles.size, name[/(20\d\d)/, 1].to_i] }
    log.("#{by_proj.size} flight projects overlap here — using #{proj} (#{items.size} tiles)")
  end
  if items.size > MAX_LIDAR_TILES
    cx = (box[0] + box[2]) / 2.0
    cy = (box[1] + box[3]) / 2.0
    items = items.sort_by do |i|
      bb = i['boundingBox']
      ((bb['minX'] + bb['maxX']) / 2.0 - cx)**2 + ((bb['minY'] + bb['maxY']) / 2.0 - cy)**2
    end.first(MAX_LIDAR_TILES)
    log.("Capping at the #{MAX_LIDAR_TILES} most central tiles — the window's outer edges will be blank")
  end

  # Download tiles concurrently — the slow part is network wait, not CPU, so
  # threads overlap the transfers. Sequential downloads of 4×100 MB tiles were
  # the main delay; parallel fetching cuts it roughly to the slowest single tile.
  items.each do |i|
    dest = File.join(CACHE_DIR, File.basename(URI(i['downloadURL']).path))
    log.("#{File.basename(dest)}: already cached") if File.exist?(dest)
  end
  to_fetch = items.reject { |i| File.exist?(File.join(CACHE_DIR, File.basename(URI(i['downloadURL']).path))) }
  unless to_fetch.empty?
    total_mb = to_fetch.sum { |i| (i['sizeInBytes'].to_f / 1e6).round }
    log.("Downloading #{to_fetch.size} tile(s) in parallel (~#{total_mb} MB total)...")
    errors = []
    threads = to_fetch.map do |i|
      Thread.new do
        dest = File.join(CACHE_DIR, File.basename(URI(i['downloadURL']).path))
        begin
          download_file(i['downloadURL'], dest, ->(_m) {})   # quiet per-thread
          log.("  finished #{File.basename(dest)}")
        rescue => e
          errors << "#{File.basename(dest)}: #{e.message}"
        end
      end
    end
    threads.each(&:join)
    raise "tile download failed — #{errors.join('; ')}" unless errors.empty?
    log.('All tiles downloaded.')
  end
  laz_paths = items.map { |i| File.join(CACHE_DIR, File.basename(URI(i['downloadURL']).path)) }

  script = File.join(CACHE_DIR, 'laz_to_ndsm.py')
  File.write(script, PY_GRIDDER)
  log.('Gridding point cloud into height-above-ground (DSM - DTM)...')
  IO.popen(['python3', script, asc,
            box[0].to_s, box[1].to_s, box[2].to_s, box[3].to_s,
            LIDAR_RES_M.to_s, *laz_paths], err: [:child, :out]) do |io|
    io.each_line { |line| log.(line.strip) unless line.strip.empty? }
  end
  raise 'LiDAR gridding failed — the point-cloud tiles could not be read (see ' \
        'log above). Corrupt tiles have been cleared; running the scan again will ' \
        're-download them.' unless $?.success? && File.exist?(asc)
  [asc, []]
end

# ============================================================================
# VECTOR PIPELINE (parameterized by cfg from the form)
# ============================================================================
def calibrate_only(cfg, log = NOOP_LOG)
  log.('Pre-calibration: loading address points...')
  addresses = load_addresses(cfg[:ad_path], cfg[:box])
  raise 'No address points found in this area. If using OSM auto-fetch: rural OSM ' \
        'address coverage is often sparse — try a county address file in the manual ' \
        'fields instead.' if addresses.empty?
  log.("Addresses loaded: #{addresses.size}")
  mean_lat = addresses.sum { |_, t| t } / addresses.size
  mlon = m_lon(mean_lat)
  log.('Loading building footprints...')
  rings = load_footprints(cfg[:fp_path], cfg[:box], mlon)
  log.("Footprints loaded: #{rings.size}")

  # Index addresses with a generous cell so we can measure each building's
  # nearest address out to a useful distance, not just within the threshold.
  probe = 75.0
  aindex = GridIndex.new(probe, mlon)
  addresses.each { |g, t| aindex.insert(g, t) }

  log.('Measuring nearest-address distance for every building...')
  dists = []
  rings.each do |r|
    area, lng, lat = ring_area_centroid(r, mlon)
    next if area < cfg[:min_area] || area > cfg[:max_area]
    best = Float::INFINITY
    # search outward in rings up to ~5 cells (≈375 m) for a robust nearest
    (0..5).each do |ring_n|
      aindex.each_near(lng, lat, ring_n) do |g, t|
        d = dist_sq(lng, lat, g, t, mlon); best = d if d < best
      end
      break if best.finite? && best <= ((ring_n + 1) * probe)**2
    end
    dists << Math.sqrt(best) if best.finite?
  end
  raise 'Not enough buildings with a measurable nearby address to calibrate ' \
        '(need at least 5). Try a larger area or a denser address source.' if dists.size < 5

  s_all = dists.sort
  # The full distribution includes buildings with no real nearby address (common
  # where address data is sparse). For the THRESHOLD recommendation, look only at
  # buildings whose nearest address is plausibly their own — within 100 m — since
  # those are the ones that are actually registered. The histogram still shows the
  # whole picture.
  registered = s_all.select { |d| d <= 100.0 }
  basis = registered.size >= 5 ? registered : s_all
  pct = ->(arr, p) { arr[[(p * (arr.size - 1) / 100.0).round, arr.size - 1].min] }
  # histogram over the full set, 10 m bands up to 100 m, then 100 m+
  bands = Array.new(11, 0)
  s_all.each { |d| bands[[(d / 10).floor, 10].min] += 1 }
  log.("Pre-calibration complete: #{s_all.size} buildings measured " \
       "(#{registered.size} with an address within 100 m).")
  {
    n: s_all.size, n_registered: registered.size,
    p50: pct.call(basis, 50).round(1), p90: pct.call(basis, 90).round(1),
    p95: pct.call(basis, 95).round(1), p99: pct.call(basis, 99).round(1),
    max: basis.last.round(1), threshold: cfg[:threshold].to_i, bands: bands
  }
end

def run_vector(cfg, log = NOOP_LOG)
  log.('Loading address points...')
  addresses = load_addresses(cfg[:ad_path], cfg[:box])
  raise 'No address points found in this area. If using OSM auto-fetch: rural OSM ' \
        'address coverage is often sparse — try a county address file in the manual ' \
        'fields instead. If using files: check the box coordinates and the file.' if addresses.empty?

  log.("Addresses loaded: #{addresses.size}")
  mean_lat = addresses.sum { |_, t| t } / addresses.size
  mlon = m_lon(mean_lat)
  log.('Loading building footprints...')
  rings = load_footprints(cfg[:fp_path], cfg[:box], mlon)
  log.("Footprints loaded: #{rings.size}")

  pindex = nil
  if cfg[:pc_path] && !cfg[:pc_path].empty?
    log.('Loading parcels...')
    parcels = load_parcels(cfg[:pc_path], cfg[:imp_field], cfg[:box])
    log.("Parcels loaded: #{parcels.size}")
    pindex = ParcelIndex.new(200.0, mlon)
    parcels.each { |r, imp| pindex.insert(r, imp) }
  end

  zones = cfg[:zones]   # OSM industrial/railway zones, if fetched
  dismissed = load_dismissed

  aindex = GridIndex.new(cfg[:threshold], mlon)
  addresses.each { |g, t| aindex.insert(g, t) }

  log.('Computing centroids and spatial indexes...')
  fps = rings.map { |r| ac = ring_area_centroid(r, mlon); [ac[0], ac[1], ac[2], r] }
  dindex_cell = 200.0
  dindex = GridIndex.new(dindex_cell, mlon)
  fps.each { |_, g, t| dindex.insert(g, t) }

  th_sq = cfg[:threshold]**2
  den_sq = (cfg[:neighbor_radius] || 200.0)**2
  out = []
  skipped = 0
  reg_dists = []   # nearest-address distance (m) for buildings judged registered

  fps.each do |area, lng, lat, ring|
    if area < cfg[:min_area] || area > cfg[:max_area]
      skipped += 1; next
    end

    best = Float::INFINITY
    aindex.each_near(lng, lat) { |g, t| d = dist_sq(lng, lat, g, t, mlon); best = d if d < best }
    # widen the search a couple rings so "registered" distances aren't all
    # clipped at the grid cell — gives an honest distribution for calibration
    if best <= th_sq
      reg_dists << Math.sqrt(best) if best.finite?
      next
    end

    nearest = best
    max_r = (cfg[:max_search] / cfg[:threshold]).ceil
    (2..max_r).each do |r|
      aindex.each_near(lng, lat, r) { |g, t| d = dist_sq(lng, lat, g, t, mlon); nearest = d if d < nearest }
      break if nearest <= (r * cfg[:threshold])**2
    end
    nearest_m = nearest == Float::INFINITY ? nil : Math.sqrt(nearest)

    pr = pindex&.lookup(lng, lat)
    pctx = pr && pr[1].is_a?(Hash) ? pr[1] : nil
    imp_val = if pctx then pctx[:imp]
              elsif pr then (pr[1].is_a?(Numeric) ? pr[1] : nil)
              else :no_parcel end
    improvement = pr.nil? ? 'no_parcel' : (imp_val.nil? ? 'field_missing' : imp_val.round)
    use_flag = parcel_use_flag(pctx)   # non-residential use description, or nil

    nbrs = 0
    dindex.each_near(lng, lat) do |g, t|
      d = dist_sq(lng, lat, g, t, mlon)
      nbrs += 1 if d <= den_sq && d > 0.25
    end
    next if cfg[:max_neighbors] && nbrs > cfg[:max_neighbors]

    # Structure-clearance filter: nearest OTHER building footprint must be at
    # least this far away. Unlike the address-based neighbor count, this checks
    # physical structures on the ground (registered or not) — for finding
    # targets with nothing built around them.
    if cfg[:clear_dist]
      clear_sq = cfg[:clear_dist]**2
      rings_out = (cfg[:clear_dist] / dindex_cell).ceil + 1
      nearest_struct = Float::INFINITY
      dindex.each_near(lng, lat, rings_out) do |g, t|
        d = dist_sq(lng, lat, g, t, mlon)
        nearest_struct = d if d > 0.25 && d < nearest_struct
      end
      next if nearest_struct < clear_sq
    end

    # Building-cluster signal: how many other footprints sit within the cluster
    # radius. A lone structure scores ~0; an industrial park or rail yard is
    # surrounded by many. Used to flag (and optionally reject) clustered sites.
    crad = cfg[:cluster_radius] || 150.0
    crad_sq = crad**2
    crings = (crad / dindex_cell).ceil + 1
    cluster_n = 0
    dindex.each_near(lng, lat, crings) do |g, t|
      d = dist_sq(lng, lat, g, t, mlon)
      cluster_n += 1 if d <= crad_sq && d > 0.25
    end
    next if cfg[:max_cluster] && cluster_n > cfg[:max_cluster]

    # OSM industrial / railway zone membership (if those layers were fetched)
    in_zone = zone_hit(zones, lng, lat) if zones
    next if cfg[:reject_zones] && in_zone

    s_iso = nearest_m ? [nearest_m / cfg[:max_search], 1.0].min : 1.0
    s_par = imp_val.is_a?(Numeric) ? (imp_val <= 0 ? 1.0 : 0.0) : 0.5
    s_den = [(10 - nbrs) / 10.0, 0.0].max
    score = 0.40 * s_iso + 0.35 * s_par + 0.25 * s_den
    # context penalties: industrial use, dense cluster, or zone membership all
    # make a "hidden structure" far less likely — push these down the ranking
    score -= 0.25 if use_flag
    score -= 0.20 if in_zone
    score -= [cluster_n * 0.02, 0.20].min
    score = 0.0 if score < 0


    ring_m = ring.map { |g, t| [(g - ring[0][0]) * mlon, (t - ring[0][1]) * M_LAT] }
    perim = 0.0
    ring_m.each_cons(2) { |(x1, y1), (x2, y2)| perim += Math.hypot(x2 - x1, y2 - y1) }
    shp = shape_descriptors(ring_m, area, perim)
    tank = lone_circle?(shp)
    cls = classify_footprint(ring_m, area, perim)
    glyph = shape_glyph_svg(ring_m, cls[:long], cls[:short])

    # Build a short "accuracy notes" string summarizing context signals so the
    # user can judge each hit. Positive signals (isolated, no improvement value)
    # and warning signals (industrial use, cluster, zone) both surface here.
    notes = []
    notes << "use: #{use_flag}" if use_flag
    notes << "in #{in_zone}" if in_zone
    notes << "#{cluster_n} bldgs within #{crad.to_i}m" if cluster_n >= 3
    notes << 'big parcel' if pctx && pctx[:acres].to_f >= 20
    notes << "owner: #{pctx[:owner_type]}" if pctx && !pctx[:owner_type].empty? &&
                                              pctx[:owner_type].upcase !~ /\A(PRIV|INDIV|PERSON)/
    flagged = !(use_flag.nil? && in_zone.nil?) || cluster_n >= 5
    dm = dismissed_match(dismissed, lat, lng)

    out << { lat: lat.round(6), lng: lng.round(6), area_m2: area.round(1),
             nearest_address_m: nearest_m ? nearest_m.round(1) : ">#{cfg[:max_search].to_i}",
             parcel_improvement: improvement, neighbors_200m: nbrs,
             cluster_n: cluster_n,
             use_desc: (pctx && !pctx[:use_desc].empty? ? pctx[:use_desc] : ''),
             site_addr: (pctx ? pctx[:site_addr] : ''),
             notes: notes.join(' · '),
             flagged: flagged,
             dismissed: !dm.nil?, dismiss_reason: (dm ? dm[:reason].to_s : ''),
             shape: shp ? "circ #{shp[:circularity].round(2)}" : 'n/a',
             shape_class: cls[:shape], likely_type: cls[:type],
             dim: (cls[:long] && cls[:short] ? "#{cls[:long].round}×#{cls[:short].round}m" : ''),
             glyph: glyph,
             tank: tank,
             score: score.round(3) }
  end

  out.reject! { |c| c[:tank] } if cfg[:hide_tanks]
  out.reject! { |c| c[:dismissed] } if cfg[:hide_dismissed]
  if cfg[:max_neighbors]
    log.("Neighbor filter: keeping only candidates with <= #{cfg[:max_neighbors]} " \
         "neighbor(s) within #{cfg[:neighbor_radius].to_i}m")
  end
  if cfg[:clear_dist]
    log.("Clearance filter: keeping only targets with no other building " \
         "within #{cfg[:clear_dist].to_i}m")
  end
  ndis = out.count { |c| c[:dismissed] }
  log.("Skipping #{ndis} dismissed location#{ndis == 1 ? '' : 's'}") if ndis > 0
  log.("Join complete: #{out.size} candidates")
  out.sort_by! { |c| [c[:dismissed] ? 1 : 0, c[:tank] ? 1 : 0, -c[:score]] }
  write_outputs(out, 'candidates')

  # Calibration: where do registered buildings' nearest-address distances fall?
  # This shows the natural cutoff for THIS dataset/area so the threshold can be
  # set from evidence instead of guesswork.
  calib = nil
  if reg_dists.size >= 5
    s = reg_dists.sort
    pct = ->(p) { s[[(p * (s.size - 1) / 100.0).round, s.size - 1].min] }
    calib = { n: s.size, p50: pct.call(50).round(1), p90: pct.call(90).round(1),
              p95: pct.call(95).round(1), p99: pct.call(99).round(1),
              max: s.last.round(1), threshold: cfg[:threshold].to_i }
    log.("Calibration: of #{s.size} registered buildings, half are within " \
         "#{calib[:p50].round}m of their address, 90% within #{calib[:p90].round}m, " \
         "95% within #{calib[:p95].round}m (current threshold #{calib[:threshold]}m)")
  end
  { candidates: out, footprints: fps, addresses: addresses.size, skipped: skipped, calib: calib }
end

# ============================================================================
# LIDAR PIPELINE
# ============================================================================
def load_asc(path)
  header = {}; values = []
  File.foreach(path) do |line|
    parts = line.split
    next if parts.empty?
    if parts[0] =~ /^[a-zA-Z]/
      header[parts[0].downcase] = parts[1].to_f
    else
      values.concat(parts.map(&:to_f))
    end
  end
  { ncols: header['ncols'].to_i, nrows: header['nrows'].to_i,
    xll: header['xllcorner'], yll: header['yllcorner'],
    cell: header['cellsize'], nodata: header['nodata_value'] || -9999.0,
    data: values }
end

def run_lidar(cfg, suppress, log = NOOP_LOG)
  log.('LiDAR: reading height grid...')
  grid = load_asc(cfg[:ndsm_path])
  log.("Grid: #{grid[:ncols]}x#{grid[:nrows]} cells — detecting blobs...")
  ncols, nrows = grid[:ncols], grid[:nrows]
  data, nodata = grid[:data], grid[:nodata]
  lo, hi = cfg[:l_minh], cfg[:l_maxh]

  mid_lat = grid[:yll] + nrows * grid[:cell] / 2.0
  mlon = m_lon(mid_lat)
  cell_area = (grid[:cell] * M_LAT) * (grid[:cell] * mlon)

  visited = Array.new(ncols * nrows, false)
  dismissed = load_dismissed
  blobs = []
  (0...nrows).each do |row|
    (0...ncols).each do |col|
      idx = row * ncols + col
      next if visited[idx]
      h = data[idx]
      next if h == nodata || h < lo || h > hi
      blob = []; queue = [idx]; visited[idx] = true
      until queue.empty?
        i = queue.shift
        blob << i
        r, c = i.divmod(ncols)
        [[r - 1, c], [r + 1, c], [r, c - 1], [r, c + 1]].each do |nr, nc|
          next if nr < 0 || nr >= nrows || nc < 0 || nc >= ncols
          ni = nr * ncols + nc
          next if visited[ni]
          nh = data[ni]
          next if nh == nodata || nh < lo || nh > hi
          visited[ni] = true; queue << ni
        end
      end
      blobs << blob
    end
  end

  sup_sq = 30.0**2
  out = []
  blobs.each do |blob|
    heights = blob.map { |i| data[i] }
    mean = heights.sum / heights.size
    rough = Math.sqrt(heights.sum { |h| (h - mean)**2 } / heights.size)
    area = blob.size * cell_area
    next if area < cfg[:l_min_area] || area > cfg[:l_max_area] || rough > cfg[:l_rough]

    rc = blob.map { |i| i.divmod(ncols) }
    crow = rc.sum(&:first).to_f / blob.size
    ccol = rc.sum(&:last).to_f / blob.size
    lng = grid[:xll] + (ccol + 0.5) * grid[:cell]
    lat = grid[:yll] + (nrows - crow - 0.5) * grid[:cell]

    next if suppress.any? { |_, sg, st|
      dist_sq(lng, lat, sg, st, mlon) <= sup_sq }

    # shape: cell centroids as points (in meters), perimeter from boundary edges
    cellw = grid[:cell] * mlon; cellh = grid[:cell] * M_LAT
    cset = {}; blob.each { |i| r, c = i.divmod(ncols); cset[[r, c]] = true }
    pts_m = blob.map { |i| r, c = i.divmod(ncols); [c * cellw, r * cellh] }
    perim = 0.0
    cset.each_key do |r, c|
      [[r - 1, c, cellw], [r + 1, c, cellw], [r, c - 1, cellh], [r, c + 1, cellh]].each do |nr, nc, edge|
        perim += edge unless cset[[nr, nc]]   # exposed cell edge = boundary
      end
    end
    shp = shape_descriptors(pts_m, area, perim)
    tank = lone_circle?(shp)
    dm = dismissed_match(dismissed, lat, lng)
    cls = classify_footprint(pts_m, area, perim)
    # refine the type with roof form from the height data, and keep the roof label
    refined_type, roof = refine_type_with_roof(cls, area, mean, rough)
    # LiDAR blobs are a set of grid cells, not an ordered ring — draw the convex
    # hull outline so the glyph still reads as a clean shape.
    glyph = shape_glyph_svg(convex_hull(pts_m), cls[:long], cls[:short])

    out << { lat: lat.round(6), lng: lng.round(6), area_m2: area.round(1),
             mean_height_m: mean.round(2), roughness_m: rough.round(2),
             shape: shp ? "circ #{shp[:circularity].round(2)}" : 'n/a',
             shape_class: cls[:shape], likely_type: refined_type, roof: roof,
             dim: (cls[:long] && cls[:short] ? "#{cls[:long].round}×#{cls[:short].round}m" : ''),
             glyph: glyph,
             dismissed: !dm.nil?, dismiss_reason: (dm ? dm[:reason].to_s : ''),
             tank: tank }
  end
  out.reject! { |c| c[:tank] } if cfg[:hide_tanks]
  out.reject! { |c| c[:dismissed] } if cfg[:hide_dismissed]
  log.("LiDAR complete: #{out.size} flat elevated blobs unknown to footprints")
  out.sort_by! { |c| [c[:dismissed] ? 1 : 0, c[:tank] ? 1 : 0, c[:roughness_m]] }
  write_outputs(out, 'lidar_candidates')
  out
end

# ============================================================================
# OUTPUT FILES (same artifacts as the CLI tools)
# ============================================================================
def write_outputs(rows, base)
  return if rows.empty?
  CSV.open("#{base}.csv", 'w') do |csv|
    csv << rows.first.keys.map(&:to_s) + ['maps_link']
    rows.each { |r| csv << r.values + ["https://maps.google.com/?q=#{r[:lat]},#{r[:lng]}"] }
  end
  fc = { 'type' => 'FeatureCollection', 'features' => rows.map { |r|
    { 'type' => 'Feature',
      'geometry' => { 'type' => 'Point', 'coordinates' => [r[:lng], r[:lat]] },
      'properties' => r.reject { |k, _| k == :lng || k == :lat } } } }
  File.write("#{base}.geojson", JSON.pretty_generate(fc))
end

# ============================================================================
# HTML — surveyor's console
# ============================================================================
def esc(s) = s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')

def field(label, name, value, hint = nil, width = '100%')
  <<~H
    <label class="f" style="width:#{width}">
      <span class="lbl">#{label}</span>
      <input name="#{name}" value="#{esc(value)}">
      #{hint ? "<span class=\"hint\">#{hint}</span>" : ''}
    </label>
  H
end



PICKER_JS = <<~'JS'
  <script>
  (function () {
    // About + how-to panel toggles (only one open at a time)
    var panels = [['aboutbtn','aboutpanel','About this instrument','Hide about'],
                  ['howsearchbtn','howsearchpanel','How to: search & tune','Hide search guide'],
                  ['howimagebtn','howimagepanel','How to: read the imagery','Hide imagery guide']];
    panels.forEach(function (cfg) {
      var b = document.getElementById(cfg[0]), p = document.getElementById(cfg[1]);
      if (!b || !p) return;
      b.addEventListener('click', function () {
        var open = p.style.display !== 'none';
        // close all first
        panels.forEach(function (o) {
          var ob = document.getElementById(o[0]), op = document.getElementById(o[1]);
          if (op) op.style.display = 'none';
          if (ob) ob.textContent = o[2];
        });
        if (!open) {
          p.style.display = 'block';
          b.textContent = cfg[3];
          p.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      });
    });
    var F = {};
    ['min_lon', 'min_lat', 'max_lon', 'max_lat'].forEach(function (n) {
      F[n] = document.querySelector('input[name="' + n + '"]');
    });
    function fillBox(lons, lats) {
      F.min_lon.value = Math.min.apply(null, lons).toFixed(6);
      F.max_lon.value = Math.max.apply(null, lons).toFixed(6);
      F.min_lat.value = Math.min.apply(null, lats).toFixed(6);
      F.max_lat.value = Math.max.apply(null, lats).toFixed(6);
    }

    // ---- paste box: digest raw coordinate pairs or KML ----
    var pbtn = document.getElementById('pastebtn');
    if (pbtn) pbtn.addEventListener('click', function () {
      var txt = document.getElementById('pastebox').value;
      var pairs = txt.match(/-?\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}/g) || [];
      var lons = [], lats = [];
      pairs.forEach(function (p) {
        var a = parseFloat(p.split(',')[0]), b = parseFloat(p.split(',')[1]);
        var lon, lat;
        if (Math.abs(a) > 90) { lon = a; lat = b; }
        else if (Math.abs(b) > 90) { lon = b; lat = a; }
        else if (a < 0 && b > 0) { lon = a; lat = b; }   // US: lon negative
        else if (b < 0 && a > 0) { lon = b; lat = a; }
        else { lon = a; lat = b; }                        // KML order fallback
        lons.push(lon); lats.push(lat);
      });
      if (lons.length >= 2) fillBox(lons, lats);
      else alert('Need at least two coordinate pairs (corners).');
    });

    // ---- pick-on-map: two taps make the box ----
    var btn = document.getElementById('pickbtn');
    var mapdiv = document.getElementById('pickmap');
    var findrow = document.getElementById('findrow');
    var map = null, clicks = [], rect = null, dot = null;
    if (btn) btn.addEventListener('click', function () {
      var show = mapdiv.style.display !== 'block';
      mapdiv.style.display = show ? 'block' : 'none';
      if (findrow) findrow.style.display = show ? 'flex' : 'none';
      btn.textContent = show ? 'Hide map' : 'Pick area on map';
      if (!show || map || typeof L === 'undefined') { if (map) map.invalidateSize(); return; }
      var clat = parseFloat(F.min_lat.value) || 35.4;
      var clng = parseFloat(F.min_lon.value) || -81.9;
      var z = F.min_lat.value ? 12 : 7;
      map = L.map('pickmap').setView([clat, clng], z);
      L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        { maxZoom: 19, attribution: 'Imagery © Esri' }).addTo(map);
      map.on('click', function (e) {
        clicks.push(e.latlng);
        if (clicks.length === 1) {
          if (rect) { map.removeLayer(rect); rect = null; }
          if (dot) map.removeLayer(dot);
          dot = L.circleMarker(e.latlng, { radius: 5, color: '#D4551F' }).addTo(map);
        } else {
          var a = clicks[0], b = clicks[1];
          clicks = [];
          if (dot) { map.removeLayer(dot); dot = null; }
          rect = L.rectangle([[a.lat, a.lng], [b.lat, b.lng]],
            { color: '#D4551F', weight: 2, fillOpacity: 0.08 }).addTo(map);
          fillBox([a.lng, b.lng], [a.lat, b.lat]);
        }
      });
    });

    // ---- jump the map to a typed place (zip / address / county, state) ----
    function doFind() {
      var q = (document.getElementById('findbox').value || '').trim();
      if (!q || !map) return;
      var fb = document.getElementById('findbtn');
      fb.textContent = '...';
      fetch('https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=us&q='
            + encodeURIComponent(q))
        .then(function (r) { return r.json(); })
        .then(function (d) {
          fb.textContent = 'Go';
          if (!d.length) { alert('Could not find "' + q + '".'); return; }
          var hit = d[0];
          if (hit.boundingbox) {
            var bb = hit.boundingbox.map(parseFloat);   // [s, n, w, e]
            map.fitBounds([[bb[0], bb[2]], [bb[1], bb[3]]]);
          } else {
            map.setView([parseFloat(hit.lat), parseFloat(hit.lon)], 15);
          }
        })
        .catch(function () { fb.textContent = 'Go'; alert('Lookup failed — try again.'); });
    }
    var findbtn = document.getElementById('findbtn');
    if (findbtn) findbtn.addEventListener('click', doFind);
    var findbox = document.getElementById('findbox');
    if (findbox) findbox.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); doFind(); }
    });
  })();

  // ---- Dismiss / restore candidates (persist across runs) ----
  function postForm(url, data) {
    var body = Object.keys(data).map(function (k) {
      return encodeURIComponent(k) + '=' + encodeURIComponent(data[k]);
    }).join('&');
    return fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body
    });
  }
  function rowFade(row, on) {
    row.querySelectorAll('td').forEach(function (td) {
      if (!td.classList.contains('actcell')) td.style.opacity = on ? '.42' : '';
    });
  }
  window.dismissCand = function (btn) {
    var row = btn.closest('tr');
    var lat = row.getAttribute('data-lat'), lng = row.getAttribute('data-lng');
    var reason = window.prompt(
      'Skip this location on future scans.\nOptional note (e.g. "occupied", "active business") — or leave blank:', '');
    if (reason === null) return; // cancelled
    btn.disabled = true; btn.textContent = '…';
    postForm('/dismiss', { lat: lat, lng: lng, reason: reason }).then(function () {
      row.classList.add('disrow'); rowFade(row, true);
      var notes = row.querySelector('.notes-cell');
      if (notes) notes.innerHTML = "<span class='distag'>dismissed" +
        (reason ? ': ' + reason.replace(/[<>&]/g, '') : '') + "</span>";
      btn.outerHTML = "<button type='button' class='dismiss-btn restore' onclick='undismiss(this)'>restore</button>";
    }).catch(function () { btn.disabled = false; btn.textContent = 'dismiss'; });
  };
  window.undismiss = function (btn) {
    var row = btn.closest('tr');
    var lat = row.getAttribute('data-lat'), lng = row.getAttribute('data-lng');
    btn.disabled = true; btn.textContent = '…';
    postForm('/undismiss', { lat: lat, lng: lng }).then(function () {
      row.classList.remove('disrow'); rowFade(row, false);
      btn.outerHTML = "<button type='button' class='dismiss-btn' onclick='dismissCand(this)'>dismiss</button>";
    }).catch(function () { btn.disabled = false; btn.textContent = 'restore'; });
  };
  window.undismissPanel = function (btn) {
    var row = btn.closest('tr');
    var lat = row.getAttribute('data-lat'), lng = row.getAttribute('data-lng');
    btn.disabled = true; btn.textContent = '…';
    postForm('/undismiss', { lat: lat, lng: lng }).then(function () {
      row.parentNode.removeChild(row);
    }).catch(function () { btn.disabled = false; btn.textContent = 'restore'; });
  };
  window.clearExamined = function (btn) {
    btn.disabled = true; btn.textContent = '…';
    postForm('/examined/clear', {}).then(function () {
      btn.closest('fieldset').style.opacity = '.5';
      btn.textContent = 'sweep reset \u2713';
    }).catch(function () { btn.disabled = false; btn.textContent = 'Reset sweep progress'; });
  };
  </script>
JS

VIEWER_JS = <<~'JS'
  <script>
  document.querySelectorAll('.ndsmwrap').forEach(function (w) {
    var pane = w.querySelector('.ndsmpane');
    var img = w.querySelector('img');
    var mks = w.querySelectorAll('.mk');
    var scale = 1, tx = 0, ty = 0;
    var ptrs = {}, lastDist = 0, moved = 0, sx = 0, sy = 0, stx = 0, sty = 0;
    var lastTap = 0;
    function apply() {
      // clamp: the image edge may never cross the frame edge inward
      var maxX = 0, minX = w.clientWidth * (1 - scale);
      var maxY = 0, minY = img.clientHeight * (1 - scale);
      tx = Math.min(maxX, Math.max(minX, tx));
      ty = Math.min(maxY, Math.max(minY, ty));
      pane.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
      var inv = 'scale(' + (1 / scale) + ')';
      mks.forEach(function (m) { m.style.transform = inv; });
    }
    function clampZoom(z) { return Math.min(Math.max(z, 1), 25); }
    function zoomAt(px, py, ns) {
      ns = clampZoom(ns);
      var ix = (px - tx) / scale, iy = (py - ty) / scale;
      scale = ns; tx = px - ix * ns; ty = py - iy * ns;
      if (scale === 1) { tx = 0; ty = 0; }
      apply();
    }
    w.addEventListener('wheel', function (e) {
      e.preventDefault();
      var r = w.getBoundingClientRect();
      zoomAt(e.clientX - r.left, e.clientY - r.top, scale * (e.deltaY < 0 ? 1.3 : 0.77));
    }, { passive: false });
    // fine zoom buttons in the relief bar (zoom toward the image center)
    (function () {
      var box = w.closest('.ndsmbox');
      if (!box) return;
      var zin = box.querySelector('.r-zin'), zout = box.querySelector('.r-zout');
      function step(factor) {
        var r = w.getBoundingClientRect();
        zoomAt(r.width / 2, r.height / 2, scale * factor);
      }
      if (zin) zin.addEventListener('click', function () { step(1.15); });
      if (zout) zout.addEventListener('click', function () { step(1 / 1.15); });
    })();
    w.addEventListener('pointerdown', function (e) {
      // If the tap landed on a candidate marker bubble, let it handle its own
      // click (highlight the row) instead of capturing the pointer for panning.
      if (e.target.closest && e.target.closest('.mkbub')) return;
      ptrs[e.pointerId] = e; w.setPointerCapture(e.pointerId);
      moved = 0; sx = e.clientX; sy = e.clientY; stx = tx; sty = ty;
      var ids = Object.keys(ptrs);
      if (ids.length === 2) {
        var a = ptrs[ids[0]], b = ptrs[ids[1]];
        lastDist = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
      }
    });
    w.addEventListener('pointermove', function (e) {
      if (!ptrs[e.pointerId]) return;
      ptrs[e.pointerId] = e;
      var ids = Object.keys(ptrs);
      if (ids.length === 1) {
        tx = stx + (e.clientX - sx); ty = sty + (e.clientY - sy);
        moved = Math.max(moved, Math.hypot(e.clientX - sx, e.clientY - sy));
        apply();
      } else if (ids.length === 2) {
        var a = ptrs[ids[0]], b = ptrs[ids[1]];
        var d = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
        var r = w.getBoundingClientRect();
        var mx = (a.clientX + b.clientX) / 2 - r.left;
        var my = (a.clientY + b.clientY) / 2 - r.top;
        if (lastDist > 0) zoomAt(mx, my, scale * d / lastDist);
        lastDist = d; moved = 99;
      }
    });
    function up(e) {
      delete ptrs[e.pointerId];
      var rem = Object.keys(ptrs);
      if (rem.length < 2) lastDist = 0;
      if (rem.length === 1) {
        // pinch ended with one finger still down: restart the drag from
        // HERE, not from the pre-pinch positions (stale baseline = fling)
        var r = ptrs[rem[0]];
        sx = r.clientX; sy = r.clientY; stx = tx; sty = ty;
      }
      if (moved < 6) {
        var now = Date.now();
        if (now - lastTap < 350) { openMaps(e); lastTap = 0; }
        else lastTap = now;
      }
    }
    w.addEventListener('pointerup', up);
    w.addEventListener('pointercancel', up);
    function openMaps(e) {
      if (!w.dataset.w) return;
      var r = w.getBoundingClientRect();
      var ix = ((e.clientX - r.left) - tx) / scale;
      var iy = ((e.clientY - r.top) - ty) / scale;
      var fx = ix / img.clientWidth, fy = iy / img.clientHeight;
      if (fx < 0 || fx > 1 || fy < 0 || fy > 1) return;
      var W = +w.dataset.w, S = +w.dataset.s, E = +w.dataset.e, N = +w.dataset.n;
      var lon = W + (E - W) * fx, lat = N - (N - S) * fy;
      window.open('https://maps.google.com/?q=' + lat.toFixed(6) + ',' + lon.toFixed(6), '_blank');
    }
  });

  // ===== LIVE in-browser hillshade: re-render as sliders move, no server =====
  document.querySelectorAll('.ndsmwrap[data-elev]').forEach(function (w) {
    // each image's own controls sit immediately after it
    var bar = w.nextElementSibling;
    while (bar && !bar.classList.contains('reliefbar')) bar = bar.nextElementSibling;
    var canvas = w.querySelector('.ndsmcanvas');
    if (!canvas || !bar) return;
    var H = 0, W2 = 0, heights = null, mPerLevel = 1, cellM = 1, ready = false;

    // load elevation PNG into an offscreen canvas, read its pixels as heights
    var meta = w.getAttribute('data-elev').replace('_elev.png', '_elev.json');
    fetch(meta).then(function (r) { return r.json(); }).then(function (m) {
      mPerLevel = m.m_per_level; cellM = m.cell_m;
    }).catch(function () {});
    var im = new Image();
    im.onload = function () {
      try {
        W2 = im.naturalWidth; H = im.naturalHeight;
        var off = document.createElement('canvas');
        off.width = W2; off.height = H;
        var oc = off.getContext('2d');
        oc.drawImage(im, 0, 0);
        var d = oc.getImageData(0, 0, W2, H).data;
        heights = new Float32Array(W2 * H);
        for (var i = 0; i < W2 * H; i++) heights[i] = d[i * 4];  // red channel = level
        canvas.width = W2; canvas.height = H;
        ready = true;
        w.classList.add('live-on');
        render();
      } catch (err) {
        // pixel read blocked or failed — still show the static image + bar
        bar.style.position = 'static';
      }
    };
    im.onerror = function () { bar.style.position = 'static'; };
    im.src = w.getAttribute('data-elev');

    // box blur (separable) for the Local Relief Model's broad-terrain estimate
    function boxBlur(src, w, h, r) {
      var tmp = new Float32Array(w * h), dst = new Float32Array(w * h), i, x, y;
      for (y = 0; y < h; y++) {        // horizontal pass
        var acc = 0, row = y * w;
        for (i = 0; i <= r; i++) acc += src[row + Math.min(i, w - 1)];
        for (x = 0; x < w; x++) {
          tmp[row + x] = acc / (2 * r + 1);
          var add = src[row + Math.min(x + r + 1, w - 1)];
          var sub = src[row + Math.max(x - r, 0)];
          acc += add - sub;
        }
      }
      for (x = 0; x < w; x++) {        // vertical pass
        var acc2 = 0;
        for (i = 0; i <= r; i++) acc2 += tmp[Math.min(i, h - 1) * w + x];
        for (y = 0; y < h; y++) {
          dst[y * w + x] = acc2 / (2 * r + 1);
          var add2 = tmp[Math.min(y + r + 1, h - 1) * w + x];
          var sub2 = tmp[Math.max(y - r, 0) * w + x];
          acc2 += add2 - sub2;
        }
      }
      return dst;
    }

    var lrmCache = null;
    function render() {
      if (!ready) return;
      var az = +bar.querySelector('.r-az').value;
      var z = +bar.querySelector('.r-z').value;
      var mode = bar.querySelector('.r-mode').value;
      var stretch = bar.querySelector('.r-stretch').checked;
      var ctx = canvas.getContext('2d');
      var out = ctx.createImageData(W2, H);
      var alt = 45 * Math.PI / 180;
      var sinAlt = Math.sin(alt), cosAlt = Math.cos(alt);
      var vscale = z * mPerLevel / cellM;   // level-units slope -> real with z

      // Local Relief Model: subtract the broad terrain (box-blur, ~25 m window)
      // so only human-scale earthworks remain. Computed once, cached.
      var hgt = heights;
      if (mode === 'lrm') {
        if (!lrmCache) {
          var broad = boxBlur(heights, W2, H, 12);
          lrmCache = new Float32Array(W2 * H);
          for (var k = 0; k < W2 * H; k++) lrmCache[k] = (heights[k] - broad[k]) * 6 + 128;
        }
        hgt = lrmCache;
      }

      function shadeAt(idx, x, y) {
        var s = 2;
        var x0 = x >= s ? x - s : x, x1 = x < W2 - s ? x + s : x;
        var y0 = y >= s ? y - s : y, y1 = y < H - s ? y + s : y;
        var dx = (x1 - x0) || 1, dy = (y1 - y0) || 1;
        var dzdx = (hgt[y * W2 + x1] - hgt[y * W2 + x0]) * vscale / dx;
        var dzdy = (hgt[y1 * W2 + x] - hgt[y0 * W2 + x]) * vscale / dy;
        var slope = Math.atan(Math.sqrt(dzdx * dzdx + dzdy * dzdy));
        var aspect = Math.atan2(-dzdx, dzdy);
        function one(adeg) {
          var a = adeg * Math.PI / 180;
          var v = sinAlt * Math.cos(slope) + cosAlt * Math.sin(slope) * Math.cos(a - aspect);
          return v < 0 ? 0 : v > 1 ? 1 : v;
        }
        if (mode === 'svf') {
          var acc = 0; for (var ad = 0; ad < 360; ad += 30) acc += one(ad); return acc / 12;
        } else if (mode === 'multi' || mode === 'lrm') {
          return Math.max(one(az), one(az + 90), one(az + 180), one(az + 270));
        }
        return one(az);
      }

      var vals = new Float32Array(W2 * H);
      var mn = 1e9, mx = -1e9;
      for (var y = 0; y < H; y++) {
        for (var x = 0; x < W2; x++) {
          var idx = y * W2 + x;
          var v = shadeAt(idx, x, y);
          vals[idx] = v; if (v < mn) mn = v; if (v > mx) mx = v;
        }
      }
      var lo = mn, hi = mx;
      if (stretch && hi > lo) { /* full-range stretch below */ } else { lo = 0; hi = 1; }
      var span = (hi - lo) || 1;
      for (var p = 0; p < W2 * H; p++) {
        var s = stretch ? (vals[p] - lo) / span : vals[p];
        var g = 40 + Math.max(0, Math.min(1, s)) * 205;
        out.data[p * 4] = g; out.data[p * 4 + 1] = g; out.data[p * 4 + 2] = g; out.data[p * 4 + 3] = 255;
      }
      ctx.putImageData(out, 0, 0);
    }

    var t = null;
    function schedule() { clearTimeout(t); t = setTimeout(render, 30); }

    // position the custom fill + thumb to match the input's value. Because they
    // move in percent across the full track, they reach 0% and 100% exactly —
    // the thumb sits flush at both ends with no native inset.
    function paintRange(el) {
      var min = +el.min, max = +el.max, val = +el.value;
      var pct = max > min ? (val - min) / (max - min) * 100 : 0;
      var sl = el.closest('.sl');
      if (!sl) return;
      var fill = sl.querySelector('.sl-fill'), thumb = sl.querySelector('.sl-thumb');
      if (fill) fill.style.width = pct + '%';
      if (thumb) thumb.style.left = pct + '%';
    }
    function updateReadouts() {
      var azEl = bar.querySelector('.r-az'), zEl = bar.querySelector('.r-z');
      var azV = bar.querySelector('.r-az-v'), zV = bar.querySelector('.r-z-v');
      if (azEl && azV) azV.textContent = Math.round(+azEl.value) + '\u00b0';
      if (zEl && zV) zV.textContent = (+zEl.value).toFixed(1) + '\u00d7';
      if (azEl) paintRange(azEl);
      if (zEl) paintRange(zEl);
    }

    bar.querySelectorAll('input,select').forEach(function (el) {
      el.addEventListener('input', function () { updateReadouts(); schedule(); });
      el.addEventListener('change', function () { updateReadouts(); schedule(); });
    });
    updateReadouts();   // set initial fill + readout immediately
  });

  // ===== Bidirectional link: marker <-> table row =====
  (function () {
    function clearHi() {
      document.querySelectorAll('.row-hi').forEach(function (el) { el.classList.remove('row-hi'); });
    }
    function flashMarker(id) {
      document.querySelectorAll('.mk[data-id="' + id + '"]').forEach(function (m) {
        m.classList.remove('mk-flash');     // restart the animation if re-tapped
        void m.offsetWidth;
        m.classList.add('mk-flash');
      });
    }
    // tap a marker bubble -> highlight its row and scroll it into view
    document.querySelectorAll('.mk .mkbub').forEach(function (bub) {
      bub.addEventListener('click', function (e) {
        e.stopPropagation();
        var id = bub.closest('.mk').getAttribute('data-id');
        clearHi();
        var row = document.getElementById('row-' + id);
        if (row) {
          row.classList.add('row-hi');
          row.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
        flashMarker(id);
      });
    });
    // tap a candidate row -> flash its marker (and highlight the row)
    document.querySelectorAll('tr.candrow').forEach(function (row) {
      row.addEventListener('click', function (e) {
        if (e.target.tagName === 'A') return;   // let location links work normally
        var id = row.getAttribute('data-mk');
        clearHi();
        row.classList.add('row-hi');
        flashMarker(id);
      });
    });
  })();
  </script>
JS

PAGE_HEAD = <<~'HTML'
  <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Structure Hunter — Survey Console</title>
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
    <style>
      :root {
        --steel-0:#1a1d21;      /* deep gunmetal background */
        --steel-1:#23272e;      /* panel base */
        --steel-2:#2c313a;      /* raised panel */
        --steel-3:#3a4049;      /* bezel / edge highlight */
        --steel-line:#0e1013;   /* machined groove */
        --ink:#e6e9ee;          /* primary text on dark */
        --ink-dim:#9aa3b0;      /* secondary text */
        --amber:#f0a830;        /* instrument amber accent */
        --signal:#46d39a;       /* signal-green readout */
        --flag:#ff6a2b;         /* alert / action orange */
        --rivet:#11141a;
      }
      * { box-sizing:border-box; }
      body {
        margin:0; color:var(--ink);
        font-family:"SF Mono","Cascadia Code",Consolas,Menlo,monospace;
        font-size:14px; line-height:1.5;
        background:
          linear-gradient(180deg, rgba(255,255,255,.02), rgba(0,0,0,.25)),
          repeating-linear-gradient(90deg,
            var(--steel-0) 0 2px, #1c2026 2px 3px),   /* fine brushed grain */
          var(--steel-0);
      }
      .wrap { max-width:880px; margin:0 auto; padding:28px 18px 80px; }
      header {
        border:1px solid var(--steel-line);
        border-radius:8px;
        background:
          linear-gradient(180deg, var(--steel-3), var(--steel-1) 55%, var(--steel-0));
        box-shadow:inset 0 1px 0 rgba(255,255,255,.10),
                   inset 0 -2px 6px rgba(0,0,0,.5), 0 2px 8px rgba(0,0,0,.4),
                   0 14px 34px -12px rgba(240,168,48,.35);
        padding:16px 18px 14px; margin-bottom:30px; position:relative;
      }
      /* corner rivets on the header plate */
      header::before, header::after {
        content:""; position:absolute; top:8px; width:7px; height:7px;
        border-radius:50%; background:radial-gradient(circle at 35% 30%, #5a626d, var(--rivet));
        box-shadow:0 1px 1px rgba(0,0,0,.6);
      }
      header::before { left:9px; } header::after { right:9px; }
      h1 { margin:0; font-size:21px; letter-spacing:.18em; text-transform:uppercase;
           font-weight:700; text-align:center; color:var(--ink);
           text-shadow:0 1px 0 #000, 0 0 12px rgba(240,168,48,.15); }
      .tagline { text-align:center; margin-top:6px;
                 font-family:Georgia,"Times New Roman",serif; font-style:italic;
                 font-size:14px; color:var(--amber); letter-spacing:.02em; }
      h1 .quad { color:var(--amber); }
      .sub { color:var(--ink-dim); font-size:12px; letter-spacing:.06em; margin-top:4px; }
      fieldset {
        position:relative; z-index:1;
        border:1px solid var(--steel-line); border-radius:7px;
        background:linear-gradient(180deg, var(--steel-2), var(--steel-1));
        box-shadow:inset 0 1px 0 rgba(255,255,255,.06),
                   inset 0 -3px 8px rgba(0,0,0,.35), 0 1px 3px rgba(0,0,0,.4),
                   0 14px 34px -12px rgba(240,168,48,.35);
        margin:0 0 30px; padding:16px 18px 18px;
      }
      legend { padding:3px 12px; font-size:11px; letter-spacing:.2em;
               text-transform:uppercase; color:var(--steel-0); font-weight:700;
               background:linear-gradient(180deg, var(--amber), #cf8c1e);
               border:1px solid var(--steel-line); border-radius:4px;
               box-shadow:0 1px 2px rgba(0,0,0,.5); }
      .row { display:flex; flex-wrap:wrap; gap:12px; }
      .f { display:flex; flex-direction:column; gap:3px;
           flex:1 1 120px; min-width:110px; max-width:100%; }
      .lbl { font-size:11px; letter-spacing:.1em; text-transform:uppercase;
             color:var(--amber); }
      input, select { font:inherit; padding:8px 10px;
              border:1px solid var(--steel-line); border-radius:4px;
              background:linear-gradient(180deg, #14171c, #1b1f25);
              color:var(--signal); width:100%;
              box-shadow:inset 0 2px 4px rgba(0,0,0,.6); }
      input:focus, select:focus { outline:none; border-color:var(--amber);
              box-shadow:inset 0 2px 4px rgba(0,0,0,.6), 0 0 0 2px rgba(240,168,48,.35); }
      .hint { font-size:11.5px; color:var(--ink-dim); font-style:italic; }
      .chk { display:flex; gap:8px; align-items:flex-start; font-size:12.5px;
             color:var(--ink-dim); margin-bottom:12px; cursor:pointer; }
      .chk input { width:auto; margin-top:2px; }
      button { font:inherit; font-weight:700; letter-spacing:.16em; text-transform:uppercase;
               color:#fff; border:1px solid var(--steel-line); border-radius:5px;
               background:linear-gradient(180deg, #ff7d44, var(--flag) 50%, #d8500f);
               box-shadow:inset 0 1px 0 rgba(255,255,255,.35),
                          inset 0 -2px 4px rgba(0,0,0,.4), 0 2px 5px rgba(0,0,0,.5);
               padding:14px 30px; cursor:pointer; width:100%; }
      button:hover { background:linear-gradient(180deg, #ff8d57, #e85a16 50%, #c4480d); }
      button:active { box-shadow:inset 0 2px 6px rgba(0,0,0,.6); }
      table { width:100%; border-collapse:collapse;
              background:var(--steel-1); border:1px solid var(--steel-line);
              border-radius:5px; overflow:hidden; font-size:13px; }
      th { background:linear-gradient(180deg, var(--steel-3), var(--steel-2));
           color:var(--amber); text-align:left;
           padding:7px 8px; font-size:10.5px; letter-spacing:.12em; text-transform:uppercase;
           border-bottom:1px solid var(--steel-line); }
      td { padding:6px 8px; border-top:1px solid rgba(255,255,255,.04); color:var(--ink); }
      tr:nth-child(even) td { background:rgba(255,255,255,.02); }
      td.sc { font-weight:700; color:var(--signal); }
      tr.tankrow { opacity:0.5; font-style:italic; }
      tr.flagrow td { background:rgba(255,106,43,.08); }
      tr.flagrow .notes-cell { color:var(--flag); }
      tr.disrow td { opacity:.42; }
      tr.disrow .actcell { opacity:1; }
      .distag { color:var(--ink-dim); font-style:italic; font-size:11.5px; }
      .actcell { text-align:center; white-space:nowrap; }
      .dismiss-btn {
        font:inherit; font-size:10.5px; letter-spacing:.08em; text-transform:uppercase;
        color:var(--ink-dim); background:linear-gradient(180deg,var(--steel-3),var(--steel-2));
        border:1px solid var(--line); border-radius:5px; padding:4px 9px; cursor:pointer;
      }
      .dismiss-btn:hover { color:var(--flag); border-color:var(--flag); }
      .dismiss-btn.restore:hover { color:var(--signal); border-color:var(--signal); }
      .notes-cell { font-size:11.5px; color:var(--ink-dim); max-width:240px; }
      .shapecell { display:flex; align-items:center; gap:9px; min-width:170px; }
      .shapecell .glyph { flex:0 0 auto; background:#11141a; border:1px solid var(--line);
                          border-radius:5px; }
      .shapetxt { display:flex; flex-direction:column; line-height:1.25; font-size:11.5px; }
      .shapetxt b { color:var(--ink); font-weight:700; letter-spacing:.02em; }
      .shapetxt .dim { color:var(--signal); font-variant-numeric:tabular-nums; font-size:10.5px; }
      .shapetxt .ltype { color:var(--amber); font-size:10.5px; }
      .shapetxt .roof { color:#7fc7ff; font-size:10px; font-style:italic; }
      /* collapsible panels: hidden until the summary is clicked */
      details.collapse > summary {
        cursor:pointer; list-style:none; user-select:none;
        font-size:11.5px; letter-spacing:.08em; color:var(--amber);
        padding:7px 11px; border:1px solid var(--line); border-radius:6px;
        background:linear-gradient(180deg,var(--steel-3),var(--steel-2));
        display:inline-flex; align-items:center; gap:8px;
      }
      details.collapse > summary::-webkit-details-marker { display:none; }
      details.collapse > summary::before { content:"▸"; color:var(--amber); font-size:10px; }
      details.collapse[open] > summary::before { content:"▾"; }
      details.collapse > summary:hover { border-color:var(--amber); }
      .calib { background:rgba(70,211,154,.07); border:1px solid var(--signal);
               border-radius:5px; padding:10px 13px; margin:8px 0 12px;
               font-size:12px; line-height:1.5; color:var(--ink); }
      .calib strong { color:var(--signal); }
      .hbars { margin:10px 0 4px; font-size:11.5px; }
      .hbar-cap { font-size:11.5px; color:var(--ink-dim); margin:10px 0 4px; }
      .hbar-row { display:flex; align-items:center; gap:8px; margin:3px 0; }
      .hbar-lbl { width:62px; text-align:right; color:var(--ink-dim);
                  font-variant-numeric:tabular-nums; }
      .hbar-track { flex:1; height:14px; background:#11141a;
                    border:1px solid var(--steel-line); border-radius:3px; overflow:hidden; }
      .hbar-fill { display:block; height:100%;
                   background:linear-gradient(90deg, #cf8c1e, var(--amber)); }
      .hbar-n { width:34px; color:var(--signal); font-variant-numeric:tabular-nums; }
      a { color:var(--amber); }
      .stat { font-size:12px; color:var(--ink-dim); margin:6px 0 10px; }
      .err { border:1px solid var(--flag); border-radius:5px;
             background:rgba(255,106,43,.10); color:#ffb38c;
             padding:12px 14px; margin-bottom:20px; }
      .ndsmbox { position:relative; margin-bottom:6px; }
      .ndsmwrap { overflow:hidden; border:1px solid var(--steel-line); border-radius:4px;
                  margin-bottom:0; cursor:grab; touch-action:none; }
      .ndsmwrap:active { cursor:grabbing; }
      .ndsmpane { transform-origin:0 0; position:relative; }
      .ndsmcanvas { position:absolute; left:0; top:0; width:100%; height:100%;
                    display:none; image-rendering:pixelated; }
      .ndsmwrap.live-on .ndsmimg { visibility:hidden; }
      .ndsmwrap.live-on .ndsmcanvas { display:block; }
      .reliefbar { position:absolute; left:0; right:0; bottom:0; z-index:5;
                   display:flex; flex-wrap:wrap; gap:14px; align-items:center;
                   background:rgba(34,48,42,.82); border:none;
                   padding:7px 10px; font-size:11px;
                   text-transform:uppercase; letter-spacing:.06em; color:var(--ink); }
      .reliefbar label { display:flex; align-items:center; gap:5px; }
      /* Custom slider: a track with a fill and thumb that I position by percent
         (so they reach 0% and 100% exactly), with the real range input laid
         transparent on top to handle all the interaction. No native-thumb inset
         quirks — the thumb sits flush at both ends. */
      .reliefbar .sl { position:relative; display:inline-block; width:96px; height:16px;
                       vertical-align:middle; }
      .reliefbar .sl-track { position:absolute; left:0; right:0; top:50%;
                             transform:translateY(-50%); height:5px; border-radius:3px;
                             background:#11141a; border:1px solid var(--line); overflow:hidden; }
      .reliefbar .sl-fill { position:absolute; left:0; top:0; bottom:0; width:0;
                            background:linear-gradient(90deg,var(--amber-deep,#cf8c1e),var(--amber)); }
      .reliefbar .sl-thumb { position:absolute; top:50%; left:0;
                             width:13px; height:13px; border-radius:50%;
                             transform:translate(-50%,-50%);
                             background:var(--amber); border:1px solid #1c1f25;
                             box-shadow:0 1px 2px rgba(0,0,0,.55); pointer-events:none; }
      .reliefbar .sl-input {
        -webkit-appearance:none; appearance:none; position:absolute; inset:0;
        width:100%; height:100%; margin:0; background:transparent; cursor:pointer; opacity:0;
      }
      .reliefbar .sl-input::-webkit-slider-thumb {
        -webkit-appearance:none; appearance:none; width:16px; height:16px;
      }
      .reliefbar .sl-input::-moz-range-thumb { width:16px; height:16px; border:0; }
      .reliefbar .rwrap { display:inline-flex; align-items:center; gap:6px; }
      .reliefbar .rval { font-variant-numeric:tabular-nums; color:var(--signal);
                         min-width:30px; text-align:right; font-size:10.5px; }
      .reliefbar select { width:auto; padding:2px 4px; font-size:11px; }
      .r-live { margin-left:auto; color:var(--flag); font-weight:700; }
      .r-zoom { display:inline-flex; gap:4px; }
      .r-zoom button { width:24px; height:20px; padding:0; font-size:14px;
                       font-weight:700; line-height:1; cursor:pointer;
                       background:linear-gradient(180deg,var(--steel-3),var(--steel-2)); color:var(--amber); border:1px solid var(--steel-line);
                       border-radius:3px; }
      .r-zoom button:hover { background:var(--steel-3); }
      .ndsmimg { width:100%; display:block; image-rendering:pixelated;
                 user-select:none; -webkit-user-drag:none; }
      .mklayer { position:absolute; inset:0; pointer-events:none; }
      .mk { position:absolute; width:0; height:0; transform-origin:0 0;
            pointer-events:none; }
      .mkdot { position:absolute; left:-2.5px; top:-2.5px; width:5px; height:5px;
               border-radius:50%; background:#fff;
               box-shadow:0 0 0 1px rgba(0,0,0,.65); }
      .mkline { position:absolute; left:0; top:0; width:13px; height:1.5px;
                background:#fff; transform-origin:0 50%;
                box-shadow:0 0 1px rgba(0,0,0,.6); }
      .mk-a .mkline { transform:rotate(-42deg); }
      .mk-b .mkline { transform:rotate(138deg); }
      .mkbub { position:absolute; min-width:15px; height:15px; padding:0 3px;
               border-radius:8px; display:flex; align-items:center;
               justify-content:center; font-size:9px; font-weight:700;
               color:#fff; border:1.5px solid #fff;
               box-shadow:0 0 3px rgba(0,0,0,.5); white-space:nowrap; }
      .mk-a .mkbub { left:9px; bottom:7px; }
      .mk-b .mkbub { right:9px; top:7px; }
      .mkbtn { font:inherit; font-size:11px; font-weight:700; letter-spacing:.06em;
               text-transform:uppercase; padding:3px 10px; margin-left:8px;
               background:linear-gradient(180deg,var(--steel-3),var(--steel-2)); color:var(--amber); border:1px solid var(--steel-line); border-radius:4px;
               cursor:pointer; width:auto; }
      .mkbtn:hover { background:var(--steel-3); color:var(--signal); }
      #pickmap { display:none; height:320px; border:1px solid var(--ink);
                 margin-top:8px; }
      textarea { font:inherit; font-size:12px; padding:7px 9px;
                 border:1px solid var(--ink); background:linear-gradient(180deg,#14171c,#1b1f25); color:var(--signal); width:100%; }
      .mkv .mkbub { background:rgba(212,85,31,.92); }
      .mkl .mkbub { background:rgba(62,92,73,.95); }
      .mkbub { pointer-events:auto; cursor:pointer; }
      tr.candrow { cursor:pointer; }
      .abt { font-size:13px; line-height:1.62; color:var(--ink); }
      .abt p { margin:0 0 11px; }
      .abt strong { color:var(--amber); }
      .abt em { color:var(--signal); font-style:normal; }
      #aboutpanel { margin-bottom:10px; }
      tr.row-hi td { background:rgba(240,168,48,.28) !important;
                     box-shadow:inset 3px 0 0 var(--amber); }
      @keyframes mkflash {
        0%   { transform:scale(1); }
        30%  { transform:scale(2.1); }
        100% { transform:scale(1); }
      }
      .mk-flash .mkbub {
        animation:mkflash .55s ease-out;
        box-shadow:0 0 0 3px #fff, 0 0 10px 4px var(--amber);
        z-index:20; position:relative;
      }
      .loglines { background:#11141a; border:1px solid var(--steel-line); border-radius:5px; padding:8px 12px;
                  max-height:260px; overflow-y:auto; }
      .logline { font-size:12px; color:var(--signal); padding:2px 0;
                 border-bottom:1px dashed rgba(255,255,255,.08); }
      .logline:last-child { border-bottom:none; }
      .logline.err { color:#8C2F08; background:none; border:none; padding:2px 0; margin:0; }
      .note { font-size:12px; color:var(--ink-dim); margin-top:6px; }
      @media (prefers-reduced-motion:no-preference) {
        fieldset { transition:border-color .15s; }
        fieldset:focus-within { border-color:var(--flag); }
      }
    </style></head><body><div class="wrap">

    <header>
      <h1>Structure Hunter <span class="quad">// survey console</span></h1>
      <div class="tagline">(Finding hidden, forgotten or otherwise known or unknown abandoned structures)</div>
      <div style="text-align:center;font-size:10px;color:var(--ink-dim);letter-spacing:.1em;margin-top:2px">build v47-roof-shape</div>
      <div style="text-align:center;margin-top:8px">
        <button type="button" class="mkbtn" id="aboutbtn" style="width:auto;display:inline-block">About this instrument</button>
        <button type="button" class="mkbtn" id="howsearchbtn" style="width:auto;display:inline-block;margin-left:6px">How to: search &amp; tune</button>
        <button type="button" class="mkbtn" id="howimagebtn" style="width:auto;display:inline-block;margin-left:6px">How to: read the imagery</button>
      </div>
      <div style="display:flex;align-items:center;justify-content:space-between;gap:14px;margin-top:6px">
        <svg viewBox="0 0 24 24" width="75" height="75" fill="none" stroke="var(--amber)"><circle cx="12" cy="12" r="9.5" stroke-width="0.65"/><ellipse cx="12" cy="12" rx="4" ry="9.5" stroke-width="0.325"/><line x1="2.5" y1="12" x2="21.5" y2="12" stroke-width="0.325"/><line x1="4" y1="6.5" x2="20" y2="6.5" stroke-width="0.325"/><line x1="4" y1="17.5" x2="20" y2="17.5" stroke-width="0.325"/></svg>
        <div class="sub" style="flex:1;text-align:center;margin-top:0">cross-reference scan · footprints × addresses × parcels · optional LiDAR refine</div>
        <svg viewBox="0 0 24 24" width="75" height="75" fill="none" stroke="var(--amber)" stroke-width="1.2" stroke-linejoin="round" stroke-linecap="round"><path d="M21.5 3.2 q1 -0.2 0.9 0.9 l-0.9 4.2 l-5.5 5 l1.2 5.8 q0.1 0.6 -0.5 0.9 l-0.9 0.4 l-3 -5.1 l-3.3 3 l0.2 2.4 q0 0.5 -0.5 0.6 l-0.6 0.1 l-1.4 -3.1 l-3.1 -1.4 l0.1 -0.6 q0.1 -0.5 0.6 -0.5 l2.4 0.2 l3 -3.3 l-5.1 -3 l0.4 -0.9 q0.3 -0.6 0.9 -0.5 l5.8 1.2 l5 -5.5 z"/></svg>
      </div>
    </header>

    <section id="aboutpanel" style="display:none">
      <fieldset><legend>About — purpose</legend>
        <div class="abt">
          <p><strong>Structure Hunter finds structures that exist on the ground but are
          missing, hidden, or unacknowledged in official records.</strong> Its core idea is a
          mismatch: compare <em>what is physically there</em> (building footprints, and the
          raw shape of the land from laser scanning) against <em>what is officially registered</em>
          (address points and tax parcels). Where a structure exists but no record claims it,
          that gap is a candidate — an unregistered cabin, a forgotten outbuilding, an
          abandoned homestead, a structure hidden under tree canopy, or the ghost of a
          foundation long since overgrown.</p>
          <p>Everything it uses is public, authoritative data: OpenStreetMap and state building
          footprints, the National Address Database and state address points, county parcel
          layers, and USGS 3DEP LiDAR and elevation models.</p>
        </div>
      </fieldset>

      <fieldset><legend>The science</legend>
        <div class="abt">
          <p><strong>1 · The footprint-vs-address join.</strong> A building footprint is a polygon
          tracing a roof seen from above. An address point is a dot a government places to mark
          a registered address. For each footprint the program finds the nearest address point;
          if the nearest one is closer than your <em>Address distance</em> threshold, the structure
          is considered registered and set aside. If the nearest address is far away, the structure
          is standing there unclaimed — a candidate. The geometry behind this is the
          <em>shoelace formula</em> (computing a polygon's area and centroid from its vertices)
          and a <em>grid spatial index</em> that makes "nearest point" fast by only checking
          nearby grid cells instead of every address in the county.</p>

          <p><strong>2 · LiDAR and the bare earth.</strong> LiDAR is laser ranging from aircraft:
          millions of pulses measure the height of everything they hit. From that point cloud the
          program builds two surfaces — the <em>DSM</em> (highest return in each cell: rooftops,
          treetops) and the <em>DTM</em> (the ground beneath, interpolated under buildings and
          trees from the laser pulses that reached bare earth). Subtracting them gives
          <em>height above ground</em> — so a building shows as a raised, flat plateau and a tree
          as a raised, ragged one. This is how the tool sees structures the footprint maps never
          recorded, including ones under canopy: enough pulses slip through bare winter branches
          to reconstruct the ground and reveal what stands on it.</p>

          <p><strong>3 · Telling buildings from vegetation — roughness.</strong> Each raised blob is
          scored by <em>roughness</em>: how much the surface heights vary across it. A roof is
          smooth (low roughness); foliage scatters laser returns at every height (high roughness).
          Sorting by roughness floats the most building-like finds to the top.</p>

          <p><strong>4 · Telling buildings from tanks — shape descriptors.</strong> Industrial areas
          are full of round storage tanks the size of buildings. The program measures each
          candidate's <em>circularity</em> (how round, from the isoperimetric ratio 4&pi;·area/perimeter²),
          <em>solidity</em> (how free of notches, via the convex hull — the tightest rubber band
          around the shape), and how square and full its bounding box is. A lone perfect circle is
          flagged as a tank; a circle with anything attached breaks those ratios and passes as a
          real structure.</p>

          <p><strong>5 · Isolation and clearance.</strong> Two independent ways to measure "alone":
          <em>neighbors</em> counts registered addresses within a radius (is this a settled area?),
          while <em>clearance</em> measures distance to the nearest physical building footprint
          (is anything actually built nearby, registered or not?). Stacked with size and shape
          filters, they let you describe a very specific target — say, a small, non-circular,
          unregistered structure with no other building within 80 metres.</p>

          <p><strong>6 · Calibration.</strong> Because address-point placement varies by data source
          and region, the program measures, for the buildings it judged registered, how far each
          sits from its address — and reports the distribution. That tells you the natural cutoff
          for the area you are actually scanning, so the registration threshold is set from
          evidence rather than guesswork.</p>
        </div>
      </fieldset>

      <fieldset><legend>How a scan runs</legend>
        <div class="abt">
          <p>You define an area (type a county or address, tap two corners on the satellite map, or
          paste coordinates). The program fetches footprints, addresses, and optionally parcels for
          that box, runs the join, and — if LiDAR is enabled — finds the USGS tiles covering your
          area, downloads them <em>in parallel</em>, grids them to a height surface, and hunts for
          smooth raised blobs unknown to the footprints. Results appear as ranked tables and as
          numbered markers laid over the LiDAR imagery, the two linked: tap a marker to highlight
          its row, tap a row to flash its marker. Downloaded data and rendered images are cached, so
          repeat visits to an area are fast; the Cache panel shows what is stored and lets you clear
          it. For a quick look without large downloads, <em>Quick ground view</em> reads just your
          box's window from a remote elevation model in seconds.</p>
        </div>
      </fieldset>

      <fieldset><legend>Image manipulation &amp; what it reveals</legend>
        <div class="abt">
          <p>The LiDAR views are not photographs — they are renderings of measured elevation, and
          how you light and stretch that data decides what you can see. The controls sit live on the
          bottom of each image and re-render it <em>instantly in your browser</em>, with no rescan:</p>

          <p><strong>Sun direction.</strong> The relief is lit by a simulated low sun. Features
          running parallel to the light cast no shadow and vanish; rotate the sun and a foundation
          edge or old roadbed that was invisible suddenly catches the light. Always sweep the sun
          angle before concluding nothing is there.</p>

          <p><strong>Vertical exaggeration.</strong> Multiplies apparent height. Most archaeological
          traces — leveled house pads, plough terraces, filled foundations, faint ditches — are only
          centimetres high. Push exaggeration to 3–5× and those whispers of relief become unmistakable.</p>

          <p><strong>Relief mode.</strong> Three ways to render the surface:
          <em>Hillshade</em> is a single natural sun, good for a realistic read.
          <em>Multi-direction</em> blends several light angles so nothing hides in shadow-parallel —
          features show regardless of orientation.
          <em>Sky-view</em> is the archaeologist's technique: instead of a sun, each point is shaded
          by how much open sky it can "see," which makes subtle pits, mounds, and edges pop with no
          directional bias. Sky-view plus exaggeration is the most revealing combination for faint
          ground features.</p>

          <p><strong>Contrast stretch.</strong> Maps the data's actual value range to full black-to-white,
          pulling maximum detail out of low-relief terrain where everything would otherwise read as
          flat grey.</p>

          <p><strong>Navigation.</strong> Drag to pan; scroll, pinch, or the ＋ / － buttons to zoom in
          fine steps down to individual laser-measured square metres. <em>Double-tap any spot</em> and
          that exact ground opens in Google Maps satellite view — so you can confirm what the laser
          found against a photograph. Markers can be hidden to study the bare surface, then shown again
          to read off candidate numbers.</p>

          <p>The two image types complement each other: the <em>height map</em> (orange = building-height
          surfaces) is best for spotting standing structures, while the <em>bare-earth hillshade</em>
          strips vegetation and buildings to expose what the ground itself remembers — pads, cuts, and
          foundations. The data underneath is the same measured truth; the renderer simply lets you ask
          it different questions.</p>
        </div>
      </fieldset>

      <fieldset><legend>Honest limits</legend>
        <div class="abt">
          <p>Findings are <em>candidates</em>, not conclusions — confirm them against imagery and,
          where appropriate, on the ground and with permission. LiDAR quality varies by project:
          point density and especially flight season matter (leaf-off winter scans see under
          deciduous canopy; summer scans largely do not, and evergreen blocks the laser year-round).
          Address and footprint coverage is uneven, which cuts both ways — sparse mapping is exactly
          where unregistered structures hide, but it also means "no record" sometimes means "not yet
          mapped" rather than "deliberately hidden." Use the tool to find places worth a closer,
          lawful look, not to draw final conclusions about them.</p>
        </div>
      </fieldset>
    </section>

    <section id="howsearchpanel" style="display:none">
      <fieldset><legend>How to — search &amp; tuning</legend>
        <div class="abt">
          <p><strong>Step 1 · Pick where to look.</strong> Three ways, any of which fills the
          coordinate box: type a <em>county and state</em> (e.g. Rutherford / North Carolina) and the
          whole county is scanned; click <em>Pick area on map</em> and tap two opposite corners on the
          satellite map to draw a box; or paste coordinates / Google Earth KML. A county is huge, so
          for LiDAR work the program automatically focuses a small window on the strongest candidate —
          for a precise look, draw a small box instead. If all four coordinate fields are blank, the
          state/county field is used; if coordinates are present, they win.</p>

          <p><strong>Step 2 · Choose a data source.</strong> For North Carolina, the NC OneMap option
          gives the best quality and includes parcels with assessed values. Elsewhere, the National
          Address Database or OpenStreetMap options work in any US state. OSM address coverage is thin
          in some rural areas — if a scan returns almost nothing, that is often why; try a county
          address file instead.</p>

          <p><strong>Step 3 · Tune the registration test.</strong> The single most important dial is
          <em>Address distance</em>: how close an address point must be to count a structure as
          registered. Too low and ordinary houses flood the candidate list; too high and real
          unregistered structures get suppressed. <strong>Let the tool calibrate it for you:</strong>
          run once, then read the <em>Threshold calibration</em> readout at the top of the results — it
          measures, for the buildings it judged registered, how far each sits from its address, and
          recommends a value (the 95th percentile). Set Address distance near that number and re-run.
          Roughly: ~30&nbsp;m suits dense suburbs, ~50–75&nbsp;m suits rural areas with long driveways.</p>

          <p><strong>Step 4 · Filter by size.</strong> <em>Min / Max building size</em> bound the
          footprint area in square metres. Raise the minimum to drop sheds and barns; lower the maximum
          to drop warehouses. A small isolated dwelling is often roughly 35–200&nbsp;m².</p>

          <p><strong>Step 5 · Filter by isolation — two independent tools.</strong>
          <em>Max neighbors</em> counts registered <em>addresses</em> within the neighbor radius:
          blank = no limit, 0 = only structures with no addresses around them at all, 2 = up to two
          nearby. <em>Min clearance</em> instead measures distance to the nearest physical
          <em>building</em> (registered or not): set it to, say, 80&nbsp;m to require open ground all
          around the target. These catch different kinds of "alone" — a hidden compound can have zero
          addresses yet several buildings clustered together — so stack them as needed. The
          <em>Isolation search cap</em> only sets how far out the tool bothers to measure the nearest
          address; it changes the reported distance, not which structures qualify.</p>

          <p><strong>Step 6 · Filter by shape.</strong> Round storage tanks are building-sized and
          otherwise pass every filter. Leave the default on to tag lone circular shapes "tank-like" and
          sink them to the bottom of the list, or tick <em>Hide round tank-like shapes</em> to remove
          them entirely. A circle with anything attached still passes — only bare circles are flagged.</p>

          <p><strong>Step 7 · Read the results.</strong> Candidates appear ranked, highest-priority
          first, with a Shape value and a Google Maps link per row. With LiDAR on, numbered markers sit
          on the imagery and link to the table both ways: tap a marker to highlight its row, tap a row
          to flash its marker. The full list is also written to candidates.csv / candidates.geojson.</p>

          <p><strong>A good first pass:</strong> scan a county you know with defaults; read the
          calibration readout; set Address distance to its suggestion; add Min clearance ~80&nbsp;m and
          Max neighbors 0 if you want truly solitary structures; re-run. Then draw small boxes on the
          most promising spots for the full LiDAR treatment.</p>
        </div>
      </fieldset>
    </section>

    <section id="howimagepanel" style="display:none">
      <fieldset><legend>How to — getting good imagery</legend>
        <div class="abt">
          <p>The LiDAR pictures are renderings of measured elevation, and the controls live on the
          bottom edge of each image, re-rendering <em>instantly</em> as you drag them — no rescan. The
          goal is to make faint ground evidence visible. Here is how to work them.</p>

          <p><strong>Start with the bare-earth view.</strong> Two images may appear: the
          <em>height map</em> (orange = building-height surfaces — best for standing structures) and the
          <em>bare-earth hillshade</em> (vegetation and buildings stripped away — best for foundations,
          pads, and old roadbeds). Most detective work happens on the bare-earth view.</p>

          <p><strong>1 · Sweep the sun before concluding anything.</strong> The relief is lit by a
          simulated low sun, and any feature running <em>parallel</em> to that light casts no shadow and
          becomes invisible. Drag <em>Sun direction</em> through its full range and watch faint edges
          appear and disappear — a foundation line hidden at one angle leaps out at another. Never decide
          a spot is empty from a single sun angle.</p>

          <p><strong>2 · Raise vertical exaggeration to find whispers.</strong> Leveled house pads,
          plough terraces, filled foundations, and old ditches are often only centimetres of relief. Push
          <em>Vertical exaggeration</em> to 3–5× and those barely-there features become unmistakable. Back
          it down to 1× to judge true relief.</p>

          <p><strong>3 · Switch relief modes for the hardest features.</strong>
          <em>Hillshade</em> (one sun) gives the most natural read.
          <em>Multi-direction</em> blends several suns so nothing hides in shadow-parallel — use it when
          features may run in many directions.
          <em>Sky-view</em> shades each point by how much open sky it can see rather than by a sun, so
          subtle pits and mounds show with no directional bias — this is the archaeologist's tool.
          <strong>Sky-view + exaggeration 3–5× is the single most revealing combination</strong> for
          faint earthworks.</p>

          <p><strong>4 · Add contrast stretch on flat terrain.</strong> Where everything reads as the
          same grey, tick <em>Contrast stretch</em> to map the data's true range to full black-to-white
          and pull out detail that was there but invisible.</p>

          <p><strong>5 · Zoom and confirm.</strong> Drag to pan; use scroll, pinch, or the
          <em>＋ / －</em> buttons to zoom in fine steps down to individual square metres of laser data.
          When something looks like a structure or foundation, <em>double-tap it</em> — that exact ground
          opens in Google Maps satellite view, so you can check the laser evidence against a photograph.
          Hide the markers to study the bare surface, then show them again to read candidate numbers.</p>

          <p><strong>A reliable recipe for hidden structures:</strong> bare-earth view → Sky-view mode →
          exaggeration ~4× → contrast stretch on → then sweep the sun a little and zoom into anything
          rectangular, sharply linear, or suspiciously level. Those are the signatures of human work the
          ground still remembers. Double-tap the best ones to confirm against satellite imagery.</p>

          <p><strong>Why a spot may look poor:</strong> resolution depends on the LiDAR project — point
          density and flight season especially. Leaf-off winter scans see under bare deciduous canopy;
          summer scans largely do not; evergreens block the laser year-round. If a wooded area looks
          empty, the data may simply not have reached the ground there.</p>
        </div>
      </fieldset>
    </section>
HTML


def examined_panel_html
  list = load_examined
  return '' if list.empty?
  <<~HTML
    <fieldset style="margin-top:26px"><legend>LiDAR sweep progress</legend>
      <div class="note" style="margin-bottom:8px">You've examined <strong>#{list.size}</strong>
      LiDAR window#{list.size == 1 ? '' : 's'} in big-area scans. With focus set to
      <em>"Next unexamined"</em>, each run advances to the next candidate you haven't looked at yet,
      sweeping the area over repeated scans. Reset to start the sweep over.</div>
      <button type="button" class="dismiss-btn" onclick="clearExamined(this)">Reset sweep progress</button>
    </fieldset>
  HTML
end

def dismissed_panel_html
  list = load_dismissed
  return '' if list.empty?
  rows = list.sort_by { |d| d[:at].to_s }.reverse.map do |d|
    link = "https://maps.google.com/?q=#{d[:lat]},#{d[:lng]}"
    reason = d[:reason].to_s.empty? ? '<span style="color:var(--ink-dim)">—</span>' : esc(d[:reason])
    "<tr data-lat=\"#{d[:lat]}\" data-lng=\"#{d[:lng]}\">" \
      "<td><a href=\"#{link}\" target=\"_blank\">#{d[:lat]}, #{d[:lng]}</a></td>" \
      "<td>#{reason}</td><td>#{d[:at]}</td>" \
      "<td class=\"actcell\"><button type=\"button\" class=\"dismiss-btn restore\" onclick=\"undismissPanel(this)\">restore</button></td></tr>"
  end.join
  <<~HTML
    <fieldset style="margin-top:26px"><legend>Dismissed locations (#{list.size})</legend>
      <details class="collapse">
        <summary>Show / manage #{list.size} dismissed location#{list.size == 1 ? '' : 's'}</summary>
        <div class="note" style="margin:10px 0">Locations you've marked to skip on future scans.
        They're matched within ~20&nbsp;m, so they stay skipped even if coordinates shift slightly.
        Restore any to let it appear in results again. (These survive clearing the cache.)</div>
        <table><tr><th>Location</th><th>Note</th><th>Dismissed</th><th></th></tr>#{rows}</table>
      </details>
    </fieldset>
  HTML
end

def cache_panel_html
  s = cache_stats
  rows = s[:groups].sort_by { |_, v| -v[:bytes] }.map do |kind, v|
    "<tr><td>#{kind}</td><td>#{v[:count]}</td><td>#{human_size(v[:bytes])}</td></tr>"
  end.join
  rows = '<tr><td colspan="3" style="color:var(--ink-dim)">cache is empty</td></tr>' if rows.empty?
  <<~HTML
    <fieldset style="margin-top:26px"><legend>Cache</legend>
      <div class="stat">Downloaded data and rendered images are saved here so repeat
      visits to the same area are fast. Total: <strong>#{s[:count]} files, #{human_size(s[:bytes])}</strong>.</div>
      <table><tr><th>What</th><th>Files</th><th>Size</th></tr>#{rows}</table>
      <form method="POST" action="/cache/clear-laz" style="display:inline">
        <button type="submit" class="mkbtn">Clear point clouds only (#{s[:laz_count]} files, #{human_size(s[:laz_bytes])})</button>
      </form>
      <form method="POST" action="/cache/clear-all" style="display:inline">
        <button type="submit" class="mkbtn" style="background:var(--flag)">Clear entire cache</button>
      </form>
      <div class="note" style="margin-top:6px">Point clouds are the large files and re-download when needed.
      Clearing images/grids only forces a quick re-render.</div>
    </fieldset>
  HTML
end

PAGE_TAIL = PICKER_JS + "</div></body></html>"

def form_html(p)
  <<~HTML
    <form method="POST" action="/run">

    <fieldset><legend>Data files</legend>
      <label class="f" style="width:100%;margin-bottom:12px">
        <span class="lbl">Data source</span>
        <select name="source">
          <option value="files" #{p['source'] == 'files' ? 'selected' : ''}>Local files (paths below)</option>
          <option value="osm" #{p['source'] == 'osm' ? 'selected' : ''}>Auto-fetch from OpenStreetMap — works anywhere, address quality varies</option>
          <option value="ncom" #{p['source'] == 'ncom' ? 'selected' : ''}>Auto-fetch NC OneMap + OSM buildings — North Carolina, best quality</option>
          <option value="nad" #{p['source'] == 'nad' ? 'selected' : ''}>Auto-fetch National Address Database + OSM buildings — any US state</option>
        </select>
        <span class="hint">auto-fetch modes need the area box (or state/county) and cache after the first run · NC mode includes parcels with assessed values automatically</span>
      </label>
      <div class="row">
        #{field('Footprints GeoJSON', 'fp_path', p['fp_path'], nil, '100%')}
        #{field('Address points GeoJSON', 'ad_path', p['ad_path'], nil, '100%')}
        #{field('Parcels GeoJSON (optional)', 'pc_path', p['pc_path'],
                'leave blank to skip the assessor layer', '60%')}
        #{field('OR parcels ArcGIS layer URL (any county)', 'parcel_url', p['parcel_url'],
                "find it on your county GIS portal: open the parcels dataset, look for an API / GeoService link ending in /FeatureServer/0 or /MapServer/1 · improvement field auto-detected", '100%')}
        #{field('Improvement field', 'imp_field', p['imp_field'],
                'the $ value column in your parcel data', '34%')}
      </div>
    </fieldset>

    <fieldset><legend>Area to scan</legend>
      <div class="row" style="margin-bottom:10px">
        #{field('State', 'loc_state', p['loc_state'], 'e.g. North Carolina')}
        #{field('County', 'loc_county', p['loc_county'],
                'fills the four coordinates below when they are blank')}
      </div>
      <div class="row">
        #{field('West (min lon)', 'min_lon', p['min_lon'])}
        #{field('South (min lat)', 'min_lat', p['min_lat'])}
        #{field('East (max lon)', 'max_lon', p['max_lon'])}
        #{field('North (max lat)', 'max_lat', p['max_lat'])}
      </div>
      <div class="note">Leave all four blank to scan everything in the files —
      or pick the area visually / paste coordinates below.</div>
      <div style="margin-top:10px">
        <button type="button" class="mkbtn" id="pickbtn">Pick area on map</button>
        <div class="row" id="findrow" style="margin-top:8px;display:none">
          <label class="f" style="flex:3">
            <span class="lbl">Jump map to a place (zip · address · county, state)</span>
            <input id="findbox" placeholder="e.g. 28079  ·  123 Main St, Monroe NC  ·  Clarke County, GA">
          </label>
          <label class="f" style="flex:1;justify-content:flex-end">
            <span class="lbl">&nbsp;</span>
            <button type="button" class="mkbtn" id="findbtn" style="margin-left:0">Go</button>
          </label>
        </div>
        <div id="pickmap"></div>
        <div class="row" style="margin-top:8px">
          <label class="f" style="flex:3">
            <span class="lbl">…or paste coordinates / Google Earth KML</span>
            <textarea id="pastebox" rows="2"
              placeholder="paste two corner pairs, a KML snippet, or any list of coordinates"></textarea>
          </label>
          <label class="f" style="flex:1;justify-content:flex-end">
            <span class="lbl">&nbsp;</span>
            <button type="button" class="mkbtn" id="pastebtn" style="margin-left:0">Use pasted</button>
          </label>
        </div>
      </div>
    </fieldset>

    <fieldset><legend>Tuning</legend>
      <div class="row">
        #{field('Address distance (m)', 'threshold', p['threshold'],
                'no hits at all? raise this · flooded with normal houses? lower it')}
        #{field('Min building size (m²)', 'min_area', p['min_area'],
                'too many barns &amp; sheds? raise this')}
        #{field('Max building size (m²)', 'max_area', p['max_area'],
                'warehouses showing up? lower this')}
        #{field('Isolation search cap (m)', 'max_search', p['max_search'],
                'how far out to measure isolation')}
        #{field('Max neighbors', 'max_neighbors', p['max_neighbors'],
                'blank = no limit · 0 = only totally isolated structures · 2 = up to 2 nearby')}
        #{field('Min clearance (m)', 'clear_dist', p['clear_dist'],
                'blank = off · require no other building within this many meters of the target')}
        #{field('Neighbor radius (m)', 'neighbor_radius', p['neighbor_radius'],
                'count neighbors within this distance (default 200)')}
        #{field('Max building cluster', 'max_cluster', p['max_cluster'],
                'blank = off · reject if more than this many buildings sit within the cluster radius (drops industrial parks &amp; rail yards)')}
        #{field('Cluster radius (m)', 'cluster_radius', p['cluster_radius'],
                'how wide to count the building cluster (default 150)')}
      </div>
    </fieldset>

    <fieldset><legend>Context &amp; accuracy (optional)</legend>
      <label class="chk">
        <input type="checkbox" name="use_zones" #{p['use_zones'] == 'on' ? 'checked' : ''}>
        <span><strong>Check OpenStreetMap industrial &amp; railway zones.</strong> Fetches
        industrial / commercial / quarry land-use, rail yards, airports, and rail lines for
        the area, and notes when a candidate sits inside one. Adds an OSM fetch (cached after
        the first run). Great for ruling out warehouses and train yards.</span>
      </label>
      <label class="chk" style="margin-bottom:0">
        <input type="checkbox" name="reject_zones" #{p['reject_zones'] == 'on' ? 'checked' : ''}>
        <span><strong>Reject candidates inside those zones entirely</strong> (default: keep them,
        flagged and pushed down the ranking). Only takes effect with the box above ticked.</span>
      </label>
      <div class="note" style="margin-top:10px">With NC OneMap parcels, each candidate also shows
      its <strong>tax use</strong> (e.g. SFR, COMMERCIAL), <strong>site address</strong>, and a
      <strong>notes</strong> column summarizing accuracy signals — industrial use, building clusters,
      large parcels, and non-individual owners are flagged automatically.</div>
      <label class="chk" style="margin:12px 0 0">
        <input type="checkbox" name="hide_dismissed" #{p['hide_dismissed'] == 'on' ? 'checked' : ''}>
        <span><strong>Hide dismissed locations entirely.</strong> When you mark a result "dismiss"
        it's skipped on future scans. By default dismissed results still appear, greyed out at the
        bottom (so you can restore them); tick this to drop them from the list completely.</span>
      </label>
    </fieldset>

    <fieldset><legend>LiDAR refine (optional)</legend>
      <label class="chk">
        <input type="checkbox" name="lidar_auto" #{p['lidar_auto'] == 'on' ? 'checked' : ''}>
        Fully automatic: download &amp; process USGS point clouds for this area,
        then hunt (small areas only, ~1.5 km · one-time setup:
        pip install laspy lazrs numpy pyproj)
      </label>
      <label class="chk">
        <input type="checkbox" name="lidar_quick" #{p['lidar_quick'] == 'on' ? 'checked' : ''}>
        Quick ground view: bare-earth hillshade via remote DEM read — seconds,
        no big downloads (terrain &amp; ghost features only, no height map ·
        needs: pip install rasterio)
      </label>
      <label class="f" style="width:100%;margin-top:4px">
        <span class="lbl">LiDAR focus (when the area is too big to scan whole)</span>
        <select name="lidar_focus">
          <option value="top1" #{(p['lidar_focus'] || 'top1') == 'top1' ? 'selected' : ''}>Top candidate only (one window — fastest)</option>
          <option value="top3" #{p['lidar_focus'] == 'top3' ? 'selected' : ''}>Top 3 candidates (three windows — covers more leads)</option>
          <option value="next" #{p['lidar_focus'] == 'next' ? 'selected' : ''}>Next unexamined (sweeps forward each run — pairs with dismiss)</option>
          <option value="pick2" #{p['lidar_focus'] == 'pick2' ? 'selected' : ''}>Candidate #2 only</option>
          <option value="pick3" #{p['lidar_focus'] == 'pick3' ? 'selected' : ''}>Candidate #3 only</option>
          <option value="pick4" #{p['lidar_focus'] == 'pick4' ? 'selected' : ''}>Candidate #4 only</option>
          <option value="pick5" #{p['lidar_focus'] == 'pick5' ? 'selected' : ''}>Candidate #5 only</option>
        </select>
        <span class="hint">A county-sized area can't be LiDAR-scanned whole, so the tool focuses ~2&nbsp;km windows. This picks which candidate(s) to examine — so #2, #3 and beyond aren't ignored. "Next unexamined" remembers what you've already looked at and advances to the next lead each run, sweeping the whole area over repeated scans.</span>
      </label>
      <div class="row">
        #{field('nDSM grid (.asc)', 'ndsm_path', p['ndsm_path'],
                'leave blank to skip · see prepare_lidar.sh to make one', '100%')}
      </div>
      <div class="row" style="margin-top:12px">
        #{field('Min height (m)', 'l_minh', p['l_minh'], 'below = bushes, cars')}
        #{field('Max height (m)', 'l_maxh', p['l_maxh'], 'above = tall trees')}
        #{field('Max roughness (m)', 'l_rough', p['l_rough'],
                'trees sneaking in? lower it · missing pitched roofs? raise it')}
        #{field('Min blob (m²)', 'l_min_area', p['l_min_area'])}
        #{field('Max blob (m²)', 'l_max_area', p['l_max_area'])}
      </div>
      <label class="chk" style="margin-top:10px;margin-bottom:0">
        <input type="checkbox" name="hide_tanks" #{p['hide_tanks'] == 'on' ? 'checked' : ''}>
        Hide round tank-like shapes entirely (default: keep them, tagged
        &ldquo;tank-like&rdquo; and sorted to the bottom). A circle with anything
        attached still passes either way.
      </label>
      <div class="note" style="margin-top:10px">Relief controls (sun angle, exaggeration,
      sky-view mode, contrast) appear <strong>live on the image itself</strong> after a
      scan — drag them and the view updates instantly, no re-scan needed.</div>
      <label class="chk" style="margin-top:10px;margin-bottom:0">
        <input type="checkbox" name="lidar_helper" #{p['lidar_helper'] == 'on' ? 'checked' : ''}>
        Find USGS LiDAR downloads for this area — lists the exact elevation
        files covering the box, with links (then see prepare_lidar.sh) 
        
        NOTE: New scans can take some time! (But it's worth the wait!!)
      </label>
      <div class="row" style="display:none">
      </div>
    </fieldset>

    <fieldset><legend>Pre-calibration (optional)</legend>
      <label class="chk" style="margin-bottom:0">
        <input type="checkbox" name="calibrate_only" #{p['calibrate_only'] == 'on' ? 'checked' : ''}>
        <span><strong>Calibrate first, don't scan yet.</strong> Runs a fast pass that measures
        how far registered buildings sit from their address in this area, shows the distribution
        as a histogram, and recommends an Address distance — without downloading LiDAR or scoring
        candidates. Use it to set the threshold from real data, then uncheck and run the full scan.</span>
      </label>
    </fieldset>

    <button type="submit">Run scan</button>
    </form>
  HTML
end

def calib_histogram(bands)
  return '' unless bands && bands.any?
  mx = [bands.max, 1].max
  labels = ['0–10', '10–20', '20–30', '30–40', '40–50',
            '50–60', '60–70', '70–80', '80–90', '90–100', '100 m+']
  rows = bands.each_with_index.map do |count, i|
    pct = (count.to_f / mx * 100).round
    "<div class=\"hbar-row\">" \
      "<span class=\"hbar-lbl\">#{labels[i]}</span>" \
      "<span class=\"hbar-track\"><span class=\"hbar-fill\" style=\"width:#{pct}%\"></span></span>" \
      "<span class=\"hbar-n\">#{count}</span>" \
    "</div>"
  end.join
  "<div class=\"hbars\">#{rows}</div>"
end

def calibrate_panel_html(c)
  return '' unless c
  rec = c[:p95].ceil
  <<~HTML
    <fieldset><legend>Pre-calibration result</legend>
      <div class="calib">
        <strong>Measured #{c[:n]} buildings</strong> — no candidate scan was run. Of those,
        <strong>#{c[:n_registered]}</strong> have an address point within 100 m (the plausibly
        registered ones). Among that registered group, the distances to their nearest address are:
        half within <strong>#{c[:p50].round} m</strong>,
        90% within <strong>#{c[:p90].round} m</strong>,
        95% within <strong>#{c[:p95].round} m</strong>,
        99% within #{c[:p99].round} m.
      </div>
      <div class="hbar-cap">Nearest-address distance — all #{c[:n]} buildings (bands of 10 m):</div>
      #{calib_histogram(c[:bands])}
      <div class="calib" style="margin-top:12px">
        <strong>Recommended Address distance: #{rec} m</strong> (95th percentile of the registered
        group). Set the Address distance field near this, then run a full scan: it will treat as
        registered nearly every building that truly has an address, and flag the rest as candidates.
        Lower it for a stricter search, raise it if real houses slip through. Current setting: #{c[:threshold]} m.
        #{c[:n_registered] < 5 ? '<br><em>Note: very few buildings here have a nearby address (sparse data), so this estimate is rough — sparse address coverage is itself a sign this is good hunting ground.</em>' : ''}
      </div>
    </fieldset>
  HTML
end

def calib_html(c)
  return '' unless c
  rec = c[:p95].ceil
  <<~HTML
    <div class="calib">
      <strong>Threshold calibration</strong> — measured from #{c[:n]} buildings the scan judged registered:
      half sit within <strong>#{c[:p50].round} m</strong> of their address,
      90% within <strong>#{c[:p90].round} m</strong>,
      95% within <strong>#{c[:p95].round} m</strong>,
      99% within #{c[:p99].round} m (max #{c[:max].round} m).
      Your current Address distance is <strong>#{c[:threshold]} m</strong>.
      A value near <strong>#{rec} m</strong> (the 95th percentile) catches almost all
      genuinely-registered buildings while flagging the rest as candidates —
      raise toward it if real houses are slipping through, lower it if the list is flooded.
    </div>
  HTML
end

def results_html(result, lidar_result, source, lidar_help, lidar_imgs = [], geo_box = nil)
  # Pre-calibration mode: show only the calibration panel, no candidate tables.
  if result.is_a?(Hash) && result[:calibrate_only]
    return "<div class=\"stat\" style=\"margin-top:20px\">#{source ? "data: #{esc(source)}" : ''}</div>" +
           calibrate_panel_html(result[:calib])
  end
  markers = ''
  if geo_box
    bw = geo_box[2] - geo_box[0]
    bh = geo_box[3] - geo_box[1]
    mk_count = 0
    add_mk = lambda do |lat, lng, label, cls, title, mkid|
      fx = (lng - geo_box[0]) / bw
      fy = (geo_box[3] - lat) / bh
      if fx >= 0 && fx <= 1 && fy >= 0 && fy <= 1
        side = mk_count.even? ? 'mk-a' : 'mk-b'
        mk_count += 1
        markers << "<div class=\"mk #{cls} #{side}\" data-id=\"#{mkid}\" style=\"left:#{(fx * 100).round(3)}%;" \
                   "top:#{(fy * 100).round(3)}%\" title=\"#{title}\">" \
                   "<span class=\"mkdot\"></span><span class=\"mkline\"></span>" \
                   "<span class=\"mkbub\">#{label}</span></div>"
      end
    end
    if result
      result[:candidates].first(100).each_with_index do |c, i|
        add_mk.call(c[:lat], c[:lng], i + 1, 'mkv', "##{i + 1} score #{c[:score]} #{c[:area_m2]}m2", "v#{i + 1}")
      end
    end
    (lidar_result || []).first(100).each_with_index do |c, i|
      add_mk.call(c[:lat], c[:lng], "L#{i + 1}", 'mkl', "L#{i + 1} #{c[:area_m2]}m2 rough #{c[:roughness_m]}", "l#{i + 1}")
    end
  end
  vec_rows = ''
  if result
    result[:candidates].first(100).each_with_index do |c, idx|
      link = "https://maps.google.com/?q=#{c[:lat]},#{c[:lng]}"
      vec_rows << <<~R
        <tr id="row-v#{idx + 1}" data-mk="v#{idx + 1}" data-lat="#{c[:lat]}" data-lng="#{c[:lng]}" class="candrow#{c[:tank] ? ' tankrow' : ''}#{c[:flagged] ? ' flagrow' : ''}#{c[:dismissed] ? ' disrow' : ''}"><td class="rk">#{idx + 1}</td><td class="sc">#{c[:score]}</td><td>#{c[:area_m2]}</td>
        <td>#{c[:nearest_address_m]}</td><td>#{c[:parcel_improvement]}</td>
        <td>#{c[:neighbors_200m]}</td>
        <td>#{esc(c[:use_desc].to_s)}</td>
        <td class="shapecell">#{c[:glyph]}<span class="shapetxt"><b>#{c[:tank] ? 'tank / silo' : esc(c[:shape_class].to_s)}</b>#{c[:dim].to_s.empty? ? '' : "<span class='dim'>#{c[:dim]}</span>"}<span class='ltype'>#{c[:tank] ? '' : esc(c[:likely_type].to_s)}</span></span></td>
        <td class="notes-cell">#{c[:dismissed] ? "<span class='distag'>dismissed#{c[:dismiss_reason].to_s.empty? ? '' : ": #{esc(c[:dismiss_reason])}"}</span>" : esc(c[:notes].to_s)}</td>
        <td><a href="#{link}" target="_blank">#{c[:lat]}, #{c[:lng]}</a></td>
        <td class="actcell">#{c[:dismissed] ? "<button type='button' class='dismiss-btn restore' onclick='undismiss(this)'>restore</button>" : "<button type='button' class='dismiss-btn' onclick='dismissCand(this)'>dismiss</button>"}</td></tr>
      R
    end
  end
  lid_rows = ''
  if lidar_result
    lidar_result.first(100).each_with_index do |c, idx|
      link = "https://maps.google.com/?q=#{c[:lat]},#{c[:lng]}"
      lid_rows << <<~R
        <tr id="row-l#{idx + 1}" data-mk="l#{idx + 1}" data-lat="#{c[:lat]}" data-lng="#{c[:lng]}" class="candrow#{c[:tank] ? ' tankrow' : ''}#{c[:dismissed] ? ' disrow' : ''}"><td class="rk">L#{idx + 1}</td><td class="sc">#{c[:roughness_m]}</td><td>#{c[:area_m2]}</td>
        <td>#{c[:mean_height_m]}</td>
        <td class="shapecell">#{c[:dismissed] ? "<span class='distag'>dismissed#{c[:dismiss_reason].to_s.empty? ? '' : ": #{esc(c[:dismiss_reason])}"}</span>" : "#{c[:glyph]}<span class='shapetxt'><b>#{c[:tank] ? 'tank / silo' : esc(c[:shape_class].to_s)}</b>#{c[:dim].to_s.empty? ? '' : "<span class='dim'>#{c[:dim]}</span>"}<span class='ltype'>#{c[:tank] ? '' : esc(c[:likely_type].to_s)}</span>#{c[:roof].to_s.empty? ? '' : "<span class='roof'>#{esc(c[:roof])}</span>"}</span>"}</td>
        <td><a href="#{link}" target="_blank">#{c[:lat]}, #{c[:lng]}</a></td>
        <td class="actcell">#{c[:dismissed] ? "<button type='button' class='dismiss-btn restore' onclick='undismiss(this)'>restore</button>" : "<button type='button' class='dismiss-btn' onclick='dismissCand(this)'>dismiss</button>"}</td></tr>
      R
    end
  end

  <<~HTML
    #{if result
        "<fieldset style=\"margin-top:26px\"><legend>Vector candidates</legend>
         <div class=\"stat\">#{source ? "data: #{source} · " : ''}#{result[:footprints].size} footprints ·
         #{result[:addresses]} addresses · #{result[:skipped]} skipped by size ·
         <strong>#{result[:candidates].size} candidates</strong>
         (top 100 shown · full list in candidates.csv / candidates.geojson)</div>
         #{calib_html(result[:calib])}
         <table><tr><th>#</th><th>Score</th><th>Area m²</th><th>Nearest addr m</th>
         <th>Improvement</th><th>Nbrs</th><th>Use</th><th>Shape &amp; likely type</th><th>Notes</th><th>Location</th><th></th></tr>#{vec_rows}</table>
         </fieldset>"
      else '' end}

    #{if lidar_help
        rows = lidar_help.map { |i|
          i[:url] ? "<tr><td>#{esc(i[:dataset])}</td><td><a href=\"#{i[:url]}\" target=\"_blank\">#{esc(i[:title][0,70])}</a></td></tr>"
                  : "<tr><td>#{esc(i[:dataset])}</td><td>#{esc(i[:title])}</td></tr>" }.join
        "<fieldset style=\"margin-top:26px\"><legend>USGS LiDAR downloads for this area</legend>
         <div class=\"stat\">Download what covers your box, then run prepare_lidar.sh and put the resulting ndsm.asc path in the LiDAR field above.</div>
         <table><tr><th>What it is</th><th>File</th></tr>#{rows}</table></fieldset>"
      else '' end}

    #{if lidar_imgs && !lidar_imgs.empty?
        geo = geo_box ? " data-w=\"#{geo_box[0]}\" data-s=\"#{geo_box[1]}\"" \
                        " data-e=\"#{geo_box[2]}\" data-n=\"#{geo_box[3]}\"" : ''
        "<fieldset style=\"margin-top:26px\"><legend>LiDAR views</legend>
         <div class=\"stat\">drag to pan · scroll or pinch to zoom · " \
        "double-tap a spot to open it in Google Maps · numbered markers = rows in the " \
        "candidate tables (orange #) and LiDAR finds (green L#)
         <button type=\"button\" class=\"mkbtn\"
           onclick=\"var h=this.textContent==='Hide markers';" \
        "document.querySelectorAll('.mklayer').forEach(function(l){l.style.display=h?'none':''});" \
        "this.textContent=h?'Show markers':'Hide markers'\">Hide markers</button></div>" +
        lidar_imgs.map { |srcf, cap, elev|
          live = elev ? " data-elev=\"/#{elev}\"" : ''
          controls = elev ? "<div class=\"reliefbar\" data-for=\"#{srcf}\">
             <label>Sun <span class=\"sl\"><span class=\"sl-track\"><span class=\"sl-fill\"></span><span class=\"sl-thumb\"></span></span><input type=\"range\" min=\"0\" max=\"360\" value=\"315\" class=\"r-az sl-input\"></span><span class=\"rval r-az-v\">315°</span></label>
             <label>Exag <span class=\"sl\"><span class=\"sl-track\"><span class=\"sl-fill\"></span><span class=\"sl-thumb\"></span></span><input type=\"range\" min=\"1\" max=\"8\" step=\"0.5\" value=\"1\" class=\"r-z sl-input\"></span><span class=\"rval r-z-v\">1.0×</span></label>
             <label>Mode <select class=\"r-mode\"><option value=\"hillshade\">Hillshade</option><option value=\"multi\">Multi-direction</option><option value=\"svf\">Sky-view</option><option value=\"lrm\">Local relief (faint earthworks)</option></select></label>
             <label>Stretch <input type=\"checkbox\" class=\"r-stretch\"></label>
             <span class=\"r-zoom\"><button type=\"button\" class=\"r-zin\">＋</button><button type=\"button\" class=\"r-zout\">－</button></span>
             <span class=\"r-live\">● live</span></div>" : ''
          "<div class=\"ndsmbox\"><div class=\"ndsmwrap\"#{geo}#{live}><div class=\"ndsmpane\"><img class=\"ndsmimg\" src=\"/#{srcf}\" alt=\"lidar view\"><canvas class=\"ndsmcanvas\"></canvas><div class=\"mklayer\">#{markers}</div></div></div>
           #{controls}</div>
           <div class=\"stat\">#{cap}</div>" }.join +
        "</fieldset>" + VIEWER_JS
      else '' end}

    #{if lidar_result
        "<fieldset><legend>LiDAR candidates — unknown to footprints</legend>

         <div class=\"stat\"><strong>#{lidar_result.size} flat elevated blobs</strong>
         (flattest first · full list in lidar_candidates.csv)</div>
         <table><tr><th>#</th><th>Roughness</th><th>Area m²</th><th>Height m</th>
         <th>Shape &amp; likely type</th><th>Location</th><th></th></tr>#{lid_rows}</table></fieldset>"
      else '' end}
  HTML
end

def page(p, result = nil, lidar_result = nil, error = nil, source = nil, lidar_help = nil)
  PAGE_HEAD +
    (error ? "<div class=\"err\">#{esc(error)}</div>" : '') +
    form_html(p) +
    (result || lidar_help ? results_html(result, lidar_result, source, lidar_help, [], nil) : '') +
    examined_panel_html +
    dismissed_panel_html +
    cache_panel_html +
    PAGE_TAIL
end

# ============================================================================
# DEFAULTS + REQUEST HANDLING
# ============================================================================
DEFAULTS = {
  'source' => 'files', 'loc_state' => '', 'loc_county' => '',
  'parcel_url' => '', 'lidar_helper' => '', 'lidar_auto' => '', 'lidar_quick' => '', 'lidar_focus' => 'top1', 'calibrate_only' => '',
  'rend_az' => '315', 'rend_z' => '1', 'rend_mode' => 'hillshade', 'rend_stretch' => '0',
  'hide_tanks' => '', 'hide_dismissed' => '',
  'fp_path' => 'footprints_clip.geojson', 'ad_path' => 'addresses.geojson',
  'pc_path' => '', 'imp_field' => 'IMPROVVAL',
  'min_lon' => '', 'min_lat' => '', 'max_lon' => '', 'max_lat' => '',
  'threshold' => '50', 'min_area' => '35', 'max_area' => '2000',
  'max_search' => '500', 'max_neighbors' => '', 'neighbor_radius' => '200', 'clear_dist' => '',
  'max_cluster' => '', 'cluster_radius' => '150', 'use_zones' => '', 'reject_zones' => '',
  'ndsm_path' => '', 'l_minh' => '2.5', 'l_maxh' => '15',
  'l_rough' => '1.2', 'l_min_area' => '30', 'l_max_area' => '3000'
}

def num(p, key) = p[key].to_s.strip.empty? ? DEFAULTS[key].to_f : p[key].to_f

def resolve_box(p)
  vals = %w[min_lon min_lat max_lon max_lat].map { |k| p[k].to_s.strip }
  box = vals.none?(&:empty?) ? vals.map(&:to_f) : nil
  if box.nil? && !p['loc_county'].to_s.strip.empty? && !p['loc_state'].to_s.strip.empty?
    box = nominatim_box(p['loc_county'].strip, p['loc_state'].strip)
    %w[min_lon min_lat max_lon max_lat].each_with_index do |k, i|
      p[k] = box[i].round(6).to_s
    end
  end
  box
end

def build_cfg(p, box)
  {
    fp_path: p['fp_path'].to_s.strip, ad_path: p['ad_path'].to_s.strip,
    pc_path: p['pc_path'].to_s.strip, imp_field: p['imp_field'].to_s.strip,
    box: box,
    threshold: num(p, 'threshold'), min_area: num(p, 'min_area'),
    max_area: num(p, 'max_area'), max_search: num(p, 'max_search'),
    ndsm_path: p['ndsm_path'].to_s.strip,
    l_minh: num(p, 'l_minh'), l_maxh: num(p, 'l_maxh'),
    l_rough: num(p, 'l_rough'),
    l_min_area: num(p, 'l_min_area'), l_max_area: num(p, 'l_max_area'),
    hide_tanks: p['hide_tanks'] == 'on',
    hide_dismissed: p['hide_dismissed'] == 'on',
    max_neighbors: (p['max_neighbors'].to_s.strip.empty? ? nil : p['max_neighbors'].to_i),
    clear_dist: (p['clear_dist'].to_s.strip.empty? ? nil : p['clear_dist'].to_f),
    max_cluster: (p['max_cluster'].to_s.strip.empty? ? nil : p['max_cluster'].to_i),
    cluster_radius: (p['cluster_radius'].to_s.strip.empty? ? 150.0 : p['cluster_radius'].to_f),
    reject_zones: p['reject_zones'] == 'on',
    neighbor_radius: (p['neighbor_radius'].to_s.strip.empty? ? 200.0 : p['neighbor_radius'].to_f)
  }
end

def run_pipeline(p, box, log)
  cfg = build_cfg(p, box)
  # Render settings drive the embedded Python via ENV, and join the cache
  # key so each distinct look is cached separately (change a knob -> new image).
  rend = {
    'REND_AZ' => (p['rend_az'].to_s.empty? ? '315' : p['rend_az'].to_s),
    'REND_Z' => (p['rend_z'].to_s.empty? ? '1' : p['rend_z'].to_s),
    'REND_MODE' => (p['rend_mode'].to_s.empty? ? 'hillshade' : p['rend_mode'].to_s),
    'REND_STRETCH' => (p['rend_stretch'] == '1' ? '1' : '0')
  }
  rend.each { |k, v| ENV[k] = v }
  rkey = rend.values.join('_').gsub(/[^a-zA-Z0-9]/, '')
  source = nil
  case p['source']
  when 'osm'
    raise 'OSM auto-fetch needs the area box — fill the coordinates or state/county.' unless box
    fp_file, ad_file, cached = osm_fetch(box, log)
    cfg[:fp_path] = fp_file
    cfg[:ad_path] = ad_file
    cfg[:box] = nil
    source = cached ? 'OpenStreetMap (from cache)' : 'OpenStreetMap (fetched fresh)'
  when 'ncom'
    raise 'NC OneMap mode needs the area box — fill the coordinates or state/county.' unless box
    key = box_key(box)
    fp_file, c1 = osm_fetch_buildings(box, key, log)
    ad_file, pc_file, c2 = ncom_fetch(box, key, log)
    cfg[:fp_path] = fp_file
    cfg[:ad_path] = ad_file
    cfg[:pc_path] = pc_file
    cfg[:imp_field] = 'IMPROVVAL'
    cfg[:box] = nil
    source = "NC OneMap + OSM buildings#{c1 && c2 ? ' (from cache)' : ' (fetched fresh)'}"
  when 'nad'
    raise 'NAD mode needs the area box — fill the coordinates or state/county.' unless box
    key = box_key(box)
    fp_file, c1 = osm_fetch_buildings(box, key, log)
    ad_file, c2 = nad_fetch(box, key, log)
    cfg[:fp_path] = fp_file
    cfg[:ad_path] = ad_file
    cfg[:box] = nil
    source = "National Address Database + OSM buildings#{c1 && c2 ? ' (from cache)' : ' (fetched fresh)'}"
  end

  if !p['parcel_url'].to_s.strip.empty? && box
    pc_file, = generic_parcels_fetch(p['parcel_url'].strip, box, box_key(box), log)
    cfg[:pc_path] = pc_file
    cfg[:imp_field] = 'IMPROVVAL'
    source = [source, 'parcels via ArcGIS URL'].compact.join(' · ')
  end

  # Pre-calibration: measure the registered-building distance distribution and
  # stop — no candidate scoring, no LiDAR. Fast way to choose a threshold first.
  if p['calibrate_only'] == 'on'
    calib = calibrate_only(cfg, log)
    return [{ calibrate_only: true, calib: calib }, nil, source, nil, [], box]
  end

  # Optional: fetch OSM industrial/railway zones so candidates can be checked
  # for industrial-site / rail-yard context. Needs a box.
  if p['use_zones'] == 'on' && box
    begin
      cfg[:zones] = osm_fetch_zones(box, box_key(box), log)
    rescue => e
      log.("Zone fetch skipped: #{e.message}")
    end
  end

  begin
    result = run_vector(cfg, log)
  rescue => e
    # If LiDAR was requested, a failed vector scan (e.g. zero addresses in
    # a deep-woods box) shouldn't kill the run — LiDAR is exactly for
    # places official data doesn't cover. Log it and continue.
    raise unless p['lidar_auto'] == 'on' || !cfg[:ndsm_path].empty?
    log.("Vector scan skipped: #{e.message}")
    result = nil
  end
  lidar_box = box
  quick = p['lidar_quick'] == 'on' && p['lidar_auto'] != 'on'
  lidar = nil
  extra_lidar_imgs = nil
  big_box = box && ((box[2] - box[0]) > 0.050 || (box[3] - box[1]) > 0.040)

  if (p['lidar_auto'] == 'on' || quick) && box && cfg[:ndsm_path].empty?
    half_lng = quick ? 0.0270 : 0.0115
    half_lat = quick ? 0.0225 : 0.0095

    # Decide which candidate window(s) to examine. On a big box we can't grid
    # the whole county, so we focus windows. The focus mode controls WHICH
    # candidates get a window — fixing the old behaviour where only #1 was ever
    # seen and re-runs repeated the same spot.
    focus = (p['lidar_focus'] || 'top1').to_s
    cands = (result && result[:candidates]) ? result[:candidates].reject { |c| c[:dismissed] } : []
    centers = []   # [label, lat, lng]

    if big_box
      if cands.empty?
        centers << ['box center', (box[1] + box[3]) / 2.0, (box[0] + box[2]) / 2.0]
      else
        case focus
        when 'top3'
          cands.first(3).each_with_index { |c, i| centers << ["##{i + 1} candidate", c[:lat], c[:lng]] }
        when 'next'
          examined = load_examined
          nextc = cands.find { |c| !examined?(examined, c[:lat], c[:lng]) }
          if nextc
            idx = cands.index(nextc) + 1
            centers << ["##{idx} candidate (next unexamined)", nextc[:lat], nextc[:lng]]
          else
            centers << ['#1 candidate (all examined — restarting)', cands.first[:lat], cands.first[:lng]]
          end
        when /\Apick(\d+)\z/
          n = Regexp.last_match(1).to_i
          c = cands[n - 1] || cands.first
          centers << ["##{cands.index(c) + 1} candidate", c[:lat], c[:lng]]
        else  # top1
          centers << ['#1 candidate', cands.first[:lat], cands.first[:lng]]
        end
      end
      km_x = ((box[2] - box[0]) * m_lon((box[1] + box[3]) / 2.0) / 1000).round(1)
      km_y = ((box[3] - box[1]) * M_LAT / 1000).round(1)
      est_tiles = (km_x * km_y * 2).round
      win_km = quick ? '~5' : '~2'
      log.("Box measures #{km_x} x #{km_y} km — full-area LiDAR would need roughly " \
           "#{est_tiles} tiles (~#{est_tiles / 10} GB). Focusing #{centers.size} " \
           "#{win_km} km window#{centers.size == 1 ? '' : 's'} (snapped for cache reuse).")
    else
      centers << ['whole box', (box[1] + box[3]) / 2.0, (box[0] + box[2]) / 2.0]
    end

    # Process each chosen window, collecting relief images and merging the
    # LiDAR candidate lists. Overlapping windows reuse cached tiles.
    extra_lidar_imgs = []
    merged_lidar = []
    centers.each do |label, rlat, rlng|
      if big_box
        clat = (rlat / 0.0075).round * 0.0075
        clng = (rlng / 0.0090).round * 0.0090
        wbox = [clng - half_lng, clat - half_lat, clng + half_lng, clat + half_lat]
      else
        clat = (box[1] + box[3]) / 2.0
        clng = (box[0] + box[2]) / 2.0
        wbox = box
      end
      log.("--- LiDAR window: #{label} ---") if centers.size > 1
      begin
        if quick
          png = dem_ground_fallback(wbox, box_key(wbox) + '_' + rkey, log)
          epng = png.sub(/\.png\z/, '_elev.png')
          elev_name = File.exist?(epng) ? File.basename(epng) : nil
          cap = centers.size > 1 ? "#{DEM_GROUND_CAPTION} — window: #{label}" : DEM_GROUND_CAPTION
          extra_lidar_imgs << [File.basename(png), cap, elev_name]
          mark_examined(clat, clng) if big_box
          lidar_box = wbox
        else
          ndsm, imgs_w = auto_lidar(wbox, box_key(wbox) + '_' + rkey, log)
          if ndsm && File.exist?(ndsm.to_s)
            wcfg = cfg.dup; wcfg[:ndsm_path] = ndsm.to_s
            suppress = result ? result[:footprints] : (begin
                mlon = m_lon(clat); load_footprints(cfg[:fp_path], nil, mlon).map { |r| ring_area_centroid(r, mlon) }
              rescue StandardError; [] end)
            merged_lidar.concat(run_lidar(wcfg, suppress, log))
            # build this window's relief images from the gridded outputs
            wpng = ndsm.to_s.sub(/\.asc\z/, '.png')
            wgpng = ndsm.to_s.sub(/\.asc\z/, '_ground.png')
            wepng = ndsm.to_s.sub(/\.asc\z/, '_elev.png')
            welev = File.exist?(wepng) ? File.basename(wepng) : nil
            wl = centers.size > 1 ? " — window: #{label}" : ''
            if File.exist?(wpng)
              extra_lidar_imgs << [File.basename(wpng),
                'Height map: bright = ground · darker gray = taller (trees) · ' \
                'orange = building-height surfaces (what the hunter searches)' + wl]
            end
            if File.exist?(wgpng)
              extra_lidar_imgs << [File.basename(wgpng),
                'Bare-earth hillshade: vegetation and buildings stripped away — ' \
                'look for rectangular pads, sharp depressions, and straight lines ' \
                '(foundations, leveled homesites, old roadbeds)' + wl, welev]
            end
            mark_examined(clat, clng) if big_box
            lidar_box = wbox
          elsif imgs_w && !imgs_w.empty?
            # auto_lidar fell back to a remote-DEM image (no point cloud) —
            # keep that relief image even though there's no nDSM to grid.
            imgs_w.each do |im|
              cap = centers.size > 1 ? "#{im[1]} — window: #{label}" : im[1]
              extra_lidar_imgs << [im[0], cap, im[2]]
            end
            mark_examined(clat, clng) if big_box
            lidar_box = wbox
          end
        end
      rescue => e
        log.("LiDAR window skipped (#{label}): #{e.message}")
      end
    end

    lidar = merged_lidar unless merged_lidar.empty?
    if lidar && lidar.size > 1
      seen = []
      lidar = lidar.reject do |c|
        dup = seen.any? { |s| haversine_m(c[:lat], c[:lng], s[0], s[1]) < 8 }
        seen << [c[:lat], c[:lng]] unless dup
        dup
      end
      lidar.sort_by! { |c| [c[:dismissed] ? 1 : 0, c[:tank] ? 1 : 0, c[:roughness_m]] }
    end
  end

  # Manual ndsm path (user supplied their own grid): grid it directly.
  if !cfg[:ndsm_path].empty?
    suppress =
      if result
        result[:footprints]
      else
        begin
          mlon = m_lon((box[1] + box[3]) / 2.0)
          load_footprints(cfg[:fp_path], nil, mlon).map { |r| ring_area_centroid(r, mlon) }
        rescue StandardError
          []
        end
      end
    lidar = run_lidar(cfg, suppress, log)
  end
  if p['lidar_helper'] == 'on' && box
    log.('Looking up USGS LiDAR products for this box...')
    lidar_help = tnm_lidar_products(box)
  end
  imgs = []
  imgs.concat(extra_lidar_imgs) if defined?(extra_lidar_imgs) && extra_lidar_imgs
  unless cfg[:ndsm_path].empty?
    png = cfg[:ndsm_path].sub(/\.asc\z/, '.png')
    gpng = cfg[:ndsm_path].sub(/\.asc\z/, '_ground.png')
    epng = cfg[:ndsm_path].sub(/\.asc\z/, '_elev.png')
    elev_name = File.exist?(epng) ? File.basename(epng) : nil
    log.(elev_name ? "Live relief controls: enabled (#{elev_name})" :
         "Live relief controls: NOT enabled — elevation file missing at #{File.basename(epng)}") if defined?(log) && log
    imgs << [File.basename(png),
             'Height map: bright = ground · darker gray = taller (trees) · ' \
             'orange = building-height surfaces (what the hunter searches)'] if File.exist?(png)
    imgs << [File.basename(gpng),
             'Bare-earth hillshade: vegetation and buildings stripped away — ' \
             'look for rectangular pads, sharp depressions, and straight lines ' \
             '(foundations, leveled homesites, old roadbeds)', elev_name] if File.exist?(gpng)
  end
  [result, lidar, source, lidar_help, imgs, lidar_box || box]
end

def stream_scan(client, p)
  # Quick phase first (so the form we send shows located coordinates)
  begin
    box = resolve_box(p)
  rescue => e
    respond(client, page(p, nil, nil, "#{e.class}: #{e.message}"))
    return
  end

  # No Content-Length: with Connection: close, the stream's end IS the
  # framing — which is exactly what lets us write the page in pieces.
  client.write "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" \
               "Connection: close\r\n\r\n"
  client.write PAGE_HEAD
  client.write form_html(p)
  client.write "<fieldset><legend>Scan log</legend><div class=\"loglines\">\n"
  if !p['loc_county'].to_s.strip.empty? && box
    km_x = ((box[2] - box[0]) * m_lon((box[1] + box[3]) / 2.0) / 1000).round(1)
    km_y = ((box[3] - box[1]) * M_LAT / 1000).round(1)
    client.write "<div class=\"logline\">Located #{esc(p['loc_county'])}, #{esc(p['loc_state'])} — " \
                 "box measures #{km_x} x #{km_y} km (coordinates filled in above)</div>\n"
  end
  t0 = Time.now
  log = lambda do |msg|
    client.write "<div class=\"logline\">#{esc(msg)}</div>\n"
  end

  begin
    result, lidar, source, lidar_help, lidar_imgs, lidar_box = run_pipeline(p, box, log)
    log.("Scan complete in #{(Time.now - t0).round(1)}s — results below.")
    client.write "</div></fieldset>\n"
    client.write results_html(result, lidar, source, lidar_help, lidar_imgs, lidar_box || box)
  rescue => e
    client.write "<div class=\"logline err\">#{esc(e.class)}: #{esc(e.message)}</div>\n"
    client.write "</div></fieldset>\n"
  end
  client.write PAGE_TAIL
end

def respond(client, html)
  body = html.b
  client.write "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" \
               "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
  client.write body
end

server = TCPServer.new('127.0.0.1', PORT)
puts "Structure Hunter console [v47-roof-shape]: http://localhost:#{PORT}  (Ctrl+C to stop)"

loop do
  client = server.accept
  client.sync = true   # push each write to the wire immediately
  begin
    request_line = client.gets or next
    method, req_path, _ = request_line.split
    headers = {}
    while (line = client.gets) && line != "\r\n"
      k, v = line.split(': ', 2)
      headers[k.to_s.downcase] = v.to_s.strip
    end
    params = DEFAULTS.dup
    if method == 'POST' && req_path == '/examined/clear'
      client.read(headers['content-length'].to_i) if headers['content-length']
      File.delete(EXAMINED_FILE) if File.exist?(EXAMINED_FILE)
      json = JSON.generate(ok: true)
      client.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}"
    elsif method == 'POST' && (req_path == '/dismiss' || req_path == '/undismiss')
      body = client.read(headers['content-length'].to_i).to_s
      f = {}; URI.decode_www_form(body).each { |k, v| f[k] = v }
      lat = f['lat'].to_f; lng = f['lng'].to_f
      n = if req_path == '/dismiss'
            add_dismissed(lat, lng, f['reason'])
          else
            remove_dismissed(lat, lng)
          end
      json = JSON.generate(ok: true, count: n)
      client.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}"
    elsif method == 'POST' && req_path.to_s.start_with?('/cache/clear')
      client.read(headers['content-length'].to_i) if headers['content-length']
      freed = clear_cache(req_path.include?('clear-laz') ? 'laz' : 'all')
      body = page(DEFAULTS.dup)
      msg = "<div class=\"logline\">Cache cleared — freed #{human_size(freed)}.</div>"
      body = body.sub('<form method="POST" action="/run">',
                      "<div class=\"loglines\" style=\"margin-bottom:16px\">#{msg}</div><form method=\"POST\" action=\"/run\">")
      respond(client, body)
    elsif method == 'POST'
      body = client.read(headers['content-length'].to_i)
      URI.decode_www_form(body).each { |k, v| params[k] = v }
      stream_scan(client, params)
    elsif req_path.to_s =~ %r{\A/(ndsm_[\w]+\.(?:png|json))\z} &&
          File.exist?(File.join(CACHE_DIR, Regexp.last_match(1)))
      fname = Regexp.last_match(1)
      data = File.binread(File.join(CACHE_DIR, fname))
      ctype = fname.end_with?('.json') ? 'application/json' : 'image/png'
      client.write "HTTP/1.1 200 OK\r\nContent-Type: #{ctype}\r\n" \
                   "Content-Length: #{data.bytesize}\r\nConnection: close\r\n\r\n"
      client.write data
    else
      respond(client, page(params))
    end
  rescue => e
    warn "request error: #{e.message}"
  ensure
    client.close
  end
end
