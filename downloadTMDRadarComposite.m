% downloadTMDRadarComposite.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- TMD nationwide radar rain-rate mosaic.
%
% Source: TMD's nationwide radar composite, linked from
%   https://weather.tmd.go.th/composite/index_composite.html
% as data/composite.nc (also composite.ascii): a GRIB2 product converted to
% NetCDF with wgrib2. Regular grid, 0.01 deg, 4-22.5 N, 95-108 E; variable
% var0_1_203_surface (TMD-local code in the "moisture" category). Its values
% (mostly 0, continuous to ~60, a few up to ~110) behave like a rain rate in
% mm/h rather than reflectivity in dBZ, so it is treated as rain rate; each new
% frame is compared with the TMD rain gauges and the comparison is printed and
% logged, as a check on that assumption.
%
% Each cycle (every PERIOD_MIN minutes):
%   1. downloads composite.nc; if its time is newer than the last frame saved:
%   2. archives the frame (RADAR/TMD/TMD_composite_<yyyymmddHHMM>.mat, UTC);
%   3. writes a map image for the dashboard (transparent PNG, rows laid out in
%      Web Mercator so it sits correctly on the map, colours by rain-rate class);
%   4. makes a 2-hour NOWCAST from the newest two frames (see below) and writes
%      its map images;
%   5. rewrites dashboard_data/radar.json, listing the frames of the last
%      KEEP_HOURS and the nowcast, and removes older map images.
%
% NOWCAST (Lagrangian persistence, base MATLAB only):
%   Motion: both frames are coarsened (NC_COARSEN x NC_COARSEN cells, ~4 km) and
%   transformed to log rain rate; for blocks of NC_BLOCK x NC_BLOCK coarse cells
%   (~100 km, half-overlapping) that hold enough rain, the shift (up to
%   NC_MAX_SHIFT cells per frame interval) with the highest correlation between
%   the earlier and the newest frame is the block's motion. Matches with
%   correlation below NC_MIN_CORR are dropped; the remaining vectors are
%   interpolated to a smooth field (median of all vectors where too few).
%   Extrapolation: the newest rain field is moved along that field in 15-min
%   steps to NC_LEAD_MAX_MIN, keeping intensities unchanged (no growth or decay),
%   which is why the nowcast stops at 2 hours.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true). TO STOP: stopPlatformTimers
%
% OUTPUTS
%   <archiveDir>/TMD_composite_<yyyymmddHHMM>.mat   rain rate (lat x lon, single), lat, lon, timeUTC
%   <dashDir>/radar/TMD_<yyyymmddHHMM>.png          map images (last KEEP_HOURS)
%   <dashDir>/radar/NC_<base>_<lead>.png            nowcast map images (newest base only)
%   <dashDir>/radar.json                            frame list, nowcast, bounds, colour classes
%   <archiveDir>/download_log.txt                   new frames + gauge comparison

clear; clc;
%% ============================ CONFIG =======================================
cfg.url        = 'https://weather.tmd.go.th/composite/data/composite.nc';
cfg.varName    = 'var0_1_203_surface';
cfg.rootDir    = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform';
cfg.archiveDir = fullfile(cfg.rootDir, 'RADAR', 'TMD');
cfg.dashDir    = fullfile(cfg.rootDir, 'dashboard', 'dashboard_data');
cfg.tmdLatest  = fullfile(cfg.rootDir, 'TMD_AWS_Archive', 'TMD_AWS_latest.csv');   % gauge check

cfg.KEEP_HOURS = 3;            % frames shown on the dashboard
cfg.UTC_OFFSET_H = 7;

% Rain-rate classes (mm/h): lower edges; below the first edge is left transparent
cfg.BINS   = [0.1 0.5 1 2 5 10 20 30 50 75 100];
cfg.COLORS = [170 210 255; 110 170 255;  40 110 255;   0 180  80; 120 210   0; 255 230   0; ...
              255 160   0; 255  80   0; 220   0   0; 200   0 160; 140   0 200];

% Nowcast
cfg.NC_ON           = true;
cfg.NC_LEAD_STEP_MIN = 15;     % nowcast frame spacing
cfg.NC_LEAD_MAX_MIN  = 120;    % how far ahead
cfg.NC_COARSEN      = 4;       % fine cells per coarse cell for the motion (0.04 deg, ~4 km)
cfg.NC_BLOCK        = 24;      % coarse cells per block side (~100 km)
cfg.NC_MAX_SHIFT    = 8;       % coarse cells per frame interval (~35 km / 15 min, ~140 km/h)
cfg.NC_MIN_RAIN_FRAC = 0.03;   % block needs this share of cells >= 0.5 mm/h
cfg.NC_MIN_CORR     = 0.3;     % weaker matches are dropped
cfg.NC_MAX_GAP_MIN  = 35;      % the earlier frame must be at most this much older

cfg.RUN_IN_BACKGROUND = true;
cfg.PERIOD_MIN = 10;
% ===========================================================================

if ~exist(cfg.archiveDir, 'dir'), mkdir(cfg.archiveDir); end
if ~exist(fullfile(cfg.dashDir, 'radar'), 'dir'), mkdir(fullfile(cfg.dashDir, 'radar')); end
cfg.logFile = fullfile(cfg.archiveDir, 'download_log.txt');

timerName = 'TMDRadarTimer';
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A TMD radar timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

runRadarCycleSafe(cfg);

if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'minute');
    nextRun  = nextRun + minutes(cfg.PERIOD_MIN - mod(minute(nextRun), cfg.PERIOD_MIN)) + seconds(20);
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    radarTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 60 * cfg.PERIOD_MIN, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runRadarCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('TMD radar timer error: %s\n', evt.Data.message));
    start(radarTimer);

    fprintf('\nTMD radar composite downloader is now running in the background.\n');
    fprintf('Every %d min (next run in %.0f seconds).\n', cfg.PERIOD_MIN, startDelaySec);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runRadarCycleSafe(cfg)
try
    runRadarCycle(cfg);
catch ME
    fprintf('[%s] TMD radar cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | %s', datestr(now), ME.message));
end
end


function runRadarCycle(cfg)
% 1. Download
tmp = [tempname '.nc'];
websave(tmp, cfg.url, weboptions('Timeout', 60, 'CertificateFilename', ''));
cleanup = onCleanup(@() delete(tmp));

tSec = ncread(tmp, 'time');
timeUTC = datetime(tSec(1), 'ConvertFrom', 'posixtime');          % unzoned, UTC
tag = datestr(timeUTC, 'yyyymmddHHMM');
matFile = fullfile(cfg.archiveDir, sprintf('TMD_composite_%s.mat', tag));
if exist(matFile, 'file')
    fprintf('[%s] TMD radar: frame %s UTC already saved.\n', datestr(now), datestr(timeUTC, 'yyyy-mm-dd HH:MM'));
    updateFrameList(cfg);
    return;
end

lat = double(ncread(tmp, 'latitude'));
lon = double(ncread(tmp, 'longitude'));
v = ncread(tmp, cfg.varName);                                      % lon x lat (x time)
v = squeeze(v(:, :, 1));
v(v > 1e19) = NaN;
R = single(v');                                                    % lat x lon, rain rate (mm/h)

% 2. Archive (compressed MAT; mostly NaN/zero, so small)
save(matFile, 'R', 'lat', 'lon', 'timeUTC');

% 3. Map image for the dashboard
pngName = sprintf('TMD_%s.png', tag);
writeRadarPng(cfg, R, lat, fullfile(cfg.dashDir, 'radar', pngName));

% Gauge check: radar rain rate at TMD stations vs their last-hour rain
msgGauge = gaugeCheck(cfg, R, lat, lon, timeUTC);

% 4. Nowcast from this frame and the previous one
ncMsg = '';
if cfg.NC_ON
    try
        ncMsg = makeNowcast(cfg, R, lat, lon, timeUTC, tag);
    catch ME
        ncMsg = ['nowcast failed: ' ME.message];
    end
end

% 5. Frame list for the dashboard
updateFrameList(cfg);

[rmax, imax] = max(R(:));
[iy, ix] = ind2sub(size(R), imax);
msg = sprintf('%s | frame %s UTC | rain cells (>=%.1f mm/h): %d | max %.1f mm/h at %.2fN %.2fE | %s', datestr(now), ...
    datestr(timeUTC, 'yyyy-mm-dd HH:MM'), cfg.BINS(1), sum(R(:) >= cfg.BINS(1)), rmax, lat(iy), lon(ix), msgGauge);
writeLog(cfg.logFile, msg);
fprintf('[%s] TMD radar: new frame %s UTC, %d rain cells, max %.1f mm/h at %.2fN %.2fE. %s\n', datestr(now), ...
    datestr(timeUTC, 'yyyy-mm-dd HH:MM'), sum(R(:) >= cfg.BINS(1)), rmax, lat(iy), lon(ix), msgGauge);
if ~isempty(ncMsg)
    fprintf('  %s\n', ncMsg);
    writeLog(cfg.logFile, sprintf('%s | %s', datestr(now), ncMsg));
end
end


function updateFrameList(cfg)
% radar.json: frames of the last KEEP_HOURS (newest frame time as reference)
files = dir(fullfile(cfg.archiveDir, 'TMD_composite_*.mat'));
tags = regexp({files.name}, '^TMD_composite_(\d{12})\.mat$', 'tokens', 'once');
okf = ~cellfun(@isempty, tags);
tags = sort(cellfun(@(c) c{1}, tags(okf), 'UniformOutput', false));
if isempty(tags)
    return;
end
t = datetime(tags, 'InputFormat', 'yyyyMMddHHmm');
keep = t >= t(end) - hours(cfg.KEEP_HOURS);
tags = tags(keep); t = t(keep);

% Bounds and grid from the newest frame
S = load(fullfile(cfg.archiveDir, sprintf('TMD_composite_%s.mat', tags{end})), 'lat', 'lon');
dlat = S.lat(2) - S.lat(1); dlon = S.lon(2) - S.lon(1);

fr = cell(numel(tags), 1);
for i = 1:numel(tags)
    png = sprintf('TMD_%s.png', tags{i});
    if ~exist(fullfile(cfg.dashDir, 'radar', png), 'file')
        continue;                                   % archived before the dashboard images existed
    end
    fr{i} = struct('time_utc', datestr(t(i), 'yyyy-mm-dd HH:MM'), ...
                   'time_local', datestr(t(i) + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM'), ...
                   'image', ['dashboard_data/radar/' png]);
end
fr = fr(~cellfun(@isempty, fr));

J = struct();
J.source  = 'TMD nationwide radar composite (weather.tmd.go.th/composite)';
J.units   = 'mm/h';
J.generated_local = datestr(datetime('now'), 'yyyy-mm-dd HH:MM');
J.bounds  = [S.lat(1) - dlat / 2, S.lon(1) - dlon / 2; S.lat(end) + dlat / 2, S.lon(end) + dlon / 2];
J.bins    = cfg.BINS;
J.colors  = cellfun(@(c) sprintf('#%02X%02X%02X', c), num2cell(cfg.COLORS, 2), 'UniformOutput', false);
J.frames  = [fr{:}];
% Nowcast made from the newest frame (if any)
J.nowcast = [];
ncFile = fullfile(cfg.archiveDir, 'nowcast_latest.mat');
if exist(ncFile, 'file')
    N = load(ncFile, 'nc');
    if isfield(N, 'nc') && strcmp(N.nc.base_tag, tags{end})
        J.nowcast = rmfield(N.nc, 'base_tag');
    end
end
writeJson(fullfile(cfg.dashDir, 'radar.json'), J);

% Remove dashboard images that dropped out of the window (the MAT archive stays)
imgs = dir(fullfile(cfg.dashDir, 'radar', 'TMD_*.png'));
for k = 1:numel(imgs)
    tk = regexp(imgs(k).name, '^TMD_(\d{12})\.png$', 'tokens', 'once');
    if ~isempty(tk) && ~ismember(tk{1}, tags)
        delete(fullfile(imgs(k).folder, imgs(k).name));
    end
end
% Nowcast images from older bases
imgs = dir(fullfile(cfg.dashDir, 'radar', 'NC_*.png'));
for k = 1:numel(imgs)
    tk = regexp(imgs(k).name, '^NC_(\d{12})_\d{3}\.png$', 'tokens', 'once');
    if ~isempty(tk) && ~strcmp(tk{1}, tags{end})
        delete(fullfile(imgs(k).folder, imgs(k).name));
    end
end
end


function writeRadarPng(cfg, R, lat, file)
% Transparent PNG, rows resampled to Web Mercator (row 1 = north), colours by rain-rate class
dlat = lat(2) - lat(1);
merc = @(la) log(tand(45 + la / 2));
latS = lat(1) - dlat / 2;  latN = lat(end) + dlat / 2;
yS = merc(latS);  yN = merc(latN);
H = numel(lat);
rowY   = yN - ((1:H)' - 0.5) / H * (yN - yS);
rowLat = 2 * atand(exp(rowY)) - 90;
ri = min(max(round((rowLat - lat(1)) / dlat) + 1, 1), numel(lat));
img = double(R(ri, :));
cls = discretize(img, [cfg.BINS Inf]);                             % NaN below the first edge
ok = isfinite(cls);
rgb = zeros([size(img) 3], 'uint8');
for c = 1:3
    ch = zeros(size(img), 'uint8');
    ch(ok) = uint8(cfg.COLORS(cls(ok), c));
    rgb(:, :, c) = ch;
end
imwrite(rgb, file, 'Alpha', double(ok));
end


function msg = makeNowcast(cfg, R1, lat, lon, timeUTC, tag)
% 2-hour Lagrangian-persistence nowcast from the newest frame (R1) and the one before
msg = '';
files = dir(fullfile(cfg.archiveDir, 'TMD_composite_*.mat'));
tags = regexp({files.name}, '^TMD_composite_(\d{12})\.mat$', 'tokens', 'once');
okf = ~cellfun(@isempty, tags);
tags = sort(cellfun(@(c) c{1}, tags(okf), 'UniformOutput', false));
tags = tags(~strcmp(tags, tag));
if isempty(tags)
    msg = 'nowcast: no earlier frame yet';
    return;
end
t0 = datetime(tags{end}, 'InputFormat', 'yyyyMMddHHmm');
gapMin = minutes(timeUTC - t0);
if gapMin <= 0 || gapMin > cfg.NC_MAX_GAP_MIN
    msg = sprintf('nowcast: previous frame is %.0f min older, skipped', gapMin);
    return;
end
P = load(fullfile(cfg.archiveDir, sprintf('TMD_composite_%s.mat', tags{end})), 'R');
R0 = double(P.R);  R1 = double(R1);
R0(~isfinite(R0)) = 0;  R1(~isfinite(R1)) = 0;

% --- Motion on a coarse grid, block matching on log rain rate ---
f = cfg.NC_COARSEN;
T = @(x) max(log10(x + 0.1) + 1, 0);                               % 0 for no rain
A = T(coarsen(R0, f));  B = T(coarsen(R1, f));
[ny, nx] = size(B);
bs = cfg.NC_BLOCK;  st = round(bs / 2);  md = cfg.NC_MAX_SHIFT;
thr = T(0.5);
cy = []; cx = []; vy = []; vx = [];
for by = 1 + md : st : ny - bs + 1 - md
    for bx = 1 + md : st : nx - bs + 1 - md
        b = B(by:by + bs - 1, bx:bx + bs - 1);
        if mean(b(:) >= thr) < cfg.NC_MIN_RAIN_FRAC
            continue;
        end
        b = b - mean(b(:));
        nb = sqrt(sum(b(:) .^ 2));
        if nb == 0, continue; end
        best = -Inf; bd = [0 0];
        for dy = -md:md
            for dx = -md:md
                a = A(by - dy:by - dy + bs - 1, bx - dx:bx - dx + bs - 1);   % where the pattern came from
                a = a - mean(a(:));
                na = sqrt(sum(a(:) .^ 2));
                if na == 0, continue; end
                c = sum(a(:) .* b(:)) / (na * nb);
                if c > best, best = c; bd = [dy dx]; end
            end
        end
        if best >= cfg.NC_MIN_CORR
            cy(end+1) = by + bs / 2; cx(end+1) = bx + bs / 2;      %#ok<AGROW>
            vy(end+1) = bd(1);       vx(end+1) = bd(2);            %#ok<AGROW>
        end
    end
end
if numel(vy) == 0 && ~any(R1(:) >= cfg.BINS(1))
    msg = 'nowcast: no rain';
    return;
end

% Motion field on the coarse grid (coarse cells per frame interval)
if numel(vy) >= 3
    Fy = scatteredInterpolant(cx(:), cy(:), vy(:), 'natural', 'nearest');
    Fx = scatteredInterpolant(cx(:), cy(:), vx(:), 'natural', 'nearest');
    [CX, CY] = meshgrid(1:nx, 1:ny);
    MVy = Fy(CX, CY);  MVx = Fx(CX, CY);
elseif numel(vy) >= 1
    MVy = median(vy) * ones(ny, nx);  MVx = median(vx) * ones(ny, nx);
else
    MVy = zeros(ny, nx);  MVx = zeros(ny, nx);                     % rain but no reliable motion
end

% To the fine grid, in fine cells per minute
[nyF, nxF] = size(R1);
cF = ((1:nx) - 0.5) * f + 0.5;  rF = ((1:ny) - 0.5) * f + 0.5;
[XF, YF] = meshgrid(1:nxF, 1:nyF);
Uf = interp2(cF, rF, MVx, XF, YF, 'linear', NaN);  Uf(~isfinite(Uf)) = median(MVx(:));
Vf = interp2(cF, rF, MVy, XF, YF, 'linear', NaN);  Vf(~isfinite(Vf)) = median(MVy(:));
Uf = Uf * f / gapMin;  Vf = Vf * f / gapMin;

% --- Extrapolation: move the newest field along the motion ---
leads = cfg.NC_LEAD_STEP_MIN:cfg.NC_LEAD_STEP_MIN:cfg.NC_LEAD_MAX_MIN;
fr = cell(numel(leads), 1);
for k = 1:numel(leads)
    L = leads(k);
    Rk = interp2(R1, XF - Uf * L, YF - Vf * L, 'linear', 0);       % backward (semi-Lagrangian)
    Rk(Rk < cfg.BINS(1)) = NaN;
    png = sprintf('NC_%s_%03d.png', tag, L);
    writeRadarPng(cfg, single(Rk), lat, fullfile(cfg.dashDir, 'radar', png));
    tk = timeUTC + minutes(L);
    fr{k} = struct('time_utc', datestr(tk, 'yyyy-mm-dd HH:MM'), ...
                   'time_local', datestr(tk + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM'), ...
                   'lead_min', L, 'image', ['dashboard_data/radar/' png]);
end

% Summary of the motion over rain areas (km/h, direction moving towards)
km = 111.2 * mean(diff(lat));                                       % km per fine cell (north-south)
rainy = R1 >= 0.5;
if any(rainy(:))
    mu = mean(Uf(rainy)) * cosd(mean(lat)) ;  mv = mean(Vf(rainy));
else
    mu = mean(Uf(:)) * cosd(mean(lat));  mv = mean(Vf(:));
end
spd = hypot(mu, mv) * km * 60;
dirTo = mod(atan2d(mu, mv), 360);

nc = struct();
nc.base_tag = tag;
nc.base_time_local = datestr(timeUTC + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM');
nc.n_vectors = numel(vy);
nc.speed_kmh = round(spd, 1);
nc.direction_to_deg = round(dirTo);
nc.frames = [fr{:}];
save(fullfile(cfg.archiveDir, 'nowcast_latest.mat'), 'nc');
msg = sprintf('nowcast: %d motion vectors, rain moving towards %.0f deg at %.0f km/h, %d frames to +%d min', ...
    numel(vy), dirTo, spd, numel(leads), leads(end));
end


function C = coarsen(R, f)
% Mean over f x f blocks (edges that do not fill a block are dropped)
[ny, nx] = size(R);
ny2 = floor(ny / f);  nx2 = floor(nx / f);
R = R(1:ny2 * f, 1:nx2 * f);
C = squeeze(mean(mean(reshape(R, f, ny2, f, nx2), 1), 3));
end


function msg = gaugeCheck(cfg, R, lat, lon, timeUTC)
% Radar rain rate at TMD stations vs the stations' rain in the last hour
msg = 'gauge check: no TMD file';
if ~exist(cfg.tmdLatest, 'file')
    return;
end
opts = detectImportOptions(cfg.tmdLatest, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
opts = setvartype(opts, intersect({'stationId', 'nameEn', 'province', 'dateTimeLocal'}, opts.VariableNames), 'char');
T = readtable(cfg.tmdLatest, opts);
tLoc = datetime(T.dateTimeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
near = abs(hours(tLoc - (timeUTC + hours(cfg.UTC_OFFSET_H)))) <= 1;
dlat = lat(2) - lat(1); dlon = lon(2) - lon(1);
ri = round((T.lat - lat(1)) / dlat) + 1;  ci = round((T.lon - lon(1)) / dlon) + 1;
in = near & ri >= 1 & ri <= numel(lat) & ci >= 1 & ci <= numel(lon) & isfinite(T.precip1Hr);
if ~any(in)
    msg = 'gauge check: no gauges within 1 h of the radar time';
    return;
end
rr = double(R(sub2ind(size(R), ri(in), ci(in))));
g  = T.precip1Hr(in);
okp = isfinite(rr);
rr = rr(okp);  g = g(okp);                          % keep radar and gauge values paired
wetR = rr >= 0.1;  wetG = g >= 0.1;
both = wetR & wetG;
msg = sprintf('gauge check: %d gauges; wet by radar %d, by gauge %d, both %d', ...
    numel(rr), sum(wetR), sum(wetG), sum(both));
if sum(both) >= 3
    msg = sprintf('%s; median radar/gauge %.2f', msg, median(rr(both) ./ g(both)));
end
end


function writeJson(outFile, data)
tmpFile = [outFile '.tmp'];
fid = fopen(tmpFile, 'w', 'n', 'UTF-8');
if fid == -1
    error('Cannot write %s', tmpFile);
end
fprintf(fid, '%s', jsonencode(data));
fclose(fid);
movefile(tmpFile, outFile, 'f');
end


function writeLog(logFile, msg)
fid = fopen(logFile, 'a');
if fid ~= -1
    fprintf(fid, '%s\n', msg);
    fclose(fid);
end
end
