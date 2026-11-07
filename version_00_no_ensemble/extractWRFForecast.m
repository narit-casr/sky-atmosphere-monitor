% extractWRFForecast.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- WRF-Chem forecast feed.
%
% Reads the operational WRF-Chem output directly over the sshfs mount
% (no copying: only surface fields are read, ~200 MB of the ~157 GB file)
% and writes small forecast products for the dashboard and for later
% forecast verification.
%
% WHICH RUN: the newest dated folder (yyyy-mm-dd) under baseDir whose
% wrfout file is COMPLETE, i.e. has EXPECTED_TIMES time steps and has not
% been modified for MIN_AGE_MIN minutes. A run that is still going is
% skipped automatically, so today this picks 2026-10-13 while 2026-10-14
% is still running. Each run is processed once; later cycles skip it.
%
% Output file layout (WRF-Chem V4.3.3, d01, 9 km, Lambert conformal):
%   one wrfout file per run, 145 hourly steps (6 days) from 00 UTC.
%   Surface level (bottom_top = 1) is used for PM2.5 and PM10.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true): once now, then hourly
% at MINUTE_PAST_HOUR. TO STOP: stopPlatformTimers
%
% OUTPUTS
%   <outDir>/WRF_StationForecast_<init>.csv  hourly forecast at every PCD
%       station (bilinear from the model grid): PM25, PM10, PBLH, T2_C,
%       WS10, WD10 (earth-relative), RAIN_1h. Kept per run for verification.
%   <outDir>/WRF_GridPM25_<init>.mat          regridded surface PM2.5 (archive)
%   <dashDir>/forecast_stations.json          station forecasts for the dashboard
%   <dashDir>/forecast_grid.json              PM2.5 map frames (whole domain) for the dashboard
%   <outDir>/lastProcessedRun.mat, download_log.txt

clear; clc;
%% ============================ CONFIG =======================================
cfg.baseDir        = '/home/arun/HPC/Projects/NARITForecastingSystem/tes2';
cfg.filePattern    = 'wrfout_d01_*';
cfg.EXPECTED_TIMES = 145;     % 6-day hourly run incl. t = 0
cfg.MIN_AGE_MIN    = 15;      % file untouched this long = finished writing
cfg.MAX_FOLDERS_BACK = 7;     % how many dated folders to search back

cfg.rootDir      = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform';
cfg.outDir       = fullfile(cfg.rootDir, 'WRF_Forecast');
cfg.dashDir      = fullfile(cfg.rootDir, 'dashboard', 'dashboard_data');
cfg.stationsFile = fullfile(cfg.rootDir, 'PCD_AllStations_Archive', 'PCD_Stations_latest.csv');

% Regular lat/lon grid for the dashboard map. [] = the whole model domain
% (mainland Southeast Asia); or give a box [W S E N] to cut it down.
cfg.GRID_BOX    = [];
cfg.GRID_RES    = 0.1;                      % degrees (~11 km, close to the 9 km model grid)
cfg.GRID_STEP_H = 3;                        % map frame every 3 h

cfg.UTC_OFFSET_H = 7;

% Bump when the output format changes, so already-processed runs are redone
cfg.FORMAT_VERSION = 2;

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

%% ----- 1. Find the newest complete run -----
[runFile, runLabel] = findLatestCompleteRun(cfg);
if isempty(runFile)
    fprintf('[%s] No complete WRF run found in the last %d folders.\n', datestr(now), cfg.MAX_FOLDERS_BACK);
    return;
end

stateFile = fullfile(cfg.outDir, 'lastProcessedRun.mat');
if exist(stateFile, 'file')
    st = load(stateFile);
    if isfield(st, 'lastRunFile') && strcmp(st.lastRunFile, runFile) && ...
            isfield(st, 'formatVersion') && st.formatVersion == cfg.FORMAT_VERSION && ...
            exist(fullfile(cfg.dashDir, 'forecast_stations.json'), 'file')
        fprintf('[%s] Latest complete run (%s) already processed.\n', datestr(now), runLabel);
        return;
    end
end
fprintf('[%s] Processing %s ...\n', datestr(now), runFile);
tic;

%% ----- 2. Read surface fields (hyperslabs only) -----
f = runFile;
lat = double(ncread(f, 'XLAT',  [1 1 1], [Inf Inf 1]));
lon = double(ncread(f, 'XLONG', [1 1 1], [Inf Inf 1]));
[nx, ny] = size(lat);

timesChar = ncread(f, 'Times')';
tUTC  = datetime(cellstr(timesChar), 'InputFormat', 'yyyy-MM-dd_HH:mm:ss');
tLoc  = tUTC + hours(cfg.UTC_OFFSET_H);
nT    = numel(tUTC);
initTag = datestr(tUTC(1), 'yyyymmddHH');

pm25 = readSurface(f, 'PM2_5_DRY', nx, ny, nT, true);
pm10 = readSurface(f, 'PM10',      nx, ny, nT, true);
pblh = readSurface(f, 'PBLH',      nx, ny, nT, false);
t2   = readSurface(f, 'T2',        nx, ny, nT, false) - 273.15;
u10  = readSurface(f, 'U10',       nx, ny, nT, false);
v10  = readSurface(f, 'V10',       nx, ny, nT, false);
rain = readSurface(f, 'RAINNC',    nx, ny, nT, false) + readSurface(f, 'RAINC', nx, ny, nT, false);
fprintf('  read surface fields in %.0f s\n', toc);

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

% Hourly rain from the accumulated totals
rain1h = cat(3, nan(nx, ny), diff(rain, 1, 3));
rain1h(rain1h < 0) = 0;
clear rain;

%% ----- 3. Interpolate to stations and to the regular map grid -----
S = readStations(cfg.stationsFile);
inDom = S.lat >= min(lat(:)) & S.lat <= max(lat(:)) & S.lon >= min(lon(:)) & S.lon <= max(lon(:));
S = S(inDom, :);
nS = height(S);

box = cfg.GRID_BOX;
if isempty(box)
    r = cfg.GRID_RES;
    box = [ceil(min(lon(:)) / r) * r, ceil(min(lat(:)) / r) * r, ...
           floor(max(lon(:)) / r) * r, floor(max(lat(:)) / r) * r];
end
gridLon = box(1):cfg.GRID_RES:box(3);
gridLat = box(2):cfg.GRID_RES:box(4);
[GLON, GLAT] = meshgrid(gridLon, gridLat);           % nLat x nLon
frameIdx = 1:cfg.GRID_STEP_H:nT;
G = nan(numel(gridLat), numel(gridLon), numel(frameIdx), 'single');

F = scatteredInterpolant(lon(:), lat(:), zeros(numel(lon), 1), 'linear', 'none');
fields = {pm25, pm10, pblh, t2, ue, ve, rain1h};
nV = numel(fields);
SV = nan(nS, nT, nV);
for k = 1:nT
    for v = 1:nV
        F.Values = reshape(fields{v}(:, :, k), [], 1);
        SV(:, k, v) = F(S.lon, S.lat);
    end
    gi = find(frameIdx == k, 1);
    if ~isempty(gi)
        F.Values = reshape(pm25(:, :, k), [], 1);
        G(:, :, gi) = single(F(GLON, GLAT));
    end
end
clear fields pm25 pm10 pblh t2 ue ve rain1h;

ws = hypot(SV(:, :, 5), SV(:, :, 6));
wd = mod(atan2d(-SV(:, :, 5), -SV(:, :, 6)), 360);    % direction the wind blows FROM

%% ----- 4. Station forecast CSV (archive, for verification) -----
[ss, kk] = meshgrid(1:nS, 1:nT);                    % station-major order (all hours of station 1 first)
ss = ss(:); kk = kk(:);
lin = sub2ind([nS nT], ss, kk);
P25 = SV(:, :, 1); P10 = SV(:, :, 2); PBL = SV(:, :, 3); T2C = SV(:, :, 4); R1 = SV(:, :, 7);
tLocStr = cellstr(datestr(tLoc, 'yyyy-mm-dd HH:MM'));
Tout = table(S.stationID(ss), tLocStr(kk), round(P25(lin), 2), round(P10(lin), 2), ...
    round(PBL(lin)), round(T2C(lin), 1), round(ws(lin), 1), round(wd(lin)), round(R1(lin), 2), ...
    'VariableNames', {'stationID', 'time_local', 'PM25', 'PM10', 'PBLH', 'T2_C', 'WS10', 'WD10', 'RAIN_1h'});
csvFile = fullfile(cfg.outDir, sprintf('WRF_StationForecast_%s.csv', initTag));
writetable(Tout, csvFile);

save(fullfile(cfg.outDir, sprintf('WRF_GridPM25_%s.mat', initTag)), ...
    'G', 'gridLat', 'gridLon', 'tLoc', 'frameIdx', 'runFile');

%% ----- 5. Dashboard JSON -----
J = struct();
J.run_file   = runLabel;
J.init_utc   = datestr(tUTC(1), 'yyyy-mm-dd HH:MM');
J.init_local = datestr(tLoc(1), 'yyyy-mm-dd HH:MM');
J.t0_local   = datestr(tLoc(1), 'yyyy-mm-dd HH:MM:SS');
J.n          = nT;
J.step_h     = 1;
st = cell(nS, 1);
for s = 1:nS
    r = struct();
    r.id     = S.stationID{s};
    r.PM25   = round(P25(s, :), 1);
    r.PBLH   = round(PBL(s, :));
    r.RAIN1H = round(R1(s, :), 1);
    st{s} = r;
end
J.stations = [st{:}];
writeJson(fullfile(cfg.dashDir, 'forecast_stations.json'), J);

Gj = struct();
Gj.init_local  = J.init_local;
Gj.lat0 = gridLat(1); Gj.lon0 = gridLon(1);
Gj.dlat = cfg.GRID_RES; Gj.dlon = cfg.GRID_RES;
Gj.nlat = numel(gridLat); Gj.nlon = numel(gridLon);
Gj.times_local = cellstr(datestr(tLoc(frameIdx), 'yyyy-mm-dd HH:MM'));
% Each frame: PM2.5 in ug/m3 rounded to whole numbers and capped at 254,
% 255 = outside the model domain; one byte per cell, base64-encoded.
% Cells are row-major, south row first. Keeps the whole-domain file ~3 MB.
Gj.encoding = 'uint8-base64';
Gj.pm25 = cell(numel(frameIdx), 1);
for i = 1:numel(frameIdx)
    fr = G(:, :, i)';
    v  = round(double(fr(:)'));
    bad = ~isfinite(v);
    v  = min(max(v, 0), 254);
    v(bad) = 255;
    Gj.pm25{i} = matlab.net.base64encode(uint8(v));
end
writeJson(fullfile(cfg.dashDir, 'forecast_grid.json'), Gj);

lastRunFile = runFile; %#ok<NASGU>
formatVersion = cfg.FORMAT_VERSION; %#ok<NASGU>
save(stateFile, 'lastRunFile', 'formatVersion');

msg = sprintf('%s | run %s | stations=%d | hours=%d | frames=%d | %.0f s', ...
    datestr(now), runLabel, nS, nT, numel(frameIdx), toc);
writeLog(cfg.logFile, msg);
fprintf('[%s] Done: %d stations x %d h, %d map frames (%.0f s).\n', ...
    datestr(now), nS, nT, numel(frameIdx), toc);
end


function [runFile, runLabel] = findLatestCompleteRun(cfg)
runFile = ''; runLabel = '';
d = dir(cfg.baseDir);
d = d([d.isdir]);
names = {d.name};
names = sort(names(~cellfun(@isempty, regexp(names, '^\d{4}-\d{2}-\d{2}$', 'once'))));
for k = numel(names):-1:max(1, numel(names) - cfg.MAX_FOLDERS_BACK + 1)
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
    try
        vi = ncinfo(f, 'Times');
        nTimes = vi.Size(2);
    catch
        continue;
    end
    if nTimes < cfg.EXPECTED_TIMES
        fprintf('  %s: %d of %d time steps so far, skipping.\n', names{k}, nTimes, cfg.EXPECTED_TIMES);
        continue;
    end
    runFile  = f;
    runLabel = fullfile(names{k}, files(1).name);
    return;
end
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
