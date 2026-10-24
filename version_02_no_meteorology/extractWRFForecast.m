% extractWRFForecast.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- WRF-Chem forecast feed with a
% time-lagged ensemble.
%
% Reads the operational WRF-Chem output directly over the sshfs mount
% (only surface fields, ~200 MB of the ~157 GB file; nothing is copied).
%
% EACH CYCLE (hourly at MINUTE_PAST_HOUR):
%   1. Lists the complete runs among the last BACKFILL_FOLDERS dated
%      folders. A run is complete when its wrfout file has EXPECTED_TIMES
%      steps and has not been modified for MIN_AGE_MIN minutes.
%   2. Extracts every complete run that has no station-forecast archive
%      yet (the first time this backfills older runs, ~45 s each).
%   3. For the newest run, also writes the PM2.5 map frames.
%   4. Builds the time-lagged ensemble: the newest run plus earlier runs
%      initialised up to ENS_MAX_AGE_DAYS before it (at most
%      ENS_MAX_MEMBERS), aligned on the newest run's hours. Members are
%      equally weighted; the dashboard shows their mean, their range and
%      how many of them exceed the Thai standard.
%   5. EVERY cycle (also without a new run, since new observations arrive
%      hourly): fits the observation-based forecast correction per station
%      and pollutant and writes forecast_correction.json (see below).
%   Steps 2-4 are skipped when there is no new run.
%
% FORECAST CORRECTION (decaying-weighted mean and variance scaling in log space)
%   For each station and pollutant, pairs of forecast and observed hourly
%   values from the last COR_WINDOW_DAYS (all archived runs, all lead
%   times) are weighted by age with a half-life of COR_HALF_LIFE_DAYS.
%   In log space, x = ln(forecast + c) and y = ln(observed + c):
%     bias:        beta  = mean_w(y) - mean_w(x)    (multiplicative bias)
%     variability: scale = sd_w(y) / sd_w(x)        (amplitude of the ups and downs)
%     corrected:   ln(F + c) = x + beta + (scale - 1)(x - mean_w(x))
%   Matching the observed variance (rather than regressing) keeps peaks
%   sharp instead of damping them. Safeguards: the scale is shrunk towards
%   1 with COR_PRIOR_N pseudo-hours and limited to COR_SCALE_LIMITS; it is
%   only used when there are COR_MIN_PAIRS_SCALE pairs and the forecast is
%   correlated with the observations (r >= COR_MIN_CORR) -- otherwise only
%   the bias is corrected; with fewer than COR_MIN_PAIRS_BIAS pairs there
%   is no correction. The dashboard applies the coefficients to the
%   station forecasts and, spread around each station, to the forecast map.
%
% Output file layout (WRF-Chem V4.3.3, d01, 9 km, Lambert conformal):
%   one wrfout file per run, 145 hourly steps (6 days) from 00 UTC.
%   Surface level (bottom_top = 1) is used for PM2.5 and PM10.
%   All output times are Bangkok local time (UTC+7).
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true). TO STOP: stopPlatformTimers
%
% OUTPUTS
%   <outDir>/WRF_StationForecast_<initUTC>.csv  hourly forecast at every PCD
%       station: PM25, PM10 (ug/m3), O3_ppb, CO_ppm, NO2_ppb, SO2_ppb (surface,
%       converted from WRF-Chem ppmv to PCD units), PBLH, T2_C, WS10, WD10
%       (earth-relative), RAIN_1h.
%       One per run -- the ensemble members and the verification archive.
%   <outDir>/WRF_GridPM25_<initUTC>.mat          regridded surface PM2.5 (newest runs)
%   <dashDir>/forecast_stations.json             newest run + ensemble members, per station
%   <dashDir>/forecast_correction.json           correction coefficients per station and pollutant
%   <dashDir>/forecast_grid_<P>.json             map frames for P = PM25, PM10, O3, CO, NO2, SO2
%                                                (newest run, whole domain; one file per
%                                                pollutant so the page loads only what it shows)
%   <outDir>/lastProcessedRun.mat, download_log.txt

clear; clc;
%% ============================ CONFIG =======================================
cfg.baseDir        = '/home/arun/HPC/Projects/NARITForecastingSystem/tes2';
cfg.filePattern    = 'wrfout_d01_*';
cfg.EXPECTED_TIMES = 145;     % 6-day hourly run incl. t = 0
cfg.MIN_AGE_MIN    = 15;      % file untouched this long = finished writing
cfg.BACKFILL_FOLDERS = 14;    % dated folders searched for complete runs (and backfilled)

% Time-lagged ensemble
cfg.ENS_MAX_MEMBERS  = 5;     % newest run + up to 4 earlier ones
cfg.ENS_MAX_AGE_DAYS = 4;     % oldest member initialised at most this long before the newest

% Observation-based correction
cfg.COR_WINDOW_DAYS     = 14;     % training window
cfg.COR_HALF_LIFE_DAYS  = 4;      % weight halves every 4 days back
cfg.COR_MIN_PAIRS_BIAS  = 12;     % fewer matched hours -> no correction
cfg.COR_MIN_PAIRS_SCALE = 72;     % fewer -> bias only (3 days of hours)
cfg.COR_MIN_CORR        = 0.3;    % weaker forecast-obs correlation -> bias only
cfg.COR_PRIOR_N         = 48;     % pseudo-hours pulling the scale towards 1
cfg.COR_SCALE_LIMITS    = [0.5 2];
cfg.COR_OFFSET = struct('PM25', 1, 'PM10', 1, 'O3', 1, 'CO', 0.01, 'NO2', 0.1, 'SO2', 0.1);  % c in ln(x + c), pollutant units
cfg.COR_TAIL_MB         = 40;     % bytes read from the end of the PCD archive
cfg.COR_MAP_RADIUS_KM   = 40;     % dashboard: how far a station's correction spreads on the map
cfg.COR_MAP_PRIOR_W     = 0.1;    % dashboard: fades the map correction to none away from stations

cfg.rootDir      = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform';
cfg.outDir       = fullfile(cfg.rootDir, 'WRF_Forecast');
cfg.dashDir      = fullfile(cfg.rootDir, 'dashboard', 'dashboard_data');
cfg.stationsFile = fullfile(cfg.rootDir, 'PCD_AllStations_Archive', 'PCD_Stations_latest.csv');
cfg.histFile     = fullfile(cfg.rootDir, 'PCD_AllStations_Archive', 'PCD_History_Archive.csv');

% Regular lat/lon grid for the dashboard map. [] = the whole model domain
% (mainland Southeast Asia); or give a box [W S E N] to cut it down.
cfg.GRID_BOX    = [];
cfg.GRID_RES    = 0.1;                      % degrees (~11 km, close to the 9 km model grid)
cfg.GRID_STEP_H = 3;                        % map frame every 3 h

% Map pollutants: dashboard name | byte step (value = byte * step, 0..254 steps)
%   PM in ug/m3, O3/NO2/SO2 in ppb, CO in ppm (same units as PCD)
cfg.MAP_POLL = {'PM25', 1; 'PM10', 1; 'O3', 1; 'CO', 0.02; 'NO2', 0.5; 'SO2', 0.25};

cfg.UTC_OFFSET_H = 7;

% Bump when the output format changes, so the dashboard files are rebuilt
cfg.FORMAT_VERSION = 4;

cfg.RUN_IN_BACKGROUND = true;
cfg.MINUTE_PAST_HOUR  = 5;
% ===========================================================================

if ~exist(cfg.outDir, 'dir'),  mkdir(cfg.outDir);  end
if ~exist(cfg.dashDir, 'dir'), mkdir(cfg.dashDir); end
cfg.logFile = fullfile(cfg.outDir, 'download_log.txt');

timerName = 'WRFForecastTimer';
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A WRF forecast timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

runWrfCycleSafe(cfg);

if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'hour') + minutes(cfg.MINUTE_PAST_HOUR);
    if nextRun <= nowLocal
        nextRun = nextRun + hours(1);
    end
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    wrfTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 3600, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runWrfCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('WRF forecast timer error: %s\n', evt.Data.message));
    start(wrfTimer);

    fprintf('\nWRF forecast extraction is now running in the background.\n');
    fprintf('Checks hourly at :%02d for a new complete run (next in %.0f s).\n', ...
        cfg.MINUTE_PAST_HOUR, startDelaySec);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runWrfCycleSafe(cfg)
try
    runWrfCycle(cfg);
catch ME
    fprintf('[%s] WRF forecast cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | %s', datestr(now), ME.message));
end
end


function runWrfCycle(cfg)
if ~exist(cfg.baseDir, 'dir')
    error('Forecast folder not visible: %s -- is the HPC mounted (sshfs with allow_other)?', cfg.baseDir);
end

%% ----- 1. Complete runs, newest first -----
runs = findCompleteRuns(cfg);
if isempty(runs)
    fprintf('[%s] No complete WRF run found in the last %d folders.\n', datestr(now), cfg.BACKFILL_FOLDERS);
    return;
end
newest = runs(1);

%% ----- 2. Extract runs that have no archive yet (newest one with map frames) -----
nNew = 0;
newestDone = false;
for r = 1:numel(runs)
    if ~exist(archiveCsv(cfg, runs(r).tag), 'file')
        extractRun(cfg, runs(r), r == 1);
        nNew = nNew + 1;
        newestDone = newestDone || (r == 1);
    end
end

%% ----- 3. Skip the rest if nothing changed -----
stateFile = fullfile(cfg.outDir, 'lastProcessedRun.mat');
upToDate = false;
if nNew == 0 && exist(stateFile, 'file') && ...
        exist(fullfile(cfg.dashDir, 'forecast_stations.json'), 'file') && ...
        exist(fullfile(cfg.dashDir, 'forecast_grid_PM25.json'), 'file')
    st = load(stateFile);
    upToDate = isfield(st, 'lastRunFile') && strcmp(st.lastRunFile, newest.file) && ...
               isfield(st, 'formatVersion') && st.formatVersion == cfg.FORMAT_VERSION;
end
if upToDate
    fprintf('[%s] Latest complete run (%s) already processed.\n', datestr(now), newest.label);
    computeCorrectionSafe(cfg);
    return;
end

% Map frames for the newest run if they were not made in step 2
if ~newestDone
    extractRun(cfg, newest, true);
end

%% ----- 4. Time-lagged ensemble + dashboard station file -----
nMem = buildEnsemble(cfg, newest);

%% ----- 5. Observation-based correction -----
computeCorrectionSafe(cfg);

lastRunFile = newest.file; %#ok<NASGU>
formatVersion = cfg.FORMAT_VERSION; %#ok<NASGU>
save(stateFile, 'lastRunFile', 'formatVersion');

msg = sprintf('%s | newest run %s | newly extracted=%d | ensemble members=%d', ...
    datestr(now), newest.label, nNew, nMem);
writeLog(cfg.logFile, msg);
fprintf('[%s] Done: newest run %s, %d newly extracted, ensemble of %d run(s).\n', ...
    datestr(now), newest.label, nNew, nMem);
end


function runs = findCompleteRuns(cfg)
% Struct array (file, label, tag), newest first. tag = init time 'yyyymmddHH' (UTC).
runs = struct('file', {}, 'label', {}, 'tag', {});
d = dir(cfg.baseDir);
d = d([d.isdir]);
names = {d.name};
names = sort(names(~cellfun(@isempty, regexp(names, '^\d{4}-\d{2}-\d{2}$', 'once'))));
for k = numel(names):-1:max(1, numel(names) - cfg.BACKFILL_FOLDERS + 1)
    runDir = fullfile(cfg.baseDir, names{k});
    files = dir(fullfile(runDir, cfg.filePattern));
    if isempty(files)
        continue;
    end
    f = fullfile(runDir, files(1).name);
    ageMin = (now - files(1).datenum) * 24 * 60;
    if ageMin < cfg.MIN_AGE_MIN
        fprintf('  %s: still being written (modified %.0f min ago), skipping.\n', names{k}, ageMin);
        continue;
    end
    tok = regexp(files(1).name, '(\d{4})-(\d{2})-(\d{2})_(\d{2})', 'tokens', 'once');
    if isempty(tok)
        continue;
    end
    try
        vi = ncinfo(f, 'Times');
        nTimes = vi.Size(2);
    catch
        continue;
    end
    if nTimes < cfg.EXPECTED_TIMES
        fprintf('  %s: %d of %d time steps, skipping.\n', names{k}, nTimes, cfg.EXPECTED_TIMES);
        continue;
    end
    runs(end+1) = struct('file', f, 'label', fullfile(names{k}, files(1).name), ...
                         'tag', [tok{:}]); %#ok<AGROW>
end
end


function fn = archiveCsv(cfg, tag)
fn = fullfile(cfg.outDir, sprintf('WRF_StationForecast_%s.csv', tag));
end


function extractRun(cfg, run, doGrid)
% Station forecast CSV for one run; with doGrid, also the map frames.
t0 = tic;
if doGrid
    fprintf('  extracting %s (stations + map) ...\n', run.label);
else
    fprintf('  extracting %s (stations) ...\n', run.label);
end
f = run.file;

lat = double(ncread(f, 'XLAT',  [1 1 1], [Inf Inf 1]));
lon = double(ncread(f, 'XLONG', [1 1 1], [Inf Inf 1]));
[nx, ny] = size(lat);

timesChar = ncread(f, 'Times')';
tUTC = datetime(cellstr(timesChar), 'InputFormat', 'yyyy-MM-dd_HH:mm:ss');
tLoc = tUTC + hours(cfg.UTC_OFFSET_H);
nT   = numel(tUTC);

pm25 = readSurface(f, 'PM2_5_DRY', nx, ny, nT, true);
pm10 = readSurface(f, 'PM10',      nx, ny, nT, true);
pblh = readSurface(f, 'PBLH',      nx, ny, nT, false);
t2   = readSurface(f, 'T2',        nx, ny, nT, false) - 273.15;
u10  = readSurface(f, 'U10',       nx, ny, nT, false);
v10  = readSurface(f, 'V10',       nx, ny, nT, false);
rain = readSurface(f, 'RAINNC',    nx, ny, nT, false) + readSurface(f, 'RAINC', nx, ny, nT, false);
% Gases: WRF-Chem ppmv at the lowest level -> PCD units (ppb; CO in ppm)
o3   = readSurface(f, 'o3',  nx, ny, nT, true) * 1000;
co   = readSurface(f, 'co',  nx, ny, nT, true);
no2  = readSurface(f, 'no2', nx, ny, nT, true) * 1000;
so2  = readSurface(f, 'so2', nx, ny, nT, true) * 1000;

% Grid-relative winds -> earth-relative (Lambert conformal)
if hasVar(f, 'COSALPHA') && hasVar(f, 'SINALPHA')
    cosa = double(ncread(f, 'COSALPHA', [1 1 1], [Inf Inf 1]));
    sina = double(ncread(f, 'SINALPHA', [1 1 1], [Inf Inf 1]));
    ue = u10 .* cosa - v10 .* sina;
    ve = v10 .* cosa + u10 .* sina;
else
    ue = u10;
    ve = v10;
end
clear u10 v10;

rain1h = cat(3, nan(nx, ny), diff(rain, 1, 3));      % hourly rain from accumulated totals
rain1h(rain1h < 0) = 0;
clear rain;

% Stations inside the domain
S = readStations(cfg.stationsFile);
inDom = S.lat >= min(lat(:)) & S.lat <= max(lat(:)) & S.lon >= min(lon(:)) & S.lon <= max(lon(:));
S = S(inDom, :);
nS = height(S);

% Map grid (newest run only)
if doGrid
    box = cfg.GRID_BOX;
    if isempty(box)
        r = cfg.GRID_RES;
        box = [ceil(min(lon(:)) / r) * r, ceil(min(lat(:)) / r) * r, ...
               floor(max(lon(:)) / r) * r, floor(max(lat(:)) / r) * r];
    end
    gridLon = box(1):cfg.GRID_RES:box(3);
    gridLat = box(2):cfg.GRID_RES:box(4);
    [GLON, GLAT] = meshgrid(gridLon, gridLat);       % nLat x nLon
    frameIdx = 1:cfg.GRID_STEP_H:nT;
    nMap = size(cfg.MAP_POLL, 1);
    G = cell(nMap, 1);
    for j = 1:nMap
        G{j} = nan(numel(gridLat), numel(gridLon), numel(frameIdx), 'single');
    end
else
    frameIdx = [];
end

F = scatteredInterpolant(lon(:), lat(:), zeros(numel(lon), 1), 'linear', 'none');
fields = {pm25, pm10, pblh, t2, ue, ve, rain1h, o3, co, no2, so2};
mapFields = {pm25, pm10, o3, co, no2, so2};          % same order as cfg.MAP_POLL
nV = numel(fields);
SV = nan(nS, nT, nV);
for k = 1:nT
    for v = 1:nV
        if all(all(isnan(fields{v}(:, :, k))))
            continue;                                % variable missing from this run
        end
        F.Values = reshape(fields{v}(:, :, k), [], 1);
        SV(:, k, v) = F(S.lon, S.lat);
    end
    gi = find(frameIdx == k, 1);
    if ~isempty(gi)
        for j = 1:numel(mapFields)
            if all(all(isnan(mapFields{j}(:, :, k))))
                continue;                            % variable missing from this run
            end
            F.Values = reshape(mapFields{j}(:, :, k), [], 1);
            G{j}(:, :, gi) = single(F(GLON, GLAT));
        end
    end
end
clear fields mapFields pm25 pm10 pblh t2 ue ve rain1h o3 co no2 so2;

ws = hypot(SV(:, :, 5), SV(:, :, 6));
wd = mod(atan2d(-SV(:, :, 5), -SV(:, :, 6)), 360);   % direction the wind blows FROM

% Station forecast CSV (ensemble member + verification archive)
[ss, kk] = meshgrid(1:nS, 1:nT);                    % station-major (all hours of station 1 first)
ss = ss(:); kk = kk(:);
lin = sub2ind([nS nT], ss, kk);
P25 = SV(:, :, 1); P10 = SV(:, :, 2); PBL = SV(:, :, 3); T2C = SV(:, :, 4); R1 = SV(:, :, 7);
O3 = SV(:, :, 8); CO = SV(:, :, 9); NO2 = SV(:, :, 10); SO2 = SV(:, :, 11);
tLocStr = cellstr(datestr(tLoc, 'yyyy-mm-dd HH:MM'));
Tout = table(S.stationID(ss), tLocStr(kk), round(P25(lin), 2), round(P10(lin), 2), ...
    round(O3(lin), 2), round(CO(lin), 3), round(NO2(lin), 2), round(SO2(lin), 2), ...
    round(PBL(lin)), round(T2C(lin), 1), round(ws(lin), 1), round(wd(lin)), round(R1(lin), 2), ...
    'VariableNames', {'stationID', 'time_local', 'PM25', 'PM10', 'O3_ppb', 'CO_ppm', 'NO2_ppb', 'SO2_ppb', ...
                      'PBLH', 'T2_C', 'WS10', 'WD10', 'RAIN_1h'});
writetable(Tout, archiveCsv(cfg, run.tag));

if doGrid
    mapNames = cfg.MAP_POLL(:, 1)'; %#ok<NASGU>
    save(fullfile(cfg.outDir, sprintf('WRF_Grid_%s.mat', run.tag)), ...
        'G', 'mapNames', 'gridLat', 'gridLon', 'tLoc', 'frameIdx');

    for j = 1:size(cfg.MAP_POLL, 1)
        if all(isnan(G{j}(:)))
            continue;                                % not in this run's output
        end
        step = cfg.MAP_POLL{j, 2};
        Gj = struct();
        Gj.pollutant   = cfg.MAP_POLL{j, 1};
        Gj.run_file    = run.label;
        Gj.init_local  = datestr(tLoc(1), 'yyyy-mm-dd HH:MM');
        Gj.lat0 = gridLat(1); Gj.lon0 = gridLon(1);
        Gj.dlat = cfg.GRID_RES; Gj.dlon = cfg.GRID_RES;
        Gj.nlat = numel(gridLat); Gj.nlon = numel(gridLon);
        Gj.times_local = cellstr(datestr(tLoc(frameIdx), 'yyyy-mm-dd HH:MM'));
        % Each frame: value / scale rounded to 0..254, 255 = outside the
        % domain; one byte per cell (row-major, south row first), base64.
        Gj.encoding = 'uint8-base64';
        Gj.scale = step;
        Gj.pm25 = cell(numel(frameIdx), 1);          % field name kept for the page; holds this pollutant
        for i = 1:numel(frameIdx)
            fr = G{j}(:, :, i)';
            v  = round(double(fr(:)') / step);
            bad = ~isfinite(v);
            v  = min(max(v, 0), 254);
            v(bad) = 255;
            Gj.pm25{i} = matlab.net.base64encode(uint8(v));
        end
        writeJson(fullfile(cfg.dashDir, sprintf('forecast_grid_%s.json', cfg.MAP_POLL{j, 1})), Gj);
    end
end
fprintf('    %d stations x %d h%s in %.0f s\n', nS, nT, ...
    repmat(sprintf(', %d map frames', numel(frameIdx)), 1, doGrid), toc(t0));
end


function nMem = buildEnsemble(cfg, newest)
% Time-lagged ensemble on the newest run's hours -> forecast_stations.json
files = dir(fullfile(cfg.outDir, 'WRF_StationForecast_*.csv'));
tags = regexp({files.name}, '^WRF_StationForecast_(\d{10})\.csv$', 'tokens', 'once');
ok = ~cellfun(@isempty, tags);
tags = cellfun(@(c) c{1}, tags(ok), 'UniformOutput', false);
tagTime = datetime(tags, 'InputFormat', 'yyyyMMddHH');
newestTime = datetime(newest.tag, 'InputFormat', 'yyyyMMddHH');

use = tagTime <= newestTime & tagTime >= newestTime - days(cfg.ENS_MAX_AGE_DAYS);
tags = tags(use); tagTime = tagTime(use);
[tagTime, ord] = sort(tagTime, 'descend');           % newest first
tags = tags(ord);
nMem = min(numel(tags), cfg.ENS_MAX_MEMBERS);
tags = tags(1:nMem); tagTime = tagTime(1:nMem);

% Newest member defines the stations and the hourly axis
T0  = readForecastCsv(archiveCsv(cfg, tags{1}));
ids = unique(T0.stationID, 'stable');
t   = datetime(T0.time_local, 'InputFormat', 'yyyy-MM-dd HH:mm');
tAx0 = min(t);
nT  = round(hours(max(t) - tAx0)) + 1;
nS  = numel(ids);

E = nan(nS, nT, nMem);                               % PM2.5 members
PB = nan(nS, nT); RN = nan(nS, nT);                  % newest run only
extraCols  = {'PM10', 'O3_ppb', 'CO_ppm', 'NO2_ppb', 'SO2_ppb'};   % newest run only
extraNames = {'PM10', 'O3', 'CO', 'NO2', 'SO2'};
extraDec   = [1, 1, 2, 1, 1];
X = nan(nS, nT, numel(extraCols));
for m = 1:nMem
    if m == 1
        T = T0;
    else
        T = readForecastCsv(archiveCsv(cfg, tags{m}));
    end
    [tf, si] = ismember(T.stationID, ids);
    k  = round(hours(datetime(T.time_local, 'InputFormat', 'yyyy-MM-dd HH:mm') - tAx0)) + 1;
    okr = tf & k >= 1 & k <= nT;
    E(sub2ind([nS nT nMem], si(okr), k(okr), m * ones(sum(okr), 1))) = T.PM25(okr);
    if m == 1
        PB(sub2ind([nS nT], si(okr), k(okr))) = T.PBLH(okr);
        RN(sub2ind([nS nT], si(okr), k(okr))) = T.RAIN_1h(okr);
        for c = 1:numel(extraCols)
            if ismember(extraCols{c}, T.Properties.VariableNames)
                X(sub2ind([nS nT numel(extraCols)], si(okr), k(okr), c * ones(sum(okr), 1))) = ...
                    T.(extraCols{c})(okr);
            end
        end
    end
end

J = struct();
J.run_file   = newest.label;
J.init_utc   = datestr(newestTime, 'yyyy-mm-dd HH:MM');
J.init_local = datestr(newestTime + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM');
J.t0_local   = datestr(tAx0, 'yyyy-mm-dd HH:MM:SS');
J.n          = nT;
J.step_h     = 1;
J.n_members  = nMem;
J.members_init_local = cellstr(datestr(tagTime + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM'));
st = cell(nS, 1);
for s = 1:nS
    r = struct();
    r.id     = ids{s};
    r.PM25   = round(E(s, :, 1), 1);
    r.PBLH   = round(PB(s, :));
    r.RAIN1H = round(RN(s, :), 1);
    for c = 1:numel(extraNames)
        r.(extraNames{c}) = round(X(s, :, c), extraDec(c));
    end
    r.ens    = round(reshape(E(s, :, :), nT, nMem)', 1);   % members x hours, newest first
    st{s} = r;
end
J.stations = [st{:}];
writeJson(fullfile(cfg.dashDir, 'forecast_stations.json'), J);
end


function computeCorrectionSafe(cfg)
try
    computeCorrection(cfg);
catch ME
    fprintf('[%s] Forecast correction failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | correction: %s', datestr(now), ME.message));
end
end


function computeCorrection(cfg)
% Fits the per-station, per-pollutant correction -> forecast_correction.json
tc = tic;
P      = {'PM25', 'PM10', 'O3', 'CO', 'NO2', 'SO2'};
fcCols = {'PM25', 'PM10', 'O3_ppb', 'CO_ppm', 'NO2_ppb', 'SO2_ppb'};
nP = numel(P);
offs = cellfun(@(x) cfg.COR_OFFSET.(x), P);

nowL = datetime('now', 'TimeZone', 'Asia/Bangkok');
nowL.TimeZone = '';
tEnd   = dateshift(nowL, 'start', 'hour');
tStart = tEnd - days(cfg.COR_WINDOW_DAYS);
nH = round(hours(tEnd - tStart)) + 1;

% --- Observations on an hourly grid: station x hour x pollutant ---
[oID, oT, oV, oNames] = readObsTail(cfg.histFile, cfg.COR_TAIL_MB, tStart);
ids = unique(oID);
nS  = numel(ids);
Obs = nan(nS, nH, nP);
if nS > 0
    [~, si] = ismember(oID, ids);
    k  = round(hours(oT - tStart)) + 1;
    ok = k >= 1 & k <= nH;
    for p = 1:nP
        j = find(strcmp(oNames, P{p}), 1);
        if ~isempty(j)
            Obs(sub2ind([nS nH nP], si(ok), k(ok), p * ones(sum(ok), 1))) = oV(ok, j);
        end
    end
end

% --- Forecast-observation pairs from every archived run in the window ---
files = dir(fullfile(cfg.outDir, 'WRF_StationForecast_*.csv'));
tags = regexp({files.name}, '^WRF_StationForecast_(\d{10})\.csv$', 'tokens', 'once');
okf = ~cellfun(@isempty, tags);
tags = cellfun(@(c) c{1}, tags(okf), 'UniformOutput', false);
initL = datetime(tags, 'InputFormat', 'yyyyMMddHH') + hours(cfg.UTC_OFFSET_H);
use = initL >= tStart - days(6) & initL <= nowL;     % runs with valid times in the window
tags = tags(use);

G = []; X = []; Y = []; W = [];                       % group (station, pollutant), ln fc, ln obs, weight
for f = 1:numel(tags)
    T = readForecastCsv(archiveCsv(cfg, tags{f}));
    [tf, fsi] = ismember(T.stationID, ids);
    t  = datetime(T.time_local, 'InputFormat', 'yyyy-MM-dd HH:mm');
    k  = round(hours(t - tStart)) + 1;
    ok = tf & k >= 1 & k <= nH & t <= nowL;
    ageW = 0.5 .^ (days(nowL - t) / cfg.COR_HALF_LIFE_DAYS);
    for p = 1:nP
        if ~ismember(fcCols{p}, T.Properties.VariableNames)
            continue;                                 % older runs have no gases
        end
        fc = T.(fcCols{p});
        ob = nan(height(T), 1);
        ob(ok) = Obs(sub2ind([nS nH nP], fsi(ok), k(ok), p * ones(sum(ok), 1)));
        good = ok & isfinite(fc) & isfinite(ob) & fc >= 0 & ob >= 0;
        G = [G; (fsi(good) - 1) * nP + p];                       %#ok<AGROW>
        X = [X; log(fc(good) + offs(p))];                        %#ok<AGROW>
        Y = [Y; log(ob(good) + offs(p))];                        %#ok<AGROW>
        W = [W; ageW(good)];                                     %#ok<AGROW>
    end
end

% --- Weighted moments per group, then the coefficients ---
nG = nS * nP;
if isempty(G)
    cnt = zeros(nG, 1); Sw = cnt; Swx = cnt; Swy = cnt; Swxx = cnt; Swyy = cnt; Swxy = cnt;
else
    cnt  = accumarray(G, 1, [nG 1]);
    Sw   = accumarray(G, W, [nG 1]);
    Swx  = accumarray(G, W .* X, [nG 1]);
    Swy  = accumarray(G, W .* Y, [nG 1]);
    Swxx = accumarray(G, W .* X .^ 2, [nG 1]);
    Swyy = accumarray(G, W .* Y .^ 2, [nG 1]);
    Swxy = accumarray(G, W .* X .* Y, [nG 1]);
end

st = cell(nS, 1);
nBias = zeros(1, nP); nFull = zeros(1, nP);
for s = 1:nS
    r = struct('id', ids{s});
    hasAny = false;
    for p = 1:nP
        g = (s - 1) * nP + p;
        n = cnt(g);
        if n < cfg.COR_MIN_PAIRS_BIAS || Sw(g) <= 0
            continue;
        end
        mx = Swx(g) / Sw(g);
        my = Swy(g) / Sw(g);
        vx = max(Swxx(g) / Sw(g) - mx ^ 2, 0);
        vy = max(Swyy(g) / Sw(g) - my ^ 2, 0);
        cxy = Swxy(g) / Sw(g) - mx * my;
        rr = cxy / sqrt(max(vx * vy, eps));
        scale = 1;
        mode = 'bias';
        if n >= cfg.COR_MIN_PAIRS_SCALE && vx > 1e-6 && vy > 1e-6 && rr >= cfg.COR_MIN_CORR
            sRaw  = sqrt(vy / vx);
            scale = 1 + (sRaw - 1) * n / (n + cfg.COR_PRIOR_N);
            scale = min(max(scale, cfg.COR_SCALE_LIMITS(1)), cfg.COR_SCALE_LIMITS(2));
            mode  = 'bias+variability';
            nFull(p) = nFull(p) + 1;
        else
            nBias(p) = nBias(p) + 1;
        end
        r.(P{p}) = struct('mode', mode, 'beta', round(my - mx, 4), 'scale', round(scale, 3), ...
                          'mf', round(mx, 4), 'n', n, 'r', round(rr, 2));
        hasAny = true;
    end
    if hasAny
        st{s} = r;
    end
end
st = st(~cellfun(@isempty, st));

J = struct();
J.generated_local = datestr(nowL, 'yyyy-mm-dd HH:MM');
J.method = 'decaying-weighted mean and variance scaling in log space';
J.window_days    = cfg.COR_WINDOW_DAYS;
J.half_life_days = cfg.COR_HALF_LIFE_DAYS;
J.offsets        = cfg.COR_OFFSET;
J.map_radius_km  = cfg.COR_MAP_RADIUS_KM;
J.map_prior_weight = cfg.COR_MAP_PRIOR_W;
if isempty(st)
    J.stations = [];
else
    J.stations = st;                                  % cell -> JSON array (fields differ per station)
end
writeJson(fullfile(cfg.dashDir, 'forecast_correction.json'), J);

fprintf('  correction: %d runs, %d pairs; PM2.5 bias+variability at %d stations, bias only at %d (%.0f s)\n', ...
    numel(tags), numel(G), nFull(1), nBias(1), toc(tc));
end


function [oID, oT, oV, oNames] = readObsTail(histFile, tailMB, tStart)
% Last tailMB of the PCD archive, rows from tStart on.
oID = {}; oT = NaT(0, 1); oV = zeros(0, 0); oNames = {};
if ~exist(histFile, 'file')
    return;
end
fid = fopen(histFile, 'r', 'n', 'UTF-8');
header    = strsplit(strtrim(fgetl(fid)), ',');
dataStart = ftell(fid);
fseek(fid, 0, 'eof');
fileSize = ftell(fid);
startPos = fileSize - tailMB * 1e6;
if startPos > dataStart
    fseek(fid, startPos, 'bof');
    fgetl(fid);                                       % drop the partial first line
else
    fseek(fid, dataStart, 'bof');
end
oNames = header(6:end);                               % stationID,nameEN,lat,lon,DATETIMEDATA,<pollutants>
fmt = ['%q%q%f%f%q' repmat('%f', 1, numel(oNames))];
C = textscan(fid, fmt, 'Delimiter', ',', 'EndOfLine', '\n');
fclose(fid);

nRow = min(cellfun(@numel, C));
t = NaT(nRow, 1);
okT = ~cellfun(@isempty, C{5}(1:nRow));
t(okT) = datetime(C{5}(okT), 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
keep = find(~isnat(t) & t >= tStart);
oID = C{1}(keep);
oT  = t(keep);
oV  = nan(numel(keep), numel(oNames));
for j = 1:numel(oNames)
    col = C{5 + j};
    oV(:, j) = col(keep);
end
end


function T = readForecastCsv(file)
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',');
opts = setvartype(opts, {'stationID', 'time_local'}, 'char');
T = readtable(file, opts);
end


function A = readSurface(f, name, nx, ny, nT, is3D)
% Surface field as nx x ny x nT double; NaN if the variable is missing.
if ~hasVar(f, name)
    A = nan(nx, ny, nT);
    return;
end
if is3D
    A = double(squeeze(ncread(f, name, [1 1 1 1], [Inf Inf 1 Inf])));
else
    A = double(ncread(f, name));
end
A = reshape(A, nx, ny, nT);
end


function tf = hasVar(f, name)
persistent cacheFile cacheVars
if isempty(cacheFile) || ~strcmp(cacheFile, f)
    info = ncinfo(f);
    cacheVars = {info.Variables.Name};
    cacheFile = f;
end
tf = any(strcmp(cacheVars, name));
end


function S = readStations(file)
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
txt = intersect({'stationID', 'nameEN', 'areaEN', 'stationType', 'AQILast_time', 'nameTH', 'areaTH'}, opts.VariableNames);
opts = setvartype(opts, txt, 'char');
opts = setvartype(opts, {'lat', 'lon'}, 'double');
T = readtable(file, opts);
ok = isfinite(T.lat) & isfinite(T.lon);
S = table(T.stationID(ok), T.lat(ok), T.lon(ok), 'VariableNames', {'stationID', 'lat', 'lon'});
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
