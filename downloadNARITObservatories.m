% downloadNARITObservatories.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- weather at NARIT's observatories.
%
% Same source as downloadWeatherAirQuality.m (SOURCE 1), extended from
% AstroPark to every observatory in OBSERVATORIES:
%   POST https://weather.narit.or.th/api/GetWeatherReport
%   Body (JSON): {"station":"<code>","start":"<ISO8601 UTC>","end":"<ISO8601 UTC>"}
%   Response: records with lastestTimestamp, outsideTemp, dewPoint,
%   outsideHumidity, barometer, windSpeed, windDir, rainRate, dailyRain,
%   solarRad, UV, ...
%
% Each poll asks every observatory for the records since its last saved
% one (minus OVERLAP_MINUTES) and appends the new ones.
%
% UNITS: values are converted to degC, hPa, m/s, mm. Imperial output
% (degF, inHg, mph, inches -- the Davis console default) is detected
% automatically from the temperatures. For metric output, set
% WIND_TO_MS to match how the console reports wind (1 for m/s, 1/3.6 for
% km/h); check one AstroPark reading against the station display.
%
% FINDING STATION CODES: put candidate codes in PROBE_CODES. On start the
% script asks the API for the last 6 hours of each and prints which ones
% return data; add the working ones to OBSERVATORIES with their
% coordinates.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true): every PERIOD_MIN
% minutes. TO STOP: stopPlatformTimers
%
% OUTPUTS (in outputDir)
%   NARIT_Observatories.csv   the configured observatories (code, name, province,
%                             lat, lon, elev_m) -- also read by the forecast extraction
%   NARIT_Obs_YYYYMM.csv      archive, one row per record (local time)
%   NARIT_Obs_latest.csv      newest record per observatory (overwritten)
%   NARIT_Seeing_YYYYMM.csv   seeing (arcsec), for stations whose records carry a
%                             seeing / DIMM field (expected at TNO only). The field is
%                             found by name (any field containing 'seeing' or 'dimm');
%                             the console reports which field was used.
%   lastState_NaritObs.mat, download_log.txt

clear; clc;
%% ============================ CONFIG =======================================
cfg.apiURL = 'https://weather.narit.or.th/api/GetWeatherReport';

% code | name | province (English, for the dashboard's area filter) | lat | lon | elevation (m)
% Thai observatories on https://weather.narit.or.th/allstation (the overseas sites --
% Gao Mei Gu, Springbrook, Sierra Remote, PROMPT-8 -- are left out).
% API codes (all confirmed): astropark, 1mtno (TNO), kkn (Khon Kaen), cco (Chachoengsao),
% sko (Songkhla; checked in the station page's GetWeatherReport request).
% Regional observatory coordinates: from the Google Maps links on NARIT's contact page
% (narit.or.th/en/contact-us). Elevation NaN = unknown; the forecast then skips the
% temperature height adjustment for that site.
cfg.OBSERVATORIES = {
    'astropark', 'Princess Sirindhorn AstroPark',                      'Chiang Mai',   18.85320874844, 98.958930881653, 330;
    '1mtno',     'Thai National Observatory, Doi Inthanon',             'Chiang Mai',   18.5736,        98.4822,         2457;
    'kkn',       'Regional Observatory for the Public, Khon Kaen',      'Khon Kaen',    16.7613772,     102.6317891,     NaN;
    'cco',       'Regional Observatory for the Public, Chachoengsao',   'Chachoengsao', 13.593513,      101.256158,      NaN;
    'sko',       'Regional Observatory for the Public, Songkhla',       'Songkhla',     7.1582045,      100.6112252,     NaN;
    };

% Candidate codes to test once at start (prints which ones return data). Leave {} to skip.
cfg.PROBE_CODES = {};

cfg.WIND_TO_MS = 1;              % metric consoles only: 1 if m/s, 1/3.6 if km/h
cfg.OVERLAP_MINUTES = 5;         % re-request this far before the last saved record
cfg.INITIAL_LOOKBACK_HOURS = 24; % first run: how far back to pull
cfg.MAX_WINDOW_HOURS = 2;        % longer requests are split into pieces of this length
                                 % (some stations, e.g. ska, reject long windows with 400)

cfg.outputDir = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform/NARIT_Obs_Archive';

cfg.RUN_IN_BACKGROUND = true;
cfg.PERIOD_MIN = 10;
cfg.UTC_OFFSET_H = 7;
% ===========================================================================

if ~exist(cfg.outputDir, 'dir')
    mkdir(cfg.outputDir);
end
cfg.logFile = fullfile(cfg.outputDir, 'download_log.txt');

% Station list for the forecast extraction and the dashboard
fid = fopen(fullfile(cfg.outputDir, 'NARIT_Observatories.csv'), 'w', 'n', 'UTF-8');
fprintf(fid, 'code,name,province,lat,lon,elev_m\n');
for k = 1:size(cfg.OBSERVATORIES, 1)
    o = cfg.OBSERVATORIES(k, :);
    fprintf(fid, '%s,"%s","%s",%.6f,%.6f,%g\n', o{1}, o{2}, o{3}, o{4}, o{5}, o{6});
end
fclose(fid);

if ~isempty(cfg.PROBE_CODES)
    probeCodes(cfg);
end

timerName = 'NARITObsTimer';
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A NARIT observatory timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

runNaritCycleSafe(cfg);

if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'minute');
    nextRun  = nextRun + minutes(cfg.PERIOD_MIN - mod(minute(nextRun), cfg.PERIOD_MIN)) + seconds(30);
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    naritTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 60 * cfg.PERIOD_MIN, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runNaritCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('NARIT observatory timer error: %s\n', evt.Data.message));
    start(naritTimer);

    fprintf('\nNARIT observatory downloader is now running in the background.\n');
    fprintf('Every %d min (next run in %.0f seconds).\n', cfg.PERIOD_MIN, startDelaySec);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runNaritCycleSafe(cfg)
try
    runNaritCycle(cfg);
catch ME
    fprintf('[%s] NARIT observatory cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | cycle failed: %s', datestr(now), ME.message));
end
end


function runNaritCycle(cfg)
nowUTC = datetime('now', 'TimeZone', 'local');
nowUTC.TimeZone = 'UTC';

stateFile = fullfile(cfg.outputDir, 'lastState_NaritObs.mat');
lastCodes = {}; lastT = NaT(0, 1); lastT.TimeZone = 'UTC';
if exist(stateFile, 'file')
    S = load(stateFile);
    if isfield(S, 'lastCodes'), lastCodes = S.lastCodes; lastT = S.lastT; end
end

latestRows = {};
summary = {};
for k = 1:size(cfg.OBSERVATORIES, 1)
    code = cfg.OBSERVATORIES{k, 1};
    j = find(strcmp(lastCodes, code), 1);
    if ~isempty(j) && ~isnat(lastT(j))
        startUTC = lastT(j) - minutes(cfg.OVERLAP_MINUTES);
    else
        startUTC = nowUTC - hours(cfg.INITIAL_LOOKBACK_HOURS);
    end

    [R, msg] = fetchWindow(cfg, code, startUTC, nowUTC);
    if isempty(R)
        summary{end+1} = sprintf('%s: %s', code, msg); %#ok<AGROW>
        continue;
    end

    % New records only
    if ~isempty(j) && ~isnat(lastT(j))
        R = R(R.timeUTC > lastT(j), :);
    end
    if height(R) > 0
        appendArchive(cfg, code, R);
        appendSeeing(cfg, code, R);
        if isempty(j)
            lastCodes{end+1, 1} = code; %#ok<AGROW>
            lastT(end+1, 1) = max(R.timeUTC);
        else
            lastT(j) = max(R.timeUTC);
        end
        latestRows{end+1} = {code, R(end, :)}; %#ok<AGROW>
    else
        latestRows{end+1} = {code, []}; %#ok<AGROW>
    end
    summary{end+1} = sprintf('%s: +%d', code, height(R)); %#ok<AGROW>
end
save(stateFile, 'lastCodes', 'lastT');
updateLatest(cfg, latestRows);

msg = sprintf('%s | %s', datestr(now), strjoin(summary, ' | '));
writeLog(cfg.logFile, msg);
fprintf('[%s] NARIT observatories: %s\n', datestr(now), strjoin(summary, ', '));
end


function [R, msg] = fetchWindow(cfg, code, startUTC, endUTC)
% Requests the window in pieces of at most MAX_WINDOW_HOURS; a failed piece is
% skipped so one bad request does not lose the rest.
R = table(); nErr = 0; nPieces = 0; lastErr = '';
t1 = startUTC;
while t1 < endUTC
    t2 = min(t1 + hours(cfg.MAX_WINDOW_HOURS), endUTC);
    [Rk, mk] = fetchRecords(cfg, code, t1, t2);
    nPieces = nPieces + 1;
    if ~isempty(Rk)
        R = [R; Rk]; %#ok<AGROW>
    elseif startsWith(mk, 'API error')
        nErr = nErr + 1;
        lastErr = mk;
    end
    t1 = t2;
end
if isempty(R)
    if nErr > 0
        msg = sprintf('%s (%d of %d request(s) failed)', lastErr, nErr, nPieces);
    else
        msg = 'no records';
    end
    return;
end
R = sortrows(R, 'timeUTC');
[~, iu] = unique(R.timeUTC, 'last');
R = R(iu, :);
msg = sprintf('%d records', height(R));
if nErr > 0
    msg = sprintf('%s, %d of %d request(s) failed', msg, nErr, nPieces);
end
if any(isfinite(R.seeing_arcsec))
    msg = sprintf('%s, %d seeing values', msg, sum(isfinite(R.seeing_arcsec)));
end
end


function [R, msg] = fetchRecords(cfg, code, startUTC, endUTC)
% Records for one station as a table in SI/metric units, sorted by time.
R = table(); msg = '';
startUTC.Format = 'yyyy-MM-dd''T''HH:mm:ss.SSS';
endUTC.Format   = 'yyyy-MM-dd''T''HH:mm:ss.SSS';
try
    opts = weboptions('MediaType', 'application/json', 'Timeout', 30, 'RequestMethod', 'post');
    resp = webwrite(cfg.apiURL, struct('station', code, 'start', [char(startUTC) 'Z'], ...
        'end', [char(endUTC) 'Z']), opts);
catch ME
    msg = sprintf('API error (%s)', ME.message);
    return;
end
if isempty(resp)
    msg = 'no records';
    return;
end
if isstruct(resp)
    resp = num2cell(resp);
end

n = numel(resp);
t = NaT(n, 1);
t.TimeZone = 'UTC';
names = {'outsideTemp', 'dewPoint', 'outsideHumidity', 'barometer', 'windSpeed', 'windDir', ...
         'rainRate', 'dailyRain', 'solarRad', 'UV'};
V = nan(n, numel(names));
see = nan(n, 1);
seeField = '';
for i = 1:n
    rec = resp{i};
    ts = getStr(rec, 'lastestTimestamp');
    try
        t(i) = datetime(ts, 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''', 'TimeZone', 'UTC');
    catch
        continue;
    end
    for c = 1:numel(names)
        V(i, c) = getNum(rec, names{c});
    end
    fn = fieldnames(rec);
    js = find(~cellfun(@isempty, regexpi(fn, 'seeing|dimm', 'once')), 1);
    if ~isempty(js)
        seeField = fn{js};
        see(i) = getNum(rec, seeField);
    end
end
ok = ~isnat(t);
t = t(ok); V = V(ok, :); see = see(ok);
if isempty(t)
    msg = 'records without timestamps';
    return;
end

% Units: imperial consoles report degF; Thai temperatures in degC stay below ~45
imperial = median(V(:, 1), 'omitnan') > 45;
if imperial
    V(:, 1:2) = (V(:, 1:2) - 32) * 5 / 9;      % degF -> degC
    V(:, 5)   = V(:, 5) * 0.44704;              % mph -> m/s
    V(:, 7:8) = V(:, 7:8) * 25.4;               % in -> mm
else
    V(:, 5)   = V(:, 5) * cfg.WIND_TO_MS;
end
p = V(:, 4);
V(:, 4) = p .* (1 + (median(p, 'omitnan') < 40) * 32.8639);   % inHg -> hPa when needed

R = array2table(V, 'VariableNames', {'temp_C', 'dewpoint_C', 'rh_pct', 'pressure_hPa', 'wind_ms', ...
    'wind_dir_deg', 'rain_rate_mmh', 'daily_rain_mm', 'solar_Wm2', 'uv'});
R.seeing_arcsec = see;
R.timeUTC = t;
R = sortrows(R, 'timeUTC');
[~, iu] = unique(R.timeUTC, 'last');
R = R(iu, :);
msg = sprintf('%d records', height(R));
if ~isempty(seeField)
    msg = sprintf('%s, seeing from field ''%s'' (%d values)', msg, seeField, sum(isfinite(R.seeing_arcsec)));
end
end


function appendArchive(cfg, code, R)
tLoc = R.timeUTC;
tLoc.TimeZone = 'Asia/Bangkok';
tLoc.TimeZone = '';
ym = year(tLoc) * 100 + month(tLoc);
for m = unique(ym)'
    sel = find(ym == m);
    fn = fullfile(cfg.outputDir, sprintf('NARIT_Obs_%d.csv', m));
    newFile = ~exist(fn, 'file');
    fid = fopen(fn, 'a', 'n', 'UTF-8');
    if newFile
        fprintf(fid, 'code,timeLocal,%s\n', strjoin(R.Properties.VariableNames(1:10), ','));
    end
    for i = sel'
        v = R{i, 1:10};
        fprintf(fid, '%s,%s,%s\n', code, datestr(tLoc(i), 'yyyy-mm-dd HH:MM:SS'), ...
            strjoin(arrayfun(@numOrNaNStr, v, 'UniformOutput', false), ','));
    end
    fclose(fid);
end
end


function appendSeeing(cfg, code, R)
ok = isfinite(R.seeing_arcsec);
if ~any(ok)
    return;
end
tLoc = R.timeUTC(ok);
tLoc.TimeZone = 'Asia/Bangkok';
tLoc.TimeZone = '';
v = R.seeing_arcsec(ok);
ym = year(tLoc) * 100 + month(tLoc);
for m = unique(ym)'
    sel = find(ym == m);
    fn = fullfile(cfg.outputDir, sprintf('NARIT_Seeing_%d.csv', m));
    newFile = ~exist(fn, 'file');
    fid = fopen(fn, 'a', 'n', 'UTF-8');
    if newFile
        fprintf(fid, 'code,timeLocal,seeing_arcsec\n');
    end
    for i = sel'
        fprintf(fid, '%s,%s,%s\n', code, datestr(tLoc(i), 'yyyy-mm-dd HH:MM:SS'), numOrNaNStr(v(i)));
    end
    fclose(fid);
end
end


function updateLatest(cfg, latestRows)
% Keeps one row per observatory: replaces those with new records this poll.
fn = fullfile(cfg.outputDir, 'NARIT_Obs_latest.csv');
cols = {'temp_C', 'dewpoint_C', 'rh_pct', 'pressure_hPa', 'wind_ms', 'wind_dir_deg', ...
        'rain_rate_mmh', 'daily_rain_mm', 'solar_Wm2', 'uv'};
codes = {}; lines = {};
if exist(fn, 'file')
    txt = strsplit(strtrim(fileread(fn)), sprintf('\n'));
    for i = 2:numel(txt)
        parts = strsplit(txt{i}, ',');
        codes{end+1} = parts{1}; %#ok<AGROW>
        lines{end+1} = txt{i};   %#ok<AGROW>
    end
end
for i = 1:numel(latestRows)
    code = latestRows{i}{1};
    r = latestRows{i}{2};
    if isempty(r)
        continue;
    end
    tLoc = r.timeUTC;
    tLoc.TimeZone = 'Asia/Bangkok';
    line = sprintf('%s,%s,%s', code, datestr(tLoc, 'yyyy-mm-dd HH:MM:SS'), ...
        strjoin(arrayfun(@numOrNaNStr, r{1, 1:10}, 'UniformOutput', false), ','));
    j = find(strcmp(codes, code), 1);
    if isempty(j)
        codes{end+1} = code; lines{end+1} = line; %#ok<AGROW>
    else
        lines{j} = line;
    end
end
fid = fopen(fn, 'w', 'n', 'UTF-8');
fprintf(fid, 'code,timeLocal,%s\n', strjoin(cols, ','));
if ~isempty(lines)
    fprintf(fid, '%s\n', lines{:});
end
fclose(fid);
end


function probeCodes(cfg)
fprintf('Probing %d candidate station code(s) (last 6 h)...\n', numel(cfg.PROBE_CODES));
nowUTC = datetime('now', 'TimeZone', 'local');
nowUTC.TimeZone = 'UTC';
for k = 1:numel(cfg.PROBE_CODES)
    [R, msg] = fetchRecords(cfg, cfg.PROBE_CODES{k}, nowUTC - hours(6), nowUTC);
    if isempty(R)
        fprintf('  %-20s -- %s\n', cfg.PROBE_CODES{k}, msg);
    else
        tl = R.timeUTC(end); tl.TimeZone = 'Asia/Bangkok';
        fprintf('  %-20s OK: %s, latest %s, %.1f degC\n', cfg.PROBE_CODES{k}, msg, ...
            datestr(tl, 'yyyy-mm-dd HH:MM'), R.temp_C(end));
    end
end
end


function s = numOrNaNStr(v)
if isnan(v)
    s = 'NaN';
else
    s = num2str(v, '%.6g');
end
end


function val = getStr(rec, name)
if isfield(rec, name) && ~isempty(rec.(name))
    val = char(rec.(name));
else
    val = '';
end
end


function val = getNum(rec, name)
val = NaN;
if isfield(rec, name)
    v = rec.(name);
    if isempty(v)
        return;
    elseif isnumeric(v)
        val = double(v(1));
    else
        val = str2double(v);
    end
end
end


function writeLog(logFile, msg)
fid = fopen(logFile, 'a');
if fid ~= -1
    fprintf(fid, '%s\n', msg);
    fclose(fid);
end
end
