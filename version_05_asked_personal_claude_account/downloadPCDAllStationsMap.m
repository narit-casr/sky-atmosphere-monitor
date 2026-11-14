% downloadPCDAllStationsMap.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible. No Mapping Toolbox or
% Statistics Toolbox required (uses base-MATLAB geoaxes/geoscatter,
% introduced in R2018b).
%
% Downloads PCD Air4Thai air-pollutant concentrations for EVERY available
% station, archives them to CSV, and draws one map per pollutant (PM2.5,
% PM10, O3, CO, NO2, SO2) as subplots in a single figure.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true):
%   Runs once immediately, then once per hour at PCD_MINUTE_PAST_HOUR
%   minutes past the hour (30 by default, e.g. 15:30, 16:30, ...), because
%   the current hour's PCD values are often still missing if queried too
%   soon after the hour. Each run draws the maps, saves them as PNG,
%   closes the figure, and appends only NEW hours to a single persistent
%   history archive. Just run this
%   script once and leave MATLAB open.
%   Set RUN_IN_BACKGROUND = false for a single one-off run.
%
%   NOTE: MATLAB timers share MATLAB's single main thread. While a run is
%   downloading (a few minutes for ~190+ stations), the command window is
%   busy; between runs MATLAB is free to use as normal.
%
% TO STOP the background runs:
%   stopPlatformTimers   (or stopPCDAllStationsTimer)
% (companion script -- keep stopPCDAllStationsTimer.m in the same folder
% or on the MATLAB path)
%
% STEP 1: Station list + latest snapshot (all stations in one call)
%   GET http://air4thai.pcd.go.th/services/getNewAQI_JSON.php
%   (fallback: https://air4thai.com/forweb/getAQI_JSON.php)
%   Response: {"stations":[{"stationID":"02t","nameEN":..,"areaEN":..,
%   "stationType":"GROUND","lat":"13.73","long":"100.48",
%   "AQILast":{"date":"YYYY-MM-DD","time":"HH:MM",
%   "PM25":{"color_id":..,"aqi":..,"value":".."}, "PM10":{..}, ...}}, ...]}
%   Negative values in AQILast are missing flags -> NaN.
%
% STEP 2: Hourly history for each station
%   GET https://air4thai.com/forweb/getHistoryData.php
%     ?stationID=<id>&param=PM25,PM10,O3,CO,NO2,SO2
%     &type=hr&sdate=YYYY-MM-DD&edate=YYYY-MM-DD&stime=00&etime=23
%   JSON null (decoded as []) and negative values -> NaN.
%   Archiving: per station, only hours newer than the last archived hour
%   are appended to PCD_History_Archive.csv (state in
%   lastState_PCDAllStations.mat). Hours newer than ARCHIVE_DELAY_HOURS
%   before now are NOT archived yet, since PCD often fills them in late;
%   they are still used for the map, and get archived on a later run.
%   If the script was off for a while, each station is backfilled from
%   its last archived day (up to MAX_BACKFILL_DAYS back).
%
% STEP 3: Maps
%   MAP_MODE = 'latest': each station's most recent valid hourly value,
%   kept only if within STALE_HOURS of the newest hour found for that
%   pollutant across all stations. MAP_MODE = 'mean': mean over the last
%   LOOKBACK_DAYS. Stations with no valid value are grey crosses.
%
% OUTPUTS (in outputDir):
%   PCD_History_Archive.csv     persistent, deduplicated hourly history (all stations)
%   PCD_Stations_latest.csv     station metadata + AQILast snapshot (overwritten each run)
%   PCD_MapValues_latest.csv    the per-station values mapped (overwritten each run)
%   PCD_Maps_latest.png         latest figure (overwritten each run)
%   PCD_Maps_<stamp>.png        per-run figure copies (if SAVE_STAMPED_PNG)
%   lastState_PCDAllStations.mat  per-station last archived hour
%   download_log.txt            errors / per-run summary

clear; clc; close all;
%% ============================ CONFIG =======================================
cfg.stationListURLs = { ...
    'http://air4thai.pcd.go.th/services/getNewAQI_JSON.php', ...
    'https://air4thai.com/forweb/getAQI_JSON.php'};
cfg.historyApiURL   = 'https://air4thai.com/forweb/getHistoryData.php';

cfg.pollutants      = {'PM25', 'PM10', 'O3', 'CO', 'NO2', 'SO2'};
cfg.pollutantLabels = {'PM_{2.5}', 'PM_{10}', 'O_3', 'CO', 'NO_2', 'SO_2'};
cfg.pollutantUnits  = {'\mug m^{-3}', '\mug m^{-3}', 'ppb', 'ppm', 'ppb', 'ppb'};

% --- Background scheduling ---
cfg.RUN_IN_BACKGROUND    = true;   % false = single run, no timer
cfg.PCD_MINUTE_PAST_HOUR = 30;     % hourly run at this minute past the hour

% --- Download / archive ---
cfg.LOOKBACK_DAYS          = 1;    % history window used for the maps (and first-run archive)
cfg.MAX_BACKFILL_DAYS      = 30;   % max gap to backfill if the script was off for a while
cfg.ARCHIVE_DELAY_HOURS    = 2;    % don't archive hours newer than this (PCD fills them in late)
cfg.PAUSE_BETWEEN_REQUESTS = 0.2;  % seconds between per-station history calls
cfg.REQUEST_TIMEOUT_SEC    = 30;

% --- Maps ---
cfg.MAP_MODE         = 'latest';   % 'latest' or 'mean'
cfg.STALE_HOURS      = 3;          % 'latest' mode: drop values older than this vs. newest hour
cfg.BASEMAP          = 'grayland'; % needs internet; falls back to 'darkwater' (ships with MATLAB)
cfg.MAP_LAT_LIMITS   = [5.5 20.6]; % Thailand
cfg.MAP_LON_LIMITS   = [97.2 105.8];
cfg.MARKER_SIZE      = 40;
cfg.SUBPLOT_ROWS     = 2;
cfg.SUBPLOT_COLS     = 3;
cfg.SAVE_STAMPED_PNG = true;       % also keep a time-stamped PNG from every run
cfg.SHOW_FIGURE      = true;       % false = draw off-screen (no window pops up); closed after saving either way

cfg.outputDir = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform/PCD_AllStations_Archive';
% ===========================================================================

if ~exist(cfg.outputDir, 'dir')
    mkdir(cfg.outputDir);
end
cfg.logFile   = fullfile(cfg.outputDir, 'download_log.txt');
cfg.stateFile = fullfile(cfg.outputDir, 'lastState_PCDAllStations.mat');
cfg.historyCsv = fullfile(cfg.outputDir, 'PCD_History_Archive.csv');

timerName = 'PCDAllStationsTimer';

% --- Avoid stacking duplicate timers if this script is run more than once ---
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A PCD all-stations timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

% --- Run once immediately ---
runPcdCycleSafe(cfg);

% --- Then hourly, aligned to PCD_MINUTE_PAST_HOUR ---
if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'hour') + minutes(cfg.PCD_MINUTE_PAST_HOUR);
    if nextRun <= nowLocal
        nextRun = nextRun + hours(1);
    end
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    pcdTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 3600, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...   % if a run is still going, skip rather than queue
        'TimerFcn', @(~,~) runPcdCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('PCD timer error: %s\n', evt.Data.message));
    start(pcdTimer);

    fprintf('\nPCD all-stations downloader is now running in the background.\n');
    fprintf('Hourly at :%02d (next run in %.0f seconds).\n', cfg.PCD_MINUTE_PAST_HOUR, startDelaySec);
    fprintf('Files saved to: %s\n', cfg.outputDir);
    fprintf('To stop it, run:  stopPCDAllStationsTimer\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runPcdCycleSafe(cfg)
% Wrapper so a failed run (e.g. PCD site down) is logged instead of
% killing the timer -- MATLAB stops a timer whose TimerFcn throws.
try
    runPcdCycle(cfg);
catch ME
    fprintf('[%s] PCD cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | cycle failed: %s', datestr(now), ME.message));
end
end


function runPcdCycle(cfg)
% One full cycle: station list -> history (with deduplicated archiving)
% -> map values -> redraw maps.

pollutants = cfg.pollutants;
nP = numel(pollutants);
webOpts = weboptions('ContentType', 'text', 'Timeout', cfg.REQUEST_TIMEOUT_SEC, ...
    'CertificateFilename', '');

% PCD timestamps are Thai local time; use Bangkok time regardless of the
% computer's clock setting, then drop the zone to compare with PCD times.
nowLocal = datetime('now', 'TimeZone', 'Asia/Bangkok');
nowLocal.TimeZone = '';
runStamp = datestr(nowLocal, 'yyyymmdd_HHMMSS');

%% ----- STEP 1: station list + snapshot -----
fprintf('[%s] Fetching PCD station list...\n', datestr(now));

stationList = {};
stationListSource = '';
for u = 1:numel(cfg.stationListURLs)
    try
        raw  = webread(cfg.stationListURLs{u}, webOpts);
        data = jsondecode(raw);
        if isfield(data, 'stations') && ~isempty(data.stations)
            stationList = toCellOfStructs(data.stations);
            stationListSource = cfg.stationListURLs{u};
            break;
        end
        fprintf('  %s returned no stations; trying next source.\n', cfg.stationListURLs{u});
    catch ME
        fprintf('  %s failed (%s); trying next source.\n', cfg.stationListURLs{u}, ME.message);
        writeLog(cfg.logFile, sprintf('%s | ERROR | station list %s: %s', ...
            datestr(now), cfg.stationListURLs{u}, ME.message));
    end
end
if isempty(stationList)
    error('Could not retrieve the PCD station list from any source.');
end

nSt        = numel(stationList);
stID       = cell(nSt, 1);
stNameEN   = cell(nSt, 1);
stAreaEN   = cell(nSt, 1);
stType     = cell(nSt, 1);
stLat      = nan(nSt, 1);
stLon      = nan(nSt, 1);
latestTime = NaT(nSt, 1);
latestVals = nan(nSt, nP);

for s = 1:nSt
    rec = stationList{s};
    stID{s}     = getFieldStr(rec, 'stationID');
    stNameEN{s} = getFieldStr(rec, 'nameEN');
    stAreaEN{s} = getFieldStr(rec, 'areaEN');
    stType{s}   = getFieldStr(rec, 'stationType');
    stLat(s)    = getFieldNumOrNull(rec, 'lat');
    stLon(s)    = getFieldNumOrNull(rec, 'long');
    if stLat(s) == 0 || stLon(s) == 0
        stLat(s) = NaN;
        stLon(s) = NaN;
    end
    if isfield(rec, 'AQILast') && isstruct(rec.AQILast)
        aq = rec.AQILast;
        try
            latestTime(s) = datetime(strtrim([getFieldStr(aq, 'date') ' ' getFieldStr(aq, 'time')]), ...
                'InputFormat', 'yyyy-MM-dd HH:mm');
        catch
            % leave NaT
        end
        for p = 1:nP
            if isfield(aq, pollutants{p}) && isstruct(aq.(pollutants{p}))
                v = getFieldNumOrNull(aq.(pollutants{p}), 'value');
                if v < 0
                    v = NaN;
                end
                latestVals(s, p) = v;
            end
        end
    end
end

keep = ~cellfun(@isempty, stID);
stID = stID(keep); stNameEN = stNameEN(keep); stAreaEN = stAreaEN(keep);
stType = stType(keep); stLat = stLat(keep); stLon = stLon(keep);
latestTime = latestTime(keep); latestVals = latestVals(keep, :);
nSt = numel(stID);
fprintf('[%s] %d stations found (source: %s).\n', datestr(now), nSt, stationListSource);

stationsCsv = fullfile(cfg.outputDir, 'PCD_Stations_latest.csv');
fid = fopen(stationsCsv, 'w', 'n', 'UTF-8');
if fid ~= -1
    fprintf(fid, '%s\n', strjoin([{'stationID', 'nameEN', 'areaEN', 'stationType', ...
        'lat', 'lon', 'AQILast_time'}, strcat('AQILast_', pollutants)], ','));
    for s = 1:nSt
        parts = {csvQuote(stID{s}), csvQuote(stNameEN{s}), csvQuote(stAreaEN{s}), ...
            csvQuote(stType{s}), numOrNaNStr(stLat(s)), numOrNaNStr(stLon(s)), dtStr(latestTime(s))};
        for p = 1:nP
            parts{end+1} = numOrNaNStr(latestVals(s, p)); %#ok<AGROW>
        end
        fprintf(fid, '%s\n', strjoin(parts, ','));
    end
    fclose(fid);
end

%% ----- STEP 2: hourly history + deduplicated archive -----
todayD        = dateshift(nowLocal, 'start', 'day');
defaultStart  = todayD - days(cfg.LOOKBACK_DAYS);
oldestAllowed = todayD - days(cfg.MAX_BACKFILL_DAYS);
archiveCutoff = nowLocal - hours(cfg.ARCHIVE_DELAY_HOURS);
edateStr      = datestr(todayD, 'yyyy-mm-dd');
paramStr      = strjoin(pollutants, ',');

% Per-station last archived hour
stateIDs  = {};
stateLast = NaT(0, 1);
if exist(cfg.stateFile, 'file')
    st = load(cfg.stateFile);
    if isfield(st, 'stateIDs') && isfield(st, 'stateLast')
        stateIDs  = st.stateIDs;
        stateLast = st.stateLast;
    end
end

% Archive CSV header on first use
if ~exist(cfg.historyCsv, 'file')
    fidH = fopen(cfg.historyCsv, 'w', 'n', 'UTF-8');
    if fidH ~= -1
        fprintf(fidH, '%s\n', strjoin([{'stationID', 'nameEN', 'lat', 'lon', 'DATETIMEDATA'}, pollutants], ','));
        fclose(fidH);
    end
end
fidH = fopen(cfg.historyCsv, 'a', 'n', 'UTF-8');
if fidH == -1
    writeLog(cfg.logFile, sprintf('%s | ERROR | cannot open %s for appending', datestr(now), cfg.historyCsv));
end

fprintf('[%s] Downloading hourly history for %d stations...\n', datestr(now), nSt);

histTimes = cell(nSt, 1);
histVals  = cell(nSt, 1);
nFailed   = 0;
nArchived = 0;

for s = 1:nSt
    histTimes{s} = NaT(0, 1);
    histVals{s}  = nan(0, nP);

    iState = find(strcmp(stateIDs, stID{s}), 1);
    if ~isempty(iState)
        lastSaved = stateLast(iState);
    else
        lastSaved = NaT;
    end

    % Request window: normal lookback, extended back to the last archived
    % day if the script was off for a while (capped at MAX_BACKFILL_DAYS)
    sdate = defaultStart;
    if ~isnat(lastSaved)
        d0 = dateshift(lastSaved, 'start', 'day');
        if d0 < sdate
            sdate = max(d0, oldestAllowed);
        end
    end
    sdateStr = datestr(sdate, 'yyyy-mm-dd');

    queryURL = sprintf('%s?stationID=%s&param=%s&type=hr&sdate=%s&edate=%s&stime=00&etime=23', ...
        cfg.historyApiURL, stID{s}, paramStr, sdateStr, edateStr);
    try
        raw  = webread(queryURL, webOpts);
        data = jsondecode(raw);
    catch ME
        nFailed = nFailed + 1;
        fprintf('  [%3d/%3d] %-6s FAILED (%s)\n', s, nSt, stID{s}, ME.message);
        writeLog(cfg.logFile, sprintf('%s | ERROR | history %s: %s', datestr(now), stID{s}, ME.message));
        pause(cfg.PAUSE_BETWEEN_REQUESTS);
        continue;
    end

    if ~isfield(data, 'result') || ~strcmp(data.result, 'OK') || ~isfield(data, 'stations')
        fprintf('  [%3d/%3d] %-6s response not OK\n', s, nSt, stID{s});
        pause(cfg.PAUSE_BETWEEN_REQUESTS);
        continue;
    end

    respStations = toCellOfStructs(data.stations);
    match = [];
    for i = 1:numel(respStations)
        if strcmpi(getFieldStr(respStations{i}, 'stationID'), stID{s})
            match = respStations{i};
            break;
        end
    end
    if isempty(match) || ~isfield(match, 'data') || isempty(match.data)
        fprintf('  [%3d/%3d] %-6s no records\n', s, nSt, stID{s});
        pause(cfg.PAUSE_BETWEEN_REQUESTS);
        continue;
    end

    recs = toCellOfStructs(match.data);
    nR = numel(recs);
    t  = NaT(nR, 1);
    v  = nan(nR, nP);
    for r = 1:nR
        key = getFieldStr(recs{r}, 'DATETIMEDATA');
        try
            t(r) = datetime(key, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        catch
            continue;
        end
        for p = 1:nP
            val = getFieldNumOrNull(recs{r}, pollutants{p});
            if val < 0
                val = NaN;
            end
            v(r, p) = val;
        end
    end
    ok = ~isnat(t);
    t = t(ok);
    v = v(ok, :);
    [t, order] = sort(t);
    v = v(order, :);
    histTimes{s} = t;
    histVals{s}  = v;

    % --- Append only new, settled hours to the archive ---
    if isnat(lastSaved)
        newRows = t <= archiveCutoff;
    else
        newRows = t > lastSaved & t <= archiveCutoff;
    end
    idxNew = find(newRows);
    if fidH ~= -1 && ~isempty(idxNew)
        for r = idxNew(:)'
            parts = {csvQuote(stID{s}), csvQuote(stNameEN{s}), numOrNaNStr(stLat(s)), ...
                numOrNaNStr(stLon(s)), dtStr(t(r))};
            for p = 1:nP
                parts{end+1} = numOrNaNStr(v(r, p)); %#ok<AGROW>
            end
            fprintf(fidH, '%s\n', strjoin(parts, ','));
        end
        nArchived = nArchived + numel(idxNew);
        newLast = max(t(idxNew));
        if isempty(iState)
            stateIDs{end+1, 1} = stID{s}; %#ok<AGROW>
            stateLast(end+1, 1) = newLast; %#ok<AGROW>
        else
            stateLast(iState) = newLast;
        end
    end

    fprintf('  [%3d/%3d] %-6s %3d hourly records, %3d newly archived\n', ...
        s, nSt, stID{s}, numel(t), numel(idxNew));
    pause(cfg.PAUSE_BETWEEN_REQUESTS);
end

if fidH ~= -1
    fclose(fidH);
end
save(cfg.stateFile, 'stateIDs', 'stateLast');

writeLog(cfg.logFile, sprintf('%s | run %s | stations=%d | newly archived rows=%d | failed=%d', ...
    datestr(now), runStamp, nSt, nArchived, nFailed));

%% ----- STEP 3: values to map -----
[mapVals, mapTimes] = computeMapValues(cfg, histTimes, histVals, latestTime, latestVals, defaultStart);

mapCsv = fullfile(cfg.outputDir, 'PCD_MapValues_latest.csv');
fid = fopen(mapCsv, 'w', 'n', 'UTF-8');
if fid ~= -1
    hdr = {'stationID', 'nameEN', 'lat', 'lon'};
    for p = 1:nP
        hdr = [hdr, {pollutants{p}, [pollutants{p} '_time']}]; %#ok<AGROW>
    end
    fprintf(fid, '%s\n', strjoin(hdr, ','));
    for s = 1:nSt
        parts = {csvQuote(stID{s}), csvQuote(stNameEN{s}), numOrNaNStr(stLat(s)), numOrNaNStr(stLon(s))};
        for p = 1:nP
            parts = [parts, {numOrNaNStr(mapVals(s, p)), dtStr(mapTimes(s, p))}]; %#ok<AGROW>
        end
        fprintf(fid, '%s\n', strjoin(parts, ','));
    end
    fclose(fid);
end

%% ----- STEP 4: redraw maps -----
drawPcdMaps(cfg, stLat, stLon, mapVals, mapTimes, datestr(defaultStart, 'yyyy-mm-dd'), ...
    edateStr, nowLocal, runStamp);

fprintf('[%s] Cycle done. %d stations, %d newly archived rows, %d failed requests.\n', ...
    datestr(now), nSt, nArchived, nFailed);

end


function [mapVals, mapTimes] = computeMapValues(cfg, histTimes, histVals, latestTime, latestVals, windowStart)
nSt = numel(histTimes);
nP  = numel(cfg.pollutants);
mapVals  = nan(nSt, nP);
mapTimes = NaT(nSt, nP);

for p = 1:nP
    % Newest valid hour for this pollutant across all stations
    newestRef = NaT;
    for s = 1:nSt
        okp = ~isnan(histVals{s}(:, p));
        if any(okp)
            tmax = max(histTimes{s}(okp));
            if isnat(newestRef) || tmax > newestRef
                newestRef = tmax;
            end
        end
    end
    if isnat(newestRef)
        okLatest = ~isnan(latestVals(:, p)) & ~isnat(latestTime);
        if any(okLatest)
            newestRef = max(latestTime(okLatest));
        end
    end

    for s = 1:nSt
        t = histTimes{s};
        v = histVals{s}(:, p);
        if strcmpi(cfg.MAP_MODE, 'mean')
            okp = ~isnan(v) & t >= windowStart;
            if any(okp)
                mapVals(s, p)  = mean(v(okp));
                mapTimes(s, p) = max(t(okp));
            end
        else % 'latest'
            okp = ~isnan(v);
            if any(okp)
                tv = t(okp);
                vv = v(okp);
                [candTime, iMax] = max(tv);
                candVal = vv(iMax);
            elseif ~isnan(latestVals(s, p)) && ~isnat(latestTime(s))
                candVal  = latestVals(s, p);   % fall back to the AQILast snapshot
                candTime = latestTime(s);
            else
                continue;
            end
            if ~isnat(newestRef) && candTime >= newestRef - hours(cfg.STALE_HOURS)
                mapVals(s, p)  = candVal;
                mapTimes(s, p) = candTime;
            end
        end
    end
    fprintf('%-5s: %3d of %d stations with a mappable value\n', ...
        cfg.pollutants{p}, sum(~isnan(mapVals(:, p))), nSt);
end
end


function drawPcdMaps(cfg, stLat, stLon, mapVals, mapTimes, sdateStr, edateStr, nowLocal, runStamp)
% Creates the figure, saves it as PNG, then closes it.
if cfg.SHOW_FIGURE
    figVisible = 'on';
else
    figVisible = 'off';
end
fig = figure('Name', 'PCD Air4Thai - all stations', ...
    'Color', 'w', 'Position', [40 40 1500 950], 'Visible', figVisible);

nP = numel(cfg.pollutants);
hasCoords = ~isnan(stLat) & ~isnan(stLon);

for p = 1:nP
    % subplot only makes Cartesian axes, so use it for the grid position,
    % then place a geographic axes there.
    tmpAx = subplot(cfg.SUBPLOT_ROWS, cfg.SUBPLOT_COLS, p, 'Parent', fig);
    pos   = get(tmpAx, 'Position');
    delete(tmpAx);

    v      = mapVals(:, p);
    hasVal = hasCoords & ~isnan(v);
    noVal  = hasCoords & isnan(v);
    cLimP  = [0 robustMax(v(hasVal))];

    if any(hasVal)
        tUsed = mapTimes(hasVal, p);
        tUsed = tUsed(~isnat(tUsed));
        if strcmpi(cfg.MAP_MODE, 'mean')
            timeLabel = sprintf('mean %s to %s (n = %d)', sdateStr, edateStr, sum(hasVal));
        elseif isempty(tUsed) || min(tUsed) == max(tUsed)
            timeLabel = sprintf('%s LT (n = %d)', dtStr(max(tUsed)), sum(hasVal));
        else
            timeLabel = sprintf('%s to %s LT (n = %d)', ...
                datestr(min(tUsed), 'dd mmm HH:MM'), datestr(max(tUsed), 'dd mmm HH:MM'), sum(hasVal));
        end
    else
        timeLabel = 'no data';
    end
    titleStr = {sprintf('%s (%s)', cfg.pollutantLabels{p}, cfg.pollutantUnits{p}), timeLabel};

    try
        gx = geoaxes('Parent', fig, 'Position', pos);
        try
            geobasemap(gx, cfg.BASEMAP);
        catch
            geobasemap(gx, 'darkwater');
        end
        hold(gx, 'on');
        if any(noVal)
            geoscatter(gx, stLat(noVal), stLon(noVal), 12, [0.55 0.55 0.55], 'Marker', 'x');
        end
        if any(hasVal)
            geoscatter(gx, stLat(hasVal), stLon(hasVal), cfg.MARKER_SIZE, v(hasVal), ...
                'filled', 'MarkerEdgeColor', 'k', 'LineWidth', 0.3);
            colormap(gx, parula(256));
            try
                caxis(gx, cLimP);
            catch
                % geoaxes without CLim support -- auto limits instead
            end
            cb = colorbar(gx);
            cb.Label.String = cfg.pollutantUnits{p};
        end
        geolimits(gx, cfg.MAP_LAT_LIMITS, cfg.MAP_LON_LIMITS);
        title(gx, titleStr);
        hold(gx, 'off');
    catch
        ax = axes('Parent', fig, 'Position', pos);
        hold(ax, 'on');
        if any(noVal)
            scatter(ax, stLon(noVal), stLat(noVal), 12, [0.55 0.55 0.55], 'x');
        end
        if any(hasVal)
            scatter(ax, stLon(hasVal), stLat(hasVal), cfg.MARKER_SIZE, v(hasVal), ...
                'filled', 'MarkerEdgeColor', 'k', 'LineWidth', 0.3);
            colormap(ax, parula(256));
            caxis(ax, cLimP);
            cb = colorbar(ax);
            cb.Label.String = cfg.pollutantUnits{p};
        end
        xlim(ax, cfg.MAP_LON_LIMITS);
        ylim(ax, cfg.MAP_LAT_LIMITS);
        daspect(ax, [1 cosd(mean(cfg.MAP_LAT_LIMITS)) 1]);
        box(ax, 'on'); grid(ax, 'on');
        xlabel(ax, 'Longitude (\circE)');
        ylabel(ax, 'Latitude (\circN)');
        title(ax, titleStr);
        hold(ax, 'off');
    end
end

try
    %sgtitle(fig, sprintf('PCD Air4Thai, all stations (%s values; grey x = no valid data) - updated %s', ...
    %    cfg.MAP_MODE, datestr(nowLocal, 'yyyy-mm-dd HH:MM')));
catch
    % not critical
end
drawnow;

try
    saveas(fig, fullfile(cfg.outputDir, 'PCD_Maps_latest.png'));
    if cfg.SAVE_STAMPED_PNG
        saveas(fig, fullfile(cfg.outputDir, ['PCD_Maps_' runStamp '.png']));
    end
catch ME
    fprintf('Could not save figure: %s\n', ME.message);
end

% Close the figure once saved (the PNGs are the record)
if isvalid(fig)
    close(fig);
end
end


function c = toCellOfStructs(x)
% jsondecode gives a struct array when all elements share fields, and a
% cell array of structs when they don't. Normalise to cell.
if iscell(x)
    c = x(:);
elseif isstruct(x)
    c = num2cell(x(:));
else
    c = {};
end
end


function m = robustMax(v)
% ~98th percentile without the Statistics Toolbox.
v = sort(v(~isnan(v)));
if isempty(v)
    m = 1;
    return;
end
m = v(max(1, ceil(0.98 * numel(v))));
if m <= 0
    m = max(v);
end
if m <= 0
    m = 1;
end
end


function s = dtStr(t)
if isnat(t)
    s = '';
else
    s = datestr(t, 'yyyy-mm-dd HH:MM:SS');
end
end


function s = csvQuote(str)
s = ['"' strrep(char(str), '"', '""') '"'];
end


function s = numOrNaNStr(v)
if isempty(v) || isnan(v)
    s = 'NaN';
else
    s = num2str(v, '%.6g');
end
end


function val = getFieldStr(rec, name)
if isstruct(rec) && isfield(rec, name)
    v = rec.(name);
    if isnumeric(v)
        val = num2str(v);
    else
        val = char(v);
    end
else
    val = '';
end
end


function val = getFieldNumOrNull(rec, name)
% JSON null (decoded as []) or unparseable strings -> NaN.
val = NaN;
if isstruct(rec) && isfield(rec, name)
    v = rec.(name);
    if isempty(v)
        val = NaN;
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
